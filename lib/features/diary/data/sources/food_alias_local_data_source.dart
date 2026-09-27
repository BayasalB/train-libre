import 'package:drift/drift.dart';
import '../../../../data/drift_database.dart';
import '../../domain/models/food_alias.dart';

/// Entirely local. No aliases are seeded or inferred from product categories.
class FoodAliasLocalDataSource {
  final AppDatabase db;
  FoodAliasLocalDataSource(this.db);

  Future<List<FoodAliase>> forFood(String barcode) => (db.select(db.foodAliases)
        ..where((t) => t.productBarcode.equals(barcode) & t.deletedAt.isNull())
        ..orderBy([
          (t) => OrderingTerm.asc(t.createdAt),
          (t) => OrderingTerm.asc(t.localId)
        ]))
      .get();

  Future<List<FoodAliase>> find(String query, {bool exact = true}) {
    final normalized = normalizeFoodAlias(query);
    if (normalized.isEmpty) return Future.value([]);
    return (db.select(db.foodAliases)
          ..where((t) =>
              t.deletedAt.isNull() &
              (exact
                  ? t.normalizedAlias.equals(normalized)
                  : t.normalizedAlias.contains(normalized))))
        .get();
  }

  Future<void> save(String barcode, FoodAliasDraft draft) async {
    final normalized = normalizeFoodAlias(draft.alias);
    if (normalized.isEmpty) throw ArgumentError('Alias cannot be empty.');
    await db.transaction(() async {
      final existing = await (db.select(db.foodAliases)
            ..where((t) =>
                t.productBarcode.equals(barcode) &
                t.normalizedAlias.equals(normalized)))
          .getSingleOrNull();
      if (existing != null &&
          existing.deletedAt == null &&
          existing.id != draft.id) {
        throw DuplicateFoodAlias(draft.alias);
      }
      final now = DateTime.now();
      final values = FoodAliasesCompanion(
          productBarcode: Value(barcode),
          alias: Value(draft.alias),
          normalizedAlias: Value(normalized),
          language: Value(draft.language?.trim().isEmpty == true
              ? null
              : draft.language?.trim()),
          updatedAt: Value(now),
          deletedAt: const Value(null));
      if (draft.id != null) {
        // A tombstone for the destination alias must not block a rename.
        if (existing != null && existing.id != draft.id) {
          await (db.delete(db.foodAliases)
                ..where((t) => t.id.equals(existing.id)))
              .go();
        }
        final count = await (db.update(db.foodAliases)
              ..where((t) =>
                  t.id.equals(draft.id!) & t.productBarcode.equals(barcode)))
            .write(values);
        if (count != 1) {
          throw StateError('Alias no longer exists. Reload the food.');
        }
      } else if (existing != null) {
        await (db.update(db.foodAliases)
              ..where((t) => t.id.equals(existing.id)))
            .write(values);
      } else {
        await db.into(db.foodAliases).insert(values);
      }
    });
  }

  Future<void> delete(String id) =>
      (db.update(db.foodAliases)..where((t) => t.id.equals(id))).write(
          FoodAliasesCompanion(
              deletedAt: Value(DateTime.now()),
              updatedAt: Value(DateTime.now())));

  /// Used by the editor inside the same transaction as saving the food.
  Future<void> replaceForFood(
      String barcode, List<FoodAliasDraft> drafts) async {
    final keys = <String>{};
    for (final draft in drafts) {
      if (!keys.add(normalizeFoodAlias(draft.alias))) {
        throw DuplicateFoodAlias(draft.alias);
      }
    }
    await db.transaction(() async {
      final previous = await forFood(barcode);
      // Retain deletion timestamps; every change commits with the food edit.
      for (final row in previous) {
        await delete(row.id);
      }
      // Release retained names during this transaction so two edits can swap
      // aliases without deleting either UUID. These keys are never committed.
      final retainedIds =
          drafts.map((draft) => draft.id).whereType<String>().toSet();
      for (final row in previous.where((row) => retainedIds.contains(row.id))) {
        await (db.update(db.foodAliases)..where((t) => t.id.equals(row.id)))
            .write(FoodAliasesCompanion(
                normalizedAlias: Value('\u0000editing:${row.id}')));
      }
      for (final draft in drafts) {
        await save(barcode, draft);
      }
    });
  }
}
