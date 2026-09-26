import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/nutrition_values.dart';
import 'package:train_libre/features/diary/presentation/dialogs/quantity_dialog_content.dart';
import 'package:train_libre/generated/app_localizations.dart';
import 'package:train_libre/widgets/common/macro_badge_row.dart';

void main() {
  testWidgets('quantity editor preserves decimal grams and accepts comma input',
      (tester) async {
    final key = GlobalKey<QuantityDialogContentState>();
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
          body: SingleChildScrollView(
              child: QuantityDialogContent(
        key: key,
        item: FoodItem(
            barcode: 'sample',
            name: 'Sample',
            calories: 288.97,
            protein: 15.65,
            carbs: 11.85,
            fat: 19.89),
        initialQuantity: 293.8,
      ))),
    ));
    await tester.pumpAndSettle();
    expect(key.currentState!.quantityText, '293.8');
    final field = find.byType(TextField).first;
    expect(tester.widget<TextField>(field).keyboardType.decimal, isTrue);
    await tester.enterText(field, '45,5');
    expect(parseNutritionNumber(key.currentState!.quantityText), 45.5);
    await tester.enterText(field, '21.3');
    expect(parseNutritionNumber(key.currentState!.quantityText), 21.3);
  });

  testWidgets('macro display rounds once to one decimal', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: MacroBadgeRow(
      kcal: 848.99386,
      protein: 45.9797,
      carbs: 34.8153,
      fat: 58.43682,
    ))));
    expect(find.textContaining('849 kcal'), findsOneWidget);
    expect(find.textContaining('46.0g P'), findsOneWidget);
    expect(find.textContaining('34.8g C'), findsOneWidget);
    expect(find.textContaining('58.4g F'), findsOneWidget);
  });
}
