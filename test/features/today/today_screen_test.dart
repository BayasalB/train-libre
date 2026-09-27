import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/features/today/data/today_repository.dart';
import 'package:train_libre/features/today/data/daily_record_repository.dart';
import 'package:train_libre/features/today/domain/daily_record_models.dart';
import 'package:train_libre/features/today/presentation/today_screen.dart';
import 'package:train_libre/features/diary/data/sources/product_local_data_source.dart';
import 'package:train_libre/features/diary/data/sources/diary_local_data_source.dart';
import 'package:train_libre/features/diary/domain/models/food_item.dart';
import 'package:train_libre/features/diary/domain/models/food_entry.dart';
import 'package:train_libre/features/profile/data/sources/profile_local_data_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppDatabase db;
  late TodayRepository today;
  final day = DateTime(2026, 9, 24);
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('today-widget-');
    db = AppDatabase(NativeDatabase(File('${dir.path}/test.sqlite')));
    DatabaseHelper.setDriftDb(db);
    today = TodayRepository(db);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  Future<void> seed() async {
    await DailyRecordRepository(db, clock: () => day).saveTargets(
        effectiveFrom: day,
        training: const NutritionTargets(
            calories: 2750, protein: 200, carbs: 250, fat: 80),
        rest: const NutritionTargets(
            calories: 2300, protein: 200, carbs: 200, fat: 70));
    await ProductLocalDataSource.forTesting(db).insertProduct(FoodItem(
        barcode: 'b',
        name: 'Label burger',
        calories: 288.97,
        protein: 15.65,
        carbs: 11.85,
        fat: 19.89,
        source: FoodItemSource.user));
    await DiaryLocalDataSource(db).insertFoodEntry(FoodEntry(
        barcode: 'b',
        timestamp: day,
        quantityInGrams: 293.8,
        mealType: 'mealtypeLunch'));
    await ProfileLocalDataSource(db).saveWeightKg(89.35, date: day);
  }

  Widget app({DateTime? date}) => MaterialApp(
      home: Scaffold(
          body: TodayScreen(repository: today, initialDate: date ?? day)));

  testWidgets(
      'Today shows local data and explicit target fallback; date changes totals',
      (tester) async {
    await seed();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Bodyweight: 89.35 kg'), findsOneWidget);
    expect(find.text('849 / 2750 kcal'), findsOneWidget);
    expect(find.text('46.0 / 200.0 g'), findsOneWidget);
    expect(find.text('Carbs 34.8 g'), findsOneWidget);
    expect(find.text('Fat 58.4 g'), findsOneWidget);
    expect(find.textContaining('Training type is unset'), findsOneWidget);
    await tester.ensureVisible(find.text('Label burger'));
    expect(find.text('Label burger'), findsOneWidget);
    await tester.tap(find.byTooltip('Next day'));
    await tester.pumpAndSettle();
    expect(find.text('0 / 2750 kcal'), findsOneWidget);
    expect(find.text('No bodyweight recorded for this day'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('Rest selection, note edit and restart keep day state',
      (tester) async {
    await seed();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<TrainingType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rest').last);
    await tester.pumpAndSettle();
    expect(find.text('849 / 2300 kcal'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Edit notes'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -220));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit notes'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('daily-notes-input')),
        'Strong shoulder session');
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Strong shoulder session'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
    db = AppDatabase(NativeDatabase(File('${dir.path}/test.sqlite')));
    DatabaseHelper.setDriftDb(db);
    today = TodayRepository(db);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('849 / 2300 kcal'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Strong shoulder session'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Strong shoulder session'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
