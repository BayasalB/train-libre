import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'chat_export_reader.dart';
import 'portable_import.dart';

enum ExtractionConfidence { high, medium, low }

/// An editable candidate, not an instruction to write to the local database.
class ChatFitnessCandidate {
  final String collection;
  final String id;
  final Map<String, Object?> fields;
  final Set<String> sourceRefs;
  final List<String> warnings;
  ExtractionConfidence confidence;
  bool included;

  ChatFitnessCandidate(this.collection, this.id, Map<String, Object?> fields,
      Iterable<String> sourceRefs, this.confidence,
      {this.included = true, List<String> warnings = const []})
      : fields = Map.of(fields),
        sourceRefs = Set.of(sourceRefs),
        warnings = List.of(warnings);

  String? get date => (fields['date'] ?? fields['effectiveFrom']) as String?;

  void addSource(String sourceRef) => sourceRefs.add(sourceRef);
}

class ChatFitnessExtraction {
  final List<ChatFitnessCandidate> candidates;
  final List<String> warnings;
  final List<String> selectedConversationIds;
  ChatFitnessExtraction(
      this.candidates, this.warnings, this.selectedConversationIds);

  /// Only selected and reviewed records enter the portable document. Removed
  /// dependencies are detached rather than leaving broken references.
  String toPortableJson() {
    final active = candidates.where((candidate) => candidate.included).toList();
    final ids = <String, Set<String>>{};
    for (final candidate in active) {
      ids.putIfAbsent(candidate.collection, () => {}).add(candidate.id);
    }
    final root = <String, Object?>{
      'formatVersion': 1,
      'metadata': {
        'source': 'Reviewed ChatGPT export fitness extraction',
        'sourceId':
            'chatgpt-${sha256.convert(utf8.encode(selectedConversationIds.join('|'))).toString().substring(0, 20)}',
        'notes':
            'Local deterministic extraction rule v1. Record IDs and notes contain source conversation/message references. No full chat text is embedded.'
      }
    };
    for (final candidate in active) {
      final fields = Map<String, Object?>.of(candidate.fields);
      fields['id'] = candidate.id;
      for (final dependency in const {
        'savedFoodId': 'savedFoods',
        'nutritionSnapshotId': 'nutritionSnapshots',
        'mealId': 'meals',
        'foodId': 'savedFoods',
        'workoutId': 'workouts',
        'exerciseId': 'exercises'
      }.entries) {
        final value = fields[dependency.key];
        if (value is String && !(ids[dependency.value] ?? {}).contains(value)) {
          fields.remove(dependency.key);
        }
      }
      if (candidate.collection == 'foodAliases' &&
              !fields.containsKey('foodId') ||
          candidate.collection == 'exercises' &&
              !fields.containsKey('workoutId') ||
          candidate.collection == 'workoutSets' &&
              !fields.containsKey('exerciseId')) {
        continue;
      }
      if (const {
        'savedFoods',
        'foodEntries',
        'meals',
        'dailyRecords',
        'workouts',
        'exercises',
        'workoutSets',
        'measurements',
        'progressPhotos'
      }.contains(candidate.collection)) {
        final refs = candidate.sourceRefs.join(',');
        final existing = (fields['notes'] as String?)?.trim();
        fields['notes'] = [
          if (existing != null && existing.isNotEmpty) existing,
          'ChatGPT refs: $refs; rule v1; confidence ${candidate.confidence.name}'
        ].join(' | ');
      }
      root.putIfAbsent(candidate.collection, () => <Map<String, Object?>>[]);
      (root[candidate.collection] as List).add(fields);
    }
    final result = PortableImportParser().validate(root);
    if (!result.isValid) {
      throw ChatPortableValidationException(result.issues);
    }
    return const JsonEncoder.withIndent('  ').convert(root);
  }
}

class ChatPortableValidationException implements Exception {
  final List<ImportIssue> issues;
  ChatPortableValidationException(this.issues);
  @override
  String toString() => issues.map((i) => '${i.path}: ${i.message}').join('\n');
}

/// Strict, local rules. Ambiguous prose is warned about, never promoted into
/// an exact log or a nutrition label. No API calls and no database imports.
class ChatFitnessAdapter {
  static const ruleVersion = 1;
  final _number = r'(\d+(?:\.\d+)?)';

