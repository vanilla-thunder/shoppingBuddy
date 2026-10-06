from tests.conftest import EAN13, EAN13_B, new_id, sync_identifier, sync_product, ts


def push(client, products=(), identifiers=()):
    resp = client.post("/sync/push", json={"products": list(products), "identifiers": list(identifiers)})
    assert resp.status_code == 200, resp.text
    return resp.json()


def pull(client, since=0, limit=500):
    resp = client.get("/sync/pull", params={"since": since, "limit": limit})
    assert resp.status_code == 200, resp.text
    return resp.json()


def by_id(rows):
    return {r["id"]: r for r in rows}


def test_push_then_pull_roundtrip(client):
    pid, iid = new_id(), new_id()
    result = push(client, [sync_product(pid, "Milk", 0, rating=5)], [sync_identifier(iid, pid, EAN13, 0)])
    assert result["products"] == [{"id": pid, "status": "applied", "detail": None}]
    assert result["identifiers"][0]["status"] == "applied"

    page = pull(client)
    assert by_id(page["products"])[pid]["rating"] == 5
    assert by_id(page["identifiers"])[iid]["value"] == "0" + EAN13
    assert page["has_more"] is False

    # Nothing new since the last seq.
    again = pull(client, since=page["last_seq"])
    assert again["products"] == [] and again["identifiers"] == []
    assert again["last_seq"] == page["last_seq"]

    # Pushed rows are visible to the web API.
    assert client.get("/api/lookup", params={"value": EAN13}).json()["id"] == pid


def test_last_write_wins(client):
    pid = new_id()
    push(client, [sync_product(pid, "Milk", 0, rating=3)])

    older = sync_product(pid, "Milk", 0, rating=1)
    older["updated_at"] = ts(-5)
    assert push(client, [older])["products"][0]["status"] == "stale"

    newer = sync_product(pid, "Milk", 0, rating=5)
    newer["updated_at"] = ts(10)
    assert push(client, [newer])["products"][0]["status"] == "applied"
    assert client.get(f"/api/products/{pid}").json()["rating"] == 5


def test_web_edit_beats_older_offline_edit(client):
    pid = new_id()
    push(client, [sync_product(pid, "Milk", 0, rating=3)])
    client.patch(f"/api/products/{pid}", json={"rating": 4})  # stamped with real "now" (2026+)

    offline = sync_product(pid, "Milk", 0, rating=1)
    offline["updated_at"] = ts(60)  # still before the web edit
    assert push(client, [offline])["products"][0]["status"] == "stale"
    assert client.get(f"/api/products/{pid}").json()["rating"] == 4


def test_web_edit_wins_over_client_clock_running_ahead(client):
    pid = new_id()
    far_future = sync_product(pid, "Milk", 0, rating=3)
    far_future["updated_at"] = "2099-01-01T00:00:00+00:00"
    push(client, [far_future])

    updated = client.patch(f"/api/products/{pid}", json={"rating": 4}).json()
    assert updated["updated_at"] > "2099-01-01"


def test_deleted_product_tombstones_identifiers(client):
    pid, iid = new_id(), new_id()
    push(client, [sync_product(pid, "Milk", 0)], [sync_identifier(iid, pid, EAN13, 0)])
    seq = pull(client)["last_seq"]

    push(client, [sync_product(pid, "Milk", 0, deleted=True) | {"updated_at": ts(1)}])
    page = pull(client, since=seq)
    assert by_id(page["products"])[pid]["deleted"] is True
    assert by_id(page["identifiers"])[iid]["deleted"] is True
    assert client.get("/api/lookup", params={"value": EAN13}).status_code == 404


