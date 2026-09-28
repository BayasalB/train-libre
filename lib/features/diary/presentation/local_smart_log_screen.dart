import 'package:flutter/material.dart';

import '../../../data/database_helper.dart';
import '../data/local_smart_food_log.dart';
import '../domain/models/food_item.dart';
import '../domain/models/nutrition_values.dart';
import '../domain/use_cases/parse_local_food_log.dart';
import 'create_food_screen.dart';

/// Offline text logging. Every candidate is reviewed before a diary write.
class LocalSmartLogScreen extends StatefulWidget {
  final DateTime? initialDate;
  final LocalSmartFoodLog? service;
  const LocalSmartLogScreen({super.key, this.initialDate, this.service});

  @override
  State<LocalSmartLogScreen> createState() => _LocalSmartLogScreenState();
}

class _LocalSmartLogScreenState extends State<LocalSmartLogScreen> {
  final _text = TextEditingController();
  late final LocalSmartFoodLog _service =
      widget.service ?? LocalSmartFoodLog(DatabaseHelper.instance.dbInstance);
  late DateTime _date = widget.initialDate ?? DateTime.now();
  String _meal = 'mealtypeSnack';
  List<LocalFoodCandidate> _candidates = [];
  bool _busy = false;
  bool _hasPreview = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    if (_text.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final result = await _service.preview(_text.text);
      if (mounted) {
        setState(() {
          _candidates = result;
          _hasPreview = true;
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
          _candidates[index] = old.copyWith(
            quantity: value,
            unit: unit,
            action: action,
            warnings: old.warnings
                .where((w) =>
                    !w.startsWith('Quantity missing') &&
                    !w.startsWith('Quantity must be positive') &&
                    !w.startsWith('Multiple quantities') &&
                    !w.startsWith('Ambiguous comma quantity'))
                .toList(),
          );
        });
      }
    }
    amount.dispose();
  }

  Future<void> _selectFood(int index) async {
    final query = TextEditingController(text: _candidates[index].foodQuery);
    List<FoodItem> options = _candidates[index].matches;
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
      setState(() => _candidates[index] = _candidates[index].copyWith(
            matches: [choice],
            warnings: _candidates[index]
                .warnings
                .where((warning) => !warning.startsWith('Food name missing'))
                .toList(),
          ));
    }
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      await _service.confirm(_candidates, date: _date, mealType: _meal);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) _message('Could not save: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final consumed =
        _candidates.where((c) => c.action == LocalFoodAction.consumed).toList();
    final canConfirm = consumed.isNotEmpty && consumed.every((c) => c.canLog);
    final total = consumed.fold(
        const NutritionValues(),
        (NutritionValues sum, candidate) =>
            sum + (candidate.nutrition ?? const NutritionValues()));
    return Scaffold(
      appBar: AppBar(title: const Text('Smart Log · Offline')),
      body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
            'Saved Foods and your aliases are used locally. Review every item before saving.'),
        const SizedBox(height: 12),
        TextField(
            controller: _text,
            maxLines: 3,
            decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '41g uurag, 80g ovyoos'),
            onChanged: (_) {
              if (_hasPreview) {
                setState(() {
                  _hasPreview = false;
                  _candidates = [];
                });
              }
            }),
        const SizedBox(height: 12),
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
          for (var i = 0; i < _candidates.length; i++) _candidateCard(i),
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
    final c = _candidates[index];
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
                Text(
                    '${c.quantity == null ? '?' : formatFoodQuantity(c.quantity!)} ${c.unit.name} · ${c.action.name} · ${c.resolution.name}'),
                if (nutrition != null)
                  Text(
                      '${nutrition.calories.toStringAsFixed(0)} kcal · P ${nutrition.protein.toStringAsFixed(1)} · C ${nutrition.carbs.toStringAsFixed(1)} · F ${nutrition.fat.toStringAsFixed(1)}'),
                if (c.unit == LocalFoodUnit.piece ||
                    c.unit == LocalFoodUnit.unknown ||
                    (c.unit == LocalFoodUnit.serving &&
                        c.amountInFoodUnit == null))
                  const Text('Enter g/ml, or use a configured serving size.'),
                for (final warning in c.warnings)
                  Text(warning,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                Row(children: [
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
