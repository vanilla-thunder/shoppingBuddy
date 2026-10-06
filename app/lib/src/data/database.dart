import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// Local copy of the server's products table (docs/sync.md, "Records").
@DataClassName('ProductRow')
class Products extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get brand => text().nullable()();
  IntColumn get rating => integer().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get category => text().withDefault(const Constant('local'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  TextColumn get mergedInto => text().nullable()();

  /// Assigned by the server; null until the row has been synced once.
  IntColumn get serverSeq => integer().nullable()();

  /// Changed on this device and not yet pushed.
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Local copy of the server's identifiers table. There is deliberately no unique index on
/// (type, value, store): pages applied during a pull can briefly hold both a stale and a
/// fresh copy of a barcode. Uniqueness for local edits is checked in the repository instead.
@DataClassName('IdentifierRow')
@TableIndex(name: 'ix_identifiers_lookup', columns: {#type, #value, #store})
@TableIndex(name: 'ix_identifiers_product', columns: {#productId})
class Identifiers extends Table {
  TextColumn get id => text()();
  TextColumn get productId => text()();
  TextColumn get type => text()();
  TextColumn get value => text()();
  TextColumn get store => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  IntColumn get serverSeq => integer().nullable()();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Small key/value store for app state such as the selected category and the last pulled seq.
@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Products, Identifiers, Settings])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? driftDatabase(name: 'shopping_buddy'));

  @override
  int get schemaVersion => 1;
}
