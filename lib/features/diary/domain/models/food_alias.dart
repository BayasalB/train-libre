/// Unicode lowercasing supports Latin and Cyrillic; no transliteration or guessing.
String normalizeFoodAlias(String value) => value
    .replaceAll(RegExp(r'[\s\u00a0\u202f]+', unicode: true), ' ')
    .trim()
    .toLowerCase();

class FoodAliasDraft {
  final String? id;
  final String alias;
  final String? language;
  const FoodAliasDraft({this.id, required this.alias, this.language});
}

class DuplicateFoodAlias implements Exception {
  final String alias;
  const DuplicateFoodAlias(this.alias);
  @override
  String toString() => 'This food already has the alias "$alias".';
}