  ChatFitnessExtraction extract(
      ChatExportCatalog catalog, Map<String, String?> selectedBranches) {
    final selected = catalog.conversations
        .where((conversation) => selectedBranches.containsKey(conversation.id))
        .toList();
    if (selected.isEmpty) {
      throw const ChatExportException('Select at least one conversation.');
    }
    final messages = <_SourceMessage>[];
    final warnings = <String>[...catalog.warnings];
    for (final conversation in selected) {
      warnings.addAll(conversation.warnings
          .map((warning) => '${conversation.title}: $warning'));
      if (conversation.allMessages.any((message) => RegExp(r'^\d+(?:\.\d+)?$')
          .hasMatch(message.originalTimestamp ?? ''))) {
        warnings.add(
            '${conversation.title}: Unix timestamps use the device timezone for local dates; review date boundaries.');
      }
      final branch = selectedBranches[conversation.id];
      for (final message in conversation.messagesForBranch(branch)) {
        messages.add(_SourceMessage(conversation, message));
      }
    }
    messages.sort((a, b) {
      final x = a.message.timestamp;
      final y = b.message.timestamp;
      if (x != null && y != null) {
        final compare = x.compareTo(y);
        if (compare != 0) return compare;
      } else if (x == null && y != null) {
        return 1;
      } else if (x != null && y == null) {
        return -1;
      }
      return a.message.sourceOrder.compareTo(b.message.sourceOrder);
    });
    final candidates = <ChatFitnessCandidate>[];
    final foodsByName = <String, ChatFitnessCandidate>{};
    final snapshotsByFood = <String, ChatFitnessCandidate>{};
    final aliasToFood = <String, ChatFitnessCandidate>{};
    final ambiguousAliases = <String>{};
    final entries = <ChatFitnessCandidate>[];
    final measurements = <ChatFitnessCandidate>[];
    final dayRecords = <String, ChatFitnessCandidate>{};
    _AssistantTotal? assistantTotal;
    for (final source in messages) {
      final message = source.message;
      if (message.mediaRefs.isNotEmpty) {
        warnings.add(
            '${source.ref}: ${message.mediaRefs.length} image/file reference(s); no OCR or media values extracted.');
      }
      final text = message.text.trim();
      if (text.isEmpty) continue;
      final resolution = _resolveDate(text, message.dateContext);
      final date = resolution.date;
      if (date == null) {
        warnings.add(
            '${source.ref}: no explicit date or usable message timestamp; skipped.');
        continue;
      }
      source.dateMethod = resolution.method;
      if (message.role == 'assistant') {
        final total = _reportedTotal(text);
        if (total != null) {
          if (RegExp(r'\b(?:daily total|total)\b|нийт', caseSensitive: false)
              .hasMatch(text)) {
            assistantTotal = _AssistantTotal(date, total, source.ref);
          }
          final approximate = RegExp(
                  r'\b(?:estimate|estimated|approx|restaurant|photo)\b|ойролцоо|таамаг',
                  caseSensitive: false)
              .hasMatch(text);
          final lastFood = entries
              .where((entry) =>
                  entry.date == date &&
                  entry.fields['status'] == 'consumed' &&
                  entry.fields['nutritionSnapshotId'] == null)
              .lastOrNull;
          final namedFood = lastFood == null
              ? false
              : _norm('${lastFood.fields['name']}')
                  .split(' ')
                  .where((token) => token.length >= 4 && token != 'restaurant')
                  .any((token) => _norm(text).contains(token));
          if (approximate &&
              namedFood &&
              lastFood.fields['quantityUnit'] == 'serving' &&
              ['calories', 'protein', 'carbs', 'fat']
                  .every(total.containsKey)) {
            final snapshot = ChatFitnessCandidate(
                'nutritionSnapshots',
                _id(source, 'restaurant-estimate', 0),
                {
                  'basis': 'perServing',
                  for (final key in ['calories', 'protein', 'carbs', 'fat'])
                    key: total[key],
                  'provenance': 'restaurantEstimate'
                },
                [lastFood.sourceRefs.first, source.ref],
                ExtractionConfidence.low,
                included: false,
                warnings: [
                  'Assistant restaurant/photo estimate; review before including.'
                ]);
            candidates.add(snapshot);
            lastFood.fields['nutritionSnapshotId'] = snapshot.id;
            lastFood.fields['provenance'] = 'restaurantEstimate';
            lastFood.confidence = ExtractionConfidence.low;
            lastFood.warnings
                .add('Assistant-estimated nutrition; review before including.');
          }
        }
        continue;
      }
      final lower = text.toLowerCase();
      if (assistantTotal != null) {
        final accepted = assistantTotal.date == date &&
            RegExp(r'\b(?:yes|confirm|confirmed|lock|final|zuv|tiim)\b|зөв|тийм|батал|🔒',
                    caseSensitive: false)
                .hasMatch(lower) &&
            !RegExp(r'\d+\s*(?:g|kg|kcal|rep)\b', caseSensitive: false)
                .hasMatch(lower);
        if (accepted) {
          _upsertTotal(
              dayRecords,
              candidates,
              date,
              assistantTotal.total,
              [assistantTotal.sourceRef, source.ref],
              true,
              message.timestamp,
              ExtractionConfidence.medium);
          if (message.timestamp == null) {
            warnings.add(
                '${source.ref}: final total has no message timestamp; no lock record was created.');
          }
        }
        // Only the next user message can accept an assistant total.
        assistantTotal = null;
      }
      final total = _reportedTotal(text);
      if (total != null &&
          RegExp(r'нийт|total|итог|🔒|final', caseSensitive: false)
              .hasMatch(lower)) {
        final finalDay = RegExp(r'🔒|\b(?:final|locked|lock)\b|эцсийн|батал',
                caseSensitive: false)
            .hasMatch(lower);
        _upsertTotal(dayRecords, candidates, date, total, [source.ref],
            finalDay, message.timestamp, ExtractionConfidence.high);
        if (finalDay && message.timestamp == null) {
          warnings.add(
              '${source.ref}: final total has no message timestamp; no lock record was created.');
        }
      }
      _extractDailyMetadata(source, date, dayRecords, candidates);
      _extractExactLabel(
          source, date, candidates, foodsByName, snapshotsByFood);
      _extractExplicitAlias(source, candidates, foodsByName, aliasToFood,
          ambiguousAliases, warnings);
      _extractMeasurements(source, date, candidates, measurements, warnings);
      _extractWorkout(source, date, candidates, warnings);
      _extractFood(source, date, candidates, entries, foodsByName,
          snapshotsByFood, aliasToFood, warnings);
    }
    _discrepancyWarnings(candidates, warnings);
    return ChatFitnessExtraction(candidates, warnings,
        selected.map((conversation) => conversation.id).toList());
  }

