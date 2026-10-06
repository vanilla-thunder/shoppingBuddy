"""CSV export/import of the product list.

Columns: id, name, brand, rating, notes, gtins, store_articles
  gtins           barcodes separated by ";"
  store_articles  "store=article" pairs separated by ";"
Only `name` is required on import; header names are case-insensitive.
"""

import csv
import io
from dataclasses import dataclass, field

from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app import catalog
from app.models import Product
from app.schemas import IdentifierFields, ProductCreate, ProductUpdate

COLUMNS = ["id", "name", "brand", "rating", "notes", "gtins", "store_articles"]
HEADER_ALIASES = {"gtin": "gtins", "ean": "gtins", "eans": "gtins", "barcode": "gtins"}
EDITABLE = ("name", "brand", "rating", "notes")


def export_csv(db: Session) -> str:
    products = db.scalars(
        select(Product)
        .where(Product.deleted.is_(False))
        .options(selectinload(Product.identifiers))
        .order_by(Product.name, Product.id)
    )
    out = io.StringIO()
    writer = csv.writer(out)
    writer.writerow(COLUMNS)
    for p in products:
        live = [i for i in p.identifiers if not i.deleted]
        writer.writerow(
            [
                p.id,
                p.name,
                p.brand or "",
                p.rating or "",
                p.notes or "",
                ";".join(i.value for i in live if i.type == "gtin"),
                ";".join(f"{i.store}={i.value}" for i in live if i.type == "store_article"),
            ]
        )
    # BOM so Excel detects UTF-8 (umlauts in product names).
    return "﻿" + out.getvalue()


@dataclass
class ImportReport:
    created: int = 0
    updated: int = 0
    unchanged: int = 0
    errors: list[tuple[int, str]] = field(default_factory=list)


class RowError(Exception):
    pass


def _error_text(exc: ValidationError) -> str:
    return "; ".join(e["msg"].removeprefix("Value error, ") for e in exc.errors())


def _parse_identifiers(row: dict[str, str]) -> list[IdentifierFields]:
    idents = []
    try:
        for value in filter(None, (v.strip() for v in row.get("gtins", "").split(";"))):
            idents.append(IdentifierFields(type="gtin", value=value))
        for pair in filter(None, (v.strip() for v in row.get("store_articles", "").split(";"))):
            store, sep, article = pair.partition("=")
            if not sep:
                raise RowError(f"store article {pair!r} must look like store=number")
            idents.append(IdentifierFields(type="store_article", value=article, store=store))
    except ValidationError as exc:
        raise RowError(_error_text(exc))
    return idents


def _find_existing(db: Session, row: dict[str, str], idents: list[IdentifierFields]) -> Product | None:
    if row.get("id"):
        try:
            return catalog.get_live_product(db, row["id"].strip())
        except catalog.NotFound:
            pass
    for ident in idents:
        product = catalog.lookup(db, ident)
        if product is not None:
            return product
    return None


def _import_row(db: Session, row: dict[str, str], report: ImportReport) -> None:
    idents = _parse_identifiers(row)
    # Empty cells mean "leave as is" for existing products.
    values = {k: row[k].strip() for k in EDITABLE if row.get(k, "").strip()}
    existing = _find_existing(db, row, idents)

    try:
        if existing is None:
            catalog.create_product(db, ProductCreate(**values, identifiers=idents))
            report.created += 1
            return
        update = ProductUpdate(**values)
    except ValidationError as exc:
        raise RowError(_error_text(exc))
    except catalog.DuplicateIdentifiers:
        raise RowError("the same identifier appears twice")

    changes = {k: getattr(update, k) for k in update.model_fields_set if getattr(existing, k) != getattr(update, k)}
    present = {(i.type, i.value, i.store) for i in existing.identifiers if not i.deleted}
    new_idents = [i for i in idents if (i.type, i.value, i.store) not in present]
    if not changes and not new_idents:
        report.unchanged += 1
        return
    if changes:
        catalog.update_product(db, existing, ProductUpdate(**changes))
    for ident in new_idents:
        catalog.add_identifier(db, existing, ident)
    report.updated += 1


def import_csv(db: Session, data: bytes) -> ImportReport:
    text = data.decode("utf-8-sig")
    try:
        dialect = csv.Sniffer().sniff(text.split("\n", 1)[0], delimiters=",;\t")
    except csv.Error:
        dialect = csv.excel
    reader = csv.DictReader(io.StringIO(text), dialect=dialect)
    if reader.fieldnames is None:
        return ImportReport(errors=[(1, "file is empty")])
    reader.fieldnames = [HEADER_ALIASES.get(h.strip().lower(), h.strip().lower()) for h in reader.fieldnames]
    if "name" not in reader.fieldnames:
        return ImportReport(errors=[(1, "header row needs a 'name' column")])

    report = ImportReport()
    for row in reader:
        row = {k: v or "" for k, v in row.items() if k is not None}
        try:
            with db.begin_nested():
                _import_row(db, row, report)
        except RowError as exc:
            report.errors.append((reader.line_num, str(exc)))
        except catalog.IdentifierTaken as exc:
            report.errors.append(
                (reader.line_num, f"{exc.identifier.value} already belongs to another product")
            )
    return report
