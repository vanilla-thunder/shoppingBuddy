import pytest
from fastapi.testclient import TestClient

from tests.conftest import EAN8, EAN13, EAN13_B, TOKEN


@pytest.fixture
def web(client):
    """Browser-like client: no bearer header, logged in via the session cookie."""
    browser = TestClient(client.app, follow_redirects=False)
    resp = browser.post("/login", data={"token": TOKEN, "next": "/"})
    assert resp.status_code == 303
    return browser


def add(web, **form):
    resp = web.post("/products/new", data={"name": "Milk", **form})
    assert resp.status_code == 303, resp.text
    return resp


def product_id(client, gtin):
    return client.get("/api/lookup", params={"value": gtin}).json()["id"]


def test_pages_require_login(client):
    browser = TestClient(client.app, follow_redirects=False)
    resp = browser.get("/products/new?gtin=1")
    assert resp.status_code == 303
    assert resp.headers["location"] == "/login?next=%2Fproducts%2Fnew%3Fgtin%3D1"
    assert browser.get("/").headers["location"] == "/login"
    htmx = browser.get("/products/rows", headers={"HX-Request": "true"})
    assert htmx.headers["HX-Redirect"] == "/login"
    assert browser.get("/static/style.css").status_code == 200


def test_login_rejects_wrong_token_and_unsafe_next(client):
    browser = TestClient(client.app, follow_redirects=False)
    assert browser.post("/login", data={"token": "nope"}).status_code == 401
    for evil in ("//evil.com", "https://evil.com", "/\\evil.com"):
        resp = browser.post("/login", data={"token": TOKEN, "next": evil})
        assert resp.headers["location"] == "/"


def test_logout(web):
    web.post("/logout")
    assert web.get("/").status_code == 303


def test_cross_origin_post_refused(web):
    resp = web.post("/products/new", data={"name": "X"}, headers={"Origin": "https://evil.com"})
    assert resp.status_code == 403
    ok = web.post("/products/new", data={"name": "X"}, headers={"Origin": "http://testserver"})
    assert ok.status_code == 303


def test_create_and_list(web, client):
    add(web, brand="Weihenstephan", rating="4", gtin=EAN13, store="Aldi", article="4711")
    page = web.get("/").text
    assert "Milk" in page and "Weihenstephan" in page
    assert EAN13 in page and "0" + EAN13 not in page  # displayed without the 14-digit padding
    assert "aldi: 4711" in page
    product = client.get(f"/api/products/{product_id(client, EAN13)}").json()
    assert product["rating"] == 4
    assert len(product["identifiers"]) == 2


def test_create_validation_errors_keep_input(web):
    resp = web.post("/products/new", data={"name": "Milk", "gtin": "4006381333932"})
    assert resp.status_code == 422
    assert "check digit" in resp.text
    assert 'value="Milk"' in resp.text
    resp = web.post("/products/new", data={"name": "Milk", "article": "4711"})
    assert resp.status_code == 422
    assert "needs a store" in resp.text


def test_create_with_taken_barcode_links_existing(web, client):
    add(web, gtin=EAN13)
    resp = web.post("/products/new", data={"name": "Other", "gtin": EAN13})
    assert resp.status_code == 409
    assert f"/products/{product_id(client, EAN13)}" in resp.text


def test_search_and_add_suggestions(web):
    add(web, gtin=EAN13)
    add(web, name="Butter")
    rows = web.get("/products/rows", params={"q": "milk"})
    assert "Milk" in rows.text and "Butter" not in rows.text
    assert rows.headers["HX-Replace-Url"] == "/?q=milk"
    assert "Milk" in web.get("/products/rows", params={"q": EAN13[-6:]}).text

    unknown = web.get("/products/rows", params={"q": EAN13_B}).text
    assert f"/products/new?gtin={EAN13_B}" in unknown
    assert "/products/new?name=Cheese" in web.get("/products/rows", params={"q": "Cheese"}).text


