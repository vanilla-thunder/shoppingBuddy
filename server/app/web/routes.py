from datetime import date
from pathlib import Path
from urllib.parse import urlencode

from fastapi import APIRouter, Depends, Form, Request, UploadFile, status
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.templating import Jinja2Templates
from pydantic import ValidationError
from sqlalchemy.orm import Session

from app import catalog
from app.categories import LOCAL, normalize_category
from app.db import get_db
from app.identifiers import GTIN_LENGTHS
from app.models import Product
from app.schemas import IdentifierFields, ProductCreate, ProductUpdate
from app.web import csv_io
from app.web.session import check_origin, check_token, is_logged_in, require_session, safe_next

PAGE_SIZE = 100
MAX_IMPORT_BYTES = 5 * 1024 * 1024

templates = Jinja2Templates(directory=Path(__file__).parent / "templates")


def display_code(ident) -> str:
    """Show GTINs in their usual printed length instead of the stored 14 digits."""
    if ident.type != "gtin":
        return f"{ident.store}: {ident.value}"
    for prefix, length in (("000000", 8), ("00", 12), ("0", 13)):  # EAN-8, UPC-A, EAN-13
        if ident.value.startswith(prefix):
            return ident.value[-length:]
    return ident.value


templates.env.filters["code"] = display_code

public = APIRouter(include_in_schema=False, dependencies=[Depends(check_origin)])
router = APIRouter(include_in_schema=False, dependencies=[Depends(check_origin), Depends(require_session)])


def render(request: Request, name: str, status_code: int = 200, **context) -> HTMLResponse:
    context.setdefault("authed", is_logged_in(request))
    return templates.TemplateResponse(request, name, context, status_code=status_code)


def see_other(url: str) -> RedirectResponse:
    return RedirectResponse(url, status_code=status.HTTP_303_SEE_OTHER)


def error_messages(exc: ValidationError) -> list[str]:
    labels = {
        "name": "Name", "brand": "Brand", "category": "Category", "rating": "Rating",
        "notes": "Notes", "identifiers": "Identifier",
    }
    messages = []
    for err in exc.errors():
        field = next((str(part) for part in err["loc"] if isinstance(part, str)), "")
        label = labels.get(field, field.capitalize() or "Input")
        messages.append(f"{label}: {err['msg'].removeprefix('Value error, ')}")
    return messages


def taken_message(exc: catalog.IdentifierTaken) -> str:
    return f"{exc.identifier.value} is already assigned to another product."


def looks_like_gtin(text: str) -> bool:
    text = text.strip()
    return text.isascii() and text.isdigit() and len(text) in GTIN_LENGTHS


def _optional(text: str) -> str | None:
    return text.strip() or None


def render_form(request: Request, db: Session, status_code: int = 200, **context) -> HTMLResponse:
    """Product form page; offers the categories in use as suggestions."""
    names = [c for c, _ in catalog.list_categories(db)]
    return render(request, "form.html", status_code, categories=names, **context)


def current_category(request: Request, c: str | None) -> str | None:
    """The list filter: `c` when given ("" = all), else the last choice stored in the session."""
    if c is None:
        return request.session.get("category")
    try:
        category = normalize_category(c) if c.strip() else None
    except ValueError:
        category = None
    if category is None:
        request.session.pop("category", None)
    else:
        request.session["category"] = category
    return category


# --- login ---


@public.get("/login")
def login_page(request: Request, next: str = "/"):
    return render(request, "login.html", next=safe_next(next), error=None)


@public.post("/login")
def login(request: Request, token: str = Form(...), next: str = Form("/")):
    if not check_token(request, token.strip()):
        return render(
            request, "login.html", status.HTTP_401_UNAUTHORIZED, next=safe_next(next), error="Wrong token."
        )
    request.session.clear()
    request.session["auth"] = True
    return see_other(safe_next(next))


@public.post("/logout")
def logout(request: Request):
    request.session.clear()
    return see_other("/login")


# --- list & search ---


def _rows_context(db: Session, q: str, offset: int, category: str | None) -> dict:
    products = catalog.search_products(db, q, PAGE_SIZE + 1, offset, category)
    return {
        "q": q,
        "category": category,
        "products": products[:PAGE_SIZE],
        "next_offset": offset + PAGE_SIZE if len(products) > PAGE_SIZE else None,
        "offset": offset,
        "barcode_query": looks_like_gtin(q),
    }


@router.get("/")
def index(request: Request, q: str = "", c: str | None = None, db: Session = Depends(get_db)):
    category = current_category(request, c)
    return render(
        request, "index.html", categories=catalog.list_categories(db), **_rows_context(db, q, 0, category)
    )


@router.get("/products/rows")
def rows(request: Request, q: str = "", c: str | None = None, offset: int = 0, db: Session = Depends(get_db)):
    category = current_category(request, c)
    response = render(request, "_rows.html", **_rows_context(db, q, max(offset, 0), category))
    if offset == 0:
        params = {k: v for k, v in (("q", q), ("c", category)) if v}
        response.headers["HX-Replace-Url"] = "/?" + urlencode(params) if params else "/"
    return response


@router.post("/products/{product_id}/rating")
def set_rating(request: Request, product_id: str, rating: int = Form(...), db: Session = Depends(get_db)):
    product = _product_or_none(db, product_id)
    if product is None:
        return Response(status_code=status.HTTP_404_NOT_FOUND)
    # Clicking the current rating again clears it.
    new_rating = None if rating == product.rating else rating
    try:
        update = ProductUpdate(rating=new_rating)
    except ValidationError:
        return Response(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT)
    catalog.update_product(db, product, update)
    db.commit()
    return render(request, "_row.html", p=product, category=request.session.get("category"))


