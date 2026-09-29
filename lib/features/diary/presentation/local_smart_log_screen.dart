import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../data/database_helper.dart';
import '../../../services/ai_meal_validation.dart';
import '../../../services/voice/voice_dictation_service.dart';
import '../../../util/permission_dialogs.dart';
import '../data/local_smart_food_log.dart';
import '../data/smart_log_ai_fallback.dart';
import '../data/smart_log_ai_provider.dart';
import '../data/smart_log_photo_adapter.dart';
import '../domain/models/food_alias.dart';
import '../domain/models/food_item.dart';
import '../domain/models/nutrition_values.dart';
import '../domain/models/saved_food_metadata.dart';
import '../domain/models/smart_log_review.dart';
import '../domain/use_cases/parse_local_food_log.dart';
import '../../settings/presentation/ai_settings_screen.dart';
import 'ai_meal_capture_screen.dart';
import 'create_food_screen.dart';
import 'dialogs/voice_dictation_sheet.dart';

/// Local text logging with an explicit, optional network fallback.
class LocalSmartLogScreen extends StatefulWidget {
  final DateTime? initialDate;
  final LocalSmartFoodLog? service;
  final SmartLogAiFallback? aiFallback;
  final Future<String?> Function(String currentText)? voiceTranscriptForTesting;
  final Future<AiMealCandidate?> Function(BuildContext context)?
      photoCaptureForTesting;
  const LocalSmartLogScreen(
      {super.key,
      this.initialDate,
      this.service,
      this.aiFallback,
      this.voiceTranscriptForTesting,
      this.photoCaptureForTesting});

  @override
  State<LocalSmartLogScreen> createState() => _LocalSmartLogScreenState();
}

class _LocalSmartLogScreenState extends State<LocalSmartLogScreen> {
  final _text = TextEditingController();
  final _textFocus = FocusNode();
  late final LocalSmartFoodLog _service =
      widget.service ?? LocalSmartFoodLog(DatabaseHelper.instance.dbInstance);
  late final SmartLogAiFallback _ai = widget.aiFallback ??
      SmartLogAiFallback(_service, ConfiguredSmartLogAiProvider());
  late DateTime _date = widget.initialDate ?? DateTime.now();
  String _meal = 'mealtypeSnack';
  List<SmartLogReviewItem> _review = [];
  SmartLogInputSource _textSource = SmartLogInputSource.text;
  bool _busy = false;
  bool _hasPreview = false;
  bool _allowEstimate = false;
  int _aiAttempts = 0;
  String? _aiError;
  String _reviewId = const Uuid().v4();
  final Map<int, SmartLogAiSuggestion> _aiSuggestions = {};
  final Map<String, FoodItem> _acceptedEstimates = {};

  List<LocalFoodCandidate> get _candidates =>
      _review.map((item) => item.candidate).toList(growable: false);

  void _replaceReview(List<SmartLogReviewItem> items) {
    _review = List.of(items);
    _hasPreview = true;
    _aiAttempts = 0;
    _aiError = null;
    _aiSuggestions.clear();
    _acceptedEstimates.clear();
    _reviewId = const Uuid().v4();
  }

  void _setCandidate(int index, LocalFoodCandidate value) {
    _review[index] = _review[index].copyWith(candidate: value);
  }

