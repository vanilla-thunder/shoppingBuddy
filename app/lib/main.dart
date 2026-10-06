import 'package:flutter/material.dart';

import 'src/app_scope.dart';
import 'src/data/database.dart';
import 'src/data/repository.dart';
import 'src/ui/products_screen.dart';
import 'src/ui/scan_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = ProductRepository(AppDatabase());
  final categoryFilter = await CategoryFilter.load(repo);
  runApp(AppScope(repo: repo, categoryFilter: categoryFilter, child: const ShoppingBuddyApp()));
}

class ShoppingBuddyApp extends StatelessWidget {
  const ShoppingBuddyApp({super.key, this.home = const HomeShell()});

  final Widget home;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2F6F4F);
    return MaterialApp(
      title: 'shoppingBuddy',
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: home,
    );
  }
}

/// Bottom navigation between the scanner and the product list. Tabs aren't kept alive, so
/// the camera stops while the list is shown.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: switch (_tab) {
        0 => const ScanScreen(),
        _ => const ProductsScreen(),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.qr_code_scanner), label: 'Scan'),
          NavigationDestination(icon: Icon(Icons.list_alt), label: 'Products'),
        ],
      ),
    );
  }
}
