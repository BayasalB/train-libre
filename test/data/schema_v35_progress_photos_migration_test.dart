import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/features/profile/data/sources/profile_local_data_source.dart';
import 'package:train_libre/features/profile/domain/models/measurement.dart'
    as model;
import 'package:train_libre/features/profile/domain/models/measurement_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v34 to v35 adds photos without changing measurement identity or values',
      () async {
    final dir = await Directory.systemTemp.createTemp('v35-migration-');
    final file = File('${dir.path}/app.sqlite');
    try {
      final seed = AppDatabase(NativeDatabase(file));
      await ProfileLocalDataSource(seed).insertMeasurementSession(
          MeasurementSession(
              timestamp: DateTime(2026, 9, 24, 8),
              measurements: [
            model.Measurement(
                sessionId: 0, type: 'abdomen', value: 102.25, unit: 'cm'),
            model.Measurement(
                sessionId: 0, type: 'lower_belly', value: 103.75, unit: 'cm'),
          ]));
      await seed.close();

      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE progress_photos');
      raw.execute('PRAGMA user_version = 34');
      final before = raw
          .select('SELECT * FROM measurements ORDER BY local_id')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
      raw.close();

      final upgraded = AppDatabase(NativeDatabase(file));
      try {
        final after = (await upgraded
                .customSelect('SELECT * FROM measurements ORDER BY local_id')
                .get())
            .map((row) => row.data)
            .toList();
        expect(after, before);
        expect(
            (await upgraded.select(upgraded.measurements).get())
                .map((m) => m.type),
            containsAll(['abdomen', 'lower_belly']));
        expect(await upgraded.select(upgraded.progressPhotos).get(), isEmpty);
        expect(await upgraded.customSelect('PRAGMA foreign_key_check').get(),
            isEmpty);
        expect(await upgraded.reconcileSchema(), isEmpty);
        expect(
            (await upgraded.customSelect('PRAGMA user_version').getSingle())
                .read<int>('user_version'),
            36);
      } finally {
        await upgraded.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
