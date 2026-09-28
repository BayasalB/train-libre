import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../data/database_helper.dart';
import '../../diary/domain/models/nutrition_values.dart';
import '../../diary/presentation/food_detail_screen.dart';
import '../../profile/presentation/measurements_screen.dart';
import '../../workout/presentation/workout_log_detail_screen.dart';
import '../../workout/presentation/widgets/workout_day_card.dart';
import '../data/today_repository.dart';
import '../domain/daily_record_models.dart';
import 'target_profiles_screen.dart';
import 'day_actions.dart';
import '../../diary/data/day_copy_service.dart';
import '../../diary/domain/day_copy_request.dart';

/// A local read model; all edits remain in the existing database repositories.
class TodayScreen extends StatefulWidget {
  final TodayRepository? repository;
  final double topInset;
  final DateTime? initialDate;
  final VoidCallback? onAddFood;
  final ValueChanged<DateTime>? onOpenDiary;
  final VoidCallback? onOpenWorkout;
  const TodayScreen(
      {super.key,
      this.repository,
      this.topInset = 0,
      this.initialDate,
      this.onAddFood,
      this.onOpenDiary,
      this.onOpenWorkout});
  @override
  State<TodayScreen> createState() => TodayScreenState();
}

class TodayScreenState extends State<TodayScreen> with WidgetsBindingObserver {
  late final TodayRepository _repo =
      widget.repository ?? TodayRepository(DatabaseHelper.instance.dbInstance);
  late final DayCopyService _copy = DayCopyService(_repo.database);
  late DateTime selectedDate = localDay(widget.initialDate ?? DateTime.now());
  late DateTime _lastToday = localDay(DateTime.now());
  late Stream<TodayData> _stream = _repo.watch(selectedDate);
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _checkDay());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkDay();
  }

  void _checkDay() {
    final now = localDay(DateTime.now());
    if (now != _lastToday && selectedDate == _lastToday) _selectDate(now);
    _lastToday = now;
  }

  void _selectDate(DateTime date) {
    setState(() {
      selectedDate = localDay(date);
      _stream = _repo.watch(selectedDate);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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

  Future<void> _editNotes(TodayData data) async {
    if (data.dayLock != null) return;
    var draft = data.record?.notes ?? '';
    final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Daily notes'),
                content: TextFormField(
                    key: const ValueKey('daily-notes-input'),
                    initialValue: draft,
                    onChanged: (value) => draft = value,
                    autofocus: true,
                    minLines: 3,
                    maxLines: 8,
                    decoration:
                        const InputDecoration(hintText: 'How was your day?')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, draft),
                      child: const Text('Save'))
                ]));
    if (result != null && mounted) {
      await _save(() => _repo.records.saveDay(data.date, notes: result));
    }
  }

  Widget _card(List<Widget> children) => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children)));
  Widget _progress(String label, double amount, double? target, String unit,
          int decimals) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        Text(
            '${amount.toStringAsFixed(decimals)}${target == null ? '' : ' / ${target.toStringAsFixed(decimals)}'} $unit',
            key: ValueKey('today-${label.toLowerCase()}'),
            style: Theme.of(context).textTheme.headlineSmall),
        if (target != null && target > 0)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(
                  value: (amount / target).clamp(0.0, 1.0),
                  semanticsLabel: label)),
      ]);
  @override
  Widget build(BuildContext context) => SafeArea(
      bottom: false,
      child: Column(children: [
        SizedBox(height: widget.topInset),
        Row(children: [
          IconButton(
              tooltip: 'Previous day',
              onPressed: () => _selectDate(DateTime(
                  selectedDate.year, selectedDate.month, selectedDate.day - 1)),
              icon: const Icon(Icons.chevron_left)),
          Expanded(
              child: TextButton(
                  onPressed: () async {
                    final date = await showDatePicker(
                        context: context,
                        initialDate: selectedDate,
                        firstDate: DateTime(1900),
                        lastDate: DateTime(2100));
                    if (date != null && mounted) _selectDate(date);
                  },
                  child: Text(DateFormat.yMMMd().format(selectedDate),
                      key: const ValueKey('today-date')))),
          IconButton(
              tooltip: 'Next day',
              onPressed: () => _selectDate(DateTime(
                  selectedDate.year, selectedDate.month, selectedDate.day + 1)),
              icon: const Icon(Icons.chevron_right)),
          TextButton(
              onPressed: () => _selectDate(DateTime.now()),
              child: const Text('Today'))
        ]),
        Expanded(
            child: StreamBuilder<TodayData>(
                key: ValueKey(localDateKey(selectedDate)),
                stream: _stream,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Could not load this day.'),
                      TextButton(
                          onPressed: () => _selectDate(selectedDate),
                          child: const Text('Retry'))
                    ]));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final data = snapshot.data!;
                  final totals = data.nutrition.summary;
                  final target = data.targets.profile;
                  return ListView(
                      key: const ValueKey('today-content'),
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 170),
                      children: [
                        _card([
                          DayLockAction(
                              date: data.date,
                              lock: data.dayLock,
                              repository: _repo.locks),
                          DropdownButtonFormField<TrainingType>(
                              key: ValueKey(
                                  'training-${data.trainingType.name}'),
                              initialValue: data.trainingType,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                  labelText: 'Training type'),
                              items: TrainingType.values
                                  .map((t) => DropdownMenuItem(
                                      value: t, child: Text(t.label)))
                                  .toList(),
                              onChanged: data.dayLock != null
                                  ? null
                                  : (type) {
                                      if (type != null) {
                                        _save(() => _repo.records.saveDay(
                                            data.date,
                                            trainingType: type));
                                      }
                                    }),
                          const SizedBox(height: 12),
                          Text(
                              data.weight == null
                                  ? 'No bodyweight recorded for this day'
                                  : 'Bodyweight: ${formatFoodQuantity(data.weight!.value)} ${data.weight!.unit}',
                              key: const ValueKey('today-weight')),
                          TextButton(
                              onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const MeasurementsScreen(
                                          initialMeasurementType: 'weight'))),
                              child: const Text('Body progress')),
                        ]),
                        _card([
                          _progress('Calories', totals.calories,
                              target?.calories, 'kcal', 0),
                          if (data.remainingCalories != null)
                            Text(data.remainingCalories! >= 0
                                ? '${data.remainingCalories!.toStringAsFixed(0)} kcal remaining'
                                : '${(-data.remainingCalories!).toStringAsFixed(0)} kcal over target'),
                          const SizedBox(height: 16),
                          _progress('Protein', totals.protein, target?.protein,
                              'g', 1),
                          const SizedBox(height: 12),
                          Text('Carbs ${totals.carbs.toStringAsFixed(1)} g',
                              key: const ValueKey('today-carbs')),
                          Text('Fat ${totals.fat.toStringAsFixed(1)} g',
                              key: const ValueKey('today-fat')),
                          const SizedBox(height: 12),
                          Text(data.targets.explanation),
                          TextButton(
                              onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => TargetProfilesScreen(
                                          repository: _repo.records))),
                              child: Text(target == null
                                  ? 'Set targets'
                                  : 'Edit target profiles')),
                        ]),
                        _card([
                          Text('Foods',
                              style: Theme.of(context).textTheme.titleLarge),
                          if (widget.onAddFood != null)
                            FilledButton.icon(
                                onPressed: data.dayLock == null
                                    ? widget.onAddFood
                                    : null,
                                icon: const Icon(Icons.add),
                                label: const Text('Add food')),
                          if (data.foods.isEmpty &&
                              data.fluids.isEmpty &&
                              data.missingFoods == 0)
                            const Text('No food logged for this day'),
                          for (final food in data.foods)
                            ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(food.item.name),
                                subtitle: Text(
                                    '${food.displayQuantity} · ${food.calculatedCalories.toStringAsFixed(0)} kcal'),
                                trailing: IconButton(
                                  tooltip: 'Copy food',
                                  icon: const Icon(Icons.copy_outlined),
                                  onPressed: () => showCopyToDate(
                                      context,
                                      _copy,
                                      DayCopyRequest(
                                          sourceDate: data.date,
                                          destinationDate: DateTime.now(),
                                          foodEntryId: food.entry.id)),
                                ),
                                onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => FoodDetailScreen(
                                            trackedItem: food,
                                            readOnly: true)))),
                          for (final fluid in data.fluids
                              .where((f) => f.linkedFoodEntryId == null))
                            ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(fluid.name),
                                subtitle: Text(
                                    '${formatFoodQuantity(fluid.quantityInMl)} ml · ${(fluid.kcal ?? 0).toStringAsFixed(0)} kcal')),
                          if (data.missingFoods > 0)
                            Text(
                                '${data.missingFoods} food snapshot(s) unavailable; totals may be incomplete.'),
                          if (widget.onOpenDiary != null)
                            TextButton(
                                onPressed: data.dayLock == null
                                    ? () => widget.onOpenDiary!(data.date)
                                    : null,
                                child: const Text('Edit food log')),
                          TextButton.icon(
                            onPressed: () => showDayCopyPreview(
                                context,
                                _copy,
                                DayCopyRequest(
                                    sourceDate: DateTime(data.date.year,
                                        data.date.month, data.date.day - 1),
                                    destinationDate: data.date,
                                    mealType: 'breakfast')),
                            icon: const Icon(Icons.replay),
                            label: const Text("Repeat Yesterday's Breakfast"),
                          ),
                          TextButton.icon(
                            onPressed: () => showDayCopyPreview(
                                context,
                                _copy,
                                DayCopyRequest(
                                    sourceDate: DateTime(data.date.year,
                                        data.date.month, data.date.day - 1),
                                    destinationDate: data.date),
                                dayOptions: true),
                            icon: const Icon(Icons.content_copy),
                            label: const Text('Copy Previous Day'),
                          ),
                        ]),
                        _card([
                          Text('Workout',
                              style: Theme.of(context).textTheme.titleLarge),
                          if (data.workouts.isEmpty)
                            const Text(
                                'No workout logged. Training type stays as you selected.'),
                          for (final workout in data.workouts)
                            WorkoutDayCard(
                                workout: workout,
                                timeKnown: !data.unknownWorkoutTimes
                                    .contains(workout.id),
                                summary:
                                    data.workoutDetails.summaries[workout.id],
                                compact: true,
                                onOpen: workout.status == 'completed'
                                    ? () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                WorkoutLogDetailScreen(
                                                    logId: workout.localId)))
                                    : widget.onOpenWorkout),
                          if (widget.onOpenWorkout != null)
                            TextButton(
                                onPressed: widget.onOpenWorkout,
                                child: const Text('Open workouts')),
                        ]),
                        _card([
                          Text('Daily notes',
                              style: Theme.of(context).textTheme.titleLarge),
                          Text(
                              data.record?.notes.isNotEmpty == true
                                  ? data.record!.notes
                                  : 'No notes yet',
                              key: const ValueKey('today-notes')),
                          TextButton(
                              onPressed: data.dayLock == null
                                  ? () => _editNotes(data)
                                  : null,
                              child: const Text('Edit notes'))
                        ]),
                      ]);
                })),
      ]));
}
