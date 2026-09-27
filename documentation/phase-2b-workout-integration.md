# Phase 2B workout integration

Today and Day Detail read the existing `workout_logs`, `set_logs`,
`workout_exercise_logs`, `exercises`, and `measurements` tables. They store no
workout summary, PR, volume, or training-type copy. A day's workout and set
rows are fetched in batches, so the query count does not grow with the number
of exercises. The existing workout detail screen remains the source for PR
indicators, estimated 1RM, history editing, and advanced workout controls.

## Day association

Workouts appear on the local calendar date of `workout_logs.start_time` using
a half-open range from local midnight to the next local midnight. A workout
that crosses midnight remains on its start date. Multiple starts on one date
remain separate sessions. `daily_records.date` is an explicit date key and is
never inferred from a workout. A workout cannot change `training_type`, and a
day without a workout does not become Rest.

Workout start times are legacy timestamps, not immutable calendar-day keys.
Changing the device timezone may therefore change which local date an old
workout appears under. This phase does not rewrite those timestamps. In-progress
workouts appear with an explicit label and no completed summary totals.

## Summary rules

The exercise count is the number of distinct blocks with completed, non-warmup
sets. On legacy sets without block IDs, exercise ID or snapshot name identifies
the exercise. The working-set count includes completed, non-warmup sets, even
when a set records cardio or duration rather than weight.

Volume is displayed only when positive. It sums completed, non-warmup sets
that the existing workout classification considers load-bearing. Catalog
strength and plyometric exercises count; catalog cardio, mobility, stretch,
and balance do not. Legacy exercises use the established category/name
fallback. For each eligible set, the existing `setTonnageKg` rule calculates
effective load times reps. Bodyweight and assisted sets use the latest recorded
bodyweight at or before workout start; no missing bodyweight is guessed.
Decimal logged weights remain decimal in calculations.

The compact screens do not independently declare PRs. Opening a completed
workout uses the established detail-screen PR and estimated-1RM logic. During a
live workout, the previous-performance strip uses the existing last-session
query, which now excludes unfinished and deleted sets.

## Manual iPhone check

- Start a routine, add an exercise, enter decimal weight and reps, add/copy a
  set, review Previous, add notes, then finish.
- Navigate away and restart during an active workout; verify recovery and the
  running-workout overlay.
- Check Today and History for one workout, two workouts, an in-progress workout,
  a workout across midnight, RPE/RIR, workout/exercise/set notes, and PR detail.
- Change Training Type independently; confirm Unset and Rest stay distinct.
- Confirm both screens still work in airplane mode and on a small iPhone.
