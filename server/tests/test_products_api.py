from fastapi.testclient import TestClient

from tests.conftest import EAN13, EAN13_B, UPC_A


def create(client, name="Milk", rating=4, identifiers=None):
    body = {"name": name, "rating": rating, "identifiers": identifiers or []}
    resp = client.post("/api/products", json=body)
    assert resp.status_code == 201, resp.text
    return resp.json()


def test_auth_required(client):
    anon = TestClient(client.app)
    assert anon.get("/api/products").status_code == 401
    assert anon.get("/api/products", headers={"Authorization": "Bearer wrong"}).status_code == 401
    assert anon.get("/health").status_code == 200


def test_create_get_and_lookup(client):
    p = create(client, identifiers=[{"type": "gtin", "value": EAN13}])
    assert p["identifiers"][0]["value"] == "0" + EAN13

    assert client.get(f"/api/products/{p['id']}").json()["name"] == "Milk"
    found = client.get("/api/lookup", params={"value": EAN13})
    assert found.status_code == 200
    assert found.json()["id"] == p["id"]
    assert client.get("/api/lookup", params={"value": EAN13_B}).status_code == 404
    assert client.get("/api/lookup", params={"value": "123"}).status_code == 422


def test_upc_lookup_matches_ean13_form(client):
    p = create(client, identifiers=[{"type": "gtin", "value": UPC_A}])
    assert client.get("/api/lookup", params={"value": "0" + UPC_A}).json()["id"] == p["id"]


def test_store_article_lookup(client):
    p = create(client, identifiers=[{"type": "store_article", "value": "4711", "store": "Aldi"}])
    found = client.get("/api/lookup", params={"type": "store_article", "value": "4711", "store": "aldi"})
    assert found.json()["id"] == p["id"]
    assert (
        client.get("/api/lookup", params={"type": "store_article", "value": "4711", "store": "lidl"}).status_code
        == 404
    )


def test_duplicate_identifier_conflicts(client):
    p = create(client, identifiers=[{"type": "gtin", "value": EAN13}])
    resp = client.post("/api/products", json={"name": "Other", "identifiers": [{"type": "gtin", "value": EAN13}]})
    assert resp.status_code == 409
    assert resp.json()["detail"]["product_id"] == p["id"]

    other = create(client, name="Other")
    resp = client.post(f"/api/products/{other['id']}/identifiers", json={"type": "gtin", "value": EAN13})
    assert resp.status_code == 409


def test_patch_partial_and_clear_rating(client):
    p = create(client)
    resp = client.patch(f"/api/products/{p['id']}", json={"brand": "Weihenstephan"})
    assert resp.json()["rating"] == 4
    assert resp.json()["brand"] == "Weihenstephan"
    resp = client.patch(f"/api/products/{p['id']}", json={"rating": None})
    assert resp.json()["rating"] is None
    assert client.patch(f"/api/products/{p['id']}", json={"rating": 6}).status_code == 422
    assert client.patch(f"/api/products/{p['id']}", json={"name": None}).status_code == 422


def test_delete_frees_barcode(client):
    p = create(client, identifiers=[{"type": "gtin", "value": EAN13}])
    assert client.delete(f"/api/products/{p['id']}").status_code == 204
    assert client.get(f"/api/products/{p['id']}").status_code == 404
    assert client.get("/api/lookup", params={"value": EAN13}).status_code == 404
    create(client, name="New milk", identifiers=[{"type": "gtin", "value": EAN13}])


def test_delete_identifier(client):
    p = create(client, identifiers=[{"type": "gtin", "value": EAN13}])
    ident_id = p["identifiers"][0]["id"]
    assert client.delete(f"/api/identifiers/{ident_id}").status_code == 204
    assert client.get(f"/api/products/{p['id']}").json()["identifiers"] == []


def test_search_by_name_brand_and_barcode(client):
    create(client, name="Vollmilch", identifiers=[{"type": "gtin", "value": EAN13}])
    create(client, name="Butter_100%")
    assert [p["name"] for p in client.get("/api/products", params={"q": "milch"}).json()] == ["Vollmilch"]
    assert [p["name"] for p in client.get("/api/products", params={"q": "333931"}).json()] == ["Vollmilch"]
    # LIKE wildcards in the query are literal
    assert [p["name"] for p in client.get("/api/products", params={"q": "_100%"}).json()] == ["Butter_100%"]
    assert len(client.get("/api/products").json()) == 2