  void _upsertTotal(
      Map<String, ChatFitnessCandidate> days,
      List<ChatFitnessCandidate> candidates,
      String date,
      Map<String, Object?> total,
      List<String> refs,
      bool finalDay,
      DateTime? lockedAt,
      ExtractionConfidence confidence) {
    final day = days.putIfAbsent(date, () {
      final candidate = ChatFitnessCandidate(
          'dailyRecords', 'cg-day-$date', {'date': date}, refs, confidence);
      candidates.add(candidate);
      return candidate;
    });
    day.fields['reportedTotal'] = {
      ...total,
      'provenance': finalDay ? 'finalDailyTotal' : 'userConfirmed'
    };
    day.sourceRefs.addAll(refs);
    day.confidence = confidence;
    if (finalDay &&
        lockedAt != null &&
        !candidates
            .any((c) => c.collection == 'lockedDays' && c.date == date)) {
      candidates.add(ChatFitnessCandidate(
          'lockedDays',
          'cg-lock-$date',
          {
            'date': date,
            'lockedAt': lockedAt.toUtc().toIso8601String(),
            'provenance': 'finalDailyTotal'
          },
          refs,
          confidence));
    }
  }

  void _extractDailyMetadata(
      _SourceMessage source,
      String date,
      Map<String, ChatFitnessCandidate> days,
      List<ChatFitnessCandidate> candidates) {
    final text = source.message.text;
    final type = RegExp(
            r'\b(?:training type|training day|rest day|today training)\s*[:=-]?\s*(chest|back|shoulder|legs|arms|full body|rest)\b|\brest day\b',
            caseSensitive: false)
        .firstMatch(text);
    final note = RegExp(r'(?:^|\n)\s*(?:daily note|note)\s*[:=]\s*([^\n]+)',
            caseSensitive: false)
        .firstMatch(text);
    if (type == null && note == null) return;
    final day = days.putIfAbsent(date, () {
      final candidate = ChatFitnessCandidate('dailyRecords', 'cg-day-$date',
          {'date': date}, [source.ref], ExtractionConfidence.high);
      candidates.add(candidate);
      return candidate;
    });
    if (type != null) {
      final raw = type.group(1)?.toLowerCase() ?? 'rest';
      day.fields['trainingType'] = raw == 'full body' ? 'fullBody' : raw;
    }
    if (note != null) day.fields['notes'] = note.group(1)!.trim();
    day.addSource(source.ref);
  }

  void _extractExactLabel(
      _SourceMessage source,
      String date,
      List<ChatFitnessCandidate> candidates,
      Map<String, ChatFitnessCandidate> foods,
      Map<String, ChatFitnessCandidate> snapshots) {
    final pattern = RegExp(
        r'([^\n:=]{3,90}?)\s*(?::|=)?\s*(?:per\s*)?100\s*(g|гр|г|ml|мл)\s*[:=]\s*(\d+(?:\.\d+)?)\s*kcal\s*[,| ]*P\s*(\d+(?:\.\d+)?)\s*[,| ]*C\s*(\d+(?:\.\d+)?)\s*[,| ]*F\s*(\d+(?:\.\d+)?)',
        caseSensitive: false);
    for (final match in pattern.allMatches(source.message.text)) {
      final name = match.group(1)!.trim();
      if (name.isEmpty) continue;
      final id = _id(source, 'food', match.start);
      final snapshotId = _id(source, 'snapshot', match.start);
      final basis = {
        'g': 'per100g',
        'гр': 'per100g',
        'г': 'per100g',
        'ml': 'per100ml',
        'мл': 'per100ml'
      }[match.group(2)!.toLowerCase()]!;
      final labelEvidence =
          RegExp(r'\b(?:label|nutrition label)\b|шошго', caseSensitive: false)
              .hasMatch(source.message.text);
      final provenance = labelEvidence ? 'exactLabel' : 'userConfirmed';
      final snapshot = ChatFitnessCandidate(
          'nutritionSnapshots',
          snapshotId,
          {
            'basis': basis,
            'calories': match.group(3),
            'protein': match.group(4),
            'carbs': match.group(5),
            'fat': match.group(6),
            'provenance': provenance
          },
          [source.ref],
          ExtractionConfidence.high,
          warnings: [
            if (!labelEvidence)
              'Per-100 values are user-provided; label evidence was not explicit.'
          ]);
      final food = ChatFitnessCandidate(
          'savedFoods',
          id,
          {
            'name': name,
            'nutritionSnapshotId': snapshotId,
            'servingSize': '100',
            'servingUnit': basis == 'per100g' ? 'g' : 'ml',
            'provenance': provenance,
            'verified': labelEvidence
          },
          [source.ref],
          ExtractionConfidence.high);
      candidates.addAll([snapshot, food]);
      foods[_norm(name)] = food;
      snapshots[id] = snapshot;
    }
  }