  @override
  void dispose() {
    _text.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    if (_text.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final result = await _service.preview(_text.text);
      if (mounted) {
        setState(() {
          _replaceReview([
            for (final candidate in result)
              SmartLogReviewItem(
                candidate: candidate,
                source: _textSource,
                sourceDescription: candidate.rawSpan,
              ),
          ]);
        });
      }
    } catch (error) {
      if (mounted) _message('Could not parse food: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String value) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(value)));

  Future<void> _voice() async {
    if (_busy) return;
    try {
      await _captureVoice();
    } catch (error) {
      if (mounted) {
        _message('Voice unavailable: $error. Typed text is unchanged.');
      }
    }
  }

  Future<void> _captureVoice() async {
    if (widget.voiceTranscriptForTesting != null) {
      final text = await widget.voiceTranscriptForTesting!(_text.text);
      if (!mounted || text == null) return;
      _text.text = text;
      setState(() => _textSource = SmartLogInputSource.voice);
      if (text.trim().isNotEmpty) await _preview();
      return;
    }
    if (!await VoiceDictationService.instance.hasPermissions()) {
      if (!mounted) return;
      final proceed = await showPrePermissionDialog(
        context: context,
        title: 'Voice Smart Log',
        body:
            'Microphone and speech recognition permission are needed. Your device may use network transcription. The editable transcript is checked locally first; Smart Log AI remains optional.',
        continueLabel: 'Continue',
        cancelLabel: 'Cancel',
      );
      if (!proceed) return;
    }
    final availability = await VoiceDictationService.instance.prepare();
    if (!mounted) return;
    if (!availability.available) {
      _message(
          'Voice recognition unavailable (${availability.reason}). Type or edit food text instead.');
      return;
    }
    final result = await showVoiceDictationSheet(
      context: context,
      initialText: _text.text,
      exampleHint: '41g uurag, 80g ovyoos',
      analyzeLabel: 'Preview locally',
      allowAiTidy: false,
    );
    if (!mounted || result == null) return;
    _text.text = result.text;
    setState(() {
      _textSource = SmartLogInputSource.voice;
      _review = [];
      _hasPreview = false;
    });
    if (result.analyzeNow && result.text.trim().isNotEmpty) await _preview();
  }

  Future<void> _photo() async {
    if (_busy) return;
    try {
      if (!await _ai.provider.isConfigured()) {
        if (mounted) {
          _message(
              'Configure an AI provider for photo analysis. Typed Smart Log still works offline.');
        }
        return;
      }
    } catch (error) {
      if (mounted) _message('AI provider unavailable: $error');
      return;
    }
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Analyze a meal photo?'),
        content: const Text(
            'Photo analysis uses your selected AI provider and may require network access. Only the chosen meal photo and any text you enter in capture are sent; diary history, workouts, body measurements and progress photos are not attached. Portions are estimates.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    AiMealCandidate? result;
    try {
      result = widget.photoCaptureForTesting != null
          ? await widget.photoCaptureForTesting!(context)
          : await Navigator.of(context).push<AiMealCandidate>(
              MaterialPageRoute(
                  builder: (_) => AiMealCaptureScreen(
                        initialDate: _date,
                        returnCandidateToSmartLog: true,
                      )),
            );
    } catch (error) {
      if (mounted) _message('Photo analysis unavailable: $error');
      return;
    }
    if (!mounted || result == null) return;
    setState(() => _busy = true);
    try {
      final items = await SmartLogPhotoAdapter(_service).review(result);
      if (!mounted) return;
      setState(() {
        _text.clear();
        _textSource = SmartLogInputSource.text;
        _replaceReview(items);
      });
    } catch (error) {
      if (mounted) _message('Photo result could not be reviewed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _tryAi() async {
    if (_busy || !_ai.canOffer(_candidates)) return;
    try {
      if (!await _ai.provider.isConfigured()) {
        if (mounted) {
          setState(() => _aiError =
              'AI provider is not configured. Local logging remains available.');
        }
        return;
      }
    } catch (error) {
      if (mounted) {
        setState(() => _aiError = 'AI configuration unavailable: $error');
      }
      return;
    }
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use optional AI?'),
        content: const Text(
            'Requires network access. Only unresolved Smart Log text and up to 8 relevant Saved Food names/aliases will be sent to your selected AI provider. No diary, workouts, measurements, photos, or past chats are sent. Direct mobile BYOK is for personal/development use; a secure relay is preferable for production.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Try AI')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() {
      _busy = true;
      _aiAttempts++;
      _aiError = null;
    });
    try {
      final result =
          await _ai.interpret(_candidates, allowEstimate: _allowEstimate);
      if (!mounted) return;
      final grouped = <int, List<SmartLogAiSuggestion>>{};
      for (final suggestion in result.suggestions) {
        final sourceIndex =
            int.parse(suggestion.interpretation.sourceCandidateId.substring(1));
        grouped.putIfAbsent(sourceIndex, () => []).add(suggestion);
      }
      final updated = <SmartLogReviewItem>[];
      final shown = <int, SmartLogAiSuggestion>{};
      for (var i = 0; i < _candidates.length; i++) {
        final original = _review[i].candidate;
        final interpretations = grouped[i];
        if (interpretations == null) {
          updated.add(_review[i]);
          continue;
        }
        for (final suggestion in interpretations) {
          final item = suggestion.interpretation;
          final keepLocalQuantity = interpretations.length == 1;
          final preservedFood = keepLocalQuantity ? original.food : null;
          final amount = keepLocalQuantity
              ? (original.quantity ?? item.quantity)
              : item.quantity;
          final candidate = LocalFoodCandidate(
            rawSpan: item.sourceText,
            normalizedText: normalizeFoodAlias(item.sourceText),
            foodQuery: preservedFood?.name ?? item.interpretedFoodName,
            quantity: amount,
            unit: keepLocalQuantity && original.unit != LocalFoodUnit.unknown
                ? original.unit
                : item.unit,
            action: original.action == LocalFoodAction.planned
                ? LocalFoodAction.planned
                : item.action ?? original.action,
            matches: preservedFood == null ? const [] : [preservedFood],
            warnings: [
              if (amount == null) 'Quantity missing: enter g or ml.',
              if (item.action == null) 'Action unclear: edit this item.',
            ],
          );
          shown[updated.length] = suggestion;
          updated.add(_review[i].copyWith(
            candidate: candidate,
            source: _review[i].source == SmartLogInputSource.photo
                ? SmartLogInputSource.photo
                : SmartLogInputSource.aiAssisted,
          ));
        }
      }
      setState(() {
        _review = updated;
        _aiSuggestions
          ..clear()
          ..addAll(shown);
        _acceptedEstimates.clear();
        _reviewId = const Uuid().v4();
      });
    } catch (error) {
      if (mounted) {
        setState(() => _aiError =
            'AI unavailable: $error. Your text and local preview are unchanged.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _linkSuggestion(int index) {
    final food = _aiSuggestions[index]?.suggestedFood;
    if (food == null) return;
    setState(() {
      final old = _review[index].candidate;
      if (old.food != null) {
        _acceptedEstimates.remove(old.food!.barcode);
      }
      _setCandidate(index, old.copyWith(matches: [food]));
    });
  }

  Future<void> _useEstimate(int index) async {
    final suggestion = _aiSuggestions[index];
    if (suggestion?.interpretation.nutritionEstimate == null ||
        _candidates[index].food != null ||
        suggestion?.suggestedFood != null) {
      return;
    }
    try {
      final interpreted = suggestion!.interpretation;
      final values = interpreted.nutritionEstimate!;
      for (final existing in _acceptedEstimates.values) {
        if (normalizeFoodAlias(existing.name) ==
                normalizeFoodAlias(interpreted.interpretedFoodName) &&
            existing.calories == values.caloriesPer100 &&
            existing.protein == values.proteinPer100 &&
            existing.carbs == values.carbsPer100 &&
            existing.fat == values.fatPer100 &&
            existing.isLiquid ==
                (interpreted.unit == LocalFoodUnit.milliliters)) {
          setState(() => _setCandidate(
              index, _candidates[index].copyWith(matches: [existing])));
          return;
        }
      }
      final food = await _ai.estimateFood(interpreted);
      if (!mounted || _candidates[index].food != null) return;
      setState(() {
        _acceptedEstimates[food.barcode] = food;
        _setCandidate(index, _candidates[index].copyWith(matches: [food]));
      });
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _edit(int index) async {
    final old = _candidates[index];
    final amount = TextEditingController(
        text: old.quantity == null ? '' : formatFoodQuantity(old.quantity!));
    var unit = old.unit;
    var action = old.action;
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: Text('Edit: ${old.foodQuery}'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: amount,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Quantity')),
                  DropdownButton<LocalFoodUnit>(
                      value: unit,
                      isExpanded: true,
                      items: LocalFoodUnit.values
                          .map((v) =>
                              DropdownMenuItem(value: v, child: Text(v.name)))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) update(() => unit = v);
                      }),
                  DropdownButton<LocalFoodAction>(
                      value: action,
                      isExpanded: true,
                      items: LocalFoodAction.values
                          .map((v) =>
                              DropdownMenuItem(value: v, child: Text(v.name)))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) update(() => action = v);
                      }),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Apply')),
                ],
              )),
    );
    if (changed == true && mounted) {
      final value = parseNutritionNumber(amount.text);
      if (value == null || value <= 0) {
        _message('Enter a positive finite quantity.');
      } else {
        setState(() {
          _setCandidate(
              index,
              old.copyWith(
                quantity: value,
                unit: unit,
                action: action,
                warnings: old.warnings
                    .where((w) =>
                        !w.startsWith('Quantity missing') &&
                        !w.startsWith('Quantity must be positive') &&
                        !w.startsWith('Multiple quantities') &&
                        !w.startsWith('Ambiguous comma quantity') &&
                        !w.startsWith('Action unclear'))
                    .toList(),
              ));
        });
      }
    }
    amount.dispose();
  }

  Future<void> _selectFood(int index) async {
    final query = TextEditingController(text: _candidates[index].foodQuery);
    List<FoodItem> options = [
      ..._candidates[index].matches,
      ..._review[index].suggestedFoods,
    ];
    var loading = false;
    final choice = await showDialog<FoodItem>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: const Text('Select Saved Food'),
                  content: SizedBox(
                      width: double.maxFinite,
                      height: 320,
                      child: Column(children: [
                        TextField(
                            controller: query,
                            decoration: InputDecoration(
                              labelText: 'Search Saved Foods',
                              suffixIcon: IconButton(
                                  icon: const Icon(Icons.search),
                                  onPressed: () async {
                                    update(() => loading = true);
                                    final found = await _service.products
                                        .searchSavedFoods(query.text);
                                    update(() {
                                      options = found;
                                      loading = false;
                                    });
                                  }),
                            ),
                            onSubmitted: (_) async {
                              update(() => loading = true);
                              final found = await _service.products
                                  .searchSavedFoods(query.text);
                              update(() {
                                options = found;
                                loading = false;
                              });
                            }),
                        if (loading) const LinearProgressIndicator(),
                        Expanded(
                            child: ListView(
                                children: options
                                    .map((food) => ListTile(
                                          title: Text(food.name),
                                          subtitle: Text(food.brand),
                                          onTap: () =>
                                              Navigator.pop(context, food),
                                        ))
                                    .toList())),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () async {
                          Navigator.pop(context);
                          await Navigator.of(this.context).push(
                              MaterialPageRoute(
                                  builder: (_) => const CreateFoodScreen()));
                        },
                        child: const Text('Create Saved Food')),
                  ],
                )));
    query.dispose();
    if (choice != null && mounted) {
      final prior = _candidates[index].food;
      setState(() => _setCandidate(
          index,
          _candidates[index].copyWith(
            matches: [choice],
            warnings: _candidates[index]
                .warnings
                .where((warning) => !warning.startsWith('Food name missing'))
                .toList(),
          )));
      if (prior != null) _acceptedEstimates.remove(prior.barcode);
    }
  }

  Future<void> _confirm() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _ai.confirm(
          reviewId: _reviewId,
          candidates: _review
              .where((item) => item.included)
              .map((item) => item.candidate)
              .toList(),
          acceptedEstimates: {
            for (final entry in _acceptedEstimates.entries)
              if (_review.any((item) =>
                  item.included && item.candidate.food?.barcode == entry.key))
                entry.key: entry.value,
          },
          date: _date,
          mealType: _meal);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) _message('Could not save: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = SmartLogReviewSummary(_review);
    final canConfirm = summary.canConfirm;
    final total = summary.totals;
    return Scaffold(
      appBar: AppBar(title: const Text('Smart Log')),
      body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
            'Saved Foods and aliases are checked locally first. AI is optional for unresolved items. Review every item before saving.'),
        const SizedBox(height: 12),
        TextField(
            controller: _text,
            focusNode: _textFocus,
            maxLines: 3,
            decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '41g uurag, 80g ovyoos'),
            onChanged: (_) {
              if (_hasPreview) {
                setState(() {
                  _hasPreview = false;
                  _review = [];
                  _textSource = SmartLogInputSource.text;
                  _aiSuggestions.clear();
                  _acceptedEstimates.clear();
                  _aiError = null;
                  _aiAttempts = 0;
                });
              }
            }),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 4, children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _textFocus.requestFocus(),
            icon: const Icon(Icons.keyboard),
            label: const Text('Type'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _voice,
            icon: const Icon(Icons.mic_outlined),
            label: const Text('Voice'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _photo,
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('Photo'),
          ),
        ]),
        const Text(
            'Voice transcription may use the device network. Typed Smart Log needs no connection.'),
        const SizedBox(height: 8),
        FilledButton.icon(
            onPressed: _busy ? null : _preview,
            icon: const Icon(Icons.preview_outlined),
            label: const Text('Preview')),
        if (_hasPreview) ...[
          const SizedBox(height: 16),
          ListTile(
              title: Text(
                  '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}'),
              trailing: const Icon(Icons.calendar_month),
              onTap: () async {
                final date = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100));
                if (date != null) setState(() => _date = date);
              }),
          DropdownButton<String>(
              value: _meal,
              isExpanded: true,
              items: const {
                'mealtypeBreakfast': 'Breakfast',
                'mealtypeLunch': 'Lunch',
                'mealtypeDinner': 'Dinner',
                'mealtypeSnack': 'Snack',
              }
                  .entries
                  .map((entry) => DropdownMenuItem(
                      value: entry.key, child: Text(entry.value)))
                  .toList(),
              onChanged: (m) {
                if (m != null) setState(() => _meal = m);
              }),
          for (var i = 0; i < _review.length; i++) _candidateCard(i),
          if (_ai.canOffer(_candidates)) ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _allowEstimate,
              title: const Text('Allow approximate AI nutrition estimates'),
              subtitle: const Text(
                  'Unchecked by default. Estimates are never verified labels.'),
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _allowEstimate = value ?? false),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _tryAi,
              icon: const Icon(Icons.auto_awesome_outlined),
              label: Text(_aiAttempts == 0
                  ? 'Try AI for unresolved items'
                  : 'Retry AI'),
            ),
          ],
          if (_aiError != null) ...[
            Text(_aiError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const AiSettingsScreen())),
                child: const Text('AI Settings')),
          ],
          const SizedBox(height: 12),
          Text(
              'Total: ${total.calories.toStringAsFixed(0)} kcal · P ${total.protein.toStringAsFixed(1)} · C ${total.carbs.toStringAsFixed(1)} · F ${total.fat.toStringAsFixed(1)}'),
          if (!canConfirm)
            const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                    'Resolve each consumed food and enter a safe g/ml quantity before Confirm. Planned/cancelled items are not logged.')),
          const SizedBox(height: 12),
          Row(children: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            const Spacer(),
            FilledButton(
                onPressed: _busy || !canConfirm ? null : _confirm,
                child: const Text('Confirm')),
          ]),
        ],
      ])),
    );
  }

  Widget _candidateCard(int index) {
    final review = _review[index];
    final c = review.candidate;
    final ai = _aiSuggestions[index];
    final nutrition = c.nutrition;
    final title = c.food?.name ?? c.foodQuery;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title.isEmpty ? c.rawSpan : title,
                    style: Theme.of(context).textTheme.titleMedium),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  Chip(label: Text(review.source.name.toUpperCase())),
                  Chip(
                    label: Text(c.action.name),
                    backgroundColor: c.action == LocalFoodAction.consumed
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.secondaryContainer,
                  ),
                  Chip(
                    label: Text(c.resolution.name),
                    backgroundColor: c.resolution == LocalFoodResolution.matched
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.errorContainer,
                  ),
                ]),
                Text(review.sourceDescription),
                Text(
                    '${c.quantity == null ? '?' : formatFoodQuantity(c.quantity!)} ${c.unit.name}'),
                if (review.confidence != null)
                  Text(
                      'Recognition confidence ${(review.confidence! * 100).toStringAsFixed(0)}%'),
                for (final warning in review.sourceWarnings)
                  Text(warning,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.tertiary)),
                if (nutrition != null)
                  Text(
                      '${nutrition.calories.toStringAsFixed(0)} kcal · P ${nutrition.protein.toStringAsFixed(1)} · C ${nutrition.carbs.toStringAsFixed(1)} · F ${nutrition.fat.toStringAsFixed(1)}'),
                if (c.food != null)
                  Text(c.food!.metadata.verified
                      ? 'Verified local Saved Food nutrition'
                      : 'Local Saved Food · ${c.food!.nutritionSource.name}'),
                if (review.suggestedFoods.length == 1 && c.food == null)
                  TextButton(
                    onPressed: () => setState(() => _setCandidate(
                        index, c.copyWith(matches: review.suggestedFoods))),
                    child: Text(
                        'Link local Saved Food: ${review.suggestedFoods.single.name}'),
                  ),
                if (ai != null) ...[
                  Text(
                      'AI suggestion · confidence ${(ai.interpretation.confidence * 100).toStringAsFixed(0)}%'),
                  for (final warning in ai.interpretation.warnings)
                    Text('AI warning: $warning'),
                  if (ai.suggestedFood != null && c.food == null)
                    TextButton(
                      onPressed: () => _linkSuggestion(index),
                      child: Text('Link Saved Food: ${ai.suggestedFood!.name}'),
                    ),
                  if (ai.interpretation.nutritionEstimate != null &&
                      c.food == null)
                    TextButton(
                      onPressed: () => _useEstimate(index),
                      child: const Text('Use AI_ESTIMATE (approximate)'),
                    ),
                ],
                if (c.food?.nutritionSource == NutritionSource.estimate)
                  const Text('AI_ESTIMATE · approximate, not a verified label'),
                if (c.unit == LocalFoodUnit.piece ||
                    c.unit == LocalFoodUnit.unknown ||
                    (c.unit == LocalFoodUnit.serving &&
                        c.amountInFoodUnit == null))
                  const Text('Enter g/ml, or use a configured serving size.'),
                for (final warning in c.warnings)
                  Text(warning,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Checkbox(
                    value: review.included,
                    onChanged: (value) => setState(() => _review[index] =
                        review.copyWith(included: value ?? false)),
                  ),
                  const Text('Include'),
                  TextButton(
                      onPressed: () => _edit(index), child: const Text('Edit')),
                  TextButton(
                      onPressed: () => _selectFood(index),
                      child: const Text('Select food')),
                ]),
              ],
            )));
  }
}
