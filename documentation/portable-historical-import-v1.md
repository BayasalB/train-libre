# Portable historical fitness import — formatVersion 1

This is an interchange format for reviewed historical data, independent of
Train Libre's SQLite tables and its full-device backup archive. Phase 3A only
parses and validates it; it cannot write to the live database. The normative
field vocabulary is in [the JSON Schema](portable-historical-import-v1.schema.json),
and runtime cross-record checks are in `PortableImportParser`. A complete
[example file](examples/portable-historical-import-v1.json) exercises all
collections. Phase 3B must require successful validation before any write and
define conflict resolution, local Saved Food linking, and lock handling.

## Envelope and identity

The top-level object requires integer `formatVersion: 1` and `metadata.source`.
`metadata.sourceId`, `exportedAt` (ISO 8601 with UTC offset), and `notes` are
optional. Each collection is an optional array. Omission means “no information
supplied,” not “delete local records.” Every item requires a nonblank portable
`id`; IDs are unique **within their collection** and references are scoped by
collection. These are external IDs, never SQLite row IDs or implied local UUIDs.
An entry may name a food without `savedFoodId`; no Saved Food match is required.
Optional `localFoodRef` is an opaque hint for a user-approved link to an existing
local Saved Food. It is not dereferenced or trusted during Phase 3A validation;
Phase 3B must check it locally and require an explicit linking choice.

All calendar dates use literal `YYYY-MM-DD`, retained without UTC conversion.
Timestamps require an explicit `Z` or `±HH:MM` offset. All quantities, calories,
macros, measurements, target values, weights, and durations are **decimal
strings**, such as `"293.8"`, `"45.5"`, `"103.0"`. The parser preserves that
text; it does not round or serialize through a binary floating-point value.
Decimals are nonnegative without exponent notation; quantities, measurement
values, target calories, and durations are positive. Reps and `setCount` are
JSON integers. Unit conversion is not performed during validation.

## Nutrition and day meaning

Saved Foods can retain serving metadata, verification status/time, and optional
`productPhotoRef` / `nutritionLabelPhotoRef`. Photo references are opaque
metadata; image originals are not bundled here. `nutritionSnapshots` contain
immutable source nutrition with `basis` of
`per100g`, `per100ml`, or `perServing`, and at least one of `calories`,
`protein`, `carbs`, `fat`, `fiber`, `sugar`, `sodium`. Missing nutrients are
**unknown**, not zero. Sodium is in grams; macros, fiber, and sugar are in
grams; calories are kcal. A `foodEntry` may refer to one snapshot and requires
a matching positive `quantity`/`quantityUnit` pair when it does. A Saved Food
may point to a snapshot as its reference nutrition, while each historical
entry independently points to the snapshot actually used. Saved Food edits in
the future must not mutate historical snapshots. Snapshots can be shared but
must remain immutable once imported.

An entry's `status` is `consumed`, `planned`, or `cancelled`. Only `consumed`
entries with a quantity and a known snapshot can contribute to **calculated**
daily totals. Planned/cancelled entries never count. A consumed observation
without nutrition remains a recorded observation, not invented macros.
`mealId` groups entries; meal and entry dates must match. `dailyRecords` may
hold a distinct `reportedTotal` with only the known nutrient fields and its
own provenance. A reported total is never decomposed into fake food entries
and never silently combined with a calculated total. If both exist, a future
import UI must present the difference explicitly.

Use `provenance` where known: `exactLabel`, `userConfirmed`,
`finalDailyTotal`, `assistantEstimate`, `restaurantEstimate`,
`inferredApproximate`, `legacyObservation`. It describes evidence, not a
nutrient-ranking override. A restaurant estimate stays an estimate. An
assistant statement of a final number is not automatically an exact label.
`finalDailyTotal` on a reported total does **not** lock a day; only an explicit
`lockedDays` item does. Unknown/future provenance values are rejected.

`targetProfiles` preserve training/rest targets by `effectiveFrom`, with no
duplicate kind/date pair. A historical target may contain only the values
actually known (at least one of calories, protein, carbs, fat); Phase 3B must
not fabricate missing target values when mapping to the local target model.
An explicit daily target reference cannot point to a profile effective after
that day.
`dailyRecords.trainingType` and
`workouts.trainingType` use `unset`, `chest`, `back`, `shoulder`, `legs`, `arms`,
`fullBody`, or `rest`. Omitted training type means unknown, never Rest.
Workout training type does not change a daily record. `targetProfileId` is an
explicit reference, not a demand to recreate internal target history rules.

## Workouts, measurements, and photos

Workouts require only an explicit date; name, timezone-aware start/end,
duration, notes, and training type can be absent. Exercises require a workout
reference and name. Sets require an exercise reference and at least one of
weight, reps, or duration. Weight has an accompanying `kg`/`lb` unit.
`setCount: 2` can represent a historically reported `100 kg × 10 × 2`
without inventing two separately observed set timestamps. Missing details
remain missing. Workout start/end timestamps may cross midnight; the explicit
`date` is the source date intended by the importer.

Measurement types match the existing app vocabulary: `weight`, `fat_percent`,
`waist`, `abdomen`, `lower_belly`, `hips`, `neck`, `shoulder`, `chest`, and
left/right bicep, forearm, thigh, calf. `abdomen` and `lower_belly` remain
distinct. Weight uses kg/lb; body fat uses `%`; lengths use cm/in.
Progress-photo records store metadata and an optional `mediaRef`; this JSON
does **not** bundle image bytes or guarantee restoration of originals. A
missing `mediaRef` is valid metadata, not a broken photo path.

## Seven representative cases

The complete example file includes all of these:

1. **Full food day:** `2026-09-23` has a Breakfast meal, consumed oats,
   Saved Food, alias, and historical label snapshot.
2. **Daily total only:** `2026-09-24` has `reportedTotal` of `2588` kcal and
   `202.9` g protein with no food entries.
3. **Workout only:** `2026-09-25` has a partial Legs workout and Squat sets,
   but no food entries or invented duration.
4. **Body measurements:** `2026-09-26` has weight, waist, lower belly, and
   abdomen as separate observations.
5. **Estimated restaurant meal:** `2026-09-27` has a consumed burger whose
   snapshot provenance is `restaurantEstimate`.
6. **Finalized day:** only `2026-09-24` has a `lockedDays` record with an
   explicit `lockedAt` timestamp.
7. **Planned, unconsumed food:** `2026-09-27` includes planned oats and a
   cancelled snack; neither contributes to calculated nutrition.

## Validation and version policy

The parser returns structured `ImportIssue` values with severity, stable code,
JSON path, and message. Any error yields no document. It checks JSON syntax,
version, required and unknown fields, finite decimal strings, dates, units,
enums, duplicate IDs/dates, reference existence, meal-date agreement,
snapshot-basis agreement, workout ranges and sets, measurement type/unit
agreement. No invalid item is silently discarded. All unknown fields,
including apparently optional future fields, are **errors** in v1: the data
may have meaning an older app does not understand. Unknown `formatVersion`
is rejected. A later version must have an explicit migration/reader.
`localFoodRef` and `mediaRef` produce non-fatal warnings because a local link
and photo original cannot be verified from the portable JSON alone.

JSON Schema validates shape and documents the public contract; cross-record
and calendar-validity rules require the runtime parser. No parser result in
Phase 3A is permission to write to SQLite. `mediaRef` is intentionally opaque;
Phase 3B needs a separate, safe media handling policy before using it.
