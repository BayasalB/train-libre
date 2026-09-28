import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/database_helper.dart';
import '../../../generated/app_localizations.dart';
import '../../diary/domain/models/nutrition_values.dart';
import '../../diary/domain/models/tracked_food_item.dart';
import '../../today/domain/daily_record_models.dart';
import '../../../util/l10n_ext.dart';
import '../../workout/presentation/workout_log_detail_screen.dart';
import '../../workout/presentation/widgets/workout_day_card.dart';
import '../../profile/presentation/progress_photos_screen.dart';
import '../data/history_repository.dart';
import '../../today/presentation/day_actions.dart';
import '../../diary/data/day_copy_service.dart';
import '../../diary/domain/day_copy_request.dart';

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
  late final DayCopyService _copy = DayCopyService(_repository.database);
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
    if (detail.today.dayLock != null) return;
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
                          DayLockAction(
                              date: _date,
                              lock: day.dayLock,
                              repository: _repository.today.locks),
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
                              onChanged: day.dayLock != null
                                  ? null
                                  : (type) {
                                      if (type != null) {
                                        _save(() => _repository.today.records
                                            .saveDay(_date,
                                                trainingType: type));
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
                        if (detail.reportedTotals.isNotEmpty)
                          _card(context, 'Reported historical total', [
                            for (final total in detail.reportedTotals)
                              Text(
                                  'Reported ${total['calories'] ?? '—'} kcal · '
                                  'P ${total['protein'] ?? '—'} g · '
                                  'C ${total['carbs'] ?? '—'} g · '
                                  'F ${total['fat'] ?? '—'} g\n'
                                  'Source: ${total['provenance']}'),
                            const Text(
                                'Kept separate from calculated food totals.'),
                          ]),
                        if (detail.importedTargetObservations.isNotEmpty)
                          _card(context, 'Imported target observations', [
                            for (final target
                                in detail.importedTargetObservations)
                              Text(
                                  '${target['kind']} · ${target['effectiveFrom']} · '
                                  '${target['calories'] ?? '—'} kcal · '
                                  'P ${target['protein'] ?? '—'} · '
                                  'C ${target['carbs'] ?? '—'} · '
                                  'F ${target['fat'] ?? '—'}'),
                          ]),
                        _card(context, 'Foods and meals', [
                          if (day.foods.isEmpty &&
                              detail.unavailableFoods.isEmpty &&
                              day.fluids.isEmpty)
                            const Text('No food logged'),
                          for (final meal in foodsByMeal.entries) ...[
                            Row(children: [
                              Expanded(
                                  child: Text(mealLabels[meal.key]!,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium)),
                              IconButton(
                                tooltip: 'Copy meal',
                                icon: const Icon(Icons.copy_outlined),
                                onPressed: () => showCopyToDate(
                                    context,
                                    _copy,
                                    DayCopyRequest(
                                        sourceDate: _date,
                                        destinationDate: DateTime.now(),
                                        mealEntryId:
                                            meal.value.first.entry.mealEntryId,
                                        mealType: meal.value.first.entry
                                                    .mealEntryId ==
                                                null
                                            ? meal.value.first.entry.mealType
                                            : null)),
                              ),
                            ]),
                            for (final tracked in meal.value)
                              ListTile(
                                  title: Text(tracked.item.name),
                                  subtitle: Text(
                                      '${tracked.displayQuantity} · ${tracked.calculatedCalories.toStringAsFixed(0)} kcal')),
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
                                onPressed: day.dayLock == null
                                    ? () => widget.onOpenDiary!(_date)
                                    : null,
                                child: const Text('Edit food log')),
                        ]),
                        _card(context, 'Workouts', [
                          if (day.workouts.isEmpty)
                            const Text('No workout logged'),
                          for (final workout in day.workouts)
                            WorkoutDayCard(
                              workout: workout,
                              timeKnown:
                                  !day.unknownWorkoutTimes.contains(workout.id),
                              summary: day.workoutDetails.summaries[workout.id],
                              sets: detail.setsByWorkoutId[workout.id] ??
                                  const [],
                              exerciseNotes: day.workoutDetails
                                      .exerciseNotesByWorkoutId[workout.id] ??
                                  const [],
                              onOpen: workout.status == 'completed'
                                  ? () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              WorkoutLogDetailScreen(
                                                  logId: workout.localId)))
                                  : null,
                            ),
                        ]),
                        _card(context, 'Body measurements', [
                          TextButton.icon(
                              onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => ProgressPhotosScreen(
                                          initialDate: _date))),
                              icon: const Icon(Icons.photo_library_outlined),
                              label: const Text('Progress photos')),
                          if (detail.measurements.isEmpty)
                            const Text('No measurements recorded'),
                          if (detail.measurements.isNotEmpty &&
                              detail.measurements
                                  .every((m) => m.type == 'weight'))
                            const Text('No other measurements recorded'),
                          for (final measurement in detail.measurements)
                            if (measurement.type != 'weight')
                              ListTile(
                                  title: Text(AppLocalizations.of(context)
                                          ?.getLocalizedMeasurementName(
                                              measurement.type) ??
                                      (measurement.type == 'lower_belly'
                                          ? 'Lower Belly'
                                          : measurement.type)),
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
                              onPressed: day.dayLock == null
                                  ? () => _editNotes(detail)
                                  : null,
                              child: const Text('Edit notes')),
                        ]),
                      ]);
                }))
      ]));
}
