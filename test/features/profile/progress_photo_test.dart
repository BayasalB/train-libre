import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:train_libre/core/infrastructure/backup_manager.dart';
import 'package:train_libre/core/media/app_media_store.dart';
import 'package:train_libre/data/database_helper.dart';
import 'package:train_libre/data/drift_database.dart';
import 'package:train_libre/features/profile/data/progress_photo_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory supportDir;
  late AppDatabase db;
  late ProgressPhotoRepository photos;
  late BackupManager backup;
  final date = DateTime(2026, 9, 24);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    supportDir = await Directory.systemTemp.createTemp('progress-photos-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => supportDir.path);
    AppMediaStore.instance.resetForTesting();
    db = AppDatabase(
        NativeDatabase(File(p.join(supportDir.path, 'app.sqlite'))));
    final helper = DatabaseHelper.forTesting(db);
    DatabaseHelper.setDriftDb(db);
    photos = ProgressPhotoRepository(db);
    backup = BackupManager(userDb: helper);
  });
  tearDown(() async {
    await db.close();
    AppMediaStore.instance.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    await supportDir.delete(recursive: true);
  });

  Future<File> sourceFile(String name) async {
    final file = File(p.join(supportDir.path, name));
    // The media store falls back to copying these bytes in a headless test.
    await file.writeAsBytes(List<int>.filled(256, 7));
    return file;
  }

  test('add, note, multiple photos, restart and delete stay local', () async {
    final first = await photos.add(await sourceFile('a.jpg'), date);
    final second =
        await photos.add(await sourceFile('b.jpg'), date, note: 'Front');
    expect(first.id, isNot(second.id));
    expect(first.localDate, '2026-09-24');
    expect(first.mediaPath, startsWith('media/progress/'));
    final stored = await AppMediaStore.instance.resolve(first.mediaPath);
    expect(await stored!.exists(), isTrue);
    await photos.updateNote(first.id, 'Side');
    await db.close();
    db = AppDatabase(
        NativeDatabase(File(p.join(supportDir.path, 'app.sqlite'))));
    photos = ProgressPhotoRepository(db);
    final reloaded = await photos.watchDay(date).first;
    expect(reloaded, hasLength(2));
    expect(reloaded.singleWhere((p) => p.id == first.id).note, 'Side');
    await photos.delete(first.id);
    expect(await stored.exists(), isFalse);
    expect((await photos.watchDay(date).first).single.id, second.id);
  });

  test('archive restores app-stored photo bytes and metadata', () async {
    final photo = await photos.add(await sourceFile('backup.jpg'), date,
        note: 'Check-in');
    final stored = (await AppMediaStore.instance.resolve(photo.mediaPath))!;
    final beforeBytes = await stored.readAsBytes();
    final archive = await backup.buildBackupArchive(
        targetPath: p.join(supportDir.path, 'backup.zip'));
    await (db.delete(db.progressPhotos)..where((t) => t.id.equals(photo.id)))
        .go();
    await stored.delete();
    expect(await backup.importFullBackupAuto(archive.path), isTrue);
    final restored = (await db.select(db.progressPhotos).get()).single;
    expect(restored.id, photo.id);
    expect(restored.localDate, '2026-09-24');
    expect(restored.note, 'Check-in');
    expect(await stored.readAsBytes(), beforeBytes);
  });

  test('encrypted archive restores progress image with the right passphrase',
      () async {
    final photo = await photos.add(await sourceFile('private.jpg'), date);
    final stored = (await AppMediaStore.instance.resolve(photo.mediaPath))!;
    final beforeBytes = await stored.readAsBytes();
    final archive = await backup.buildBackupArchive(
        targetPath: p.join(supportDir.path, 'private.zip'),
        passphrase: 'local-secret');
    await (db.delete(db.progressPhotos)..where((t) => t.id.equals(photo.id)))
        .go();
    await stored.delete();
    expect(
        await backup.importFullBackupAuto(archive.path,
            passphrase: 'local-secret'),
        isTrue);
    expect((await db.select(db.progressPhotos).get()).single.id, photo.id);
    expect(await stored.readAsBytes(), beforeBytes);
  });

  test('metadata without image is removed during restore', () async {
    final stored =
        File(p.join(supportDir.path, 'media', 'progress', 'missing.jpg'));
    await stored.parent.create(recursive: true);
    await stored.writeAsBytes([1, 2, 3]);
    await db.into(db.progressPhotos).insert(ProgressPhotosCompanion.insert(
        id: const drift.Value('missing-id'),
        localDate: '2026-09-24',
        mediaPath: 'media/progress/missing.jpg'));
    final payload = await backup.generateBackupPayloadForTesting();
    await stored.delete();
    expect(await backup.importBackupPayloadForTesting(payload), isTrue);
    expect(await db.select(db.progressPhotos).get(), isEmpty);
  });

  test(
      'archive creation refuses to claim a missing progress image is backed up',
      () async {
    final photo = await photos.add(await sourceFile('gone.jpg'), date);
    final stored = (await AppMediaStore.instance.resolve(photo.mediaPath))!;
    await stored.delete();
    await expectLater(
        backup.buildBackupArchive(
            targetPath: p.join(supportDir.path, 'incomplete.zip')),
        throwsStateError);
  });

  test('deleting one record keeps an image referenced by another', () async {
    final first = await photos.add(await sourceFile('shared.jpg'), date);
    await db.into(db.progressPhotos).insert(ProgressPhotosCompanion.insert(
        id: const drift.Value('second-reference'),
        localDate: '2026-09-24',
        mediaPath: first.mediaPath));
    final stored = (await AppMediaStore.instance.resolve(first.mediaPath))!;
    await photos.delete(first.id);
    expect(await stored.exists(), isTrue);
    await photos.delete('second-reference');
    expect(await stored.exists(), isFalse);
  });

  test('older v8 payload without progress photos still restores', () async {
    final payload = await backup.generateBackupPayloadForTesting();
    payload['schemaVersion'] = 8;
    payload.remove('progress_photos');
    expect(await backup.importBackupPayloadForTesting(payload), isTrue);
    expect(await db.select(db.progressPhotos).get(), isEmpty);
  });
}
