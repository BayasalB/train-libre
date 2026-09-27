import 'package:flutter/material.dart';
import '../../domain/models/food_alias.dart';
import '../../domain/models/food_item.dart';
import '../../domain/models/nutrition_values.dart';
import '../../domain/models/saved_food_metadata.dart';

/// Part of the existing food form; nothing is persisted before its Save action.
class SavedFoodFields extends StatefulWidget {
  final FoodItem? food;
  final List<FoodAliasDraft> aliases;
  const SavedFoodFields({super.key, this.food, required this.aliases});
  @override
  SavedFoodFieldsState createState() => SavedFoodFieldsState();
}

class SavedFoodFieldsState extends State<SavedFoodFields> {
  late final TextEditingController _serving;
  late final TextEditingController _sodium;
  late final TextEditingController _notes;
  late final TextEditingController _photo;
  late final TextEditingController _label;
  late List<FoodAliasDraft> aliases;
  late String unit;
  late String servingUnit;
  late NutritionSource source;
  late bool verified;
  DateTime? verifiedAt;

  @override
  void initState() {
    super.initState();
    final meta = widget.food?.metadata ?? const SavedFoodMetadata();
    _serving = TextEditingController(text: meta.servingSize?.toString() ?? '');
    _sodium =
        TextEditingController(text: widget.food?.sodium?.toString() ?? '');
    _notes = TextEditingController(text: meta.notes ?? '');
    _photo = TextEditingController(text: meta.productPhotoRef ?? '');
    _label = TextEditingController(text: meta.labelPhotoRef ?? '');
    aliases = List.of(widget.aliases);
    unit = widget.food?.isLiquid == true || widget.food?.isFluid == true
        ? 'ml'
        : 'g';
    servingUnit = meta.servingUnit ?? unit;
    source = widget.food?.nutritionSource ?? NutritionSource.manual;
    verified = meta.verified;
    verifiedAt = meta.verifiedAt;
  }

