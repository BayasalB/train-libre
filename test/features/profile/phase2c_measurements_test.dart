import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/features/profile/data/sources/profile_local_data_source.dart';
import 'package:train_libre/features/profile/domain/latest_measurements.dart';
import 'package:train_libre/features/profile/domain/models/measurement.dart'
    as model;
import 'package:train_libre/features/profile/domain/models/measurement_session.dart';
import 'package:train_libre/features/history/data/history_repository.dart';
import 'package:train_libre/features/statistics/domain/timeframe_block.dart';
import 'package:train_libre/features/today/data/today_repository.dart';
import 'package:train_libre/services/unit_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppDatabase db;
  late ProfileLocalDataSource source;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('phase2c-measurements-');
    db = AppDatabase(NativeDatabase(File('${dir.path}/app.sqlite')));
    source = ProfileLocalDataSource(db);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  model.Measurement m(String type, double value, String unit) =>
      model.Measurement(sessionId: 0, type: type, value: value, unit: unit);

  test('Lower Belly stays distinct from abdomen and survives restart',
      () async {
    final date = DateTime(2026, 9, 24, 8);
    await source.insertMeasurementSession(
        MeasurementSession(timestamp: date, measurements: [
      m('waist', 100, 'cm'),
      m('abdomen', 102, 'cm'),
      m('lower_belly', 103.25, 'cm'),
      m('weight', 99.5, 'kg'),
    ]));
    await db.close();
    db = AppDatabase(NativeDatabase(File('${dir.path}/app.sqlite')));
    source = ProfileLocalDataSource(db);
    final session = (await source.getMeasurementSessions()).single;
    expect(session.measurements.map((m) => m.type),
        containsAll(['waist', 'abdomen', 'lower_belly', 'weight']));
    expect(
        session.measurements.singleWhere((m) => m.type == 'lower_belly').value,
        103.25);
  });

  test(
      'edit updates existing IDs atomically, changes date and prevents duplicates',
      () async {
    final firstDate = DateTime(2026, 9, 24, 8);
    await source.insertMeasurementSession(MeasurementSession(
        timestamp: firstDate,
        measurements: [m('waist', 100, 'cm'), m('lower_belly', 103, 'cm')]));
    final original = (await source.getMeasurementSessions()).single;
    final oldId =
        original.measurements.singleWhere((m) => m.type == 'waist').id;
    final changedDate = DateTime(2026, 9, 25, 9);
    await source.updateMeasurementSession(
        original,
        MeasurementSession(
          id: original.id,
          timestamp: changedDate,
          measurements: [m('waist', 99.75, 'cm'), m('chest', 124.5, 'cm')],
        ));
    final changed = (await source.getMeasurementSessions()).single;
    expect(changed.id, original.id);
    expect(changed.timestamp, changedDate);
    expect(changed.measurements.map((m) => m.type),
        containsAll(['waist', 'chest']));
    expect(changed.measurements, hasLength(2));
    expect(
        changed.measurements.singleWhere((m) => m.type == 'waist').id, oldId);
    expect(changed.measurements.singleWhere((m) => m.type == 'waist').value,
        99.75);
    await expectLater(
      source.updateMeasurementSession(
          changed,
          MeasurementSession(
              id: changed.id,
              timestamp: changedDate,
              measurements: [m('waist', 1, 'cm'), m('waist', 2, 'cm')])),
      throwsArgumentError,
    );
    expect((await source.getMeasurementSessions()).single.measurements,
        hasLength(2));
  });

  test('multiple sessions on one day remain separate when one is deleted',
      () async {
    await source.insertMeasurementSession(MeasurementSession(
        timestamp: DateTime(2026, 9, 24, 8),
        measurements: [m('weight', 99.5, 'kg')]));
    await source.insertMeasurementSession(MeasurementSession(
        timestamp: DateTime(2026, 9, 24, 20),
        measurements: [m('weight', 99.7, 'kg')]));
    final sessions = await source.getMeasurementSessions();
    expect(sessions, hasLength(2));
    await source.deleteMeasurementSession(sessions.first.id!);
    final remaining = await source.getMeasurementSessions();
    expect(remaining, hasLength(1));
    expect(remaining.single.measurements.single.value, 99.5);
  });

  test('duplicate types in one new session are rejected without partial writes',
      () async {
    await expectLater(
        source.insertMeasurementSession(MeasurementSession(
            timestamp: DateTime(2026, 9, 24),
            measurements: [m('waist', 100, 'cm'), m('waist', 101, 'cm')])),
        throwsArgumentError);
    expect(await db.select(db.measurements).get(), isEmpty);
  });

  test('latest and previous values are selected by timestamp', () {
    final sessions = [
      MeasurementSession(
          timestamp: DateTime(2026, 9, 20),
          measurements: [m('weight', 100.1, 'kg'), m('waist', 101, 'cm')]),
      MeasurementSession(
          timestamp: DateTime(2026, 9, 25),
          measurements: [m('weight', 99.5, 'kg'), m('lower_belly', 103, 'cm')]),
      MeasurementSession(
          timestamp: DateTime(2026, 9, 23),
          measurements: [m('waist', 100, 'cm')]),
    ];
    final latest = latestMeasurements(sessions);
    expect(latest['weight']!.value, 99.5);
    expect(latest['weight']!.previousValue, 100.1);
    expect(latest['waist']!.change, -1);
    expect(latest['lower_belly']!.previousValue, isNull);
  });

  test('existing chart ranges cover 7, 30, 90 days and all time', () {
    expect(TimeframeBlock.week.rollingDurationDays, 7);
    expect(TimeframeBlock.month.rollingDurationDays, 30);
    expect(TimeframeBlock.threeMonths.rollingDurationDays, 90);
    expect(TimeframeBlock.maxBlock.getRollingBounds().start.year, 2020);
  });

  test('Lower Belly centimeters round-trip through imperial display units',
      () async {
    SharedPreferences.setMockInitialValues({'unit_system': 'imperial'});
    final units = UnitService();
    await units.reload();
    final inches = units.convertDisplayValue(103.25, UnitDimension.height);
    expect(units.suffixFor(UnitDimension.height), 'in');
    expect(units.convertToMetric(inches, UnitDimension.height),
        closeTo(103.25, 0.001));
    units.dispose();
  });

  test(
      'Today and History read edited weight and Lower Belly from the same rows',
      () async {
    final day = DateTime(2026, 9, 24);
    await source.insertMeasurementSession(
        MeasurementSession(timestamp: DateTime(2026, 9, 24, 8), measurements: [
      m('weight', 99.5, 'kg'),
      m('waist', 100, 'cm'),
      m('lower_belly', 103, 'cm'),
    ]));
    expect((await TodayRepository(db).load(day)).weight!.value, 99.5);
    var detail = await HistoryRepository(db).loadDay(day);
    expect(detail.measurements.map((m) => m.type),
        containsAll(['weight', 'waist', 'lower_belly']));
    final original = (await source.getMeasurementSessions()).single;
    await source.updateMeasurementSession(
        original,
        MeasurementSession(
            id: original.id,
            timestamp: original.timestamp,
            measurements: [
              m('weight', 99.7, 'kg'),
              m('waist', 100, 'cm'),
              m('lower_belly', 102.5, 'cm'),
            ]));
    expect((await TodayRepository(db).load(day)).weight!.value, 99.7);
    detail = await HistoryRepository(db).loadDay(day);
    expect(
        detail.measurements.singleWhere((m) => m.type == 'lower_belly').value,
        102.5);
  });

  test('a measurement exactly at local midnight belongs to that date',
      () async {
    final day = DateTime(2026, 9, 24);
    await source.insertMeasurementSession(MeasurementSession(
        timestamp: day, measurements: [m('lower_belly', 103.4, 'cm')]));
    expect(
        (await HistoryRepository(db).loadDay(day)).measurements, hasLength(1));
    expect(
        await source.getChartDataForTypeAndRange(
            'lower_belly', day, DateTime(2026, 9, 24, 23, 59, 59)),
        hasLength(1));
  });
}
