# Phase 1A — Data foundation

2026-09-26 · Суурь commit: `8aec25262e07144db7bb99731bffa34617da546a`

Хамрах хүрээ: хэрэглэгчийн баталсан Phase 1A буюу decimal-safe nutrition. Phase 1B-ийн aliases, provenance, нэмэлт Saved Food fields болон Phase 1C-ийн Today dashboard хараахан хийгдээгүй. Phase 1A-ийн дараа зогсоно.

## Хийсэн өөрчлөлт

- Хоолны грамм, шингэний миллилитр, meal template quantity, calorie density, AI review quantity, daily totals нь `double` утгаа хадгална. UI, domain, repository, SQLite, reload, JSON backup болон nutrition CSV замд integer рүү таслах үйлдлүүдийг арилгасан.
- `NutritionValues`, `scaleNutritionValue`, `FoodItem.nutritionFor` нь per-100 g/ml өгөгдлийг хэмжээгээр үржүүлэх төвлөрсөн тооцоолол болсон. Daily болон meal totals нь rounded entry values бус, бүтэн нарийвчлалтай утгуудын нийлбэр.
- Decimal keyboard ашиглана. Quantity болон nutrition input нь цэг, таслалыг дэмжинэ; NaN/Infinity-ийг хүлээж авахгүй. Quantity edit нь `293.8`-ыг `294` болгож урьдчилан бөглөхгүй.
- UI дээр calories-ийг бүхлээр, macro summary-ийг нэг орны нарийвчлалтай харуулна. Хадгалалт болон тооцооллын утгыг display rounding өөрчлөхгүй.
- Existing meal templates, AI review, analytics, home-widget payload, XLSX export болон CSV/backup замуудыг decimal төрөлтэй нийцүүлсэн. Шинэ AI provider эсвэл AI Log нэмээгүй.
- Шингэний `kcal` нь тухайн entry-ийн нийт kcal учраас CSV export дээр quantity-гаар дахин үржүүлж байсан алдааг зассан.
- Food entry-ийн хэмжээ/цагийг засахад caller archive reference дамжуулаагүй байсан ч өмнөх nutrition snapshot-ийг хадгалдаг болгосон. Saved Food засварлахад хуучин entry-ийн шим тэжээл шинэ catalog утгаар солигдохгүй.
- Хуучин бүхэл calorie утгын content hash-ийг `288` → `288.0` гэсэн serialization ялгаанаас болж өөрчлөхгүй. Хуучин архивыг дахин hash хийхгүй.

Local SQLite нь source of truth хэвээр. Backend, account, cloud database, subscription, social feature нэмээгүй. iOS signing, Team ID, bundle ID, App Groups, iCloud container өөрчлөгдөөгүй.

## Database migration: v31 → v32

| Table | Column | Өөрчлөлт |
| --- | --- | --- |
| `products` | `calories` | INTEGER → REAL |
| `user_food_overrides` | `calories` | INTEGER → REAL |
| `off_products_archive` | `calories` | INTEGER → REAL |
| `meal_items` | `quantity_in_grams` | INTEGER → REAL |
| `fluid_logs` | `amount_ml`, `kcal` | INTEGER → REAL |

`nutrition_logs.amount` өмнө нь REAL байсан тул affinity-г өөрчлөөгүй. Domain/repository хэсгийн truncation-ийг арилгасан.

Drift `TableMigration` ашиглан таван хүснэгтийг transaction дотор rebuild хийнэ. Existing v31 build-үүдийн nullable/defaulted additive columns-ийг эхлээд reconcile хийнэ. Бүх column, local ID, UUID, timestamp, archive hash, log reference-ийг хадгална. `sqlite_sequence` high-water mark-ийг хоосон хүснэгтийн хувьд ч хамгаална.

SQLite foreign keys-ийг transaction-аас өмнө түр унтрааж, rebuild дууссаны дараа transaction дотор `foreign_key_check` хийнэ. Зөрчил гарвал exception өгч transaction rollback хийнэ; `finally` дотор foreign keys-ийг буцааж асаана. Хуучин өгөгдлөөс аль хэдийн алдагдсан бутархайг таамгаар сэргээхгүй.

