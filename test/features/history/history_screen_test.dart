import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/features/diary/data/sources/diary_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/domain/models/food_entry.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/history/data/history_repository.dart';
import 'package:train_libre/features/history/presentation/day_detail_screen.dart';
import 'package:train_libre/features/history/presentation/history_screen.dart';
import 'package:train_libre/features/today/data/daily_record_repository.dart';
import 'package:train_libre/features/today/domain/daily_record_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late HistoryRepository history;
  final date = DateTime(2026, 9, 24);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    history = HistoryRepository(db);
    await ProductLocalDataSource.forTesting(db).insertProduct(FoodItem(
        barcode: 'oats',
        name: 'Hercules Oats',
        calories: 288.97,
        protein: 15.65,
        carbs: 11.85,
        fat: 19.89,
        source: FoodItemSource.user));
    await db.into(db.mealEntries).insert(MealEntriesCompanion.insert(
        id: const drift.Value('meal-breakfast'),
        consumedAt: date,
        mealType: 'mealtypeBreakfast',
        source: 'manual',
        title: const drift.Value('Breakfast bowl')));
    await DiaryLocalDataSource(db).insertFoodEntry(FoodEntry(
        barcode: 'oats',
        timestamp: date,
        quantityInGrams: 293.8,
        mealType: 'mealtypeBreakfast',
        mealEntryId: 'meal-breakfast'));
    await DailyRecordRepository(db, clock: () => DateTime(2026, 9, 1))
        .saveTargets(
            effectiveFrom: DateTime(2026, 9, 1),
            training: const NutritionTargets(
                calories: 2750, protein: 200, carbs: 250, fat: 80),
            rest: const NutritionTargets(
                calories: 2300, protein: 180, carbs: 200, fat: 70));
    await DailyRecordRepository(db).saveDay(date,
        trainingType: TrainingType.shoulder, notes: 'Good session');
  });
  tearDown(() => db.close());

  testWidgets('History month opens day detail and navigates adjacent day',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(repository: history, initialMonth: date)));
    await tester.pumpAndSettle();
    expect(find.text('September 2026'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('history-day-2026-09-24')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('history-day-2026-09-24')));
    await tester.pumpAndSettle();
    expect(find.byType(DayDetailScreen), findsOneWidget);
    expect(find.text('849 / 2750 kcal'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Breakfast bowl'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Breakfast bowl'), findsOneWidget);
    expect(find.text('Bodyweight: 0 kg'), findsNothing);
    await tester.tap(find.byTooltip('Next day'));
    await tester.pumpAndSettle();
    expect(find.text('0 / 2750 kcal'), findsOneWidget);
    expect(find.text('No food logged'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('day detail edits historical notes and reacts to food deletion',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: DayDetailScreen(date: date, repository: history)));
    await tester.pumpAndSettle();
    expect(find.text('849 / 2750 kcal'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Edit notes'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(find.text('Good session'), findsOneWidget);
    await tester.tap(find.text('Edit notes'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('history-notes-input')),
        'Updated history note');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Updated history note'), findsOneWidget);
    final entry =
        (await DiaryLocalDataSource(db).getEntriesForDate(date)).single;
    await DiaryLocalDataSource(db).deleteFoodEntry(entry.id!);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 900));
    await tester.pumpAndSettle();
    expect(find.text('0 / 2750 kcal'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
