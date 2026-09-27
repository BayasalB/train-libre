# Phase 1B — Saved Foods

2026-09-27. Суурь commit: `d8a9caa83d42dda2e6d7520f23204631e00982e9`.
Branch: `codex/phase-1a-decimal-nutrition`.

## Хамрах хүрээ

Saved Food aliases, metadata, local search, nutrition priority, existing snapshot болон backup compatibility-г хэрэгжүүлсэн. Phase 1C / Today dashboard эхлээгүй. Natural-language meal parsing, OpenAI/provider өөрчлөлт, backend, cloud database, account, subscription нэмээгүй. iOS signing болон App Groups тохиргоог өөрчлөөгүй.

## Хэрэглэгчийн ажиллагаа

- Existing Create/Edit Food form-д Saved Food details нэмсэн. Catalog food-ийн detail дээрх **Saved Food details & aliases** үйлдлээр тухайн food-д personal override болон alias үүсгэнэ.
- Aliases-ийг нэг нэгээр нэмэх, дараад засах, remove хийх боломжтой. Нэрийн эх бичвэр, optional language хадгалагдана. Food болон alias өөрчлөлтүүд Save дарахад нэг transaction-аар хадгалагдана; Cancel хийвэл database өөрчлөгдөхгүй.
- Latin/Cyrillic lowercase болон whitespace normalization ашиглана. `uurag`, `УУРАГ`, `  ovyoos  `, `тараг` нь зөвхөн хэрэглэгч тохируулсан mapping-аар таарна. Transliteration болон NLP байхгүй: `uurag`-ийг тохируулсан нь `уураг`-ийг автоматаар тохируулсан гэсэн үг биш.
- Нэг food-д normalized alias давхардвал UI болон repository reject хийнэ; SQLite unique constraint давхар хамгаална. Нэг alias олон food-д оноогдож болно. Search тэдгээрийг сонголт болгон харуулж, автоматаар log хийхгүй.
- Existing Food/Add Food search дээр exact alias matches эхэнд, catalog-ийн өмнөх exact/prefix/recency ranking дараа нь хэвээр ажиллана. Saved Food-ийн primary name Unicode-aware хайлттай. Recent, Favorites болон fast quantity flow-г дахин ашигласан.
- Quantity entry нь explicit serving size-ийг санал болгоно; serving байхгүй бол 100 g/ml. Package quantity-г serving гэж ашиглахгүй. Package quantity тусдаа хадгалагдана; serving unit-ээс nutrition basis рүү density таамаглан хөрвүүлэхгүй.

Шинэ metadata талбарууд:

| Талбар | Утга/нэгж |
| --- | --- |
| Serving size, unit | Positive decimal + `g` эсвэл `ml`; package quantity-гаас тусдаа |
| Sodium | **g per 100 g/ml**, salt-аас тусдаа; 1000 mg = 1 g |
| Nutrition source | `label`, `manual`, `catalog`, `estimate` |
| Verified, verified date | Хэрэглэгчийн сонголт болон огноо; автоматаар verified болгохгүй |
| Notes | Optional text |
| Product / nutrition-label photo reference | Optional local file reference; энэ phase-д image picker/file-copy workflow ороогүй |

## Database migration: v32 → v33

Шинэ `food_aliases` хүснэгт:

- `local_id` — local autoincrement primary key.
- `id` — unique UUID.
- `product_barcode` — existing `products.barcode` руу foreign key. Catalog refresh-ийн үед өөрчлөгдөж болох row position биш, тогтвортой barcode key ашиглана.
- `alias` — оруулсан эх бичвэрийг хэвээр хадгална.
- `normalized_alias` — lowercase + whitespace-normalized lookup key.
- `language` — nullable text.
- `created_at`, `updated_at`, `deleted_at` — existing architecture-ийн metadata.
- Unique `(product_barcode, normalized_alias)`; lookup index `idx_food_alias_lookup`.

`products`, `user_food_overrides`, `off_products_archive` хүснэгт бүрт **9 additive column** нэмсэн:

