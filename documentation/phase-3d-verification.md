# Phase 3D historical import verification

The local pipeline is: selected ChatGPT conversation files → deterministic
extraction → date-grouped user review → Portable Historical Import v1 validation
→ Phase 3B preview and explicit mappings → recovery backup → one SQLite
transaction → foreign-key/reference checks → import report. The adapter does
not access the live database or a network service. No schema or backup-format
change was needed: the database remains v37 and the current backup payload v11.

The synthetic end-to-end fixture contains two continuing fitness chats and an
unselected unrelated chat. It covers exact labels, aliases, fractional amounts,
planned/confirmed/cancelled food, corrections, a restaurant estimate, differing
reported/calculated totals, final locks, a workout with six actual sets, and
four body measurements. The test verifies local Saved Foods, immutable nutrition
archives, calculated and reported totals separately, workout and set links,
measurements, notes, locks, audit decimal text, import batches, and
`PRAGMA foreign_key_check`. An exact re-import creates zero native records; a
changed external ID produces a review conflict. A late exercise mapping error
rolls back staged food/workout rows and locks, records a failed batch, and
preserves a real recovery ZIP. A pre-import backup payload can be restored in
the test environment.

The measured synthetic load test uses 180 local days, 1,080 consumed food
entries, 90 workouts and sets, 180 measurements, a Saved Food and an alias.
The final run took about 1.6 seconds for preview and 2.0 seconds for merge on
this Windows test host. These are diagnostic measurements, not iPhone
performance guarantees. The test confirms resulting row counts and foreign
keys; it does not prove a fixed memory ceiling or rule out every N+1 query.

Portable decimal strings such as `293.8`, `45.5`, `21.3`, `288.97`, `15.65`,
`99.5` and `103.0` are validated before conversion and are not rounded at the
database boundary. SQLite `REAL` stores binary floating-point approximations,
so exact textual identity is not guaranteed in native rows. The original text
remains in import audit payloads. Calculated display values may be rounded for
presentation; historical nutrition uses each imported entry's archived
snapshot, not today's Saved Food values.

Explicit local dates remain explicit. ISO timestamps with offsets use their
source wall date for relative phrases. Unix timestamps lack a source timezone;
the adapter uses the device's local date and warns about boundary dates. An
unrecognized export structure fails before portable output. Image-only values
are not interpreted. The adapter processes selected conversations only, and
the portable output retains compact source references rather than full chat
messages. Its temporary Files share source is removed after sharing. A real
user archive and native iPhone Files behavior still need manual verification.
