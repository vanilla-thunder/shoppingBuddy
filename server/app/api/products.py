from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import ValidationError
from sqlalchemy import or_, select
from sqlalchemy.orm import Session, selectinload

from app.auth import require_token
from app.db import get_db
from app.models import Identifier, Product
from app.schemas import (
    IdentifierFields,
    IdentifierOut,
    IdentifierType,
    ProductCreate,
    ProductOut,
    ProductUpdate,
)
from app.services import (
    fresh_timestamp,
    find_live_identifier,
    next_seq,
    tombstone_identifiers,
    touch,
    utcnow,
)

router = APIRouter(prefix="/api", tags=["products"], dependencies=[Depends(require_token)])


def product_out(product: Product) -> ProductOut:
    return ProductOut(
        id=product.id,
        name=product.name,
        brand=product.brand,
        rating=product.rating,
        notes=product.notes,
        created_at=product.created_at,
        updated_at=product.updated_at,
        identifiers=[IdentifierOut.model_validate(i) for i in product.identifiers if not i.deleted],
    )


def get_live_product(db: Session, product_id: str) -> Product:
    product = db.get(Product, product_id)
    if product is None or product.deleted:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "product not found")
    return product


def ensure_identifier_free(db: Session, ident: IdentifierFields) -> None:
    clash = find_live_identifier(db, ident.type, ident.value, ident.store)
    if clash is not None:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            {"message": "identifier already assigned", "product_id": clash.product_id},
        )


def add_identifier(db: Session, product: Product, ident: IdentifierFields) -> Identifier:
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
    return row


def _escape_like(text: str) -> str:
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


@router.get("/products", response_model=list[ProductOut])
def list_products(
    q: str | None = None,
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db),
):
    query = (
        select(Product)
        .where(Product.deleted.is_(False))
        .options(selectinload(Product.identifiers))
        .order_by(Product.name, Product.id)
        .limit(limit)
        .offset(offset)
    )
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
    return [product_out(p) for p in db.scalars(query)]


@router.post("/products", response_model=ProductOut, status_code=status.HTTP_201_CREATED)
def create_product(body: ProductCreate, db: Session = Depends(get_db)):
    keys = [(i.type, i.value, i.store) for i in body.identifiers]
    if len(keys) != len(set(keys)):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "duplicate identifiers in request")
    for ident in body.identifiers:
        ensure_identifier_free(db, ident)

    ts = utcnow()
    product = Product(
        id=str(uuid4()),
        name=body.name,
        brand=body.brand,
        rating=body.rating,
        notes=body.notes,
        created_at=ts,
        updated_at=ts,
        deleted=False,
        server_seq=next_seq(db),
    )
    db.add(product)
    for ident in body.identifiers:
        add_identifier(db, product, ident)
    db.commit()
    return product_out(product)


@router.get("/products/{product_id}", response_model=ProductOut)
def get_product(product_id: str, db: Session = Depends(get_db)):
    return product_out(get_live_product(db, product_id))


@router.patch("/products/{product_id}", response_model=ProductOut)
def update_product(product_id: str, body: ProductUpdate, db: Session = Depends(get_db)):
    product = get_live_product(db, product_id)
    for field in body.model_fields_set:
        setattr(product, field, getattr(body, field))
    touch(db, product, fresh_timestamp(product.updated_at))
    db.commit()
    return product_out(product)


@router.delete("/products/{product_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_product(product_id: str, db: Session = Depends(get_db)):
    product = get_live_product(db, product_id)
    tombstone_identifiers(db, product)
    product.deleted = True
    touch(db, product, fresh_timestamp(product.updated_at))
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/products/{product_id}/identifiers",
    response_model=IdentifierOut,
    status_code=status.HTTP_201_CREATED,
)
def create_identifier(product_id: str, body: IdentifierFields, db: Session = Depends(get_db)):
    product = get_live_product(db, product_id)
    ensure_identifier_free(db, body)
    row = add_identifier(db, product, body)
    db.commit()
    return row


@router.delete("/identifiers/{identifier_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_identifier(identifier_id: str, db: Session = Depends(get_db)):
    row = db.get(Identifier, identifier_id)
    if row is None or row.deleted:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "identifier not found")
    row.deleted = True
    touch(db, row, fresh_timestamp(row.updated_at))
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/lookup", response_model=ProductOut)
def lookup(
    value: str,
    type: IdentifierType = "gtin",
    store: str = "",
    db: Session = Depends(get_db),
):
    try:
        ident = IdentifierFields(type=type, value=value, store=store)
    except ValidationError as exc:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_CONTENT, exc.errors(include_url=False, include_context=False)
        )
    row = find_live_identifier(db, ident.type, ident.value, ident.store)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "unknown identifier")
    return product_out(row.product)
