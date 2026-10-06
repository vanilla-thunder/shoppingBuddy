import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopping_buddy/main.dart';
import 'package:shopping_buddy/src/app_scope.dart';
import 'package:shopping_buddy/src/data/database.dart';
import 'package:shopping_buddy/src/data/repository.dart';
import 'package:shopping_buddy/src/domain/identifiers.dart';
import 'package:shopping_buddy/src/product_info.dart';
import 'package:shopping_buddy/src/sync/sync_controller.dart';
import 'package:shopping_buddy/src/ui/products_screen.dart';
import 'package:shopping_buddy/src/ui/scan_screen.dart';
import 'package:shopping_buddy/src/ui/sync_screen.dart';

const milkCode = '4006381333931';

class FakeProductInfo implements ProductInfoLookup {
  final known = <String, ProductInfo>{};
  final asked = <String>[];

  @override
  Future<ProductInfo?> lookup(String gtin) async {
    asked.add(gtin);
    return known[gtin];
  }
}

void main() {
  late AppDatabase db;
  late ProductRepository repo;
  late CategoryFilter filter;
  late FakeProductInfo productInfo;
  late SyncController sync;
  late void Function(String raw, {bool isUpcE}) scan;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = ProductRepository(db);
    filter = await CategoryFilter.load(repo);
    productInfo = FakeProductInfo();
    sync = await SyncController.load(repo); // not configured: never contacts a server
  });

  tearDown(() => db.close());

  Future<void> pumpApp(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(AppScope(
      repo: repo,
      categoryFilter: filter,
      productInfo: productInfo,
      sync: sync,
      child: ShoppingBuddyApp(home: home),
    ));
    await tester.pumpAndSettle();
  }

  /// Unmounts the app so drift's stream cleanup timers run before the test ends.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  Widget fakeCamera(BuildContext context, void Function(String raw, {bool isUpcE}) onCode) {
    scan = onCode;
    return const ColoredBox(color: Colors.black);
  }

  Future<void> scanCode(WidgetTester tester, String code, {bool isUpcE = false}) async {
    await tester.runAsync(() async => scan(code, isUpcE: isUpcE));
    await tester.pumpAndSettle();
  }

  testWidgets('scanning a known barcode shows the rating; tapping a star changes it', (tester) async {
    final id = await tester.runAsync(
      () => repo.createProduct(ProductDraft(name: 'Vollmilch', brand: 'Weihenstephan', rating: 2), [normalizeGtin(milkCode)]),
    );
    await pumpApp(tester, ScanScreen(cameraBuilder: fakeCamera));

    expect(find.text('Point the camera at a barcode'), findsOneWidget);
    await scanCode(tester, milkCode);
    expect(find.text('Vollmilch'), findsOneWidget);
    expect(find.text('Weihenstephan · local · $milkCode'), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsNWidgets(2));

    await tester.tap(find.bySemanticsLabel('5 of 5 stars'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect((await tester.runAsync(() => repo.getProduct(id!)))!.row.rating, 5);
    expect(find.byIcon(Icons.star_rounded), findsNWidgets(5));
    await unmount(tester);
  });

  testWidgets('unknown barcode leads to an add form with the barcode filled in', (tester) async {
    await pumpApp(tester, ScanScreen(cameraBuilder: fakeCamera));
    await scanCode(tester, milkCode);
    expect(find.text('Unknown product'), findsOneWidget);

    await tester.tap(find.text('Add product'));
    await tester.pumpAndSettle();
    expect(find.text('New product'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, milkCode), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'local'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Vollmilch');
    await tester.tap(find.bySemanticsLabel('4 of 5 stars'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    // Back on the scanner, the card now shows the new product.
    expect(find.text('Vollmilch'), findsOneWidget);
    final product = await tester.runAsync(() => repo.lookup(normalizeGtin(milkCode)));
    expect(product!.row.rating, 4);
    expect(product.row.dirty, isTrue);
    await unmount(tester);
  });

  testWidgets('unknown barcode: name and brand are prefilled from Open Food Facts', (tester) async {
    productInfo.known[normalizeGtin(milkCode).value] = const ProductInfo(name: 'Frische Vollmilch', brand: 'Weihenstephan');
    await pumpApp(tester, ScanScreen(cameraBuilder: fakeCamera));
    await scanCode(tester, milkCode);
    await tester.tap(find.text('Add product'));
    await tester.pumpAndSettle();

    expect(productInfo.asked, [normalizeGtin(milkCode).value]);
    expect(find.widgetWithText(TextFormField, 'Frische Vollmilch'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Weihenstephan'), findsOneWidget);
    expect(find.text('From Open Food Facts, please check'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('invalid and UPC-E barcodes', (tester) async {
    await pumpApp(tester, ScanScreen(cameraBuilder: fakeCamera));
    await scanCode(tester, '4006381333932');
    expect(find.textContaining('check digit'), findsOneWidget);
    await scanCode(tester, '04252614', isUpcE: true);
    expect(find.text('042100005264'), findsOneWidget); // shown as its UPC-A form
    await unmount(tester);
  });

  testWidgets('sync screen shows unsynced changes and saves the server settings', (tester) async {
    await tester.runAsync(() => repo.createProduct(ProductDraft(name: 'Vollmilch'), [normalizeGtin(milkCode)]));
    await pumpApp(tester, const SyncScreen());
    expect(find.text('2 unsynced changes'), findsOneWidget);
    expect(find.text('Enter the server URL and token to sync.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Server URL'), 'not a url');
    await tester.tap(find.text('Save and sync'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a URL'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('product list is filtered by category, "local" by default', (tester) async {
    await tester.runAsync(() async {
      await repo.createProduct(ProductDraft(name: 'Vollmilch'));
      await repo.createProduct(ProductDraft(name: 'Pizza', category: 'lieferando.de'));
    });
    await pumpApp(tester, const ProductsScreen());
    expect(find.text('Vollmilch'), findsOneWidget);
    expect(find.text('Pizza'), findsNothing);

    await tester.tap(find.text('local'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All categories'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Pizza'), findsOneWidget);
    expect(find.text('lieferando.de'), findsOneWidget); // category shown in "all"
    expect(await tester.runAsync(() => repo.getSetting('category_filter')), '*');
    await unmount(tester);
  });
}