`drift_database.g.dart`-ийг build_runner-аар үүсгэсэн; гараар засаагүй. Localization-ийн quantity placeholder `int` → `num` өөрчлөлтөөс гарсан файлуудыг `flutter gen-l10n`-оор үүсгэсэн.

## Backup нийцэл

Backup format version **5 → 6** болсон. Энэ нь database schema version 32-оос тусдаа дугаарлалт. Existing JSON талбаруудын утга fractional number байж болно; integer агуулсан хуучин supported backups-ийг numeric conversion хүлээн авна. JSON encode/decode, restore болон хуучин backup regression tests-ээр шалгасан.

Шинэ decimal backup-ийг шинэ app version-оор сэргээнэ. Хуучин app version шинэ бутархай утгыг зөв уншина гэж батлахгүй. Phase 3-ийн шинэ import schema, historical ChatGPT import, full database file backup workflow-г энэ өөрчлөлтөөр хийсэн гэж үзэхгүй.

CSV нь display rounding хийхгүй. XLSX-ийн quantity/calorie cells нь double утга авна. Existing backup infrastructure-ийг ашигласан; iOS Files/iCloud Drive picker-ийн төхөөрөмж дээрх ажиллагааг тусад нь шалгах шаардлагатай.

## Exact test case

Per 100 g: **288.97 kcal · P 15.65 · C 11.85 · F 19.89**.

293.8 g оруулахад:

| | Дотоод үр дүн, ойролцоогоор | UI |
| --- | ---: | ---: |
| Calories | 848.99386 | 849 kcal |
| Protein | 45.9797 | 46.0 g |
| Carbs | 34.8153 | 34.8 g |
| Fat | 58.43682 | 58.4 g |

`double`/SQLite REAL нь binary floating point тул decimal arithmetic-ийн өчүүхэн төлөөллийн зөрүү байж болно. Tests нь зохистой tolerance ашиглана. Entry тус бүрийг rounding хийхгүй; зөвхөн display дээр round хийнэ.

## Automated validation

Эцсийн run: **114/114 tests PASS**, process exit code 0. Analyzer: **0 errors, 1 existing warning**, `--no-fatal-warnings` сонголттой exit code 0. Warning нь өөрчлөөгүй `lib/main.dart:92:7` дахь `unawaited_return_in_try_block`; analyzer warning-free гэж тайлагнаагүй. `git diff --check` PASS.

Run logs: [tests](../../../work/test-phase1a-final.txt), [analyzer](../../../work/analyze-phase1a-final.txt).

Шинэ тестүүд дараахыг шалгана:

- Exact 293.8 g scaling, decimal comma/point, invalid quantity, display rounding.
- Daily/meal totals болон home-widget payload-д бүтэн нарийвчлал үлдэх.
- Existing AI review JSON-д decimal quantity хадгалагдах.
- On-disk SQLite хааж дахин нээхэд 293.8 g, meal template 45.5 g, fluid 21.3 ml хадгалагдах.
- Saved Food-ийн kcal өөрчилсний дараа хуучин log-ийн snapshot хэвээр байх; хэмжээ 45.5 g болгоход хуучин density-гаар тооцох.
- Edit/delete хийсний дараа daily totals шинэчлэгдэх.
- Analytics, health-export data payload, nutrition CSV, JSON backup/restore дээр decimal утга үлдэх.
- Legacy INTEGER affinity бүхий v31 fixture-ээс v32 руу migrate хийхэд rows, IDs, UUID, archive hashes, references, indexes, AUTOINCREMENT sequence хадгалагдах; foreign-key check хоосон байх.
- Quantity dialog болон macro badge-ийн widget test.

Ажиллуулсан regression suite:

```text
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
```

Тестүүдийг `flutter test --no-pub <дээрх 13 файл> --reporter expanded` командаар ажиллуулсан. Бүх repository test suite гэж тайлагнаагүй; энэ нь nutrition өөрчлөлттэй холбоотой 114-test regression suite.

