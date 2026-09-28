import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/chat_export_reader.dart';
import '../domain/chat_fitness_adapter.dart';
import 'historical_import_screen.dart';

Future<ChatExportCatalog> _parseChatExport(String filePath) async {
  final file = File(filePath);
  if (await file.length() > ChatExportReader.maxInputBytes) {
    throw const ChatExportException(
        'Export is too large for on-device review.');
  }
  return ChatExportReader()
      .read(path.basename(filePath), await file.readAsBytes());
}

Future<ChatExportCatalog> _parseChatExportFiles(List<String> filePaths) async {
  if (filePaths.length == 1) return _parseChatExport(filePaths.single);
  final files = <String, Uint8List>{};
  var total = 0;
  for (final filePath in filePaths) {
    if (!filePath.toLowerCase().endsWith('.json')) {
      throw const ChatExportException(
          'Select one ZIP, or multiple unzipped conversation JSON files.');
    }
    final file = File(filePath);
    final size = await file.length();
    if (size > ChatExportReader.maxJsonBytes ||
        total + size > ChatExportReader.maxTotalJsonBytes) {
      throw const ChatExportException(
          'Conversation JSON exceeds the on-device size limit.');
    }
    total += size;
    files[filePath] = await file.readAsBytes();
  }
  return ChatExportReader().readMany(files);
}

class _ExtractionRequest {
  final ChatExportCatalog catalog;
  final Map<String, String?> branches;
  _ExtractionRequest(this.catalog, this.branches);
}

ChatFitnessExtraction _extractSelected(_ExtractionRequest request) =>
    ChatFitnessAdapter().extract(request.catalog, request.branches);

/// Local-only adapter. The only route to a database write is the existing
/// Phase 3B review screen, after portable v1 validation and its own confirmation.
class ChatGptExportAdapterScreen extends StatefulWidget {
  const ChatGptExportAdapterScreen({super.key});

  @override
  State<ChatGptExportAdapterScreen> createState() =>
      _ChatGptExportAdapterScreenState();
}

