import 'package:flutter/widgets.dart';

import 'data/repository.dart';
import 'domain/categories.dart';
import 'product_info.dart';
import 'sync/sync_controller.dart';

/// The category the lists are filtered by; null means all. Persisted across app starts.
class CategoryFilter extends ValueNotifier<String?> {
  CategoryFilter._(this._repo, super.value);

  static const _key = 'category_filter';
  static const _all = '*';
  final ProductRepository _repo;

  /// Defaults to "local": in the shop, scans and lists should only show groceries.
  static Future<CategoryFilter> load(ProductRepository repo) async {
    final stored = await repo.getSetting(_key);
    return CategoryFilter._(repo, stored == null ? localCategory : (stored == _all ? null : stored));
  }

  Future<void> select(String? category) async {
    value = category;
    await _repo.setSetting(_key, category ?? _all);
  }

  /// Category for new products: the current filter, or "local" when showing all.
  String get forNewProducts => value ?? localCategory;
}

class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.repo,
    required this.categoryFilter,
    required this.productInfo,
    required this.sync,
    required super.child,
  });

  final ProductRepository repo;
  final CategoryFilter categoryFilter;
  final ProductInfoLookup productInfo;
  final SyncController sync;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'no AppScope above this context');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      repo != oldWidget.repo || categoryFilter != oldWidget.categoryFilter ||
      productInfo != oldWidget.productInfo ||
      sync != oldWidget.sync;
}
