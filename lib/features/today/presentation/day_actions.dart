import 'package:flutter/material.dart';

import '../../../data/drift_database.dart' as db;
import '../../diary/data/day_copy_service.dart';
import '../../diary/domain/day_copy_request.dart';
import '../data/day_lock_repository.dart';

class DayLockAction extends StatelessWidget {
  final DateTime date;
  final db.DayLock? lock;
  final DayLockRepository repository;

  const DayLockAction(
      {super.key,
      required this.date,
      required this.lock,
      required this.repository});

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        key: ValueKey(lock == null ? 'lock-day' : 'unlock-day'),
        icon: Icon(lock == null ? Icons.lock_outline : Icons.lock_open),
        label: Text(lock == null ? 'Lock Day' : 'Locked 🔒 · Unlock Day'),
        onPressed: () async {
          try {
            if (lock == null) {
              await repository.lock(date);
            } else {
              await repository.unlock(date);
            }
          } catch (error) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not change day lock: $error')));
            }
          }
        },
      );
}

Future<void> showDayCopyPreview(
    BuildContext context, DayCopyService service, DayCopyRequest request,
    {bool dayOptions = false}) async {
  DayCopyPreview preview;
  try {
    preview = await service.preview(request);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not preview food: $error')));
    }
    return;
  }
  if (!context.mounted) return;
  var training = false;
  var notes = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Copy food preview'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(shrinkWrap: true, children: [
            if (preview.isEmpty)
              const Text('No foods to copy from this day or meal.'),
            for (final food in preview.foods)
              ListTile(
                title: Text(food.name),
                subtitle: Text(
                    '${food.quantity} g · ${food.nutrition.calories.toStringAsFixed(0)} kcal · P ${food.nutrition.protein.toStringAsFixed(1)} · C ${food.nutrition.carbs.toStringAsFixed(1)} · F ${food.nutrition.fat.toStringAsFixed(1)}'),
              ),
            if (!preview.isEmpty)
              Text(
                  'Total ${preview.total.calories.toStringAsFixed(0)} kcal · P ${preview.total.protein.toStringAsFixed(1)} · C ${preview.total.carbs.toStringAsFixed(1)} · F ${preview.total.fat.toStringAsFixed(1)}'),
            if (dayOptions) ...[
              CheckboxListTile(
                title: const Text('Training type'),
                value: training,
                onChanged: (value) =>
                    setDialogState(() => training = value ?? false),
              ),
              CheckboxListTile(
                title: const Text('Daily notes'),
                value: notes,
                onChanged: (value) =>
                    setDialogState(() => notes = value ?? false),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: preview.isEmpty && (!dayOptions || (!training && !notes))
                ? null
                : () async {
                    try {
                      await service.copy(DayCopyRequest(
                        sourceDate: request.sourceDate,
                        destinationDate: request.destinationDate,
                        foodEntryId: request.foodEntryId,
                        mealEntryId: request.mealEntryId,
                        mealType: request.mealType,
                        includeTrainingType: training,
                        includeNotes: notes,
                      ));
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                    } catch (error) {
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext)
                            .showSnackBar(SnackBar(
                          content: Text(error is DayLockedException
                              ? error.toString()
                              : 'Could not copy food: $error'),
                        ));
                      }
                    }
                  },
            child: const Text('Confirm'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showCopyToDate(
    BuildContext context, DayCopyService service, DayCopyRequest source) async {
  final destination = await showDatePicker(
    context: context,
    initialDate: source.destinationDate,
    firstDate: DateTime(1900),
    lastDate: DateTime(2100),
  );
  if (destination == null || !context.mounted) return;
  await showDayCopyPreview(
      context,
      service,
      DayCopyRequest(
        sourceDate: source.sourceDate,
        destinationDate: destination,
        foodEntryId: source.foodEntryId,
        mealEntryId: source.mealEntryId,
        mealType: source.mealType,
      ));
}
