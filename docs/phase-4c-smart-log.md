# Phase 4C Smart Log input and review boundary

Type and accepted voice transcripts use `LocalSmartFoodLog.preview`, which runs
the deterministic parser and exact Saved Food/alias resolver. The existing
dictation sheet supplies editable text. Its optional AI transcript tidy-up is
disabled on the Smart Log route so transcription never silently changes a
quantity before local parsing. Device speech recognition may itself need a
network connection, depending on language and OS availability.

The Smart Log Photo action reuses `AiMealCaptureScreen` camera/photo capture,
`AiService.analyzeImages`, and the existing meal validation/repair pipeline.
In `returnCandidateToSmartLog` mode, capture returns an `AiMealCandidate` and
cannot log its barcode or save a meal. `SmartLogPhotoAdapter` checks the
candidate, offers exact local Saved Food matches, and labels image-derived
portions as estimates. It ignores AI-returned database IDs. The existing meal
image API supplies food names and estimated weights, **not nutrition macros**.
Unknown items therefore have no nutrition until the user links a Saved Food or
explicitly requests and accepts an `AI_ESTIMATE` through Phase 4B.

Every Smart Log input is represented by `SmartLogReviewItem` around the same
`LocalFoodCandidate`. The review computes totals only from included, valid,
consumed candidates. Confirm uses `SmartLogAiFallback.confirm` and
`LocalSmartFoodLog.confirm`: one database transaction checks Day Lock, checks
the current Saved Food against preview, inserts any accepted estimate, and
creates immutable nutrition snapshots through the established diary source.
Photo files used for Smart Log recognition are not saved as progress photos or
meal attachments by this route.

The older rich `AiMealReviewScreen` stays available for meal photos, depth
metadata, voice transcript attachment, and meal grouping. Replacing that UI
would discard useful capture features. Its final save now calls the same
`LocalSmartFoodLog.confirm` transaction with an optional `MealEntry`, so meal
metadata and foods succeed or roll back together. Photos copied before that
database transaction are removed on failure. The two screens retain distinct
editing layouts, but share the write safety boundary and nutrition snapshots.

No new backend, provider, key storage, or database schema is introduced.
Native iPhone camera, speech permission, background/resume, and live provider
behavior require device testing.