def test_same_barcode_added_offline_twice_merges(client):
    # Web UI created "Milk" (no rating) earlier; phone, offline, created "Vollmilch" ★5 for the same EAN.
    web = client.post(
        "/api/products", json={"name": "Milk", "identifiers": [{"type": "gtin", "value": EAN13}]}
    ).json()
    phone_pid, phone_iid, phone_iid2 = new_id(), new_id(), new_id()
    phone_product = sync_product(phone_pid, "Vollmilch", 0, rating=5)
    phone_product["created_at"] = phone_product["updated_at"] = "2099-01-01T00:00:00+00:00"
    result = push(
        client,
        [phone_product],
        [
            sync_identifier(phone_iid, phone_pid, EAN13, 0),
            sync_identifier(phone_iid2, phone_pid, EAN13_B, 0),  # arrives after the merge
        ],
    )

    assert result["merges"] == [{"merged": phone_pid, "into": web["id"]}]
    assert result["identifiers"][0]["status"] == "duplicate"
    assert result["identifiers"][1]["status"] == "applied"

    survivor = client.get(f"/api/products/{web['id']}").json()
    assert survivor["rating"] == 5  # filled from the phone product
    assert survivor["name"] == "Vollmilch"  # phone edit is newer
    assert {i["value"] for i in survivor["identifiers"]} == {"0" + EAN13, "0" + EAN13_B}

    page = pull(client)
    loser = by_id(page["products"])[phone_pid]
    assert loser["deleted"] is True and loser["merged_into"] == web["id"]
    dup = by_id(page["identifiers"])[phone_iid]
    assert dup["deleted"] is True and dup["product_id"] == web["id"]
    # The server-made tombstone must beat the client's live copy of that row.
    assert dup["updated_at"] > ts(0)

    # Later edits to the merged-away product are ignored and point to the survivor.
    late = push(client, [phone_product | {"updated_at": "2099-02-01T00:00:00+00:00", "rating": 1}])
    assert late["products"][0] == {"id": phone_pid, "status": "ignored_merged", "detail": web["id"]}


def test_identifier_for_merged_product_is_redirected(client):
    a, b = new_id(), new_id()
    push(client, [sync_product(a, "A", 0), sync_product(b, "B", 1)])
    push(client, [], [sync_identifier(new_id(), a, EAN13, 2), sync_identifier(new_id(), b, EAN13, 3)])

    iid = new_id()
    result = push(client, [], [sync_identifier(iid, b, EAN13_B, 4)])
    assert result["identifiers"][0]["status"] == "applied"
    assert by_id(pull(client)["identifiers"])[iid]["product_id"] == a


def test_identifier_for_unknown_product_rejected(client):
    result = push(client, [], [sync_identifier(new_id(), new_id(), EAN13, 0)])
    assert result["identifiers"][0]["status"] == "rejected"


def test_identifier_on_deleted_product_is_stored_as_tombstone(client):
    pid = new_id()
    push(client, [sync_product(pid, "Gone", 0, deleted=True)])
    iid = new_id()
    push(client, [], [sync_identifier(iid, pid, EAN13, 1)])
    assert by_id(pull(client)["identifiers"])[iid]["deleted"] is True
    assert client.get("/api/lookup", params={"value": EAN13}).status_code == 404


def test_invalid_push_rejected_whole(client):
    resp = client.post(
        "/sync/push",
        json={"products": [sync_product(new_id(), "Bad", 0, rating=9)], "identifiers": []},
    )
    assert resp.status_code == 422
    naive = sync_product(new_id(), "Naive", 0) | {"updated_at": "2026-01-01T00:00:00"}
    assert client.post("/sync/push", json={"products": [naive]}).status_code == 422


def test_pull_paging_includes_referenced_products(client):
    pids = [new_id() for _ in range(3)]
    push(client, [sync_product(pid, f"P{n}", n) for n, pid in enumerate(pids)])
    push(client, [], [sync_identifier(new_id(), pids[0], EAN13, 5)])
    # Touch P0 again so its latest seq is after its identifier's.
    push(client, [sync_product(pids[0], "P0 renamed", 0) | {"updated_at": ts(10)}])

    seen_products, seen_identifiers, since = {}, {}, 0
    while True:
        page = pull(client, since=since, limit=2)
        product_ids = {p["id"] for p in page["products"]}
        for ident in page["identifiers"]:
            assert ident["product_id"] in product_ids  # never dangling within a page
        seen_products |= by_id(page["products"])
        seen_identifiers |= by_id(page["identifiers"])
        since = page["last_seq"]
        if not page["has_more"]:
            break

    assert set(seen_products) == set(pids)
    assert seen_products[pids[0]]["name"] == "P0 renamed"
    assert len(seen_identifiers) == 1
