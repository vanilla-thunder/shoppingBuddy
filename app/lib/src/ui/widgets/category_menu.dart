import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/repository.dart';

/// App-bar dropdown that switches the category filter ("All" or one category).
class CategoryMenu extends StatelessWidget {
  const CategoryMenu({super.key});

  // PopupMenuButton treats a null value as "cancelled", so "all" needs a real value.
  static const _all = '\u0000all';

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return StreamBuilder<List<CategoryCount>>(
      stream: scope.repo.watchCategories(),
      builder: (context, snapshot) {
        final categories = snapshot.data ?? const <CategoryCount>[];
        return ValueListenableBuilder<String?>(
          valueListenable: scope.categoryFilter,
          builder: (context, selected, _) {
            final names = {for (final c in categories) c.category, ?selected};
            return PopupMenuButton<String>(
              tooltip: 'Category',
              initialValue: selected ?? _all,
              onSelected: (value) => scope.categoryFilter.select(value == _all ? null : value),
              itemBuilder: (_) => [
                const PopupMenuItem<String>(value: _all, child: Text('All categories')),
                for (final name in names)
                  PopupMenuItem<String>(
                    value: name,
                    child: Text(
                      '$name (${categories.where((c) => c.category == name).firstOrNull?.count ?? 0})',
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.storefront_outlined, size: 20),
                    const SizedBox(width: 6),
                    Text(selected ?? 'All'),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
