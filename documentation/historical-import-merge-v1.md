# Portable historical import: merge policy (Phase 3B)

Input is the [portable historical JSON v1](portable-historical-import-v1.md),
not a database backup or a raw ChatGPT export. The portable format is unchanged
by this phase. In **More → Data Management → Import historical JSON**, selecting
a file parses and validates it, then shows a read-only preview. The database is
written only after the user resolves required conflicts and taps **Confirm and
import**. A full recovery ZIP is created in the app's support directory before
the write. Keep a separate copy of that ZIP in Files/iCloud Drive if desired.

## Identity and review

The import source is identified by `metadata.source` and optional
`metadata.sourceId`; each collection's external `id` is scoped to that source.
The database stores a SHA-256 checksum of the source text and a SHA-256 hash of
each record. Exact re-imports skip matching external IDs, including after app
restart. A changed record with the same scoped external ID requires a separate
**Keep existing** choice. The importer never deduplicates on a display name.

Saved Food exact normalized names, aliases, and `localFoodRef` produce
suggestions only. The user can link to a specific existing local Saved Food,
create a new one, or leave historical entries unlinked. A food entry without a
portable Saved Food can likewise be linked to a suggested local item or remain
unlinked. Exercise-name suggestions are optional; absent an explicit selection,
the workout keeps the historical exercise-name snapshot without asserting local
exercise identity. Exact measurement date, type, unit, and value can link to an
existing measurement; distinct measurements are preserved.

## Nutrition and incomplete observations

Only `consumed` entries with a positive quantity, a compatible unit, and all
four main nutrients in their portable snapshot become calculated nutrition
logs. Their own immutable archive contains the imported snapshot; editing a
current Saved Food does not replace it. Planned, cancelled, and incomplete
entries remain in the import audit and do not count. `reportedTotal` remains an
imported observation, displayed separately in History/Day Detail, even when
calculated entries are also present. Partial target profiles also remain
observations. Complete target profiles are created only if the user opts in and
there is no existing local profile for the same kind/effective date.

Portable decimals are validated as finite, nonnegative decimal strings (with
positive quantities where required), then converted once at the SQLite write
boundary. No rounding is performed before writing. The original decimal text
is retained in the import audit payload. SQLite `REAL` is binary floating point
and cannot guarantee textual decimal identity. For `perServing` snapshots, the
historical serving count is retained in the log and the archive uses a per-100
equivalent so the existing calculator returns the exact intended arithmetic
result. The UI labels these entries in servings where the archived metadata is
available. Workout weight in pounds is converted to kilograms for the existing
workout engine; the original pounds text and unit remain in the audit.

## Dates, locks, and rollback

Portable local dates are kept as calendar-date keys in daily records, locks,
and the audit. Existing timestamp-based nutrition, workout, and measurement
tables need a timestamp; a local noon anchor is used when the source provides
only a date. It is **not** an observed event time. Imported workouts without a
start time are labeled “Time unknown” in Today and Day Detail. As with legacy
timestamp data, changing the device timezone can change the local day used by
timestamp queries; the explicit portable date remains in the audit.

An existing local day is not overwritten by default. The preview requires
**Keep existing**, **Use imported**, or **Skip this date** when daily metadata
conflicts. An already locked destination can only be skipped until the user
unlocks it through the normal app action. Imported final-day locks are applied
after that day's records have been written. The merge, foreign-key check, and
count/reference verification share one database transaction. A fatal failure
rolls it all back, leaves the recovery ZIP in place, and records a failed batch
with the error. The batch and per-record audit are included in current full
backups; older supported backups restore without them.

Portable progress-photo JSON contains metadata, not image bytes. The importer
preserves it in audit data and reports missing media, but does not create a
broken Progress Photo UI record. Saved Food photo references are likewise not
installed without their image files. External media packaging is outside this
phase.
