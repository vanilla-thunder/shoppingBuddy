# Sync protocol

The phone keeps a full local copy of the database and works offline. Sync is two calls:
push local changes, then pull everything the server has changed since the last pull.

All requests need `Authorization: Bearer <token>`.

## Records

Two tables, identical on server and client:

- **products**: `id`, `name`, `brand`, `rating` (1–5 or null), `notes`, `created_at`,
  `updated_at`, `deleted`, `merged_into`, `server_seq`
- **identifiers**: `id`, `product_id`, `type` (`gtin` | `store_article`), `value`, `store`,
  `created_at`, `updated_at`, `deleted`, `server_seq`

Rules:

- **Ids are UUIDs created by whoever creates the row**, client or server. No id mapping is needed.
- **Rows are never removed**, only flagged `deleted: true` (tombstones), so deletions sync.
- **Timestamps** are ISO 8601 with a timezone (`2026-10-06T12:00:00.123Z`). Naive timestamps are
  rejected.
- **`server_seq`** is assigned by the server on every change, from one global counter. Clients
  never set it.

### Identifier normalization (clients must do the same)

- `gtin`: digits only, length 8/12/13/14, valid check digit, stored **zero-padded to 14 digits**.
  `store` must be empty. This makes a UPC-A and the EAN-13 form of the same code equal.
- `store_article`: any non-empty value, `store` required and **casefolded** (`"ALDI"` → `"aldi"`).
- Leading and trailing whitespace is stripped from all fields.

A live `(type, value, store)` combination is unique. Deleted identifiers don't count.

## Push: `POST /sync/push`

```json
{ "products": [ProductSyncIn...], "identifiers": [IdentifierSyncIn...] }
```

Send every locally changed row (any row flagged dirty) with its full current state. Products are
applied before identifiers. The whole request is one transaction: a validation error (HTTP 422)
rejects everything.

Per row, the server applies **last-write-wins on `updated_at`**:

| status           | meaning                                                                            |
|------------------|------------------------------------------------------------------------------------|
| `applied`        | stored                                                                             |
| `stale`          | the server already has an equal or newer version; the client gets it on pull       |
| `ignored_merged` | the product was merged into another (`detail` = survivor id); the edit is dropped |
| `duplicate`      | the barcode already exists on another product; stored as a tombstone (see below)   |
| `rejected`       | `product_id` unknown on the server; fix the order and push again                   |

In every case except `rejected`, the client can clear its dirty flag. The pull that follows
delivers the server's version.

### Duplicate barcodes → merge

If you add the same barcode as two different products (say, offline on the phone and on the web),
the server **merges** them when the second identifier is pushed:

- The **older** product (by `created_at`) survives.
- Fields come from whichever side was edited more recently. Where that side has a null field, the
  other side's value is used, so a rating set on either side is kept.
- The loser becomes `deleted: true, merged_into: <survivor id>`.
- The loser's identifiers are moved to the survivor. The duplicate identifier is stored as a
  tombstone.
- The push response lists each merge in `merges: [{merged, into}]`.

Server-made changes are stamped with a timestamp later than both versions involved. This way they
win LWW against the client's copy even if the phone's clock runs ahead.

Identifiers pushed later that still point at a merged product are re-pointed to the survivor.

## Pull: `GET /sync/pull?since=<last_seq>&limit=500`

```json
{ "products": [...], "identifiers": [...], "last_seq": 42, "has_more": false }
```

- Returns rows with `server_seq > since`, in seq order, at most `limit` rows.
- Store `last_seq` locally, but only after the page is applied and committed. Repeat while
  `has_more` is true.
- A page also includes every product its identifiers (or `merged_into` links) refer to, so it never
  contains dangling references. Such extra products may show up again on a later page; applying
  them twice is harmless.
- Your own pushed rows come back too, carrying their `server_seq`.

Seqs commit in order (the counter row is locked until commit). A row with a lower seq can therefore
never appear after you have already passed it.

### Applying a pulled row on the client

```
local = find(row.id)
if local is null                                     → insert row
elif local.dirty and local.updated_at > row.updated_at → keep local (it gets pushed next sync)
else                                                 → overwrite local with row, clear dirty
```

When a product arrives with `merged_into` set, re-point any local references (open screens,
history) to the survivor.

## Recommended client loop

1. `push` all dirty rows, or skip this if there are none.
2. `pull` from the stored `last_seq` until `has_more` is false.
3. Run this on app start, when connectivity returns, a few seconds after a local edit
   (debounced), and on pull-to-refresh.

## Known limits

- LWW works on whole rows, not single fields. Editing the same product on two devices offline
  keeps the newer edit completely.
- LWW relies on the phone's clock being roughly right. A clock running *behind* can lose edits.
- An offline edit to a product that was meanwhile merged away is dropped (`ignored_merged`).
