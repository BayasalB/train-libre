import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/database_helper.dart';
import '../../diary/domain/models/nutrition_values.dart';
import '../../diary/domain/models/tracked_food_item.dart';
import '../../today/domain/daily_record_models.dart';
import '../../workout/presentation/workout_log_detail_screen.dart';
import '../data/history_repository.dart';

class DayDetailScreen extends StatefulWidget {
  final DateTime date;
  final HistoryRepository? repository;
  final ValueChanged<DateTime>? onOpenDiary;

  const DayDetailScreen(
      {super.key, required this.date, this.repository, this.onOpenDiary});

  @override
  State<DayDetailScreen> createState() => _DayDetailScreenState();
}

class _DayDetailScreenState extends State<DayDetailScreen> {
  String _mealLabel(String type) => switch (type) {
        'mealtypeBreakfast' => 'Breakfast',
        'mealtypeLunch' => 'Lunch',
        'mealtypeDinner' => 'Dinner',
        'mealtypeSnack' => 'Snack',
        _ => type,
      };

  late final HistoryRepository _repository = widget.repository ??
      HistoryRepository(DatabaseHelper.instance.dbInstance);
  late DateTime _date = localDay(widget.date);
  late Stream<HistoryDayDetail> _detail = _repository.watchDay(_date);

  void _selectDate(DateTime date) {
    setState(() {
      _date = localDay(date);
      _detail = _repository.watchDay(_date);
    });
  }