  void _extractExplicitAlias(
      _SourceMessage source,
      List<ChatFitnessCandidate> candidates,
      Map<String, ChatFitnessCandidate> foods,
      Map<String, ChatFitnessCandidate> aliases,
      Set<String> ambiguousAliases,
      List<String> warnings) {
    final pattern = RegExp(
        r'(?:alias\s*[:=]\s*)?([\p{L}][\p{L}\d /-]{1,70})\s*(?:=|→|means|гэдэг нь)\s*([^\n,;]{3,90})',
        caseSensitive: false,
        unicode: true);
    for (final match in pattern.allMatches(source.message.text)) {
      final food = foods[_norm(match.group(2)!)];
      if (food == null) {
        continue;
      }
      final variants = match.group(1)!.split(RegExp(r'\s*/\s*'));
      for (var i = 0; i < variants.length; i++) {
        final alias = variants[i].trim();
        final key = _norm(alias);
        if (alias.isEmpty || key == _norm(food.fields['name'] as String)) {
          continue;
        }
        if (ambiguousAliases.contains(key)) continue;
        final existing = aliases[key];
        if (existing != null) {
          if (existing.id != food.id) {
            aliases.remove(key);
            ambiguousAliases.add(key);
            for (final previous in candidates.where((candidate) =>
                candidate.collection == 'foodAliases' &&
                _norm('${candidate.fields['alias']}') == key)) {
              previous.included = false;
              previous.addSource(source.ref);
              previous.warnings
                  .add('Conflicting product identity for this alias.');
            }
            warnings.add(
                '${source.ref}: alias "$alias" names multiple foods; no automatic identity mapping.');
          }
          continue;
        }
        final candidate = ChatFitnessCandidate(
            'foodAliases',
            _id(source, 'alias', match.start + i),
            {
              'foodId': food.id,
              'alias': alias,
              'language': RegExp(r'[А-Яа-яЁёӨөҮү]').hasMatch(alias)
                  ? 'mn-Cyrl'
                  : 'mn-Latn'
            },
            [source.ref],
            ExtractionConfidence.high);
        candidates.add(candidate);
        aliases[key] = food;
      }
    }
  }

  void _extractMeasurements(
      _SourceMessage source,
      String date,
      List<ChatFitnessCandidate> candidates,
      List<ChatFitnessCandidate> measurements,
      List<String> warnings) {
    final text = source.message.text;
    final types = <String, String>{
      'weight': 'weight',
      'bodyweight': 'weight',
      'жин': 'weight',
      'waist': 'waist',
      'бэлхүүс': 'waist',
      'lower belly': 'lower_belly',
      'доод гэдэс': 'lower_belly',
      'abdomen': 'abdomen',
      'гэдэс': 'abdomen',
      'chest': 'chest',
      'цээж': 'chest',
      'hips': 'hips',
      'ташаа': 'hips',
      'shoulders': 'shoulder',
      'мөр': 'shoulder',
      'body fat': 'fat_percent',
      'body-fat': 'fat_percent',
      'bodyfat': 'fat_percent',
      'neck': 'neck',
      'left bicep': 'left_bicep',
      'right bicep': 'right_bicep',
      'left forearm': 'left_forearm',
      'right forearm': 'right_forearm',
      'left thigh': 'left_thigh',
      'right thigh': 'right_thigh',
      'left calf': 'left_calf',
      'right calf': 'right_calf',
    };
    final typed = RegExp(
        r'\b(bodyweight|weight|lower belly|body fat|body-fat|bodyfat|left bicep|right bicep|left forearm|right forearm|left thigh|right thigh|left calf|right calf|waist|abdomen|chest|hips|shoulders|neck)\b|жин|бэлхүүс|доод гэдэс|гэдэс|цээж|ташаа|мөр',
        caseSensitive: false);
    for (final match in typed.allMatches(text)) {
      final type = types[match.group(0)!.toLowerCase()];
      if (type == null) continue;
      final tail = text.substring(match.end);
      final value = RegExp(r'\s*[:=]?\s*(\d+(?:\.\d+)?)\s*(kg|lb|cm|in|%)?',
              caseSensitive: false)
          .firstMatch(tail);
      if (value == null) continue;
      final unit = value.group(2)?.toLowerCase() ??
          (type == 'weight'
              ? 'kg'
              : type == 'fat_percent'
                  ? '%'
                  : 'cm');
      if (type == 'weight' && !{'kg', 'lb'}.contains(unit) ||
          type == 'fat_percent' && unit != '%' ||
          type != 'weight' &&
              type != 'fat_percent' &&
              !{'cm', 'in'}.contains(unit)) {
        continue;
      }
      final uncertain = RegExp(
              r'\b(?:bish|not|later|planned)\b|биш|дараа|хэмжинэ',
              caseSensitive: false)
          .hasMatch(text);
      final old = measurements
          .where(
              (m) => m.date == date && m.fields['type'] == type && m.included)
          .toList();
      if (uncertain) {
        for (final candidate in old) {
          candidate.included = false;
          candidate.addSource(source.ref);
          candidate.warnings.add('Later statement withdrew this measurement.');
        }
        warnings.add(
            '${source.ref}: uncertain or withdrawn $type measurement; no new value accepted.');
        continue;
      }
      for (final candidate in old) {
        candidate.included = false;
        candidate.addSource(source.ref);
        candidate.warnings.add('Superseded by a later value on the same date.');
      }
      final candidate = ChatFitnessCandidate(
          'measurements',
          _id(source, 'measurement', match.start),
          {
            'date': date,
            'type': type,
            'value': value.group(1),
            'unit': unit,
            'provenance': 'userConfirmed'
          },
          [source.ref, ...old.expand((m) => m.sourceRefs)],
          ExtractionConfidence.high);
      measurements.add(candidate);
      candidates.add(candidate);
    }
    if (!typed.hasMatch(text.trim())) {
      final standalone =
          RegExp(r'^\s*(\d{2,3}(?:\.\d+)?)\s*(kg|lb)\s*$', caseSensitive: false)
              .firstMatch(text);
      if (standalone != null) {
        final old = measurements
            .where((m) =>
                m.date == date && m.fields['type'] == 'weight' && m.included)
            .toList();
        for (final candidate in old) {
          candidate.included = false;
          candidate.addSource(source.ref);
        }
        final candidate = ChatFitnessCandidate(
            'measurements',
            _id(source, 'measurement', 0),
            {
              'date': date,
              'type': 'weight',
              'value': standalone.group(1),
              'unit': standalone.group(2)!.toLowerCase(),
              'provenance': 'userConfirmed'
            },
            [source.ref, ...old.expand((m) => m.sourceRefs)],
            ExtractionConfidence.high);
        measurements.add(candidate);
        candidates.add(candidate);
      }
    }
  }

