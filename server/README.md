# shoppingBuddy server

A FastAPI backend: the product rating database, a web UI, a JSON CRUD API, and the sync API for
the phone app. The sync protocol is described in [../docs/sync.md](../docs/sync.md).

## Setup

```bash
cd server
python3 -m venv .venv
.venv/bin/pip install -e '.[dev]'
cp .env.example .env      # then set SB_API_TOKEN to a long random secret
```

## Run

```bash
.venv/bin/uvicorn app.main:create_app --factory --reload
```

- Web UI: http://localhost:8000/ (log in with the API token)
- API docs: http://localhost:8000/docs (click "Authorize" and enter the token)

## Test

```bash
.venv/bin/pytest
```

## Configuration (environment variables or `.env`)

| Variable          | Default                         | Notes                                   |
|-------------------|---------------------------------|-----------------------------------------|
| `SB_API_TOKEN`    | — (required, ≥16 characters)    | Bearer token for every `/api` and `/sync` call |
| `SB_DATABASE_URL` | `sqlite:///./shoppingbuddy.db`  | Any SQLAlchemy URL; Postgres also works |
| `SB_SECURE_COOKIES` | `false`                       | Set to `true` when served over HTTPS     |

## Web UI

Server-rendered Jinja2 templates with [htmx](https://htmx.org) (bundled in `app/web/static`, no
CDN needed). Pages:

- **List and search:** live search by name, brand or barcode, with a category filter
  (`local`, `lieferando.de`, …) that is remembered per session. Clicking a star sets the rating;
  clicking the current star clears it. A search for an unknown barcode offers to add it.
- **Add and edit:** product fields and a star rating. On the edit page you can add or remove
  barcodes and store article numbers.
- **CSV import and export:** `/export.csv`, `/import`. The format is described on the import page.

The login is a signed session cookie (30 days, SameSite=Lax), with an Origin check on form posts.
Its key is derived from `SB_API_TOKEN`, so rotating the token logs out every browser.

## API overview

| Method & path                         | Purpose                                   |
|---------------------------------------|-------------------------------------------|
| `GET /api/products?q=&category=&limit=&offset=` | List and search by name, brand or barcode, optionally in one category |
| `GET /api/categories`                 | Categories in use, with product counts    |
| `POST /api/products`                  | Create a product with its identifiers (409 if a barcode is taken) |
| `GET/PATCH/DELETE /api/products/{id}` | Read, partially update, or delete (tombstone) a product |
| `POST /api/products/{id}/identifiers` | Add a barcode or article number           |
| `DELETE /api/identifiers/{id}`        | Remove an identifier                      |
| `GET /api/lookup?value=&type=&store=` | Find a product by barcode                 |
| `POST /sync/push`, `GET /sync/pull`   | Phone sync                                |
| `GET /health`                         | Liveness check (no auth)                  |

The JSON API takes `Authorization: Bearer <token>`. The web UI uses its session cookie instead.

## Notes

- Tables are created at startup with `create_all`. Alembic migrations should be added before the
  first production deploy, so schema changes don't need a database reset.
- With SQLite, run a single uvicorn worker. Concurrent writers can hit `database is locked`.
