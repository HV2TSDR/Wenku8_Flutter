import 'catalog.dart';

/// A tag query can continue through catalogue pages while its owner is alive.
/// Other repository/search callers keep their original one-Future contract.
abstract interface class ProgressiveTagCatalogue {
  Future<NovelPage> tagPage(
    String tag, {
    int page = 1,
    bool refresh = false,
    bool Function()? current,
  });
}