  void _extractWorkout(_SourceMessage source, String date,
      List<ChatFitnessCandidate> candidates, List<String> warnings) {
    final text = source.message.text;
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final setPattern = RegExp(
        r'^(?:(\d+(?:\.\d+)?)\s*(kg|lb)|(?:bw|bodyweight))\s*(?:x|×)?\s*(\d+)\s*(?:rep|reps|давталт|steps?)?\s*(?:[x×]\s*(\d+)|\s+(\d+)\s*sets?)?\s*(.*)$',
        caseSensitive: false);
    if (!lines.any((line) => setPattern.hasMatch(line))) {
      final cardio = RegExp(r'\b(cardio|run|walk|cycling|treadmill)\b|алх|гүй',
              caseSensitive: false)
          .hasMatch(text);
      if (!cardio) return;
      final duration = RegExp(
              r'(?:duration|хугацаа)\s*[:=]?\s*(\d+(?:\.\d+)?)\s*(min|minutes|sec|seconds)',
              caseSensitive: false)
          .firstMatch(text);
      final notes = <String>[];
      for (final metric in [
        'active calories',
        'total calories',
        'average heart rate',
        'distance',
        'cadence',
        'hr zones',
        'segments'
      ]) {
        final match = RegExp('${RegExp.escape(metric)}\\s*[:=]?\\s*([^\\n,;]+)',
                caseSensitive: false)
            .firstMatch(text);
        if (match != null) notes.add('$metric: ${match.group(1)!.trim()}');
      }
      if (duration == null && notes.isEmpty) return;
      candidates.add(ChatFitnessCandidate(
          'workouts',
          _id(source, 'cardio', 0),
          {
            'date': date,
            'name': 'Cardio',
            'notes': notes.join('; '),
            if (duration != null)
              'durationSeconds': (double.parse(duration.group(1)!) *
                      (duration.group(2)!.toLowerCase().startsWith('min')
                          ? 60
                          : 1))
                  .toString(),
            'provenance': 'userConfirmed'
          },
          [source.ref],
          ExtractionConfidence.medium,
          warnings: [
            'Only explicitly written wearable metrics were retained in notes.'
          ]));
      return;
    }
    final workout = ChatFitnessCandidate(
        'workouts',
        _id(source, 'workout', 0),
        {
          'date': date,
          'name': 'Historical workout',
          'provenance': 'userConfirmed'
        },
        [source.ref],
        ExtractionConfidence.high);
    final duration = RegExp(
            r'(?:duration|хугацаа)\s*[:=]?\s*(\d+(?:\.\d+)?)\s*(min|minutes|sec|seconds)',
            caseSensitive: false)
        .firstMatch(text);
    if (duration != null) {
      workout.fields['durationSeconds'] = (double.parse(duration.group(1)!) *
              (duration.group(2)!.toLowerCase().startsWith('min') ? 60 : 1))
          .toString();
    }
    candidates.add(workout);
    ChatFitnessCandidate? exercise;
    var setIndex = 0;
    final unmodelled = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final set = setPattern.firstMatch(line);
      if (set != null) {
        if (exercise == null) {
          warnings.add(
              '${source.ref}: set without exercise name retained for review.');
          exercise = ChatFitnessCandidate(
              'exercises',
              _id(source, 'exercise', i),
              {
                'workoutId': workout.id,
                'name': 'Unknown exercise',
                'notes': 'Exercise name missing in export.'
              },
              [source.ref],
              ExtractionConfidence.low,
              included: false);
          candidates.add(exercise);
        }
        final weight = set.group(1);
        final extra = set.group(6)?.trim();
        final repeated = set.group(4) ??
            set.group(5) ??
            RegExp(r'(?:[x×]\s*)?(\d+)\s*sets?\b', caseSensitive: false)
                .firstMatch(line)
                ?.group(1);
        candidates.add(ChatFitnessCandidate(
            'workoutSets',
            _id(source, 'set', setIndex++),
            {
              'exerciseId': exercise.id,
              if (weight != null) 'weight': weight,
              if (weight != null) 'weightUnit': set.group(2)!.toLowerCase(),
              'reps': int.parse(set.group(3)!),
              if (repeated != null) 'setCount': int.parse(repeated),
              if (weight == null || extra != null && extra.isNotEmpty)
                'notes': [
                  if (weight == null) 'Bodyweight',
                  if (extra != null && extra.isNotEmpty) extra
                ].join('; '),
              'provenance': 'userConfirmed'
            },
            [source.ref],
            exercise.included
                ? ExtractionConfidence.high
                : ExtractionConfidence.low,
            included: exercise.included));
      } else if (i + 1 < lines.length &&
          setPattern.hasMatch(lines[i + 1]) &&
          line.length < 80 &&
          !RegExp(r'\bkcal\b|\btotal\b|нийт', caseSensitive: false)
              .hasMatch(line)) {
        exercise = ChatFitnessCandidate(
            'exercises',
            _id(source, 'exercise', i),
            {'workoutId': workout.id, 'name': line},
            [source.ref],
            ExtractionConfidence.high);
        candidates.add(exercise);
      } else if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(line) &&
          RegExp(r'\b(?:drop set|steps|rpe|rir|cardio|duration|workout|training|reps|heart rate|lunges)\b|дасгал|алх|давталт',
                  caseSensitive: false)
              .hasMatch(line)) {
        unmodelled.add(line.length > 120 ? '${line.substring(0, 120)}…' : line);
      }
    }
    if (unmodelled.isNotEmpty) {
      workout.fields['notes'] = unmodelled.take(8).join('; ');
    }
    if (!candidates.any((c) =>
        c.collection == 'workoutSets' &&
        (c.fields['exerciseId'] as String?)?.startsWith('cg-') == true &&
        c.sourceRefs.contains(source.ref))) {
      workout.included = false;
    }
  }

  void _extractFood(
      _SourceMessage source,
      String date,
      List<ChatFitnessCandidate> candidates,
      List<ChatFitnessCandidate> entries,
      Map<String, ChatFitnessCandidate> foods,
      Map<String, ChatFitnessCandidate> snapshots,
      Map<String, ChatFitnessCandidate> aliases,
      List<String> warnings) {
    final text = source.message.text;
    final portion = RegExp(
            r'\b(?:ate|consumed|idsen)\s+(?:(?:about|approximately|approx\.?)\s+)?(\d+(?:\.\d+)?)\s*%\s*(?:of\s*)?(?:that\s*)?(.+)',
            caseSensitive: false)
        .firstMatch(text);
    if (portion != null) {
      final percent = double.tryParse(portion.group(1)!);
      final hint = _norm(portion.group(2)!);
      final matches = entries
          .where((entry) =>
              entry.date == date &&
              !entry.included &&
              entry.warnings.any((w) => w.contains('Raw/uncooked weight')) &&
              hint.contains(_norm('${entry.fields['name']}')))
          .toList();
      if (percent != null &&
          percent > 0 &&
          percent <= 100 &&
          matches.length == 1) {
        final entry = matches.single;
        final raw = double.tryParse('${entry.fields['quantity']}');
        if (raw != null && raw.isFinite) {
          entry.fields['quantity'] = (raw * percent / 100).toString();
          entry.addSource(source.ref);
          entry.warnings.add(
              'Raw-weight portion derived from an explicit percentage; verify the edible quantity and nutrition before including.');
          return;
        }
      }
      warnings.add(
          '${source.ref}: percentage portion cannot be tied to one raw-weight food; review manually.');
      return;
    }
    final rawWeightCorrection =
        RegExp(r'\b(?:tuuhii|raw weight|uncooked)\b', caseSensitive: false)
            .hasMatch(text);
    if (RegExp(r'\bkcal\b|\b(?:rep|reps|sets?)\b|\b(?:waist|chest|weight)\b',
                caseSensitive: false)
            .hasMatch(text) &&
        !rawWeightCorrection &&
        !RegExp(r'\b(?:idsen|idlee|uusan|eaten|drank|consumed|beldsen)\b|идсэн|идлээ|уусан|бэлдсэн',
                caseSensitive: false)
            .hasMatch(text)) {
      return;
    }
    final segments = text.split(RegExp(r'[,;\n]+'));
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i].trim();
      final lower = segment.toLowerCase();
      if (RegExp(r'\b(?:tuuhii|raw weight|uncooked)\b|түүхий',
              caseSensitive: false)
          .hasMatch(lower)) {
        final amount = RegExp(r'(\d+(?:\.\d+)?)\s*(?:g|гр|г)(?=\s|$)',
                caseSensitive: false)
            .firstMatch(segment)
            ?.group(1);
        final matches = entries
            .where((entry) =>
                entry.date == date &&
                entry.included &&
                entry.fields['quantity'] == amount)
            .toList();
        if (matches.length == 1) {
          final entry = matches.single;
          entry.included = false;
          entry.confidence = ExtractionConfidence.low;
          entry.addSource(source.ref);
          entry.warnings.add(
              'Raw/uncooked weight correction requires manual nutrition review.');
        } else {
          warnings.add(
              '${source.ref}: raw-weight statement cannot be tied to one food; review manually.');
        }
        continue;
      }
      final bareCorrection = RegExp(
              r'^\s*(\d+(?:\.\d+)?)\s*(g|ml)\s*(?:bsn|baisan)\s*$',
              caseSensitive: false)
          .firstMatch(segment);
      if (bareCorrection != null) {
        final matches = entries
            .where((entry) =>
                entry.date == date &&
                entry.included &&
                entry.fields['quantityUnit'] ==
                    bareCorrection.group(2)!.toLowerCase())
            .toList();
        if (matches.length == 1) {
          final entry = matches.single;
          entry.fields['quantity'] = bareCorrection.group(1)!;
          entry.addSource(source.ref);
          entry.warnings.add('Quantity corrected by later user message.');
        } else {
          warnings.add(
              '${source.ref}: bare quantity correction has ${matches.length} possible foods; review manually.');
        }
        continue;
      }
      final correction = RegExp(
              r'^\s*(\d+(?:\.\d+)?)\s*(g|гр|г|ml|мл)\s*(?:bish|биш|not)\s*(\d+(?:\.\d+)?)\s*(g|гр|г|ml|мл)?\s*(.*)$',
              caseSensitive: false)
          .firstMatch(segment);
      if (correction != null) {
        String unit(String text) =>
            {'гр': 'g', 'г': 'g', 'мл': 'ml'}[text.toLowerCase()] ??
            text.toLowerCase();
        final oldUnit = unit(correction.group(2)!);
        final newUnit =
            correction.group(4) == null ? oldUnit : unit(correction.group(4)!);
        final hint = _norm(correction.group(5) ?? '');
        final hintedFood = foods[hint] ?? aliases[hint];
        final matches = entries
            .where((entry) =>
                entry.date == date &&
                entry.included &&
                entry.fields['quantity'] == correction.group(1) &&
                entry.fields['quantityUnit'] == oldUnit &&
                (hint.isEmpty ||
                    _norm('${entry.fields['name']}').contains(hint) ||
                    hintedFood?.id == entry.fields['savedFoodId']))
            .toList();
        if (oldUnit == newUnit && matches.length == 1) {
          final entry = matches.single;
          entry.fields['quantity'] = correction.group(3)!;
          entry.addSource(source.ref);
          entry.warnings.add('Quantity corrected by later user message.');
        } else {
          warnings.add(
              '${source.ref}: quantity correction is ambiguous or changes unit; review manually.');
        }
        continue;
      }
      final cancelled = RegExp(
              r'\b(?:boliloo|ideegui|cancelled|canceled|didn.t eat|don.t add)\b|боли\w*|идээгүй',
              caseSensitive: false)
          .hasMatch(lower);
      final planned = RegExp(
              r'\b(?:beldsen|planned|planning|will eat|ideh gej baina)\b|бэлдсэн|идэх гэж байна',
              caseSensitive: false)
          .hasMatch(lower);
      final consumed = RegExp(
              r'\b(?:idsen|idlee|uusan|eaten|ate|drank|consumed|idchihlee)\b|идсэн|идлээ|уусан|идчихлээ',
              caseSensitive: false)
          .hasMatch(lower);
      if (cancelled ||
          consumed &&
              !RegExp(r'\d+\s*(?:g|гр|г|ml|мл|serving)', caseSensitive: false)
                  .hasMatch(segment)) {
        final match = _findMatchingEntry(segment, date, entries);
        if (match != null) {
          match.fields['status'] = cancelled ? 'cancelled' : 'consumed';
          match.addSource(source.ref);
          match.warnings.add(cancelled
              ? 'Cancelled by later user message.'
              : 'Planned item confirmed consumed later.');
        } else {
          warnings.add(
              '${source.ref}: ${cancelled ? 'cancellation' : 'confirmation'} could not be linked to a prior food; review manually.');
        }
        continue;
      }
      final qty = RegExp(
              r'^\s*(?:(?:today|yesterday|өнөөдөр|өчигдөр|20\d{2}-\d{1,2}-\d{1,2})\s+)?(\d+(?:\.\d+)?)\s*(g|гр|г|ml|мл|servings?)(?=\s|$)\s*(.+)',
              caseSensitive: false)
          .firstMatch(segment);
      final trailingQty = qty == null
          ? RegExp(
                  r'^\s*(.+?)\s+(\d+(?:\.\d+)?)\s*(g|гр|г|ml|мл|servings?)(?=\s|$)',
                  caseSensitive: false)
              .firstMatch(segment)
          : null;
      if (qty == null && trailingQty == null) {
        if (RegExp(r'^[\p{L}][\p{L}\s-]{2,80}\s+\d+(?:\.\d+)?$', unicode: true)
            .hasMatch(segment)) {
          warnings.add(
              '${source.ref}: product count has no serving unit or consumed/planned state; review manually.');
        }
        continue;
      }
      if (!planned && !consumed) {
        warnings.add(
            '${source.ref}: quantity statement has no clear consumed/planned verb; candidate excluded by default.');
      }
      final quantity = qty?.group(1) ?? trailingQty!.group(2)!;
      final unit = {
            'гр': 'g',
            'г': 'g',
            'мл': 'ml',
            'servings': 'serving'
          }[(qty?.group(2) ?? trailingQty!.group(3)!).toLowerCase()] ??
          (qty?.group(2) ?? trailingQty!.group(3)!).toLowerCase();
      var name = (qty?.group(3) ?? trailingQty!.group(1)!)
          .replaceAll(
              RegExp(
                  r'\b(?:idsen|idlee|uusan|eaten|ate|drank|consumed|beldsen|planned|idchihlee)\b|идсэн|идлээ|уусан|бэлдсэн|идчихлээ',
                  caseSensitive: false),
              '')
          .trim();
      name = name.replaceAll(RegExp(r'[.!?]+$'), '').trim();
      if (name.isEmpty ||
          name.length > 90 ||
          {'dahiad', 'again', 'more', 'дахин', 'нэмж'}.contains(_norm(name))) {
        warnings.add(
            '${source.ref}: quantity without a trustworthy food identity; skipped.');
        continue;
      }
      final food = foods[_norm(name)] ?? aliases[_norm(name)];
      final snapshot = food == null ? null : snapshots[food.id];
      final compatible = snapshot != null &&
          ({
                'per100g': 'g',
                'per100ml': 'ml',
                'perServing': 'serving'
              }[snapshot.fields['basis']] ==
              unit);
      final confidence = consumed || planned
          ? ExtractionConfidence.high
          : ExtractionConfidence.low;
      final candidate = ChatFitnessCandidate(
          'foodEntries',
          _id(source, 'entry', i),
          {
            'date': date,
            'name': food?.fields['name'] ?? name,
            'status': cancelled
                ? 'cancelled'
                : planned
                    ? 'planned'
                    : 'consumed',
            'quantity': quantity,
            'quantityUnit': unit,
            if (food != null) 'savedFoodId': food.id,
            if (compatible) 'nutritionSnapshotId': snapshot.id,
            'provenance': 'userConfirmed'
          },
          [source.ref],
          confidence,
          included: confidence != ExtractionConfidence.low,
          warnings: [
            if (snapshot == null || !compatible)
              'No matching exact nutrition snapshot; entry will not become a calculated log.',
            if (confidence == ExtractionConfidence.low)
              'Consumption state is uncertain.'
          ]);
      entries.add(candidate);
      candidates.add(candidate);
    }
  }

  ChatFitnessCandidate? _findMatchingEntry(
      String statement, String date, List<ChatFitnessCandidate> entries) {
    final norm = _norm(statement);
    for (final entry in entries.reversed) {
      if (entry.date != date || entry.fields['status'] == 'cancelled') continue;
      final name = _norm(entry.fields['name'] as String);
      if (name.length < 3) continue;
      if (norm.contains(name) ||
          name
              .split(' ')
              .any((token) => token.length >= 4 && norm.contains(token)) ||
          name.contains('whey') &&
              RegExp(r'uurag|uurgaa|уураг|уургаа').hasMatch(norm)) {
        return entry;
      }
    }
    return null;
  }

  void _discrepancyWarnings(
      List<ChatFitnessCandidate> candidates, List<String> warnings) {
    final snapshots = {
      for (final c
          in candidates.where((c) => c.collection == 'nutritionSnapshots'))
        c.id: c
    };
    for (final day in candidates.where((c) =>
        c.collection == 'dailyRecords' && c.fields['reportedTotal'] is Map)) {
      var calculated = 0.0;
      var count = 0;
      for (final entry in candidates.where((c) =>
          c.collection == 'foodEntries' &&
          c.included &&
          c.date == day.date &&
          c.fields['status'] == 'consumed')) {
        final snapshot = snapshots[entry.fields['nutritionSnapshotId']];
        if (snapshot == null || snapshot.fields['calories'] == null) continue;
        calculated += double.parse('${snapshot.fields['calories']}') *
            double.parse('${entry.fields['quantity']}') /
            (snapshot.fields['basis'] == 'perServing' ? 1 : 100);
        count++;
      }
      final reported = (day.fields['reportedTotal'] as Map)['calories'];
      if (count > 0 &&
          reported is String &&
          (calculated - double.parse(reported)).abs() > 0.01) {
        warnings.add(
            '${day.date}: calculated ${calculated.toStringAsFixed(1)} kcal from $count known entries differs from reported $reported kcal; both remain separate.');
      }
    }
  }

  Map<String, Object?>? _reportedTotal(String text) {
    final kcal =
        RegExp('$_number\\s*kcal', caseSensitive: false).firstMatch(text);
    if (kcal == null) return null;
    final total = <String, Object?>{'calories': kcal.group(1)!};
    for (final key in ['P', 'C', 'F']) {
      final match = RegExp('\\b$key\\s*[:=]?\\s*$_number', caseSensitive: false)
          .firstMatch(text);
      if (match != null) {
        total[{'P': 'protein', 'C': 'carbs', 'F': 'fat'}[key]!] =
            match.group(1)!;
      }
    }
    return total;
  }

  _DateResolution _resolveDate(String text, DateTime? timestamp) {
    final explicit =
        RegExp(r'\b(20\d{2})-(\d{1,2})-(\d{1,2})\b').firstMatch(text);
    if (explicit != null) {
      final date = _validDate(int.parse(explicit.group(1)!),
          int.parse(explicit.group(2)!), int.parse(explicit.group(3)!));
      if (date != null) return _DateResolution(date, 'explicit YYYY-MM-DD');
    }
    final monthDay =
        RegExp(r'\b(\d{1,2})/(\d{1,2})(?:/(20\d{2}))?\b').firstMatch(text);
    if (monthDay != null && (timestamp != null || monthDay.group(3) != null)) {
      final date = _validDate(
          int.parse(monthDay.group(3) ?? '${timestamp!.year}'),
          int.parse(monthDay.group(1)!),
          int.parse(monthDay.group(2)!));
      if (date != null) return _DateResolution(date, 'explicit month/day');
    }
    if (timestamp == null) {
      return const _DateResolution(null, 'missing timestamp');
    }
    final lower = text.toLowerCase();
    var day = DateTime(timestamp.year, timestamp.month, timestamp.day);
    if (RegExp(r'\b(?:day before yesterday|urchigdur)\b|уржигдар')
        .hasMatch(lower)) {
      day = day.subtract(const Duration(days: 2));
    } else if (RegExp(r'\b(?:yesterday|uchigdur)\b|өчигдөр').hasMatch(lower)) {
      day = day.subtract(const Duration(days: 1));
    }
    return _DateResolution(
        _formatDate(day),
        RegExp(r'\b(?:yesterday|uchigdur|urchigdur|today)\b|өчигдөр|уржигдар|өнөөдөр')
                .hasMatch(lower)
            ? 'relative to message timestamp'
            : 'message local date');
  }
}

