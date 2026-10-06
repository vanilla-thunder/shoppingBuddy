"""Product operations shared by the JSON API and the web UI.

Callers commit; these functions only stage changes on the session.
"""

from uuid import uuid4

from sqlalchemy import case, func, or_, select
from sqlalchemy.orm import Session, selectinload

from app.categories import LOCAL
from app.models import Identifier, Product
from app.schemas import IdentifierFields, ProductCreate, ProductUpdate
from app.services import fresh_timestamp, find_live_identifier, next_seq, tombstone_identifiers, touch, utcnow


class NotFound(Exception):
    pass


class IdentifierTaken(Exception):
    def __init__(self, ident: IdentifierFields, product_id: str):
        super().__init__(f"{ident.type} {ident.value} already belongs to product {product_id}")
        self.identifier = ident
        self.product_id = product_id


class DuplicateIdentifiers(Exception):
    pass


def _escape_like(text: str) -> str:
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def search_products(
    db: Session, q: str | None, limit: int, offset: int = 0, category: str | None = None
) -> list[Product]:
    """Search live products; `category` (already normalized) restricts to one category."""
    query = (
        select(Product)
        .where(Product.deleted.is_(False))
        .options(selectinload(Product.identifiers))
        .order_by(Product.name, Product.id)
        .limit(limit)
        .offset(offset)
    )
    if category is not None:
        query = query.where(Product.category == category)
    if q and q.strip():
        pattern = f"%{_escape_like(q.strip())}%"
        matching_ids = select(Identifier.product_id).where(
            Identifier.deleted.is_(False), Identifier.value.like(pattern, escape="\\")
        )
        query = query.where(
            or_(
                Product.name.ilike(pattern, escape="\\"),
                Product.brand.ilike(pattern, escape="\\"),
                Product.id.in_(matching_ids),
            )
        )
    return list(db.scalars(query))


def list_categories(db: Session) -> list[tuple[str, int]]:
    """Categories in use with their live product counts, "local" first."""
    rows = db.execute(
        select(Product.category, func.count())
        .where(Product.deleted.is_(False))
        .group_by(Product.category)
        .order_by(case((Product.category == LOCAL, 0), else_=1), Product.category)
    )
    return [(category, count) for category, count in rows]


def get_live_product(db: Session, product_id: str) -> Product:
    product = db.get(Product, product_id)
    if product is None or product.deleted:
        raise NotFound(product_id)
    return product


def lookup(db: Session, ident: IdentifierFields) -> Product | None:
    row = find_live_identifier(db, ident.type, ident.value, ident.store)
    return row.product if row is not None else None


def ensure_identifier_free(db: Session, ident: IdentifierFields) -> None:
    clash = find_live_identifier(db, ident.type, ident.value, ident.store)
    if clash is not None:
        raise IdentifierTaken(ident, clash.product_id)


def add_identifier(db: Session, product: Product, ident: IdentifierFields) -> Identifier:
    ensure_identifier_free(db, ident)
    ts = utcnow()
    row = Identifier(
        id=str(uuid4()),
        product_id=product.id,
        type=ident.type,
        value=ident.value,
        store=ident.store,
        created_at=ts,
        updated_at=ts,
        deleted=False,
        server_seq=next_seq(db),
    )
    db.add(row)
    db.flush()
    return row


def create_product(db: Session, data: ProductCreate) -> Product:
    keys = [(i.type, i.value, i.store) for i in data.identifiers]
    if len(keys) != len(set(keys)):
        raise DuplicateIdentifiers()
    for ident in data.identifiers:
        ensure_identifier_free(db, ident)

    ts = utcnow()
    product = Product(
        id=str(uuid4()),
        name=data.name,
        brand=data.brand,
        rating=data.rating,
        notes=data.notes,
        category=data.category,
        created_at=ts,
        updated_at=ts,
        deleted=False,
        server_seq=next_seq(db),
    )
    db.add(product)
    db.flush()
    for ident in data.identifiers:
        add_identifier(db, product, ident)
    return product


def update_product(db: Session, product: Product, data: ProductUpdate) -> Product:
    for field in data.model_fields_set:
        setattr(product, field, getattr(data, field))
    touch(db, product, fresh_timestamp(product.updated_at))
    return product


def delete_product(db: Session, product: Product) -> None:
    tombstone_identifiers(db, product)
    product.deleted = True
    touch(db, product, fresh_timestamp(product.updated_at))


def delete_identifier(db: Session, identifier_id: str) -> Identifier:
    row = db.get(Identifier, identifier_id)
    if row is None or row.deleted:
        raise NotFound(identifier_id)
    row.deleted = True
    touch(db, row, fresh_timestamp(row.updated_at))
    return row
