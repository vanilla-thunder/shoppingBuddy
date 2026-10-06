# Roadmap

Status of shoppingBuddy. Update this file whenever a task is finished or a decision is made.

## Milestones

- [x] **1. Server core**: FastAPI, product and identifier model, CRUD API, sync push/pull with
      last-write-wins, tombstones and duplicate-barcode merge (`docs/sync.md`)
- [x] **2. Web UI**: Jinja2 + htmx, login, live search, star ratings, CSV import/export
- [x] **Categories**: `local` or a website domain (e.g. `lieferando.de`), filter in API and web UI
- [x] **Alembic migrations**: run automatically on server start
- [ ] **3. Android app, offline only** (Flutter): barcode scanner (`mobile_scanner`), local
      database (`drift`), lookup screen, add-product screen, category filter defaulting to `local`
- [ ] **4. Sync engine in the app**: push/pull as described in `docs/sync.md`, background sync,
      unsynced-changes badge
- [ ] **5. Extras**: Open Food Facts name prefill for unknown barcodes
- [ ] **6. Deployment**: Docker image, `docker-compose.yml` with labels for an existing Traefik,
      `SB_SECURE_COOKIES=true`
- [ ] **Later**: browser extension for lieferando.de (uses `GET /api/products?category=…`)

## Next step

Milestone 3: check that the Flutter SDK and the Android toolchain are installed, then scaffold
`app/` (the Flutter project) next to `server/`.

## Open decisions

- **Deployment:** the domain, the Traefik Docker network name, the HTTPS entrypoint name and the
  certresolver name. All four are needed for milestone 6.

## Known limitations

- Last-write-wins applies to whole rows, not single fields. If a product is edited on two devices
  offline, only the newer edit survives.
- Last-write-wins depends on the phone's clock being roughly right.
- With SQLite, run a single uvicorn worker only.
- Web login has no rate limiting, so the API token must be long and random.
- Web search doesn't match store names in article numbers.
