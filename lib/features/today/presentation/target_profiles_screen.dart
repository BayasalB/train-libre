import 'package:flutter/material.dart';
import '../../../data/database_helper.dart';
import '../../diary/domain/models/nutrition_values.dart';
import '../data/daily_record_repository.dart';
import '../domain/daily_record_models.dart';

class TargetProfilesScreen extends StatefulWidget {
  final DailyRecordRepository? repository;
  const TargetProfilesScreen({super.key, this.repository});
  @override
  State<TargetProfilesScreen> createState() => _TargetProfilesScreenState();
}

class _TargetProfilesScreenState extends State<TargetProfilesScreen> {
  final _form = GlobalKey<FormState>();
  final _fields = List.generate(8, (_) => TextEditingController());
  late final DailyRecordRepository _repo = widget.repository ??
      DailyRecordRepository(DatabaseHelper.instance.dbInstance);
  late DateTime _effective = localDay(_repo.clock());
  bool _loading = true, _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      for (var i = 0; i < 2; i++) {
        final p = await _repo.profileFor(TargetKind.values[i], _effective);
        if (p != null) {
          final values = [p.calories, p.protein, p.carbs, p.fat];
          for (var n = 0; n < 4; n++) {
            _fields[i * 4 + n].text = formatFoodQuantity(values[n]);
          }
        }
      }
    } catch (e) {
      _error = 'Could not load targets: $e';
    }
    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    NutritionTargets values(int offset) => NutritionTargets(
        calories: parseNutritionNumber(_fields[offset].text)!,
        protein: parseNutritionNumber(_fields[offset + 1].text)!,
        carbs: parseNutritionNumber(_fields[offset + 2].text)!,
        fat: parseNutritionNumber(_fields[offset + 3].text)!);
    try {
      await _repo.saveTargets(
          effectiveFrom: _effective, training: values(0), rest: values(4));
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Manual nutrition targets')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _form,
              child: ListView(padding: const EdgeInsets.all(20), children: [
                const Text(
                    'These targets control Today. Adaptive recommendations do not change them. Unset training type uses training-day targets, never assumes Rest.'),
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Effective from'),
                    subtitle: Text(localDateKey(_effective)),
                    trailing: const Icon(Icons.calendar_today),
                    onTap: _saving
                        ? null
                        : () async {
                            final day = await showDatePicker(
                                context: context,
                                initialDate: _effective,
                                firstDate: localDay(_repo.clock()),
                                lastDate: DateTime(2100));
                            if (mounted && day != null) {
                              setState(() {
                                _effective = day;
                              });
                            }
                          }),
                const Text(
                    'Saving creates a new version. Dates before this effective date keep their previous targets.'),
                for (var group = 0; group < 2; group++) ...[
                  Padding(
                      padding: const EdgeInsets.only(top: 24, bottom: 12),
                      child: Text(group == 0 ? 'Training day' : 'Rest day',
                          style: Theme.of(context).textTheme.titleLarge)),
                  for (var n = 0; n < 4; n++)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: TextFormField(
                            key: ValueKey('target-$group-$n'),
                            controller: _fields[group * 4 + n],
                            enabled: !_saving,
                            decoration: InputDecoration(
                                labelText: [
                              'Calories (kcal)',
                              'Protein (g)',
                              'Carbs (g)',
                              'Fat (g)'
                            ][n]),
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            validator: (text) {
                              final value = parseNutritionNumber(text ?? '');
                              return value == null ||
                                      value < 0 ||
                                      (n == 0 && value == 0)
                                  ? 'Enter a valid target'
                                  : null;
                            })),
                ],
                if (_error != null)
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                FilledButton(
                    onPressed:
                        _saving || _error?.startsWith('Could not load') == true
                            ? null
                            : _save,
                    child: Text(_saving ? 'Saving…' : 'Save target version')),
              ])));
}