def _product_or_none(db: Session, product_id: str) -> Product | None:
    try:
        return catalog.get_live_product(db, product_id)
    except catalog.NotFound:
        return None


# --- create ---


@router.get("/products/new")
def new_product(request: Request, gtin: str = "", name: str = "", db: Session = Depends(get_db)):
    form = {
        "name": name, "brand": "", "category": request.session.get("category") or LOCAL,
        "rating": "", "notes": "", "gtin": gtin, "store": "", "article": "",
    }
    return render_form(request, db, product=None, form=form, errors=[])


@router.post("/products/new")
def create_product(
    request: Request,
    name: str = Form(""),
    brand: str = Form(""),
    category: str = Form(""),
    rating: str = Form(""),
    notes: str = Form(""),
    gtin: str = Form(""),
    store: str = Form(""),
    article: str = Form(""),
    db: Session = Depends(get_db),
):
    form = {
        "name": name, "brand": brand, "category": category, "rating": rating, "notes": notes,
        "gtin": gtin, "store": store, "article": article,
    }
    identifiers = []
    if gtin.strip():
        identifiers.append({"type": "gtin", "value": gtin})
    if article.strip() or store.strip():
        identifiers.append({"type": "store_article", "value": article, "store": store})
    try:
        data = ProductCreate(
            name=name, brand=_optional(brand), category=category.strip() or LOCAL,
            rating=_optional(rating), notes=_optional(notes), identifiers=identifiers,
        )
        product = catalog.create_product(db, data)
    except ValidationError as exc:
        return render_form(request, db, 422, product=None, form=form, errors=error_messages(exc))
    except catalog.IdentifierTaken as exc:
        return render_form(
            request, db, 409, product=None, form=form, errors=[taken_message(exc)], taken_id=exc.product_id
        )
    db.commit()
    return see_other(f"/?{urlencode({'q': product.name})}")


# --- edit ---


def _edit_form(product: Product) -> dict:
    return {
        "name": product.name,
        "brand": product.brand or "",
        "category": product.category,
        "rating": str(product.rating or ""),
        "notes": product.notes or "",
    }


@router.get("/products/{product_id}")
def edit_product(request: Request, product_id: str, db: Session = Depends(get_db)):
    product = _product_or_none(db, product_id)
    if product is None:
        return render(request, "not_found.html", 404)
    return render_form(request, db, product=product, form=_edit_form(product), errors=[])


@router.post("/products/{product_id}")
def save_product(
    request: Request,
    product_id: str,
    name: str = Form(""),
    brand: str = Form(""),
    category: str = Form(""),
    rating: str = Form(""),
    notes: str = Form(""),
    db: Session = Depends(get_db),
):
    product = _product_or_none(db, product_id)
    if product is None:
        return render(request, "not_found.html", 404)
    form = {"name": name, "brand": brand, "category": category, "rating": rating, "notes": notes}
    try:
        data = ProductUpdate(
            name=name, brand=_optional(brand), category=category.strip() or LOCAL,
            rating=_optional(rating), notes=_optional(notes),
        )
    except ValidationError as exc:
        return render_form(request, db, 422, product=product, form=form, errors=error_messages(exc))
    catalog.update_product(db, product, data)
    db.commit()
    return see_other(f"/?{urlencode({'q': product.name})}")


@router.post("/products/{product_id}/delete")
def delete_product(product_id: str, db: Session = Depends(get_db)):
    product = _product_or_none(db, product_id)
    if product is not None:
        catalog.delete_product(db, product)
        db.commit()
    return see_other("/")


@router.post("/products/{product_id}/identifiers")
def add_identifier(
    request: Request,
    product_id: str,
    type: str = Form("gtin"),
    value: str = Form(""),
    store: str = Form(""),
    db: Session = Depends(get_db),
):
    product = _product_or_none(db, product_id)
    if product is None:
        return render(request, "not_found.html", 404)
    ident_form = {"type": type, "value": value, "store": store}
    try:
        ident = IdentifierFields(type=type, value=value, store=store)
        catalog.add_identifier(db, product, ident)
    except ValidationError as exc:
        return render_form(
            request, db, 422, product=product, form=_edit_form(product),
            errors=error_messages(exc), ident_form=ident_form,
        )
    except catalog.IdentifierTaken as exc:
        return render_form(
            request, db, 409, product=product, form=_edit_form(product),
            errors=[taken_message(exc)], taken_id=exc.product_id, ident_form=ident_form,
        )
    db.commit()
    return see_other(f"/products/{product_id}")


@router.post("/identifiers/{identifier_id}/delete")
def delete_identifier(identifier_id: str, db: Session = Depends(get_db)):
    try:
        row = catalog.delete_identifier(db, identifier_id)
    except catalog.NotFound:
        return see_other("/")
    db.commit()
    return see_other(f"/products/{row.product_id}")


# --- CSV ---


@router.get("/export.csv")
def export(db: Session = Depends(get_db)):
    filename = f"shoppingbuddy-{date.today().isoformat()}.csv"
    return Response(
        csv_io.export_csv(db),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.get("/import")
def import_page(request: Request):
    return render(request, "import.html", report=None, error=None)


@router.post("/import")
def import_upload(request: Request, file: UploadFile, db: Session = Depends(get_db)):
    data = file.file.read(MAX_IMPORT_BYTES + 1)
    if len(data) > MAX_IMPORT_BYTES:
        return render(request, "import.html", 413, report=None, error="File is larger than 5 MB.")
    try:
        report = csv_io.import_csv(db, data)
    except UnicodeDecodeError:
        return render(request, "import.html", 422, report=None, error="File is not UTF-8 encoded.")
    db.commit()
    return render(request, "import.html", report=report, error=None)