def test_rating_click_sets_and_clears(web, client):
    add(web, gtin=EAN13)
    pid = product_id(client, EAN13)
    row = web.post(f"/products/{pid}/rating", data={"rating": "3"})
    assert row.status_code == 200
    assert row.text.count("star on") == 3
    assert client.get(f"/api/products/{pid}").json()["rating"] == 3
    row = web.post(f"/products/{pid}/rating", data={"rating": "3"})
    assert row.text.count("star on") == 0
    assert client.get(f"/api/products/{pid}").json()["rating"] is None
    assert web.post(f"/products/{pid}/rating", data={"rating": "9"}).status_code == 422


def test_edit_product_and_identifiers(web, client):
    add(web, gtin=EAN13)
    pid = product_id(client, EAN13)
    assert web.get(f"/products/{pid}").status_code == 200

    resp = web.post(f"/products/{pid}", data={"name": "Vollmilch", "brand": "", "rating": "5", "notes": "lecker"})
    assert resp.status_code == 303
    product = client.get(f"/api/products/{pid}").json()
    assert (product["name"], product["rating"], product["notes"]) == ("Vollmilch", 5, "lecker")

    assert web.post(f"/products/{pid}/identifiers", data={"type": "gtin", "value": EAN8}).status_code == 303
    bad = web.post(f"/products/{pid}/identifiers", data={"type": "gtin", "value": "123"})
    assert bad.status_code == 422 and 'value="123"' in bad.text

    ident = next(i for i in client.get(f"/api/products/{pid}").json()["identifiers"] if i["value"].endswith(EAN8))
    assert web.post(f"/identifiers/{ident['id']}/delete").headers["location"] == f"/products/{pid}"
    assert len(client.get(f"/api/products/{pid}").json()["identifiers"]) == 1


def test_delete_product(web, client):
    add(web, gtin=EAN13)
    pid = product_id(client, EAN13)
    web.post(f"/products/{pid}/delete")
    assert web.get(f"/products/{pid}").status_code == 404
    assert client.get(f"/api/products/{pid}").status_code == 404


def test_csv_export_import_roundtrip(web, client):
    add(web, name="Milk, 3.5%", rating="4", gtin=EAN13, store="Aldi", article="4711")
    csv_text = web.get("/export.csv").content.decode("utf-8-sig")
    assert csv_text.splitlines()[0] == "id,name,brand,rating,notes,gtins,store_articles"
    assert '"Milk, 3.5%"' in csv_text and "aldi=4711" in csv_text

    # Re-importing the export changes nothing.
    report = web.post("/import", files={"file": ("x.csv", csv_text.encode())})
    assert "0 created · 0 updated · 1 unchanged · 0 errors" in report.text


def test_csv_import_semicolons_aliases_and_errors(web, client):
    add(web, name="Milk", gtin=EAN13)
    data = (
        "Name;EAN;Rating;Store_Articles\n"
        f"Milch;{EAN13};5;\n"  # matches existing by barcode → update
        f"Brot;{EAN13_B};3;Lidl=99\n"  # new
        "Bad;4006381333932;;\n"  # wrong check digit
        "Worse;;7;\n"  # rating out of range
        "Odd;;;nostore\n"  # malformed store article
    ).encode()
    resp = web.post("/import", files={"file": ("x.csv", data)})
    assert "1 created · 1 updated · 0 unchanged · 3 errors" in resp.text
    assert "Line 4" in resp.text and "Line 5" in resp.text and "Line 6" in resp.text

    milk = client.get(f"/api/products/{product_id(client, EAN13)}").json()
    assert (milk["name"], milk["rating"]) == ("Milch", 5)
    brot = client.get(f"/api/products/{product_id(client, EAN13_B)}").json()
    assert {i["value"] for i in brot["identifiers"]} == {"0" + EAN13_B, "99"}


def test_csv_import_needs_name_column(web):
    resp = web.post("/import", files={"file": ("x.csv", b"gtin\n4006381333931\n")})
    assert "needs a &#39;name&#39; column" in resp.text


def test_upc_and_ean8_display_in_printed_length(web):
    add(web, name="Cola", gtin="036000291452")
    add(web, name="Gum", gtin=EAN8)
    page = web.get("/").text
    assert ">036000291452<" in page
    assert f">{EAN8}<" in page
