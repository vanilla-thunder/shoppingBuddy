# Roadmap

Status of shoppingBuddy. Update this file whenever a task is finished or a decision is made.

## Milestones

- [x] **1. Server core**: FastAPI, product and identifier model, CRUD API, sync push/pull with
      last-write-wins, tombstones and duplicate-barcode merge (`docs/sync.md`)
- [x] **2. Web UI**: Jinja2 + htmx, login, live search, star ratings, CSV import/export
- [x] **Categories**: `local` or a website domain (e.g. `lieferando.de`), filter in API and web UI
- [x] **Alembic migrations**: run automatically on server start
- [x] **3. Android app, offline only** (Flutter, `app/`): barcode scanner (`mobile_scanner`),
      local database (`drift`), scan → rating card / add product, product list with search and a
      category filter defaulting to `local`, edit/delete, extra barcodes. Scanning real products
      confirmed on a real device
- [ ] **4. Sync engine in the app**: push/pull as described in `docs/sync.md`, background sync,
      unsynced-changes badge
- [x] **5. Extras**: Open Food Facts name prefill for unknown barcodes (app only: the add form
      fills in name and brand, never overwriting typed text; offline or not found leaves it empty)
- [ ] **6. Deployment**: Docker image, `docker-compose.yml` with labels for an existing Traefik,
      `SB_SECURE_COOKIES=true`
- [ ] **Later**: browser extension for lieferando.de (uses `GET /api/products?category=…`)

## Next step

Milestone 4: the sync engine in the app (server URL and token in settings, push dirty rows,
pull pages, apply rules from `docs/sync.md`). Until deployment, the phone reaches the dev
server through `adb reverse tcp:8000 tcp:8000` (WSL2 mirrored networking isn't available);
the debug build will need cleartext HTTP allowed for `127.0.0.1`.

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
- The Open Food Facts lookup sends scanned unknown barcodes to openfoodfacts.org.
- The app can add GTIN barcodes, but not yet store article numbers (the web UI can).
