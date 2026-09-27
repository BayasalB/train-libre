# Phase 2A: unified History and Day Detail

Built on the clean, tagged Phase 1 baseline (`phase-1-baseline`, commit `7ef594de1483afe0680120e229e9f22764be1177`). Phase 2B–2D were not started. This work is uncommitted pending approval.

## Architecture

`HistoryRepository` reads one local calendar month at a time from the existing DailyRecord, nutrition log, fluid log, archived nutrition, product, workout, and measurement tables. Its queries have month start/end predicates and batch nutrition lookups rather than 28–31 separate day queries. It uses the same `CalculateDailyNutritionUseCase` as Today, so linked fluid entries are not counted twice and historical archive rows take priority over current product nutrition. Daily summaries are calculated in memory and never stored as another authoritative total. The month returns one row per calendar day, including empty days, so a user can open any date.

Day Detail reuses `TodayRepository` for the date's food, totals, bodyweight, workouts, and effective-date target profile. It adds a bounded read of that day's measurements, existing workout sets, and titles of linked meal entries. Food edits open the existing detailed diary; workout taps open the existing workout-log detail screen. Daily notes and training type use `DailyRecordRepository`. History is accessed from **More**, preserving the five primary tabs and existing deep-link tab indices.

No SQLite schema change or migration was needed. No nutrition, workout, measurement, or bodyweight rows are duplicated.

## Dates and performance

DailyRecord and target dates use their explicit local `YYYY-MM-DD` keys. Legacy nutrition, workout, and measurement timestamps are assigned to days using the device's current local calendar interpretation, matching Today. A timezone change can therefore move a timestamped entry to another displayed date; a stored DailyRecord date does not change. Month queries use half-open local start/end bounds, including the last second of a month and excluding the next month's midnight. The number of calendar days uses calendar construction rather than elapsed hours, so daylight-saving transitions do not shorten a month.

The bounded-range test inserts entries across 12 years and confirms only the selected month's 30 days and one relevant food entry are returned. Nutrition and fluid tables already have date indexes. Workout and measurement range predicates may still scan their existing tables because those date columns have no dedicated indexes; measure on a real device with a large dataset before deciding whether a later additive index migration is warranted.

## Verification

- Phase 2A repository and widget tests cover decimal archived nutrition, linked/standalone fluids, target revisions, Rest versus Unset, meals, workout exercises, body measurements, notes, navigation, edit/delete/move reactivity, food-only/workout-only/measurement-only/legacy days, unavailable-food placeholders, midnight/month boundary, and a 12-year out-of-range fixture.
- Complete relevant Phase 1A–1D regression suite and Phase 2A tests: **264 passed, 0 failed** across 31 test files.
- Flutter analyzer: no errors or new warnings. The pre-existing `lib/main.dart:92` `unawaited_return_in_try_block` warning remains.
- `git diff --check`: passed.

## Known risks and iPhone checks

Native iPhone layout and performance have not been verified. Month queries are bounded but workout/measurement date columns lack dedicated indexes. Older timestamped entries remain sensitive to a change in device timezone. A missing referenced archive produces an incomplete-total warning. Truly legacy food rows with no archive reference still use the current product fallback inherited from Today, so their historical nutrition can change if that product changes.

On an iPhone, open **More → History**; swipe through months and open a date. Check a food-only day, workout-only day, and a day with measurements. Compare calories/macros and effective targets to Today for an old Training day, explicit Rest day, and Unset day. Edit a food's grams or delete it in the detailed diary, return to History, and confirm totals update. Edit notes/training type, restart in airplane mode, and confirm persistence. Check meal titles, exercise sets, small-screen scrolling, back navigation, and the running-workout overlay.

## Files

Modified:

- `lib/features/app/presentation/main_screen.dart`
- `lib/features/diary/data/sources/diary_local_data_source.dart`

New:

- `lib/features/history/data/history_repository.dart`
- `lib/features/history/presentation/history_screen.dart`
- `lib/features/history/presentation/day_detail_screen.dart`
- `test/features/history/history_repository_test.dart`
- `test/features/history/history_screen_test.dart`
- `documentation/phase-2a-report.md`