```text
serving_size REAL NULL
serving_unit TEXT NULL
sodium REAL NULL
nutrition_source TEXT NULL
nutrition_verified BOOLEAN NOT NULL DEFAULT false
nutrition_verified_at DATETIME NULL
food_notes TEXT NULL
product_photo_ref TEXT NULL
label_photo_ref TEXT NULL
```

Versioned migration transaction нь nullable/defaulted columns болон шинэ table/index үүсгэнэ. Existing rows, IDs, UUIDs, nutrient values, archive hashes-ийг дахин бичихгүй. Хуучин data-д serving, explicit sodium, verified source-ийг таамгаар бөглөхгүй. SQLite нь Drift-ийн existing date storage convention-ийг ашиглана.

Existing v31 → v32 migration-ийг хадгалсан; v31 → current болон v32 → v33 замуудыг тестэлсэн. Generated Drift кодыг build_runner-аар үүсгэсэн, гараар засаагүй.

## Nutrition priority ба history

Existing `user_food_overrides` нь catalog өгөгдлөөс тэргүүлнэ. Catalog food засахад catalog row-ийг хэрэглэгчийн утгаар дарж бичихгүй; personal override-г хадгална. Optional nutrient-ийг хэрэглэгч хоосолсон бол catalog-ийн утгыг чимээгүй нөхөж оруулахгүй.

Catalog import нь UPSERT ашиглан existing UUID/local ID-ийг хадгална; user-created food-ийг catalog update-аар солихгүй. User-authored food руу бага priority-тай catalog/estimate ingestion ороход хамгаалалттай. Alias/override-тай OFF food-ийг catalog-аас хасагдсан ч offline ашиглаж болохоор retain хийнэ.

Шинэ log existing `off_products_archive` snapshot системийг ашиглана. Sodium болон бүх шинэ metadata нь archive snapshot ба content hash-д орно. Legacy metadata байхгүй record-ийн хуучин hash convention хэвээр. Food edit болон quantity edit нь хуучин archive-ийг mutate хийхгүй; дараагийн log шинэ утгаар snapshot үүсгэнэ.

Diary-ийн food detail-ээс Saved Food засахад editor нь current Saved Food-ийг ачаална. Буцаж ирэхэд historical detail хуучин archived nutrition-оо үргэлжлүүлэн харуулна. Хоёр дахь snapshot систем үүсгээгүй.

## Reusable resolver

`ResolveSavedFoodUseCase` нь local exact-name/alias lookup-ийг dependency болгон авна. Жишээ:

```dart
final resolver = ResolveSavedFoodUseCase(
  (query) => products.searchSavedFoods(query, exact: true),
);
final result = await resolver.execute('УУРАГ');
```

- 0 candidate → `unknown`, `food == null`.
- 1 candidate → `matched`, `food` нь тэр Saved Food.
- Олон candidate → `ambiguous`, `food == null`, `candidates`-аас хэрэглэгч сонгоно.

Existing AI fuzzy search өөрийн catalog search замаа хэрэглэсээр байна; alias resolver-ийг AI auto-selection-д холбогоогүй. Phase 4 энэ local resolver-ийг дахин ашиглаж болно.

## Backup: format v6 → v7

Existing JSON backup-д `food_aliases` болон `saved_food_products` datasets нэмсэн. `saved_food_products` нь custom foods төдийгүй alias, override, favorite-тай catalog food-уудыг авч явна. Иймээс catalog татаж аваагүй, хоосон database дээр offline restore хийхэд тэдгээрийг хайж/log хийж болно.

Alias UUID, language, timestamps, tombstones, metadata, explicit sodium, package quantity болон existing archive snapshot fields round-trip хийнэ. Restore нь normalized alias-ийг дахин тооцоолно. Duplicate/malformed alias байвал transaction rollback хийж, existing data-г хэвээр үлдээнэ. Хуучин supported backup-д эдгээр datasets байхгүй бол legacy restore зам ажиллана. Шинэ format-ийг хуучин app version уншина гэж батлахгүй.

