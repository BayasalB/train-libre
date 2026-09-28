# ChatGPT export fitness adapter (Phase 3C)

This is an **offline, deterministic review tool**, not an AI interpreter. It
reads a selected ChatGPT `.zip` export or conversation JSON, generates the
existing [portable historical JSON v1](portable-historical-import-v1.md), and
hands that document to the [Phase 3B merge preview](historical-import-merge-v1.md).
It has no database write path or network call. The user must separately confirm
the Phase 3B import. Access it under **More → Data Management → Convert ChatGPT
fitness history**.

## Supported export shapes and selection

- `conversations.json` or numbered/split `conversations-0001.json`,
  `conversations_1.json` and analogous `conversation` names, either as a JSON
  file or inside ZIP. Several unzipped chunk files can be selected together.
  Top-level arrays, `{ "conversations": [...] }`, and a
  single conversation object are accepted.
- Linear `messages` arrays and `mapping` trees with `parent`, optional
  `children`, and `current_node`. Tree paths are reconstructed from parent
  pointers. Only one branch per selected conversation is read for extraction.
  A valid `current_node` is suggested; ambiguous trees without one require an
  explicit branch choice. Duplicate conversation/message IDs are not counted
  twice.
- Message text in strings or `content.parts` is read. Image/file references
  produce warnings; no image OCR or binary media interpretation occurs.
- Discovery shows title, conversation ID, message count, date range, and
  title/content search. Only checked conversations are extracted. Unrelated
  conversations are never copied to portable output.
- Unrecognized structures stop with detected filenames/structure. A 256 MiB
  input limit and 128 MiB per-JSON limit keep on-device processing bounded.

## Deterministic extraction and review

User statements are primary evidence. Explicit consumed/planned/cancelled
phrases determine food status. A later named confirmation can turn a planned
item into consumed, and a later cancellation reverses it; both source message
IDs remain in trace references. A one-to-one explicit grams correction replaces
the prior quantity; a raw/uncooked-weight clarification excludes the old entry
until reviewed. A later explicit percentage of that raw weight may update the
same excluded candidate, but the edible quantity and nutrition still require
review. A bare correction such as `293.8g bsn` updates a quantity only when
there is exactly one possible same-day entry with the same unit. A product
count without a serving unit or consumption state is warned about, not logged.
Conflicting explicit alias definitions are disabled and warned
about. Unknown foods remain unlinked. Nutrition is
calculated only when a compatible per-100 or per-serving snapshot was directly
provided; the adapter never invents macros. Explicit user-provided 100 g/ml
macros are `userConfirmed`; `exactLabel` requires label wording. An alias needs
an explicit identity statement, for example `uurag / уураг → Kirkland Whey`.

Explicit sets, repetitions, weight and repeated set counts become workout
records. Body measurements retain type, unit and explicit local date; a later
same-date correction supersedes the earlier candidate. Assistant-only guesses
are not exact facts. An assistant daily total can only be accepted by the
immediately following user message. An assistant restaurant estimate is a low-confidence,
excluded snapshot candidate only when it names a just-logged serving; the user
must include it during review. Explicit wearable/cardio text is retained in
workout notes without inventing missing metrics. Image-only values remain
unextracted.

An explicit user total (or assistant daily total subsequently accepted by the
user) becomes `dailyRecords.reportedTotal`, separate from calculated entries.
Explicit final/lock wording creates a `lockedDays` candidate only when an
actual message timestamp exists. Discrepancies between known food calories and
reported calories are warned about; neither value overwrites the other.

Review is grouped by date. Each candidate can be included or excluded, and
supported date, quantity, status, Saved Food identity, provenance, confidence,
measurement value, workout set, and nutrition values are editable. Low
confidence candidates are visibly marked, and assistant estimates are
excluded by default. The user must explicitly acknowledge the extraction
review before generating output; editing a candidate clears that acknowledgement.
**Generate and validate** runs the Phase 3A validator;
errors block Files export and Phase 3B handoff. The Files action uses the iOS
share sheet and removes its temporary source file afterward; the handoff opens
the ordinary Phase 3B preview and mapping UI.

## Dates, traceability, and limits

Explicit `YYYY-MM-DD` or month/day references win. `today`, `yesterday`,
`uchigdur`, and `urchigdur` are resolved relative to the message timestamp,
never the current date. ISO timestamps with offsets use their original wall
date; Unix timestamps have no timezone and use the device timezone, with a
warning to review boundary dates. Records with neither an explicit date nor a
usable timestamp are skipped with a warning.

Portable record IDs are stable hashes of conversation ID, message ID, rule
kind, and position. Supported `notes` fields carry compact conversation/message
IDs, original timestamps, date-resolution method, extraction rule version,
and confidence; they do not embed full chat messages. Non-note collections
retain trace via stable IDs and linked records. Raw parsed conversations remain
in screen memory only during review, are not persisted by the adapter, and are
released when the screen closes. The generated portable JSON contains only
reviewed fitness candidates.

This bounded rule set intentionally misses unfamiliar shorthand, OCR-only
nutrition labels, complex corrections, and exercise formats it cannot prove.
Those cases require manual review/editing or a separately prepared portable
file. It does not use OpenAI or parse every sentence as food.