class _SourceMessage {
  final ChatConversation conversation;
  final ChatMessage message;
  String? dateMethod;
  _SourceMessage(this.conversation, this.message);
  String get ref =>
      '${conversation.id}/${message.id}@${message.originalTimestamp ?? 'no-time'}#${dateMethod ?? 'unresolved'}';
}

class _DateResolution {
  final String? date;
  final String method;
  const _DateResolution(this.date, this.method);
}

class _AssistantTotal {
  final String date;
  final Map<String, Object?> total;
  final String sourceRef;
  _AssistantTotal(this.date, this.total, this.sourceRef);
}

String _id(_SourceMessage source, String kind, int index) {
  final raw = '${source.conversation.id}|${source.message.id}|$kind|$index';
  return 'cg-${sha256.convert(utf8.encode(raw)).toString().substring(0, 24)}-$kind';
}

String _norm(String text) => text
    .toLowerCase()
    .trim()
    .replaceAll('uurgaa', 'uurag')
    .replaceAll('уургаа', 'уураг')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'[.!?]+$'), '');

String? _validDate(int year, int month, int day) {
  if (year < 1900 ||
      year > 2100 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > 31) {
    return null;
  }
  final date = DateTime(year, month, day);
  return date.year == year && date.month == month && date.day == day
      ? _formatDate(date)
      : null;
}

String _formatDate(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
