import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../data/database_helper.dart';
import '../data/historical_import_service.dart';

/// A deliberately reviewed path for portable v1 JSON. Opening a file only
/// reads it; the confirmation button is the first path to any live write.
class HistoricalImportScreen extends StatefulWidget {
  const HistoricalImportScreen({super.key, this.service});
  final HistoricalImportService? service;

  @override
  State<HistoricalImportScreen> createState() => _HistoricalImportScreenState();
}

class _HistoricalImportScreenState extends State<HistoricalImportScreen> {
  late final HistoricalImportService _service = widget.service ??
      HistoricalImportService(DatabaseHelper.instance.dbInstance);
  ImportPreview? _preview;
  ImportReport? _report;
  String? _error;
  bool _busy = false;
  final Map<String, FoodMapping> _foods = {};
  final Map<String, DayConflictChoice> _days = {};
  final Set<String> _targets = {};
  final Set<String> _keepExternal = {};
  final Map<String, String> _productNames = {};
  final Map<String, String> _exerciseLinks = {};
  final Map<String, String> _entryFoodLinks = {};

  Future<void> _select() async {
    final selected = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: ['json']);
    if (selected.isEmpty || selected.single.path == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _report = null;
      _preview = null;
    });
    try {
      final json = await File(selected.single.path!).readAsString();
      final preview = await _service.preview(json);
      final ids = {
        ...preview.foodSuggestions.values.expand((e) => e),
        ...preview.entryFoodSuggestions.values.expand((e) => e),
      };
      final products = ids.isEmpty
          ? []
          : await (_service.db.select(_service.db.products)
                ..where((t) => t.id.isIn(ids)))
              .get();
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _foods.clear();
        _days.clear();
        _targets.clear();
        _keepExternal.clear();
        _exerciseLinks.clear();
        _entryFoodLinks.clear();
        _productNames
          ..clear()
          ..addEntries(products.map((p) => MapEntry(p.id, p.name)));
      });
    } on ImportValidationException catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final preview = _preview;
    if (preview == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await _service.importReviewed(
        preview,
        ImportResolution(
          foods: Map.of(_foods),
          days: Map.of(_days),
          createTargetProfiles: Set.of(_targets),
          exerciseLinks: Map.of(_exerciseLinks),
          entryFoodLinks: Map.of(_entryFoodLinks),
          keepExistingExternalIds: Set.of(_keepExternal),
        ),
        confirmed: true,
      );
      if (mounted) {
        setState(() {
          _report = report;
          _preview = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Historical JSON import')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
            'Portable formatVersion 1 only. Review mappings before import. '
            'A recovery backup is saved before the database changes.'),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _select,
          icon: const Icon(Icons.file_open),
          label: const Text('Select JSON file'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)))),
        if (_report != null) ...[
          const SizedBox(height: 16),
          Text('Import complete',
              style: Theme.of(context).textTheme.titleLarge),
          Text('Batch: ${_report!.batchId}'),
          Text('Recovery backup: ${_report!.recoveryBackupPath}'),
          for (final entry in _report!.counts.entries)
            Text('${entry.key}: ${entry.value}'),
          for (final warning in _report!.warnings) Text('⚠ $warning'),
        ],
        if (preview != null) ...[
          const SizedBox(height: 16),
          Text('Preview · ${preview.document.metadata['source']}',
              style: Theme.of(context).textTheme.titleLarge),
          for (final entry in preview.counts.entries)
            if (entry.value > 0) Text('${entry.key}: ${entry.value}'),
          const SizedBox(height: 8),
          Text(
              'New: ${preview.newCount} · Already imported: ${preview.duplicateCount} · '
              'Reported-total-only days: ${preview.reportedTotalOnlyDays} · '
              'Planned/cancelled: ${preview.plannedOrCancelled} · '
              'Missing media: ${preview.missingMedia}'),
          for (final entry in preview.document.collections.entries)
            if (entry.value.isNotEmpty)
              ExpansionTile(
                title: Text('Review ${entry.key} (${entry.value.length})'),
                children: [
                  for (final record in entry.value.take(20))
                    ListTile(
                      dense: true,
                      title: Text(
                          '${record.fields['name'] ?? record.fields['type'] ?? record.id}'),
                      subtitle: Text([
                        if (record.date != null) record.date!,
                        if (record.fields['effectiveFrom'] != null)
                          '${record.fields['effectiveFrom']}',
                        if (record.fields['status'] != null)
                          '${record.fields['status']}',
                        if (record.fields['quantity'] != null)
                          '${record.fields['quantity']} ${record.fields['quantityUnit']}',
                        if (record.fields['weight'] != null)
                          '${record.fields['weight']} ${record.fields['weightUnit']}',
                        if (record.fields['reps'] != null)
                          '${record.fields['reps']} reps',
                        if (record.fields['reportedTotal'] is Map)
                          'Reported ${(record.fields['reportedTotal'] as Map)['calories'] ?? '—'} kcal',
                        if (record.provenance != null) record.provenance!,
                      ].join(' · ')),
                    ),
                  if (entry.value.length > 20)
                    ListTile(
                        title: Text(
                            '${entry.value.length - 20} more records in file')),
                ],
              ),
          const SizedBox(height: 16),
          for (final food in preview.document.records('savedFoods')) ...[
            Text('Saved Food ${food.fields['name']}: choose identity'),
            DropdownButtonFormField<String>(
              key: ValueKey('food-${food.id}'),
              initialValue: _foods[food.id] == null
                  ? preview.foodSuggestions.containsKey(food.id)
                      ? null
                      : 'create'
                  : _foods[food.id]!.choice == ImportChoice.link
                      ? _foods[food.id]!.localFoodId
                      : _foods[food.id]!.choice.name,
              hint: const Text('Choose mapping'),
              items: [
                const DropdownMenuItem(
                    value: 'create', child: Text('Create new')),
                const DropdownMenuItem(
                    value: 'unlinked',
                    child: Text('Leave historical entries unlinked')),
                for (final id
                    in preview.foodSuggestions[food.id] ?? const <String>[])
                  DropdownMenuItem(
                      value: id,
                      child: Text('Link: ${_productNames[id] ?? id}')),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                        if (value == null) return;
                        _foods[food.id] = value == 'create'
                            ? const FoodMapping(ImportChoice.create)
                            : value == 'unlinked'
                                ? const FoodMapping(ImportChoice.unlinked)
                                : FoodMapping(ImportChoice.link,
                                    localFoodId: value);
                      }),
            ),
          ],
          for (final entry in preview.exerciseSuggestions.entries)
            DropdownButtonFormField<String>(
              key: ValueKey('exercise-${entry.key}'),
              initialValue: _exerciseLinks[entry.key] ?? 'name-only',
              decoration: InputDecoration(labelText: 'Exercise ${entry.key}'),
              items: [
                const DropdownMenuItem(
                    value: 'name-only',
                    child: Text('Keep historical exercise name only')),
                for (final id in entry.value)
                  DropdownMenuItem(
                      value: id, child: Text('Link existing exercise $id')),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                        if (value == null || value == 'name-only') {
                          _exerciseLinks.remove(entry.key);
                        } else {
                          _exerciseLinks[entry.key] = value;
                        }
                      }),
            ),
          for (final entry in preview.entryFoodSuggestions.entries)
            DropdownButtonFormField<String>(
              key: ValueKey('entry-food-${entry.key}'),
              initialValue: _entryFoodLinks[entry.key] ?? 'unlinked',
              decoration: InputDecoration(labelText: 'Food entry ${entry.key}'),
              items: [
                const DropdownMenuItem(
                    value: 'unlinked',
                    child: Text('Keep historical entry unlinked')),
                for (final id in entry.value)
                  DropdownMenuItem(
                      value: id,
                      child: Text('Link: ${_productNames[id] ?? id}')),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                        if (value == null || value == 'unlinked') {
                          _entryFoodLinks.remove(entry.key);
                        } else {
                          _entryFoodLinks[entry.key] = value;
                        }
                      }),
            ),
          for (final conflict
              in preview.conflicts.where((c) => c.kind == 'date'))
            DropdownButtonFormField<DayConflictChoice>(
              key: ValueKey('day-${conflict.key}'),
              initialValue: _days[conflict.key.substring(5)],
              decoration: InputDecoration(
                  labelText: conflict.key, helperText: conflict.reason),
              items: [
                const DropdownMenuItem(
                    value: DayConflictChoice.keepExisting,
                    child: Text('Keep existing')),
                const DropdownMenuItem(
                    value: DayConflictChoice.useImported,
                    child: Text('Use imported day metadata')),
                const DropdownMenuItem(
                    value: DayConflictChoice.skipDate,
                    child: Text('Skip this date')),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                        if (value != null) {
                          _days[conflict.key.substring(5)] = value;
                        }
                      }),
            ),
          for (final conflict
              in preview.conflicts.where((c) => c.kind == 'externalId'))
            CheckboxListTile(
              title: Text('Keep existing: ${conflict.key}'),
              subtitle: Text(conflict.reason),
              value: _keepExternal.contains(conflict.key),
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                        if (value == true) {
                          _keepExternal.add(conflict.key);
                        } else {
                          _keepExternal.remove(conflict.key);
                        }
                      }),
            ),
          for (final target in preview.document.records('targetProfiles'))
            if (['calories', 'protein', 'carbs', 'fat']
                .every(target.fields.containsKey))
              CheckboxListTile(
                title: Text('Create target profile ${target.id}'),
                subtitle: Text(
                    '${target.fields['kind']} · ${target.fields['effectiveFrom']}'),
                value: _targets.contains(target.id),
                onChanged: _busy || preview.targetConflicts.contains(target.id)
                    ? null
                    : (value) => setState(() {
                          if (value == true) {
                            _targets.add(target.id);
                          } else {
                            _targets.remove(target.id);
                          }
                        }),
              ),
          if (preview.warnings.isNotEmpty) ...[
            Text('Warnings', style: Theme.of(context).textTheme.titleMedium),
            for (final warning in preview.warnings) Text('⚠ $warning'),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('confirm-historical-import'),
            onPressed: _busy ? null : _import,
            child: const Text('Confirm and import'),
          ),
        ],
      ]),
    );
  }
}
