import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/repository.dart';
import '../domain/categories.dart';
import 'product_form_screen.dart';
import 'widgets/category_menu.dart';
import 'widgets/star_rating.dart';

/// Searchable product list, filtered by the selected category.
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  String _query = '';

  void _open(BuildContext context, {String? productId}) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ProductFormScreen(productId: productId)),
      );

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Products'), actions: const [CategoryMenu()]),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add product',
        onPressed: () => _open(context),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SearchBar(
              hintText: 'Search name, brand or barcode',
              leading: const Icon(Icons.search),
              onChanged: (q) => setState(() => _query = q),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<String?>(
              valueListenable: scope.categoryFilter,
              builder: (context, category, _) => StreamBuilder<List<Product>>(
                // Keyed so a new filter or query starts a fresh stream.
                key: ValueKey((category, _query)),
                stream: scope.repo.watchProducts(category: category, query: _query),
                builder: (context, snapshot) {
                  final products = snapshot.data;
                  if (products == null) return const SizedBox.shrink();
                  // Pull-to-refresh syncs with the server.
                  return RefreshIndicator(
                    onRefresh: scope.sync.syncNow,
                    child: products.isEmpty
                        ? ListView(children: [
                            const SizedBox(height: 120),
                            Center(
                              child: Text(
                                _query.isEmpty
                                    ? 'No products${category == null ? '' : ' in $category'} yet'
                                    : 'Nothing found',
                              ),
                            ),
                          ])
                        : ListView.separated(
                            padding: const EdgeInsets.only(bottom: 88),
                            itemCount: products.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, i) => _ProductTile(
                              product: products[i],
                              showCategory: category == null,
                              onTap: () => _open(context, productId: products[i].id),
                              onRating: (r) => scope.repo.setRating(products[i].id, r),
                            ),
                          ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.product, required this.showCategory, required this.onTap, required this.onRating});

  final Product product;
  final bool showCategory;
  final VoidCallback onTap;
  final ValueChanged<int?> onRating;

  @override
  Widget build(BuildContext context) {
    final row = product.row;
    final subtitle = [
      row.brand,
      if (showCategory && row.category != localCategory) row.category,
      ...product.identifiers.map((i) => i.toString()),
    ].nonNulls.join(' · ');
    return ListTile(
      title: Text(row.name),
      subtitle: subtitle.isEmpty ? null : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: StarRating(rating: row.rating, size: 22, onChanged: onRating),
      onTap: onTap,
    );
  }
}
