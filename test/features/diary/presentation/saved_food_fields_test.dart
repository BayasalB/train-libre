import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:train_libre/features/diary/domain/models/food_alias.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/saved_food_metadata.dart';
import 'package:train_libre/features/diary/presentation/widgets/saved_food_fields.dart';
import 'package:train_libre/features/diary/presentation/dialogs/quantity_dialog_content.dart';
import 'package:train_libre/generated/app_localizations.dart';

void main() {
  final food = FoodItem(
      barcode: 'whey',
      name: 'Kirkland Whey',
      calories: 288.97,
      protein: 15.65,
      carbs: 11.85,
      fat: 19.89,
      productQuantity: 1000,
      productQuantityUnit: 'g',
      sodium: .123,
      metadata: const SavedFoodMetadata(
          servingSize: 45.5, servingUnit: 'g', source: NutritionSource.label));
  testWidgets(
      'metadata editor preserves serving, sodium, notes and prevents mixed unit serving',
      (tester) async {
    final key = GlobalKey<SavedFoodFieldsState>();
    final form = GlobalKey<FormState>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: Form(
                    key: form,
                    child: SavedFoodFields(
                        key: key, food: food, aliases: const []))))));
    expect(key.currentState!.metadata.servingSize, 45.5);
    expect(key.currentState!.sodium, .123);
    expect(form.currentState!.validate(), isTrue);
    final serving =
        find.widgetWithText(TextFormField, 'Serving size (optional)');
    await tester.enterText(serving, '21,3');
    expect(key.currentState!.metadata.servingSize, 21.3);
    await tester.enterText(serving, '-5');
    expect(form.currentState!.validate(), isFalse);
    await tester.enterText(serving, '30');
    key.currentState!.servingUnit = 'ml';
    expect(form.currentState!.validate(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'alias dialog rejects duplicates, edits original UUID and supports deletion',
      (tester) async {
    final key = GlobalKey<SavedFoodFieldsState>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: SavedFoodFields(key: key, food: food, aliases: const [
      FoodAliasDraft(id: 'uuid', alias: 'uurag', language: 'mn')
    ])))));
    await tester.ensureVisible(find.text('Add alias'));
    await tester.tap(find.text('Add alias'));
    await tester.pumpAndSettle();
    final aliasField = find
        .descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextFormField))
        .first;
    await tester.enterText(aliasField, ' UURAG ');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Alias already exists for this food'), findsOneWidget);
    await tester.enterText(aliasField, 'уураг');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(key.currentState!.aliases.length, 2);
    await tester.ensureVisible(find.text('uurag'));
    await tester.tap(find.text('uurag'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find
            .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(TextFormField))
            .first,
        'whey');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(key.currentState!.aliases.first.id, 'uuid');
    expect(key.currentState!.aliases.first.alias, 'whey');
    await tester.ensureVisible(find.byTooltip('Remove alias').first);
    await tester.tap(find.byTooltip('Remove alias').first);
    await tester.pumpAndSettle();
    expect(key.currentState!.aliases.single.alias, 'уураг');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'quantity entry defaults to serving size rather than the package size',
      (tester) async {
    final key = GlobalKey<QuantityDialogContentState>();
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: QuantityDialogContent(key: key, item: food))));
    expect(key.currentState!.quantityText, '45.5');
  });
}
