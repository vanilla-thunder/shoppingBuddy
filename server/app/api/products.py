from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import ValidationError
from sqlalchemy.orm import Session

from app import catalog
from app.auth import require_token
from app.categories import normalize_category
from app.db import get_db
from app.models import Product
from app.schemas import (
    CategoryOut,
    IdentifierFields,
    IdentifierOut,
    IdentifierType,
    ProductCreate,
    ProductOut,
    ProductUpdate,
)

router = APIRouter(prefix="/api", tags=["products"], dependencies=[Depends(require_token)])


def product_out(product: Product) -> ProductOut:
    return ProductOut(
        id=product.id,
        name=product.name,
        brand=product.brand,
        rating=product.rating,
        notes=product.notes,
        category=product.category,
        created_at=product.created_at,
        updated_at=product.updated_at,
        identifiers=[IdentifierOut.model_validate(i) for i in product.identifiers if not i.deleted],
    )


def _live_product(db: Session, product_id: str) -> Product:
    try:
        return catalog.get_live_product(db, product_id)
    except catalog.NotFound:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "product not found")


def _conflict(exc: catalog.IdentifierTaken) -> HTTPException:
    return HTTPException(
        status.HTTP_409_CONFLICT,
        {"message": "identifier already assigned", "product_id": exc.product_id},
    )


@router.get("/products", response_model=list[ProductOut])
def list_products(
    q: str | None = None,
    category: str | None = Query(None, description="'local' or a website domain; omit for all"),
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db),
):
    if category is not None:
        try:
            category = normalize_category(category)
        except ValueError as exc:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(exc))
    return [product_out(p) for p in catalog.search_products(db, q, limit, offset, category)]


@router.get("/categories", response_model=list[CategoryOut])
def list_categories(db: Session = Depends(get_db)):
    return [CategoryOut(category=c, count=n) for c, n in catalog.list_categories(db)]


@router.post("/products", response_model=ProductOut, status_code=status.HTTP_201_CREATED)
def create_product(body: ProductCreate, db: Session = Depends(get_db)):
    try:
        product = catalog.create_product(db, body)
    except catalog.DuplicateIdentifiers:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "duplicate identifiers in request")
    except catalog.IdentifierTaken as exc:
        raise _conflict(exc)
    db.commit()
    return product_out(product)


@router.get("/products/{product_id}", response_model=ProductOut)
def get_product(product_id: str, db: Session = Depends(get_db)):
    return product_out(_live_product(db, product_id))


@router.patch("/products/{product_id}", response_model=ProductOut)
def update_product(product_id: str, body: ProductUpdate, db: Session = Depends(get_db)):
    product = catalog.update_product(db, _live_product(db, product_id), body)
    db.commit()
    return product_out(product)


@router.delete("/products/{product_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_product(product_id: str, db: Session = Depends(get_db)):
    catalog.delete_product(db, _live_product(db, product_id))
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/products/{product_id}/identifiers",
    response_model=IdentifierOut,
    status_code=status.HTTP_201_CREATED,
)
def create_identifier(product_id: str, body: IdentifierFields, db: Session = Depends(get_db)):
    product = _live_product(db, product_id)
    try:
        row = catalog.add_identifier(db, product, body)
    except catalog.IdentifierTaken as exc:
        raise _conflict(exc)
    db.commit()
    return row


@router.delete("/identifiers/{identifier_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_identifier(identifier_id: str, db: Session = Depends(get_db)):
    try:
        catalog.delete_identifier(db, identifier_id)
    except catalog.NotFound:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "identifier not found")
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
    product = catalog.lookup(db, ident)
    if product is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "unknown identifier")
    return product_out(product)