Photo **reference strings** backup-д орно. Photo file-ийн binary contents энэ phase-ийн шинэ JSON datasets-д орохгүй; төхөөрөмж сольсон үед зураг тусдаа байхгүй бол reference зураг нээхэд хүрэлцэхгүй. Existing meal/workout photo backup нь өөрийн өмнөх workflow-той хэвээр.

## Тест ба шалгалт

Эцсийн үр дүн: **147/147 tests PASS**, exit code 0. Үүнд Phase 1B-ийн 16 шинэ тест орсон. Analyzer: **0 errors, 1 existing warning** (`lib/main.dart:92:7`, `unawaited_return_in_try_block`); `--no-fatal-warnings` сонголттой exit code 0. Шинэ warning/info үлдээгүй. `git diff --check` PASS.

Ажиллуулсан command: `flutter test --no-pub <доорх 19 файл> --reporter expanded`.

```text
test/saved_foods_test.dart
test/data/schema_v33_saved_foods_migration_test.dart
test/features/diary/presentation/saved_food_fields_test.dart
test/decimal_nutrition_test.dart
test/data/schema_v32_decimal_migration_test.dart
test/features/diary/presentation/decimal_quantity_test.dart
test/add_food_meal_totals_test.dart
test/backup_manager_test.dart
test/backup_restore_integrity_test.dart
test/data/schema_v30_migration_test.dart
test/diary_reactive_migration_test.dart
test/health_export_data_source_test.dart
test/ai_meal_validation_test.dart
test/features/home_widgets/build_home_widget_snapshot_test.dart
test/features/diary/data/sources/meal_entry_move_test.dart
test/features/diary/presentation/widgets/meal_ingredients_summary_test.dart
test/features/diary/data/sources/product_local_data_source_test.dart
test/product_database_helper_batch_test.dart
test/offline_food_archive_test.dart
```

Analyzer: `flutter analyze --no-pub --no-fatal-warnings`. Өөрчлөгдсөн non-generated Dart files-д formatter ажиллуулсан. Drift generation: existing build_runner snapshot-ийн `build` command (workspace-ийн portable Dart SDK); output нь generator-оос гарсан. Бүх repository-ийн test suite бус, энэ өөрчлөлттэй холбоотой 19 файлын regression suite-г ажиллуулсан.

Шинэ tests нь дараахыг хамарсан:

- Case/whitespace, Latin/Cyrillic, romanized Mongolian alias resolution; тохируулаагүй хувилбар unknown байх.
- Duplicate prevention, ambiguity/no silent selection, alias update/delete/reactivation, UUID/createdAt preservation, олон alias-ийг зэрэг rename хийх.
- Primary name search; catalog ranking regression.
- Serving/package separation, sodium, metadata JSON serialization/validation, editor болон alias dialog widgets.
- User nutrition priority after catalog/estimate ingestion; old snapshot unchanged, future snapshot updated.
- Empty database offline backup restore, deleted aliases, catalog food availability, malformed backup rollback, restart persistence.
- HTTP client-ийг зориуд хаасан үед aliases, manual logging, recent болон favorites ажиллах.
- v32 schema дээр metadata columns болон aliases table үнэхээр байхгүй fixture-ээс v33 upgrade; original columns/hash/IDs unchanged; foreign-key check болон idempotent schema reconciliation.
- Phase 1A-ийн decimal tests, backups, health-export payload, AI review compatibility, home widget payload, meal movement болон archive regressions.

Run logs: [tests](../../../work/test-phase1b-final.txt), [analyzer](../../../work/analyze-phase1b-final.txt), [generation](../../../work/build-phase1b.txt).

## Хязгаарлалт ба эрсдэл

