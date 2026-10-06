"""Write rules shared by the CRUD API and the sync endpoints.

Every change to a row assigns it a fresh server_seq. Clients pull "everything with
server_seq > N", so a row that changes without a new seq never reaches them.
"""

from datetime import datetime, timedelta, timezone

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.models import Identifier, Product, SyncState
from app.schemas import (
    IdentifierSyncIn,
    IdentifierSyncOut,
    Merge,
    ProductSyncIn,
    ProductSyncOut,
    PullResponse,
    PushRequest,
    PushResponse,
    PushResult,
)

ONE_MS = timedelta(milliseconds=1)
PRODUCT_FIELDS = ("name", "brand", "rating", "notes", "category")


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def fresh_timestamp(*prior: datetime) -> datetime:
    """Timestamp for a server-made change that must win last-write-wins against `prior`,
    even if the client that wrote `prior` has a clock running ahead of the server."""
    return max([utcnow(), *(p + ONE_MS for p in prior)])


def next_seq(db: Session) -> int:
    # The UPDATE holds the counter row lock (Postgres) or the write lock (SQLite) until
    # commit, so transactions commit in seq order and a concurrent pull can never see
    # seq N+1 while N is still uncommitted (which would make clients skip N forever).
    table = SyncState.__table__
    return db.execute(
        update(table)
        .where(table.c.id == 1)
        .values(last_seq=table.c.last_seq + 1)
        .returning(table.c.last_seq)
    ).scalar_one()


def touch(db: Session, row: Product | Identifier, ts: datetime) -> None:
    row.updated_at = ts
    row.server_seq = next_seq(db)


def live_identifiers(db: Session, product_id: str) -> list[Identifier]:
    return list(
        db.scalars(
            select(Identifier).where(
                Identifier.product_id == product_id, Identifier.deleted.is_(False)
            )
        )
    )


def find_live_identifier(
    db: Session, type_: str, value: str, store: str, exclude_id: str | None = None
) -> Identifier | None:
    query = select(Identifier).where(
        Identifier.type == type_,
        Identifier.value == value,
        Identifier.store == store,
        Identifier.deleted.is_(False),
    )
    if exclude_id is not None:
        query = query.where(Identifier.id != exclude_id)
    return db.scalars(query).first()


def resolve_product(db: Session, product_id: str) -> Product | None:
    """Follow merged_into links to the product that currently stands for `product_id`."""
    product = db.get(Product, product_id)
    while product is not None and product.merged_into is not None:
        product = db.get(Product, product.merged_into)
    return product


def tombstone_identifiers(db: Session, product: Product) -> None:
    for ident in live_identifiers(db, product.id):
        ident.deleted = True
        touch(db, ident, fresh_timestamp(ident.updated_at))


def merge_products(db: Session, a: Product, b: Product) -> tuple[Product, Product]:
    """Fold two products that turned out to share a barcode into one.

    The older product survives so its id stays stable. Fields come from whichever side was
    edited more recently, falling back to the other side where that one is empty.
    Returns (survivor, loser).
    """
    survivor, loser = sorted((a, b), key=lambda p: (p.created_at, p.id))
    newer, older = (loser, survivor) if loser.updated_at > survivor.updated_at else (survivor, loser)
    for field in PRODUCT_FIELDS:
        value = getattr(newer, field)
        setattr(survivor, field, value if value is not None else getattr(older, field))

    ts = fresh_timestamp(survivor.updated_at, loser.updated_at)
    touch(db, survivor, ts)
    for ident in live_identifiers(db, loser.id):
        ident.product_id = survivor.id
        touch(db, ident, ts)
    loser.deleted = True
    loser.merged_into = survivor.id
    touch(db, loser, ts)
    return survivor, loser


# --- push ---


