# Phase 1D: data safety and integrity verification

This work starts from the clean Phase 1C commit `7b88606230266e90b47f8f312f48e9a8bbb4acc6` on `codex/phase-1a-decimal-nutrition`. It changes no SQLite schema, adds no feature from Phase 2, and is intentionally uncommitted pending review.

## Findings and fixes

- A food write could create an archive nutrition snapshot and then fail to write its log, leaving an orphan snapshot. Food insert/edit and linked food/fluid deletion now run in Drift transactions. A trigger-induced failure test verifies rollback of both sides, including linked fluid rows.
- Opening an encrypted backup with a wrong passphrase leaked an open file handle. That prevented archive cleanup on Windows. `BackupArchive.open` now closes its input on every error path; the existing wrong-passphrase archive test passes.
- Restore previously accepted future backup format versions, ignored unknown top-level fields, and skipped malformed raw rows/columns. Format 8 now rejects unsupported typed nested fields before any restore write; future versions and unknown top-level fields are also rejected before writes. Raw-row errors abort the existing database transaction and restore the previous preferences. Tests confirm the prior local data remains after rejection or rollback.

## Migration and historical data

The supported legacy v29 fixture migrates to v34; v31→v32, v32→v33, v33→v34, and the sequential route through the Phase 1 changes are exercised. The new v33 fixture includes a user Saved Food, label metadata, alias, favorite, fractional food log, point-in-time nutrition archive and hash, meal template/item, workout, and weight measurement. Raw rows before and after migration are compared for IDs, UUIDs, timestamps, nutrition, hashes, and references. `sqlite_sequence` survives and its next inserted ID remains above the saved value. Each applicable test runs `PRAGMA foreign_key_check`. No destructive migration or attempt to recreate precision already lost in legacy integer fields was added.

Editing the current Saved Food or its aliases leaves older logged snapshots intact. Changing an old entry to 45.5 g, copying at 21.3 g, and moving it at 293.8 g retain the original archived nutrition. Today derives totals from entries. Training and Rest target revisions remain independent: September 10 uses the September 1 revisions (2800/2300 kcal), while September 25 uses the September 20 revisions (2700/2200 kcal). Unset retains the labelled Training fallback; it does not become Rest.

## Backup and restart verification

The synthetic format 6 and 7 compatibility fixtures restore their available food data into the current app. A format 8 round trip checks Saved Food metadata (serving size/unit, sodium, label provenance, verification date, notes, photo references), aliases, favorites, daily record and notes, training target revision, fractional food log, nutrition archive hash, meal template, workout, and weight. Restore foreign keys pass. A live Today stream updates after restore without restarting. Unknown top-level, typed food, alias, and daily-record fields are rejected rather than silently dropped; future format 9 is rejected. These compatibility fixtures are derived from the current exporter with fields removed to model earlier formats, rather than recovered copies of a real user's old backup.

Normal manual food logging, local alias matching, Today, training type, notes, targets, and decimal quantities pass an automated network-disabled test across database close/reopen. Product/alias writes and daily-record/target writes already use transactions; backup restore already uses a database transaction with preference rollback. Phase 1D adds transaction boundaries around multi-step diary writes.

The archive contains JSON plus **meal and workout preview thumbnails**. It does not include full-resolution meal/workout images or Saved Food product/nutrition-label image files. Photo reference strings round-trip, but references alone cannot reconstruct those missing files on another device. Do not call the current archive a complete photo backup.

## Dates and remaining risks

`daily_records.date` and target effective dates are stored as explicit local `YYYY-MM-DD` keys. The day also records the time-zone name and UTC offset at capture. Today uses the device's current local calendar date; food, workouts, and measurements are timestamped and grouped by the device's current local time zone. Changing the device time zone can place an existing timestamp in a different displayed day, while the stored DailyRecord date remains stable. Existing local-midnight boundary tests cover the final millisecond of a day. A time-zone migration redesign is outside this phase.

The test suite runs on Windows, not a physical iPhone. Files picker, manual iCloud Drive save, HealthKit, small-screen layout, running-workout overlay, and real-device restart still need the manual checks below. The backup exporter reads several tables in succession, so concurrent writes during export have not been proven to form a single database-wide snapshot. Avoid editing entries while exporting until that is hardened in a future focused change. The existing diary UI can also perform separate food and fluid repository calls; each individual source write is atomic, but the two-call action has no shared transaction. These are remaining risks, not claims of full end-to-end backup coverage.

## Verification

- Complete selected Phase 1A–1D regression suite: **251 passed, 0 failed** across 29 test files, including backup archives and iCloud archive format tests.
- Flutter analyzer: 0 errors, 0 new warnings. Existing `lib/main.dart:92` `unawaited_return_in_try_block` warning remains; `--no-fatal-warnings` exits successfully.
- `git diff --check`: passed. Git emitted a Windows LF→CRLF notice only.

## Manual iPhone checklist

1. In airplane mode, log 293.8 g, 45.5 g, and 21.3 g; edit/delete one entry and confirm Today totals immediately change.
2. Search a Saved Food by a Latin and Cyrillic alias; edit its nutrition and confirm an older logged entry keeps its prior values.
3. Set separate Training/Rest targets, choose explicit Rest and then Unset, and inspect an earlier effective-date target.
4. Add a bodyweight, workout, and daily note; confirm Today shows them, then force-quit/reopen and confirm persistence.
5. Export to Files, manually save to iCloud Drive, restore on a separate test install, and compare foods, aliases, notes, targets, workouts, and weight. Check that missing original photo files are understood.
6. Check the five tabs and running-workout overlay on a small iPhone; complete a HealthKit permission/read smoke test.

## Files

Modified:

- `lib/core/infrastructure/backup_archive.dart`
- `lib/core/infrastructure/backup_manager.dart`
- `lib/features/diary/data/sources/diary_local_data_source.dart`
- `test/data/schema_v30_migration_test.dart`
- `test/features/diary/data/sources/meal_entry_move_test.dart`

New:

- `test/data/phase1d_migration_integrity_test.dart`
- `test/phase1d_integrity_test.dart`
- `documentation/phase-1d-report.md`

Phase 1A–1D is a reasonable local data baseline for review and further work, subject to the listed photo-backup, concurrent-export, time-zone, and on-device checks. No commit was made.
