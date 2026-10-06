import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/repository.dart';
import '../domain/categories.dart';
import '../domain/identifiers.dart';
import 'widgets/star_rating.dart';

/// Create a product (optionally with a scanned barcode) or edit an existing one.
class ProductFormScreen extends StatefulWidget {
  const ProductFormScreen({super.key, this.productId, this.initialGtin});

  final String? productId;
  final String? initialGtin;

  @override
  State<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends State<ProductFormScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _brand = TextEditingController();
  final _notes = TextEditingController();
  final _category = TextEditingController();
  final _gtin = TextEditingController();
  int? _rating;
  Product? _product;
  bool _loading = true;
  bool _lookingUp = false;
  bool _prefilled = false;

  bool get _isNew => widget.productId == null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final scope = AppScope.of(context);
    if (_isNew) {
      _category.text = scope.categoryFilter.forNewProducts;
      _gtin.text = widget.initialGtin == null ? '' : displayGtin(widget.initialGtin!);
      if (widget.initialGtin != null) _prefill(widget.initialGtin!);
    } else {
      final product = await scope.repo.getProduct(widget.productId!);
      if (product != null) {
        _product = product;
        _name.text = product.row.name;
        _brand.text = product.row.brand ?? '';
        _notes.text = product.row.notes ?? '';
        _category.text = product.row.category;
        _rating = product.row.rating;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Fills name and brand from Open Food Facts, but never overwrites what the user typed.
  Future<void> _prefill(String gtin) async {
    _lookingUp = true; // runs from _load, before the first build: no setState needed
    final info = await AppScope.of(context).productInfo.lookup(gtin);
    if (!mounted) return;
    setState(() {
      _lookingUp = false;
      if (info == null || _name.text.trim().isNotEmpty) return;
      _name.text = info.name;
      if (_brand.text.trim().isEmpty) _brand.text = info.brand ?? '';
      _prefilled = true;
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _brand, _notes, _category, _gtin]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _validateCategory(String? value) {
    try {
      normalizeCategory((value ?? '').trim().isEmpty ? localCategory : value!);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  String? _validateGtin(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    try {
      normalizeGtin(value);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final repo = AppScope.of(context).repo;
    final draft = ProductDraft(
      name: _name.text,
      brand: _brand.text,
      notes: _notes.text,
      rating: _rating,
      category: _category.text.trim().isEmpty ? localCategory : _category.text,
    );
    try {
      if (_isNew) {
        final gtin = _gtin.text.trim();
        await repo.createProduct(draft, [if (gtin.isNotEmpty) normalizeGtin(gtin)]);
      } else {
        // Re-resolved, in case a sync merged this product into another while the form was open.
        final current = await repo.getProduct(_product!.id);
        if (current == null) throw StateError('product no longer exists');
        await repo.updateProduct(current.id, draft);
      }
      if (mounted) Navigator.of(context).pop();
    } on IdentifierTaken catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${e.identifier} already belongs to another product'),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
            builder: (_) => ProductFormScreen(productId: e.productId),
          )),
        ),
      ));
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete product?'),
        content: Text(_name.text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await AppScope.of(context).repo.deleteProduct(_product!.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _addBarcode() async {
    final repo = AppScope.of(context).repo;
    final code = await showDialog<String>(context: context, builder: (_) => const _BarcodeDialog());
    if (code == null || !mounted) return;
    try {
      await repo.addIdentifier(_product!.id, normalizeGtin(code));
    } on IdentifierTaken catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${e.identifier} belongs to another product')));
      }
    }
    final product = await repo.getProduct(_product!.id);
    if (mounted) setState(() => _product = product);
  }

  Future<void> _removeBarcode(NormalizedIdentifier ident) async {
    final repo = AppScope.of(context).repo;
    await repo.removeIdentifier(_product!.id, ident);
    final product = await repo.getProduct(_product!.id);
    if (mounted) setState(() => _product = product);
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New product' : 'Edit product'),
        actions: [
          if (!_isNew) IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (!_isNew && _product == null)
              ? const Center(child: Text('This product no longer exists.'))
              : Form(
                  key: _form,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      TextFormField(
                        controller: _name,
                        autofocus: _isNew,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          labelText: 'Name',
                          helperText: _lookingUp
                              ? 'Looking up Open Food Facts…'
                              : (_prefilled ? 'From Open Food Facts, please check' : null),
                          suffixIcon: _lookingUp
                              ? const Padding(
                                  padding: EdgeInsets.all(14),
                                  child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                                )
                              : null,
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Name is required' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _brand,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(labelText: 'Brand / restaurant'),
                      ),
                      const SizedBox(height: 12),
                      StreamBuilder<List<CategoryCount>>(
                        stream: repo.watchCategories(),
                        builder: (context, snapshot) => _CategoryField(
                          controller: _category,
                          suggestions: {localCategory, ...?snapshot.data?.map((c) => c.category)}.toList(),
                          validator: _validateCategory,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text('Rating', style: Theme.of(context).textTheme.labelLarge),
                      StarRating(rating: _rating, size: 40, onChanged: (r) => setState(() => _rating = r)),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _notes,
                        minLines: 2,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(labelText: 'Notes'),
                      ),
                      const SizedBox(height: 12),
                      if (_isNew)
                        TextFormField(
                          controller: _gtin,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Barcode (EAN / GTIN)'),
                          validator: _validateGtin,
                        )
                      else ...[
                        Text('Barcodes & article numbers', style: Theme.of(context).textTheme.labelLarge),
                        for (final ident in _product!.identifiers)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(ident.toString()),
                            trailing: IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.close),
                              onPressed: () => _removeBarcode(ident),
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _addBarcode,
                            icon: const Icon(Icons.add),
                            label: const Text('Add barcode'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(onPressed: _save, child: const Text('Save')),
                    ],
                  ),
                ),
    );
  }
}

class _CategoryField extends StatefulWidget {
  const _CategoryField({required this.controller, required this.suggestions, required this.validator});

  final TextEditingController controller;
  final List<String> suggestions;
  final FormFieldValidator<String> validator;

  @override
  State<_CategoryField> createState() => _CategoryFieldState();
}

class _CategoryFieldState extends State<_CategoryField> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: widget.controller,
      focusNode: _focus,
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        return widget.suggestions.where((s) => s != q && s.contains(q));
      },
      fieldViewBuilder: (context, textController, focusNode, onSubmit) => TextFormField(
        controller: textController,
        focusNode: focusNode,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: 'Category',
          helperText: '“local” for shops, or a website such as lieferando.de',
        ),
        validator: widget.validator,
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200, maxWidth: 320),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [for (final o in options) ListTile(title: Text(o), onTap: () => onSelected(o))],
            ),
          ),
        ),
      ),
    );
  }
}

class _BarcodeDialog extends StatefulWidget {
  const _BarcodeDialog();

  @override
  State<_BarcodeDialog> createState() => _BarcodeDialogState();
}

class _BarcodeDialogState extends State<_BarcodeDialog> {
  final _text = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      normalizeGtin(_text.text);
      Navigator.pop(context, _text.text);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add barcode'),
      content: TextField(
        controller: _text,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(hintText: 'EAN / GTIN', errorText: _error),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}
