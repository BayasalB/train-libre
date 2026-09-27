# Phase 1C: Today and daily records

Implemented on branch `codex/phase-1a-decimal-nutrition`, starting from clean Phase 1B commit `87283bba92293c805fb5e77cf9416a5536fc8d8c`. Phase 1D and Phase 2 were not started.

## Data and migration

Drift schema 33 → 34, additive migration with no changed historical rows:

- `daily_records`: UUID and local ID, unique `YYYY-MM-DD` local date, captured device time-zone name and UTC offset, explicit training type (`unset`, `chest`, `back`, `shoulder`, `legs`, `arms`, `fullBody`, `rest`), notes, nullable target-profile UUID override, and standard created/updated/deleted timestamps.
- `nutrition_target_profiles`: UUID and local ID, `training` or `rest` kind, effective-from local date, REAL calories/protein/carbs/fat, and standard timestamps. An index supports kind/effective-date lookup.

Profile saving appends training and rest revisions together. The latest revision effective on or before the requested day wins. The manual editor only permits today or future effective dates, so changing today's targets cannot change an earlier date. A day-level override, where present, refers to an immutable profile UUID and is validated against that day's date. No profile is generated from legacy/adaptive goals.

`Unset / Unknown` is distinct from explicit `Rest`. Unset uses the training-day profile as an explicitly labelled fallback. If that profile does not exist for a date, Today shows consumed values and a **Set targets** action with no target or remaining-calorie figure.

`daily_records.date` is a calendar key, not a UTC instant. A record retains its capture-time device time-zone label and offset. Existing food/workout/measurement timestamps are grouped using the device's local calendar time; travel across time zones can therefore change which day an existing timestamp appears on. The stored daily-record key itself does not shift. Food/fluid date queries now use a half-open local-day interval so entries at 23:59:59.999 remain in the correct day.

## User experience and existing systems

The main tabs now appear as **Today, Food, Workout, Progress, More**. Internal route IDs remain Today=0, Workout=1, Progress=2, Food=3, More=4, preserving old tab links. Food opens the existing Nutrition Hub; Workout and Progress reuse their existing modules. The detailed diary, measurements, targets, existing Settings, and backups remain accessible through More. Today provides direct food logging, detailed diary editing, workout navigation, a date switcher, training type selection, and daily notes.

Today combines the existing archived food snapshots, fluid entries, measurement rows, and workout logs in one reactive read model. There is no new nutrition-total, bodyweight, or workout storage. Food edit/delete/quantity changes trigger recalculation from individual entries. The dashboard's calorie display rounds to whole numbers and macros to one decimal; persisted quantities and calculations stay in double precision. Existing adaptive recommendations remain separate; manual profiles are authoritative for Today.

Backup JSON format 7 → 8 adds `daily_records` and `nutrition_target_profiles`, including profile revision IDs and day overrides. Restore imports profiles before referencing records. New datasets are validated before destructive restore work begins. Format-7 backups remain accepted and restore with these tables empty. Clear-all-user-data also removes the new tables.

## Files changed

Modified:

- `lib/core/infrastructure/backup_manager.dart`
- `lib/data/database_helper.dart`
- `lib/data/drift_database.dart`
- `lib/data/drift_database.g.dart` (generated)
- `lib/features/app/presentation/main_screen.dart`
- `lib/features/diary/data/sources/diary_local_data_source.dart`
- `lib/features/settings/presentation/settings_screen.dart`
- `test/data/schema_v30_migration_test.dart`
- `test/data/schema_v33_saved_foods_migration_test.dart`

New:

- `lib/features/app/presentation/main_tab_navigation.dart`
- `lib/features/today/domain/daily_record_models.dart`
- `lib/features/today/data/daily_record_repository.dart`
- `lib/features/today/data/today_repository.dart`
- `lib/features/today/data/daily_backup_validation.dart`
- `lib/features/today/presentation/today_screen.dart`
- `lib/features/today/presentation/target_profiles_screen.dart`
- `test/features/today/today_repository_test.dart`
- `test/features/today/today_screen_test.dart`
- `documentation/phase-1c-report.md`

## Verification

- Flutter test suite covering Phase 1A, Phase 1B, Phase 1C, backups, prior migrations, widget deep links, and running-workout overlay: **198 passed, 0 failed** (24 selected test files).
- Includes numeric precision, Rest vs Unset, historical target versions, manual versus adaptive goals, notes, existing bodyweight/workout data, local midnight boundary, food edit/delete reactive totals, offline database reopen, Today widget restart, backup restore and malformed-backup rejection, and v33→v34 migration.
- Final focused rerun after the navigation and UI polish: **50 passed, 0 failed**.
- Flutter analyzer: **0 errors, 0 new warnings**. One pre-existing warning remains in `lib/main.dart:92` (`unawaited_return_in_try_block`).
- `git diff --check`: passed; Git prints a Windows line-ending notice for generated `drift_database.g.dart`.

Tests ran on Windows. Native iPhone navigation, layout, and Files/iCloud Drive backup flows still require on-device verification. The new labels are English. Existing cross-time-zone timestamp grouping remains device-local as described above.

## Manual iPhone checklist

1. In airplane mode, open Today, change training type to Shoulder, write a note, force-quit and reopen; confirm both remain.
2. Set training/rest calorie and macro targets in Settings. Mark Today Rest, then Unset; verify the target changes and Unset explicitly says it uses training targets.
3. Log a decimal quantity from a Saved Food; verify Today kcal/macros. Edit the grams and delete the entry in the detailed diary; verify Today updates after each action.
4. Add a weight measurement and a workout; confirm Today shows them without changing training type automatically.
5. Change today's targets; visit yesterday and confirm its earlier effective target remains. Select another date and confirm food totals change.
6. Create a backup, restore it to a separate test install, and confirm notes, day types, target revisions, foods, and measurements.
7. Check the five-tab bar and running-workout overlay on a small iPhone, including opening Food and returning to Today.