Generation: `dart run build_runner build --delete-conflicting-outputs`, `flutter gen-l10n`. Analyzer: `flutter analyze --no-pub --no-fatal-warnings`. Өөрчлөгдсөн Dart файлуудад formatter болон `git diff --check` хэрэглэсэн.

Windows verification орчинд portable Flutter 3.47.5 / Dart 3.13.4 ашигласан. Git dependency-ийн existing lockfile revision-ийн verified source-ийг түр local path-аар resolve хийж тестэлсэн; temporary override-ийг repository-д үлдээгээгүй. `sqlite3`-ийн version өөрчлөгдөөгүй, migration fixture шууд ашигладаг тул existing transitive dependency-г direct dev dependency болгосон.

## Шалгаагүй зүйл ба үлдсэн эрсдэл

- Windows host дээр iOS/Xcode build, signing, iPhone installation, native HealthKit write болон iOS widget extension-ийн төхөөрөмжийн ажиллагааг шалгаагүй. Health export-ийн Dart data payload-ийг шалгасан.
- Бодит iPhone airplane mode flow болон Files/iCloud Drive picker-ээр backup хадгалах/сэргээхийг шалгаагүй. Local database болон backup logic-ийн automated tests network service шаардахгүй ажилласан.
- Таны бодит historical database ирээгүй; synthetic legacy v31 fixture болон existing migration tests ашигласан. Бодит дата оруулахын өмнө backup авч migration-ийг мөн турших хэрэгтэй.
- Existing backup tests дотор platform media-cleanup plugin байхгүй тухай nonfatal log гардаг. JSON/database restore тэнцсэн ч зурагтай backup-ийн native end-to-end ажиллагааг энэ нь батлахгүй.
- XLSX numeric cell үүсгэх кодыг decimal төрөлтэй болгож analyzer-аар шалгасан; Excel app-аар exported workbook нээж шалгаагүй.
- Хуучин record-д өмнө нь таслагдаж алдагдсан decimal утгыг сэргээх боломжгүй. Шинэ migration тэдгээрийг өөрчилж таамаглахгүй.

## iPhone дээр хийх богино manual checklist

1. Existing installation-ийн backup ав. Test build-ийг суулгаад хуучин logs, meal templates, workout history хэвээр байгааг шалга.
2. Дээрх exact per-100 g утгатай Saved Food үүсгээд 293.8 g log хий. UI нь 849 kcal, P 46.0, C 34.8, F 58.4 байх ёстой.
3. App-ийг бүрэн хааж нээ. Quantity 293.8 хэвээр байгааг шалгаад 45.5 g болгож зас. Өдрийн total шинэчлэгдэх ёстой. Decimal comma `45,5` input-ийг мөн турш.
4. Saved Food-ийн calories-ийг өөрчил. Өмнө log хийсэн entry хуучин density-гаар тооцогдох ёстой. Entry-г устгахад түүний шим тэжээл daily total-оос хасагдах ёстой.
5. Meal template-д 45.5 g, fluid-д 21.3 ml оруул. Airplane mode үед log/edit/delete хийж app restart хийсний дараа хадгалсан эсэхийг шалга.
6. JSON backup болон nutrition CSV гарга. Backup-ийг Files-д хадгалж, тусдаа test installation/data copy дээр restore хий; quantities, snapshots, meal templates, totals-ийг тулга. Native HealthKit permission зөвшөөрсөн бол export-ийг тусад нь шалга.

## Файлууд

Доорх жагсаалт нь энэ Phase 1A-ийн Git working tree diff-ээс авсан. Өөрчлөлтүүд local branch `codex/phase-1a-decimal-nutrition` дээр байна; commit/push хийгдээгүй.

### Өөрчлөгдсөн 62 файл

