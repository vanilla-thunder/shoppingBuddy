import pytest
from fastapi.testclient import TestClient

from app.categories import normalize_category
from tests.conftest import EAN13, EAN13_B, TOKEN, new_id, sync_identifier, sync_product


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("local", "local"),
        ("  Local ", "local"),
        ("lieferando.de", "lieferando.de"),
        ("https://www.lieferando.de/speisekarte/pizza-luigi", "lieferando.de"),
        ("www.Wolt.com/de", "wolt.com"),
        ("lieferando.de:443", "lieferando.de"),
        ("bäckerei-müller.de", "bäckerei-müller.de"),
    ],
)
def test_normalize_category(raw, expected):
    assert normalize_category(raw) == expected


@pytest.mark.parametrize("raw", ["", "   ", "https://", "two words", "a..b", "x" * 101])
def test_invalid_categories_rejected(raw):
    with pytest.raises(ValueError):
        normalize_category(raw)


# --- JSON API ---


def create(client, name, category=None, **extra):
    body = {"name": name, **extra}
    if category is not None:
        body["category"] = category
    resp = client.post("/api/products", json=body)
    assert resp.status_code == 201, resp.text
    return resp.json()


def test_default_category_is_local(client):
    assert create(client, "Milk")["category"] == "local"


def test_filter_and_list_categories(client):
    create(client, "Milk")
    create(client, "Pizza Margherita", "https://www.lieferando.de/menu/luigi", brand="Luigi")
    create(client, "Pizza Funghi", "lieferando.de", brand="Luigi")
    create(client, "Pad Thai", "wolt.com")

    names = lambda **params: [p["name"] for p in client.get("/api/products", params=params).json()]
    assert names(category="local") == ["Milk"]
    assert names(category="Lieferando.de") == ["Pizza Funghi", "Pizza Margherita"]
    assert names(category="lieferando.de", q="funghi") == ["Pizza Funghi"]
    assert len(names()) == 4
    assert client.get("/api/products", params={"category": "no spaces"}).status_code == 422

    assert client.get("/api/categories").json() == [
        {"category": "local", "count": 1},
        {"category": "lieferando.de", "count": 2},
        {"category": "wolt.com", "count": 1},
    ]


def test_patch_category(client):
    p = create(client, "Pizza")
    resp = client.patch(f"/api/products/{p['id']}", json={"category": "lieferando.de"})
    assert resp.json()["category"] == "lieferando.de"
    assert client.patch(f"/api/products/{p['id']}", json={"category": None}).status_code == 422
    assert client.patch(f"/api/products/{p['id']}", json={"category": "bad value"}).status_code == 422


# --- sync ---


def test_sync_category_default_and_roundtrip(client):
    old_client, new_client = new_id(), new_id()
    client.post(
        "/sync/push",
        json={
            "products": [
                sync_product(old_client, "Milk", 0),  # client that doesn't know categories yet
                sync_product(new_client, "Pizza", 0, category="https://lieferando.de/x"),
            ]
        },
    )
    pulled = {p["id"]: p for p in client.get("/sync/pull").json()["products"]}
    assert pulled[old_client]["category"] == "local"
    assert pulled[new_client]["category"] == "lieferando.de"


def test_merge_takes_category_from_newer_side(client):
    a, b = new_id(), new_id()
    newer = sync_product(b, "Cola", 1, category="lieferando.de")
    client.post("/sync/push", json={"products": [sync_product(a, "Cola", 0), newer]})
    client.post(
        "/sync/push",
        json={"identifiers": [sync_identifier(new_id(), a, EAN13, 2), sync_identifier(new_id(), b, EAN13, 3)]},
    )
    assert client.get(f"/api/products/{a}").json()["category"] == "lieferando.de"


# --- web UI ---


@pytest.fixture
def web(client):
    browser = TestClient(client.app, follow_redirects=False)
    browser.post("/login", data={"token": TOKEN})
    return browser


def test_web_filter_is_remembered(web, client):
    create(client, "Milk")
    create(client, "Pizza", "lieferando.de")

    page = web.get("/", params={"c": "lieferando.de"}).text
    assert "Pizza" in page and "Milk" not in page
    assert '<option value="lieferando.de" selected>' in page

    # Remembered for the next visit and for live search…
    assert "Milk" not in web.get("/").text
    rows = web.get("/products/rows", params={"q": "pi", "c": "lieferando.de"})
    assert rows.headers["HX-Replace-Url"] == "/?q=pi&c=lieferando.de"
    # …and used as the default for new products.
    assert 'name="category" value="lieferando.de"' in web.get("/products/new").text

    # "All categories" clears it.
    page = web.get("/", params={"c": ""}).text
    assert "Milk" in page and "Pizza" in page
    assert '<span class="tag">lieferando.de</span>' in page  # non-local products are tagged in "all"
    assert 'name="category" value="local"' in web.get("/products/new").text


def test_web_create_and_edit_category(web, client):
    resp = web.post("/products/new", data={"name": "Sushi", "category": "https://www.wolt.com/de/x", "gtin": EAN13_B})
    assert resp.status_code == 303
    p = client.get("/api/lookup", params={"value": EAN13_B}).json()
    assert p["category"] == "wolt.com"

    bad = web.post(f"/products/{p['id']}", data={"name": "Sushi", "category": "not valid"})
    assert bad.status_code == 422 and "Category:" in bad.text
    web.post(f"/products/{p['id']}", data={"name": "Sushi", "category": ""})  # empty → local
    assert client.get(f"/api/products/{p['id']}").json()["category"] == "local"


def test_csv_category_column(web, client):
    create(client, "Pizza", "lieferando.de")
    csv_text = web.get("/export.csv").content.decode("utf-8-sig")
    assert ",lieferando.de," in csv_text

    data = b"name,category\nDoener,https://www.lieferando.de/x\nBread,\n"
    resp = web.post("/import", files={"file": ("x.csv", data)})
    assert "2 created" in resp.text
    names = [p["name"] for p in client.get("/api/products", params={"category": "lieferando.de"}).json()]
    assert names == ["Doener", "Pizza"]
    assert [p["name"] for p in client.get("/api/products", params={"category": "local"}).json()] == ["Bread"]