- iPhone/Xcode build, actual airplane-mode UI, iOS Files picker, native HealthKit write-ийг Windows дээр шалгаагүй. Offline repository/widget tests нь actual iPhone test-ийг орлохгүй.
- Шинэ form labels English. Existing app-ийн бүх locale-д translation нэмээгүй.
- Photo references хадгалдаг; энэ phase-д photo capture/import, file lifecycle, photo-content backup шинээр хийгдээгүй.
- Alias matching нь Unicode lowercase болон whitespace normalization; fuzzy matching/transliteration/NLP байхгүй. Exact утга тодорхойгүй бол хэрэглэгч сонгоно.
- Personal foods subset-ийн Unicode primary-name matching Dart талд явагдана. Хувийн хэрэглээний хэмжээнд зориулсан; маш олон мянган Saved Food-той үед search performance-ийг profile хийж normalized name index нэмж болно.
- Бодит хэрэглэгчийн database ирээгүй. Migration нь legacy fixture болон existing regression tests-ээр шалгагдсан.
- Existing native media-cleanup plugin unit test орчинд байхгүй тухай nonfatal log гарна. Database/JSON restore test амжилтыг photo file restore гэж тайлбарлахгүй.

## Manual checklist

1. Food үүсгээд name, per-100 nutrition, 45.5 g serving, 100 g/ml nutrition basis, explicit sodium, label source, verified date, notes оруулж хадгал. App restart хийж эдгээрийг тулга.
2. Kirkland Whey-д `uurag`, `уураг`; Hercules Oats-д `ovyoos`, `овьёос`; yogurt-д `tarag`, `тараг` оноо. Search дээр `UURAG`, `УУРАГ`, `  ovyoos  `, `тараг` гэж шалга.
3. Нэг food-д `uurag`/` UURAG ` давхар нэмэхэд reject болох ёстой. Өөр food-д ижил alias өгвөл хоёулаа search-д харагдаж, та өөрөө сонгоно.
4. Alias-ийг засаж/устгаад дахин хай. Save-ээс өмнө Cancel хийсэн өөрчлөлт хадгалагдахгүй байх ёстой.
5. Food log хийгээд Saved Food-ийн kcal/sodium/notes-ийг зас. Хуучин log-ийн detail болон total өөрчлөгдөхгүй, шинэ log шинэ утгаар тооцогдох ёстой. Quantity edit нь хуучин density-г хэрэглэнэ.
6. Recent/Favorites-ээс food сонго. Serving 45.5 g бол quantity default 45.5; package 1000 g байсан ч serving-ийг 1000 болгохгүй. Serving байхгүй бол default 100.
7. Airplane mode үед create/edit/search/log хий. Backup гаргаж, тусдаа test installation дээр restore хийж alias, metadata, snapshot-уудыг тулга. Photo references болон photo files-ийг тусад нь шалга.

## Өөрчлөгдсөн болон шинэ файлууд

Доорх жагсаалт нь зөвхөн Phase 1B-ийн working tree diff. Phase 1A commit хэвээр, Phase 1C файл нэмээгүй. Энэ phase-ийн өөрчлөлтийг commit/push хийгээгүй.

### Өөрчлөгдсөн 14 файл

- `lib/core/infrastructure/backup_manager.dart`
- `lib/core/infrastructure/basis_data_manager.dart`
- `lib/data/database_helper.dart`
- `lib/data/drift_database.dart`
- `lib/data/drift_database.g.dart`
- `lib/features/diary/data/sources/diary_local_data_source.dart`
- `lib/features/diary/data/sources/product_local_data_source.dart`
- `lib/features/diary/domain/models/food_item.dart`
- `lib/features/diary/domain/use_cases/retain_historical_off_products_use_case.dart`
- `lib/features/diary/presentation/create_food_screen.dart`
- `lib/features/diary/presentation/dialogs/quantity_dialog_content.dart`
- `lib/features/diary/presentation/food_detail_screen.dart`
- `test/data/schema_v30_migration_test.dart`
- `test/offline_food_archive_test.dart`

### Шинээр нэмсэн 9 файл

- `documentation/phase-1b-report.md`
- `lib/features/diary/data/sources/food_alias_local_data_source.dart`
- `lib/features/diary/domain/models/food_alias.dart`
- `lib/features/diary/domain/models/saved_food_metadata.dart`
- `lib/features/diary/domain/use_cases/resolve_saved_food_use_case.dart`
- `lib/features/diary/presentation/widgets/saved_food_fields.dart`
- `test/data/schema_v33_saved_foods_migration_test.dart`
- `test/features/diary/presentation/saved_food_fields_test.dart`
- `test/saved_foods_test.dart`