- `lib/core/infrastructure/backup_manager.dart`
- `lib/core/infrastructure/basis_data_manager.dart`
- `lib/core/infrastructure/export_manager.dart`
- `lib/data/database_helper.dart`
- `lib/data/drift_database.dart`
- `lib/data/drift_database.g.dart`
- `lib/features/app/domain/models/train_libre_backup.dart`
- `lib/features/app/presentation/main_screen.dart`
- `lib/features/diary/data/sources/diary_local_data_source.dart`
- `lib/features/diary/data/sources/meal_local_data_source.dart`
- `lib/features/diary/domain/calculate_daily_nutrition_use_case.dart`
- `lib/features/diary/domain/models/daily_nutrition.dart`
- `lib/features/diary/domain/models/fluid_entry.dart`
- `lib/features/diary/domain/models/food_entry.dart`
- `lib/features/diary/domain/models/food_item.dart`
- `lib/features/diary/domain/models/tracked_food_item.dart`
- `lib/features/diary/domain/models/water_entry.dart`
- `lib/features/diary/presentation/add_food_screen.dart`
- `lib/features/diary/presentation/ai_meal_review_screen.dart`
- `lib/features/diary/presentation/create_food_screen.dart`
- `lib/features/diary/presentation/dialogs/delete_meal_entry_bottom_sheet.dart`
- `lib/features/diary/presentation/dialogs/fluid_dialog_content.dart`
- `lib/features/diary/presentation/dialogs/quantity_dialog_content.dart`
- `lib/features/diary/presentation/dialogs/quantity_log_flow.dart`
- `lib/features/diary/presentation/diary_screen.dart`
- `lib/features/diary/presentation/food_detail_screen.dart`
- `lib/features/diary/presentation/food_explorer_screen.dart`
- `lib/features/diary/presentation/general_food_selection_screen.dart`
- `lib/features/diary/presentation/meal_entry_screen.dart`
- `lib/features/diary/presentation/meal_screen.dart`
- `lib/features/diary/presentation/meals_screen.dart`
- `lib/features/diary/presentation/widgets/confirm_log_meal_bottom_sheet.dart`
- `lib/features/diary/presentation/widgets/food_entry_tile.dart`
- `lib/features/diary/presentation/widgets/food_item_search_tile.dart`
- `lib/features/diary/presentation/widgets/meal_entry_card.dart`
- `lib/features/diary/presentation/widgets/meal_ingredients_summary.dart`
- `lib/features/diary/presentation/widgets/meal_reanalysis_comparison_dialog.dart`
- `lib/features/diary/presentation/widgets/meal_review_comparison_card.dart`
- `lib/features/diary/presentation/widgets/meal_review_macros_bar.dart`
- `lib/features/statistics/data/body_nutrition_analytics_data_adapter.dart`
- `lib/generated/app_localizations.dart`
- `lib/generated/app_localizations_de.dart`
- `lib/generated/app_localizations_en.dart`
- `lib/generated/app_localizations_fr.dart`
- `lib/generated/app_localizations_it.dart`
- `lib/generated/app_localizations_ja.dart`
- `lib/l10n/app_de.arb`
- `lib/l10n/app_en.arb`
- `lib/l10n/app_fr.arb`
- `lib/l10n/app_it.arb`
- `lib/l10n/app_ja.arb`
- `lib/services/ai/ai_models.dart`
- `lib/services/ai/ai_parsing.dart`
- `lib/services/ai/ai_prompts.dart`
- `lib/services/ai/validation/validation_models.dart`
- `lib/services/ai_repair_candidate.dart`
- `lib/widgets/common/macro_badge_row.dart`
- `pubspec.lock`
- `pubspec.yaml`
- `test/ai_meal_validation_test.dart`
- `test/data/schema_v30_migration_test.dart`
- `test/features/diary/data/sources/meal_entry_move_test.dart`

### Шинээр нэмсэн 5 файл

- `documentation/phase-1a-report.md`
- `lib/features/diary/domain/models/nutrition_values.dart`
- `test/data/schema_v32_decimal_migration_test.dart`
- `test/decimal_nutrition_test.dart`
- `test/features/diary/presentation/decimal_quantity_test.dart`