def apply_product_push(db: Session, item: ProductSyncIn) -> PushResult:
    pid = str(item.id)
    existing = db.get(Product, pid)
    if existing is None:
        db.add(
            Product(
                id=pid,
                **{f: getattr(item, f) for f in PRODUCT_FIELDS},
                created_at=item.created_at,
                updated_at=item.updated_at,
                deleted=item.deleted,
                server_seq=next_seq(db),
            )
        )
        db.flush()
        return PushResult(id=pid, status="applied")
    if existing.merged_into is not None:
        return PushResult(id=pid, status="ignored_merged", detail=existing.merged_into)
    if item.updated_at <= existing.updated_at:
        return PushResult(id=pid, status="stale")

    for field in PRODUCT_FIELDS:
        setattr(existing, field, getattr(item, field))
    if item.deleted and not existing.deleted:
        tombstone_identifiers(db, existing)
    existing.deleted = item.deleted
    touch(db, existing, item.updated_at)
    db.flush()
    return PushResult(id=pid, status="applied")


def apply_identifier_push(
    db: Session, item: IdentifierSyncIn, merges: list[Merge]
) -> PushResult:
    iid = str(item.id)
    existing = db.get(Identifier, iid)
    if existing is not None and item.updated_at <= existing.updated_at:
        return PushResult(id=iid, status="stale")

    product = resolve_product(db, str(item.product_id))
    if product is None:
        return PushResult(id=iid, status="rejected", detail="unknown product_id")

    status = "applied"
    # A live barcode on a deleted product would block it for good, so store it as deleted.
    deleted = item.deleted or product.deleted
    if not deleted:
        clash = find_live_identifier(db, item.type, item.value, item.store, exclude_id=iid)
        if clash is not None:
            if clash.product_id != product.id:
                other = db.get(Product, clash.product_id)
                product, loser = merge_products(db, product, other)
                merges.append(Merge(merged=loser.id, into=product.id))
            # The barcode is already on the (surviving) product; keep this copy as a tombstone.
            deleted = True
            status = "duplicate"

    # If the server changed the outcome, the stored version must beat the client's copy.
    altered = deleted != item.deleted or product.id != str(item.product_id)
    ts = fresh_timestamp(item.updated_at) if altered else item.updated_at

    row = existing or Identifier(id=iid, created_at=item.created_at)
    row.product_id = product.id
    row.type = item.type
    row.value = item.value
    row.store = item.store
    row.deleted = deleted
    touch(db, row, ts)
    if existing is None:
        db.add(row)
    db.flush()
    return PushResult(id=iid, status=status)


def apply_push(db: Session, request: PushRequest) -> PushResponse:
    merges: list[Merge] = []
    products = [apply_product_push(db, p) for p in request.products]
    identifiers = [apply_identifier_push(db, i, merges) for i in request.identifiers]
    return PushResponse(products=products, identifiers=identifiers, merges=merges)


# --- pull ---


def pull(db: Session, since: int, limit: int) -> PullResponse:
    products = db.scalars(
        select(Product).where(Product.server_seq > since).order_by(Product.server_seq).limit(limit + 1)
    ).all()
    identifiers = db.scalars(
        select(Identifier)
        .where(Identifier.server_seq > since)
        .order_by(Identifier.server_seq)
        .limit(limit + 1)
    ).all()
    rows = sorted([*products, *identifiers], key=lambda r: r.server_seq)
    page = rows[:limit]

    page_products = [r for r in page if isinstance(r, Product)]
    page_identifiers = [r for r in page if isinstance(r, Identifier)]

    # Ship every product this page refers to, even if its own latest change falls on a
    # later page, so a client can apply each page without dangling references.
    have = {p.id for p in page_products}
    referenced = {i.product_id for i in page_identifiers} | {
        p.merged_into for p in page_products if p.merged_into
    }
    missing = referenced - have
    if missing:
        page_products += db.scalars(select(Product).where(Product.id.in_(missing))).all()

    return PullResponse(
        products=[ProductSyncOut.model_validate(p) for p in page_products],
        identifiers=[IdentifierSyncOut.model_validate(i) for i in page_identifiers],
        last_seq=page[-1].server_seq if page else since,
        has_more=len(rows) > limit,
    )