class _ChatGptExportAdapterScreenState
    extends State<ChatGptExportAdapterScreen> {
  ChatExportCatalog? _catalog;
  ChatFitnessExtraction? _extraction;
  final Map<String, String?> _selectedBranches = {};
  String _search = '';
  String? _portableJson;
  String? _error;
  bool _busy = false;

  Future<void> _pickExport() async {
    final selected = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'json']);
    if (selected.isEmpty || selected.any((file) => file.path == null)) return;
    setState(() {
      _busy = true;
      _error = null;
      _catalog = null;
      _extraction = null;
      _portableJson = null;
      _selectedBranches.clear();
    });
    try {
      final catalog = await compute(
          _parseChatExportFiles, selected.map((file) => file.path!).toList());
      if (mounted) setState(() => _catalog = catalog);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _extract() async {
    final catalog = _catalog;
    if (catalog == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _portableJson = null;
    });
    try {
      final result = await compute(_extractSelected,
          _ExtractionRequest(catalog, Map.of(_selectedBranches)));
      if (mounted) setState(() => _extraction = result);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _invalidate() => setState(() => _portableJson = null);

  void _generate() {
    try {
      final json = _extraction!.toPortableJson();
      setState(() {
        _portableJson = json;
        _error = null;
      });
    } on ChatPortableValidationException catch (error) {
      setState(() {
        _portableJson = null;
        _error = 'Portable v1 validation failed:\n$error';
      });
    } catch (error) {
      setState(() {
        _portableJson = null;
        _error = '$error';
      });
    }
  }

  Future<void> _saveToFiles() async {
    final json = _portableJson;
    if (json == null) return;
    File? temporary;
    try {
      final directory = await getTemporaryDirectory();
      temporary = File(path.join(directory.path,
          'train-libre-reviewed-chatgpt-${DateTime.now().millisecondsSinceEpoch}.json'));
      await temporary.writeAsString(json, flush: true);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(temporary.path, mimeType: 'application/json')],
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not share portable JSON: $error');
      }
    } finally {
      try {
        await temporary?.delete();
      } catch (_) {
        // The share result has priority; the OS can prune its temp directory.
      }
    }
  }

  void _handoff() {
    final json = _portableJson;
    if (json == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HistoricalImportScreen(initialJson: json),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    final extraction = _extraction;
    return Scaffold(
      appBar: AppBar(title: const Text('ChatGPT fitness history')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
            'Local conversion only. Select fitness chats, review every extracted record, then generate portable JSON v1. Images are not read.'),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _pickExport,
          icon: const Icon(Icons.folder_open),
          label: const Text('Select ChatGPT ZIP or conversation JSON files'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Card(
              child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          )),
        if (catalog != null) ...[
          const SizedBox(height: 16),
          Text('${catalog.conversations.length} conversations discovered',
              style: Theme.of(context).textTheme.titleLarge),
          Text('Files: ${catalog.detectedFiles.take(8).join(', ')}'),
          for (final warning in catalog.warnings.take(20)) Text('⚠ $warning'),
          TextField(
            decoration: const InputDecoration(
                labelText: 'Search titles or message content'),
            onChanged: (value) => setState(() => _search = value),
          ),
          for (final conversation in catalog.search(_search)) ...[
            CheckboxListTile(
              value: _selectedBranches.containsKey(conversation.id),
              title: Text(conversation.title),
              subtitle: Text(
                  '${conversation.approximateMessageCount} messages · '
                  '${_date(conversation.firstMessageAt)} – ${_date(conversation.lastMessageAt)} · ${conversation.id}'),
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                        _extraction = null;
                        _portableJson = null;
                        if (value == true) {
                          _selectedBranches[conversation.id] =
                              conversation.activeBranch;
                        } else {
                          _selectedBranches.remove(conversation.id);
                        }
                      }),
            ),
            if (_selectedBranches.containsKey(conversation.id) &&
                conversation.branches.length > 1)
              Padding(
                  padding: const EdgeInsets.only(left: 16, right: 16),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('branch-${conversation.id}'),
                    initialValue: _selectedBranches[conversation.id],
                    decoration:
                        const InputDecoration(labelText: 'Conversation branch'),
                    hint: const Text('Choose branch'),
                    items: [
                      for (final branch in conversation.branches.entries)
                        DropdownMenuItem(
                            value: branch.key,
                            child: Text(
                                '${branch.key} (${branch.value.length} messages)',
                                overflow: TextOverflow.ellipsis))
                    ],
                    onChanged: (value) => setState(() {
                      _selectedBranches[conversation.id] = value;
                      _extraction = null;
                      _portableJson = null;
                    }),
                  )),
            for (final warning in conversation.warnings)
              Text('⚠ ${conversation.title}: $warning'),
          ],
          FilledButton(
            onPressed: _busy || _selectedBranches.isEmpty ? null : _extract,
            child: const Text('Extract selected conversations'),
          ),
        ],
        if (extraction != null) ...[
          const SizedBox(height: 16),
          Text('Extraction review',
              style: Theme.of(context).textTheme.titleLarge),
          Text(
              '${extraction.candidates.length} candidates · ${extraction.candidates.where((c) => c.included).length} included'),
          for (final warning in extraction.warnings.take(50))
            Text('⚠ $warning'),
          if (extraction.warnings.length > 50)
            Text('${extraction.warnings.length - 50} more warnings'),
          for (final group in _groups(extraction).entries)
            ExpansionTile(
              title: Text('${group.key} (${group.value.length})'),
              subtitle: group.key == 'Saved foods / undated'
                  ? null
                  : Text(_daySummary(group.key, extraction)),
              children: [
                for (final candidate in group.value)
                  _candidateEditor(candidate, extraction)
              ],
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _generate,
            child: const Text('Generate and validate portable JSON v1'),
          ),
          if (_portableJson != null) ...[
            Text(
                'Validated portable JSON ready (${_portableJson!.length} characters).'),
            OutlinedButton.icon(
              onPressed: _saveToFiles,
              icon: const Icon(Icons.save_alt),
              label: const Text('Save to Files'),
            ),
            FilledButton.icon(
              onPressed: _handoff,
              icon: const Icon(Icons.preview),
              label: const Text('Review in historical importer'),
            ),
          ],
        ],
      ]),
    );
  }

  Map<String, List<ChatFitnessCandidate>> _groups(
      ChatFitnessExtraction extraction) {
    final groups = <String, List<ChatFitnessCandidate>>{};
    for (final candidate in extraction.candidates) {
      (groups[candidate.date ?? 'Saved foods / undated'] ??= []).add(candidate);
    }
    return Map.fromEntries(
        groups.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  String _daySummary(String date, ChatFitnessExtraction extraction) {
    final snapshots = {
      for (final candidate in extraction.candidates.where((candidate) =>
          candidate.collection == 'nutritionSnapshots' && candidate.included))
        candidate.id: candidate
    };
    final totals = <String, double>{
      'calories': 0,
      'protein': 0,
      'carbs': 0,
      'fat': 0
    };
    var known = 0;
    for (final entry in extraction.candidates.where((candidate) =>
        candidate.collection == 'foodEntries' &&
        candidate.included &&
        candidate.date == date &&
        candidate.fields['status'] == 'consumed')) {
      final snapshot = snapshots[entry.fields['nutritionSnapshotId']];
      final quantity = double.tryParse('${entry.fields['quantity']}');
      if (snapshot == null || quantity == null || !quantity.isFinite) continue;
      final nutrients = <String, double>{};
      for (final key in totals.keys) {
        final value = double.tryParse('${snapshot.fields[key]}');
        if (value == null || !value.isFinite) break;
        nutrients[key] = value;
      }
      if (nutrients.length != totals.length) continue;
      final scale =
          quantity / (snapshot.fields['basis'] == 'perServing' ? 1 : 100);
      for (final key in totals.keys) {
        totals[key] = totals[key]! + nutrients[key]! * scale;
      }
      known++;
    }
    final reported = extraction.candidates.where((candidate) =>
        candidate.collection == 'dailyRecords' &&
        candidate.included &&
        candidate.date == date &&
        candidate.fields['reportedTotal'] is Map);
    return [
      if (known > 0)
        'Calculated from $known known foods: ${totals['calories']!.toStringAsFixed(1)} kcal · P ${totals['protein']!.toStringAsFixed(1)} · C ${totals['carbs']!.toStringAsFixed(1)} · F ${totals['fat']!.toStringAsFixed(1)}',
      for (final day in reported)
        'Reported historical total: ${(day.fields['reportedTotal'] as Map)['calories'] ?? '—'} kcal',
      if (known == 0 && reported.isEmpty) 'No known nutrition total'
    ].join('\n');
  }

  String _candidateSummary(ChatFitnessCandidate candidate) {
    final fields = candidate.fields;
    switch (candidate.collection) {
      case 'foodEntries':
        return '${fields['status']} · ${fields['quantity'] ?? 'unknown quantity'} ${fields['quantityUnit'] ?? ''} · ${fields['nutritionSnapshotId'] == null ? 'nutrition unknown' : 'snapshot available'}';
      case 'nutritionSnapshots':
        return '${fields['basis']} · ${fields['calories'] ?? '—'} kcal · P ${fields['protein'] ?? '—'} · C ${fields['carbs'] ?? '—'} · F ${fields['fat'] ?? '—'}';
      case 'dailyRecords':
        final reported = fields['reportedTotal'];
        return 'Training: ${fields['trainingType'] ?? 'unset'} · ${reported is Map ? 'reported ${reported['calories'] ?? '—'} kcal, P ${reported['protein'] ?? '—'}, C ${reported['carbs'] ?? '—'}, F ${reported['fat'] ?? '—'}' : 'no reported total'}';
      case 'workouts':
        return 'Duration: ${fields['durationSeconds'] ?? 'unknown'} sec · ${fields['notes'] ?? 'no notes'}';
      case 'workoutSets':
        return '${fields['weight'] ?? 'bodyweight'} ${fields['weightUnit'] ?? ''} × ${fields['reps'] ?? 'unknown reps'}${fields['setCount'] == null ? '' : ' × ${fields['setCount']} sets'}';
      case 'measurements':
        return '${fields['type']}: ${fields['value']} ${fields['unit']}';
      case 'lockedDays':
        return 'Final / locked at ${fields['lockedAt']}';
      case 'foodAliases':
        return 'Alias ${fields['alias']} → saved food ${fields['foodId']}';
      default:
        return 'Provenance: ${fields['provenance'] ?? 'not specified'}';
    }
  }

  Widget _candidateEditor(
      ChatFitnessCandidate candidate, ChatFitnessExtraction extraction) {
    final title = '${candidate.collection}: '
        '${candidate.fields['name'] ?? candidate.fields['type'] ?? candidate.id}';
    final foods = extraction.candidates
        .where((c) => c.collection == 'savedFoods')
        .toList();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(title),
              subtitle: Text(
                  'Confidence: ${candidate.confidence.name} · ${candidate.sourceRefs.join(', ')}'),
              value: candidate.included,
              onChanged: (value) {
                candidate.included = value ?? false;
                _invalidate();
              },
            ),
            Text(_candidateSummary(candidate)),
            for (final warning in candidate.warnings) Text('⚠ $warning'),
            if (candidate.date != null)
              TextFormField(
                key: ValueKey('${candidate.id}-date'),
                initialValue: candidate.date,
                decoration:
                    const InputDecoration(labelText: 'Local date YYYY-MM-DD'),
                onChanged: (value) {
                  candidate.fields[candidate.fields.containsKey('effectiveFrom')
                      ? 'effectiveFrom'
                      : 'date'] = value;
                  _invalidate();
                },
              ),
            if (candidate.fields['quantity'] != null)
              TextFormField(
                key: ValueKey('${candidate.id}-quantity'),
                initialValue: '${candidate.fields['quantity']}',
                decoration: InputDecoration(
                    labelText:
                        'Quantity (${candidate.fields['quantityUnit']})'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (value) {
                  candidate.fields['quantity'] = value;
                  _invalidate();
                },
              ),
            if (candidate.fields['name'] != null)
              TextFormField(
                key: ValueKey('${candidate.id}-name'),
                initialValue: '${candidate.fields['name']}',
                decoration: const InputDecoration(labelText: 'Name / identity'),
                onChanged: (value) {
                  candidate.fields['name'] = value;
                  _invalidate();
                },
              ),
            if (candidate.fields['notes'] is String)
              TextFormField(
                key: ValueKey('${candidate.id}-notes'),
                initialValue: '${candidate.fields['notes']}',
                decoration: const InputDecoration(labelText: 'Notes'),
                maxLines: 2,
                onChanged: (value) {
                  candidate.fields['notes'] = value;
                  _invalidate();
                },
              ),
            if (candidate.collection == 'foodEntries') ...[
              DropdownButtonFormField<String>(
                key: ValueKey('${candidate.id}-status'),
                initialValue: '${candidate.fields['status']}',
                decoration:
                    const InputDecoration(labelText: 'Consumption status'),
                items: ['consumed', 'planned', 'cancelled']
                    .map((status) =>
                        DropdownMenuItem(value: status, child: Text(status)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    candidate.fields['status'] = value;
                    _invalidate();
                  }
                },
              ),
              DropdownButtonFormField<String>(
                key: ValueKey('${candidate.id}-food'),
                initialValue: candidate.fields['savedFoodId'] as String? ?? '',
                decoration:
                    const InputDecoration(labelText: 'Saved Food identity'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Unlinked')),
                  for (final food in foods)
                    DropdownMenuItem(
                        value: food.id,
                        child: Text(
                            '${food.fields['name']}${food.included ? '' : ' (excluded)'}'))
                ],
                onChanged: (value) {
                  if (value == null || value.isEmpty) {
                    candidate.fields.remove('savedFoodId');
                  } else {
                    candidate.fields['savedFoodId'] = value;
                  }
                  _invalidate();
                },
              ),
            ],
            if (candidate.fields['provenance'] is String)
              DropdownButtonFormField<String>(
                key: ValueKey('${candidate.id}-provenance'),
                initialValue: candidate.fields['provenance'] as String,
                decoration: const InputDecoration(labelText: 'Provenance'),
                items: const [
                  'exactLabel',
                  'userConfirmed',
                  'finalDailyTotal',
                  'assistantEstimate',
                  'restaurantEstimate',
                  'inferredApproximate',
                  'legacyObservation'
                ]
                    .map((value) =>
                        DropdownMenuItem(value: value, child: Text(value)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    candidate.fields['provenance'] = value;
                    _invalidate();
                  }
                },
              ),
            DropdownButtonFormField<ExtractionConfidence>(
              key: ValueKey('${candidate.id}-confidence'),
              initialValue: candidate.confidence,
              decoration:
                  const InputDecoration(labelText: 'Extraction confidence'),
              items: ExtractionConfidence.values
                  .map((value) =>
                      DropdownMenuItem(value: value, child: Text(value.name)))
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  candidate.confidence = value;
                  _invalidate();
                }
              },
            ),
            if (candidate.collection == 'nutritionSnapshots')
              for (final nutrient in ['calories', 'protein', 'carbs', 'fat'])
                if (candidate.fields[nutrient] != null)
                  TextFormField(
                    key: ValueKey('${candidate.id}-$nutrient'),
                    initialValue: '${candidate.fields[nutrient]}',
                    decoration: InputDecoration(
                        labelText: '$nutrient (${candidate.fields['basis']})'),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (value) {
                      candidate.fields[nutrient] = value;
                      _invalidate();
                    },
                  ),
            if (candidate.collection == 'measurements' &&
                candidate.fields['value'] != null)
              TextFormField(
                key: ValueKey('${candidate.id}-value'),
                initialValue: '${candidate.fields['value']}',
                decoration: InputDecoration(
                    labelText: 'Measurement (${candidate.fields['unit']})'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (value) {
                  candidate.fields['value'] = value;
                  _invalidate();
                },
              ),
            if (candidate.collection == 'workoutSets')
              for (final field in ['weight', 'reps', 'setCount'])
                if (candidate.fields[field] != null)
                  TextFormField(
                    key: ValueKey('${candidate.id}-$field'),
                    initialValue: '${candidate.fields[field]}',
                    decoration: InputDecoration(labelText: field),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (value) {
                      candidate.fields[field] = field == 'weight'
                          ? value
                          : int.tryParse(value) ?? value;
                      _invalidate();
                    },
                  ),
          ])),
    );
  }

  String _date(DateTime? date) => date == null
      ? 'unknown date'
      : '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}