  Future<void> _save(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not save. Please try again.')));
      }
    }
  }

  Future<void> _editNotes(HistoryDayDetail detail) async {
    var draft = detail.today.record?.notes ?? '';
    final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Daily notes'),
              content: TextFormField(
                  key: const ValueKey('history-notes-input'),
                  initialValue: draft,
                  onChanged: (text) => draft = text,
                  minLines: 3,
                  maxLines: 8),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, draft),
                    child: const Text('Save'))
              ],
            ));
    if (result != null && mounted) {
      await _save(
          () => _repository.today.records.saveDay(_date, notes: result));
    }
  }

  Widget _card(BuildContext context, String title, List<Widget> children) =>
      Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    ...children,
                  ])));

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Day Detail')),
      body: Column(children: [
        Row(children: [
          IconButton(
              tooltip: 'Previous day',
              onPressed: () =>
                  _selectDate(DateTime(_date.year, _date.month, _date.day - 1)),
              icon: const Icon(Icons.chevron_left)),
          Expanded(
              child: TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                        context: context,
                        initialDate: _date,
                        firstDate: DateTime(1900),
                        lastDate: DateTime(2100));
                    if (picked != null && mounted) _selectDate(picked);
                  },
                  child: Text(DateFormat.yMMMd().format(_date),
                      key: const ValueKey('day-detail-date')))),
          IconButton(
              tooltip: 'Next day',
              onPressed: () =>
                  _selectDate(DateTime(_date.year, _date.month, _date.day + 1)),
              icon: const Icon(Icons.chevron_right)),
        ]),
        Expanded(
            child: StreamBuilder<HistoryDayDetail>(
                key: ValueKey(localDateKey(_date)),
                stream: _detail,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                        child: TextButton(
                            onPressed: () => _selectDate(_date),
                            child:
                                const Text('Could not load this day. Retry')));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final detail = snapshot.data!;
                  final day = detail.today;
                  final totals = day.nutrition.summary;
                  final target = day.targets.profile;
                  final foodsByMeal = <String, List<TrackedFoodItem>>{};
                  final mealLabels = <String, String>{};
                  for (final food in day.foods) {
                    final key = food.entry.mealEntryId ?? food.entry.mealType;
                    mealLabels[key] =
                        detail.mealTitles[food.entry.mealEntryId] ??
                            _mealLabel(food.entry.mealType);
                    foodsByMeal.putIfAbsent(key, () => []).add(food);
                  }
                  return ListView(
                      key: const ValueKey('day-detail-content'),
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
                      children: [
                        _card(context, 'Day', [
                          DropdownButtonFormField<TrainingType>(
                              key: ValueKey(
                                  'history-training-${day.trainingType.name}'),
                              initialValue: day.trainingType,
                              decoration: const InputDecoration(
                                  labelText: 'Training type'),
                              items: TrainingType.values
                                  .map((type) => DropdownMenuItem(
                                      value: type, child: Text(type.label)))
                                  .toList(),
                              onChanged: (type) {
                                if (type != null) {
                                  _save(() => _repository.today.records
                                      .saveDay(_date, trainingType: type));
                                }
                              }),
                          Text(
                              day.weight == null
                                  ? 'No bodyweight recorded'
                                  : 'Bodyweight: ${formatFoodQuantity(day.weight!.value)} ${day.weight!.unit}',
                              key: const ValueKey('day-detail-weight')),
                        ]),
                        _card(context, 'Nutrition', [
                          Text(
                              '${totals.calories.toStringAsFixed(0)}${target == null ? '' : ' / ${target.calories.toStringAsFixed(0)}'} kcal',
                              key: const ValueKey('day-detail-calories')),
                          Text(
                              'Protein ${totals.protein.toStringAsFixed(1)}${target == null ? '' : ' / ${target.protein.toStringAsFixed(1)}'} g',
                              key: const ValueKey('day-detail-protein')),
                          Text(
                              'Carbs ${totals.carbs.toStringAsFixed(1)} g · Fat ${totals.fat.toStringAsFixed(1)} g'),
                          Text(day.targets.explanation),
                        ]),
                        _card(context, 'Foods and meals', [
                          if (day.foods.isEmpty &&
                              detail.unavailableFoods.isEmpty &&
                              day.fluids.isEmpty)
                            const Text('No food logged'),
                          for (final meal in foodsByMeal.entries) ...[
                            Text(mealLabels[meal.key]!,
                                style: Theme.of(context).textTheme.titleMedium),
                            for (final tracked in meal.value)
                              ListTile(
                                  title: Text(tracked.item.name),
                                  subtitle: Text(
                                      '${formatFoodQuantity(tracked.entry.quantityInGrams)} g · ${tracked.calculatedCalories.toStringAsFixed(0)} kcal')),
                          ],
                          for (final fluid in day.fluids
                              .where((f) => f.linkedFoodEntryId == null))
                            ListTile(
                                title: Text(fluid.name),
                                subtitle: Text(
                                    '${formatFoodQuantity(fluid.quantityInMl)} ml · ${(fluid.kcal ?? 0).toStringAsFixed(0)} kcal')),
                          for (final entry in detail.unavailableFoods)
                            ListTile(
                                title:
                                    Text('Unavailable food · ${entry.barcode}'),
                                subtitle: Text(
                                    '${formatFoodQuantity(entry.quantityInGrams)} g · nutrition unavailable')),
                          if (day.missingFoods > 0)
                            Text(
                                '${day.missingFoods} food snapshot(s) unavailable; totals may be incomplete.'),
                          if (widget.onOpenDiary != null)
                            TextButton(
                                onPressed: () => widget.onOpenDiary!(_date),
                                child: const Text('Edit food log')),
                        ]),
                        _card(context, 'Workouts', [
                          if (day.workouts.isEmpty)
                            const Text('No workout logged'),
                          for (final workout in day.workouts) ...[
                            ListTile(
                                title: Text(
                                    workout.routineNameSnapshot ?? 'Workout'),
                                subtitle: Text(workout.endTime == null
                                    ? workout.status
                                    : '${workout.endTime!.difference(workout.startTime).inMinutes} min · ${detail.setsByWorkoutId[workout.id]?.length ?? 0} sets · ${workout.status}'),
                                onTap: workout.status != 'completed'
                                    ? null
                                    : () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                WorkoutLogDetailScreen(
                                                    logId: workout.localId)))),
                            for (final set
                                in detail.setsByWorkoutId[workout.id] ??
                                    const [])
                              Padding(
                                  padding: const EdgeInsets.only(
                                      left: 16, bottom: 4),
                                  child: Text(
                                      '${set.exerciseNameSnapshot ?? 'Exercise'} · ${set.weight == null ? '' : '${formatFoodQuantity(set.weight!)} kg × '}${set.reps ?? 0} reps${set.durationSeconds == null ? '' : ' · ${set.durationSeconds} sec'}')),
                          ],
                        ]),
                        _card(context, 'Body measurements', [
                          if (detail.measurements.isEmpty)
                            const Text('No measurements recorded'),
                          if (detail.measurements.isNotEmpty &&
                              detail.measurements
                                  .every((m) => m.type == 'weight'))
                            const Text('No other measurements recorded'),
                          for (final measurement in detail.measurements)
                            if (measurement.type != 'weight')
                              ListTile(
                                  title: Text(measurement.type),
                                  trailing: Text(
                                      '${formatFoodQuantity(measurement.value)} ${measurement.unit}')),
                        ]),
                        _card(context, 'Daily notes', [
                          Text(
                              day.record?.notes.isNotEmpty == true
                                  ? day.record!.notes
                                  : 'No notes yet',
                              key: const ValueKey('day-detail-notes')),
                          TextButton(
                              onPressed: () => _editNotes(detail),
                              child: const Text('Edit notes')),
                        ]),
                      ]);
                }))
      ]));
}