  double? get sodium => parseNutritionNumber(_sodium.text);
  String? _optional(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();
  SavedFoodMetadata get metadata => SavedFoodMetadata(
      servingSize: parseNutritionNumber(_serving.text),
      servingUnit: _serving.text.trim().isEmpty ? null : servingUnit,
      source: source,
      verified: verified,
      verifiedAt: verified ? verifiedAt : null,
      notes: _optional(_notes),
      productPhotoRef: _optional(_photo),
      labelPhotoRef: _optional(_label));

  @override
  void dispose() {
    for (final controller in [_serving, _sodium, _notes, _photo, _label]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _editAlias([int? index]) async {
    final original = index == null ? null : aliases[index];
    final text = TextEditingController(text: original?.alias ?? '');
    final language = TextEditingController(text: original?.language ?? '');
    final form = GlobalKey<FormState>();
    final route = DialogRoute<FoodAliasDraft>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(index == null ? 'Add alias' : 'Edit alias'),
              content: Form(
                  key: form,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextFormField(
                        controller: text,
                        autofocus: true,
                        decoration: const InputDecoration(labelText: 'Alias'),
                        validator: (value) {
                          final key = normalizeFoodAlias(value ?? '');
                          if (key.isEmpty) return 'Enter an alias';
                          for (var i = 0; i < aliases.length; i++) {
                            if (i != index &&
                                normalizeFoodAlias(aliases[i].alias) == key) {
                              return 'Alias already exists for this food';
                            }
                          }
                          return null;
                        }),
                    TextFormField(
                        controller: language,
                        decoration: const InputDecoration(
                            labelText: 'Language (optional)',
                            hintText: 'mn, en')),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel')),
                TextButton(
                    onPressed: () {
                      if (form.currentState!.validate()) {
                        Navigator.pop(
                            ctx,
                            FoodAliasDraft(
                                id: original?.id,
                                alias: text.text,
                                language: language.text.trim().isEmpty
                                    ? null
                                    : language.text.trim()));
                      }
                    },
                    child: const Text('Done'))
              ],
            ));
    final result = await Navigator.of(context).push(route);
    await route.completed;
    text.dispose();
    language.dispose();
    if (!mounted || result == null) return;
    setState(() {
      if (index == null) {
        aliases.add(result);
      } else {
        aliases[index] = result;
      }
    });
  }

  Widget _text(TextEditingController controller, String label,
          {bool number = false, String? helper}) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextFormField(
              controller: controller,
              keyboardType: number
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : TextInputType.text,
              decoration: InputDecoration(
                  labelText: label, helperText: helper, helperMaxLines: 3),
              validator: number
                  ? (value) {
                      if (value == null || value.trim().isEmpty) return null;
                      final parsed = parseNutritionNumber(value);
                      if (parsed == null ||
                          parsed < 0 ||
                          (controller == _serving && parsed == 0)) {
                        return 'Enter a valid positive quantity';
                      }
                      if (controller == _serving && servingUnit != unit) {
                        return 'Serving unit must match the nutrition basis';
                      }
                      return null;
                    }
                  : null));

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Saved Food details',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
            initialValue: unit,
            decoration: const InputDecoration(labelText: 'Nutrition basis'),
            items: const [
              DropdownMenuItem(value: 'g', child: Text('Per 100 g')),
              DropdownMenuItem(value: 'ml', child: Text('Per 100 ml'))
            ],
            onChanged: (value) => setState(() {
                  unit = value!;
                })),
        const SizedBox(height: 14),
        _text(_serving, 'Serving size (optional)',
            number: true,
            helper: 'One serving, separate from package quantity.'),
        DropdownButtonFormField<String>(
            initialValue: servingUnit,
            decoration: const InputDecoration(labelText: 'Serving unit'),
            items: const [
              DropdownMenuItem(value: 'g', child: Text('g')),
              DropdownMenuItem(value: 'ml', child: Text('ml'))
            ],
            onChanged: (value) => setState(() {
                  servingUnit = value!;
                })),
        const SizedBox(height: 14),
        _text(_sodium, 'Sodium (g per 100 g/ml)',
            number: true,
            helper:
                'Explicit label value. 1000 mg = 1 g. Stored separately from salt.'),
        DropdownButtonFormField<NutritionSource>(
            initialValue: source,
            decoration: const InputDecoration(labelText: 'Nutrition source'),
            items: NutritionSource.values
                .map((value) =>
                    DropdownMenuItem(value: value, child: Text(value.name)))
                .toList(),
            onChanged: (value) => setState(() {
                  source = value!;
                })),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Verified nutrition'),
            value: verified,
            onChanged: (value) => setState(() {
                  verified = value;
                  verifiedAt = value ? DateTime.now() : null;
                })),
        if (verified)
          TextButton(
              onPressed: () async {
                final date = await showDatePicker(
                    context: context,
                    initialDate: verifiedAt ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now());
                if (mounted && date != null) {
                  setState(() {
                    verifiedAt = date;
                  });
                }
              },
              child: Text(
                  'Verified: ${verifiedAt?.toIso8601String().split('T').first ?? ''}')),
        _text(_notes, 'Notes'),
        _text(_photo, 'Product photo reference (optional)',
            helper:
                'Local file reference. The photo file itself is not included in the JSON backup.'),
        _text(_label, 'Nutrition-label photo reference (optional)'),
        Text('Aliases', style: Theme.of(context).textTheme.titleMedium),
        const Text(
            'Assign your own names. If another food has the same alias, search will show both for you to choose.'),
        for (var i = 0; i < aliases.length; i++)
          ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(aliases[i].alias),
              subtitle: aliases[i].language == null
                  ? null
                  : Text(aliases[i].language!),
              onTap: () => _editAlias(i),
              trailing: IconButton(
                  tooltip: 'Remove alias',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                        aliases.removeAt(i);
                      }))),
        TextButton.icon(
            onPressed: () => _editAlias(),
            icon: const Icon(Icons.add),
            label: const Text('Add alias')),
      ]);
}
