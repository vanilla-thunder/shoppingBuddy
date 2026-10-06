# shoppingBuddy server

A FastAPI backend: the product rating database, the CRUD API for the web UI, and the sync API for
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

The interactive API docs are at http://localhost:8000/docs (use "Authorize" with the token).

## Test

```bash
.venv/bin/pytest
```

## Configuration (environment variables or `.env`)

| Variable          | Default                         | Notes                                   |
|-------------------|---------------------------------|-----------------------------------------|
| `SB_API_TOKEN`    | — (required, ≥16 characters)    | Bearer token for every `/api` and `/sync` call |
| `SB_DATABASE_URL` | `sqlite:///./shoppingbuddy.db`  | Any SQLAlchemy URL; Postgres also works |

## API overview

| Method & path                         | Purpose                                   |
|---------------------------------------|-------------------------------------------|
| `GET /api/products?q=&limit=&offset=` | List and search by name, brand or barcode |
| `POST /api/products`                  | Create a product with its identifiers (409 if a barcode is taken) |
| `GET/PATCH/DELETE /api/products/{id}` | Read, partially update, or delete (tombstone) a product |
| `POST /api/products/{id}/identifiers` | Add a barcode or article number           |
| `DELETE /api/identifiers/{id}`        | Remove an identifier                      |
| `GET /api/lookup?value=&type=&store=` | Find a product by barcode                 |
| `POST /sync/push`, `GET /sync/pull`   | Phone sync                                |
| `GET /health`                         | Liveness check (no auth)                  |

## Notes

- Tables are created at startup with `create_all`. Alembic migrations should be added before the
  first production deploy, so schema changes don't need a database reset.
- With SQLite, run a single uvicorn worker. Concurrent writers can hit `database is locked`.
