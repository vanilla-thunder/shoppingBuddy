# shoppingBuddy

A personal product rating database: a barcode or article number maps to a product with 1–5 stars.
It has a FastAPI server with a web UI and an offline-first Android app (planned) that syncs with
the server. The current status and next step are in `ROADMAP.md`. The sync protocol is in
`docs/sync.md`.

## Layout

- `server/` — FastAPI app (`app/`), tests (`tests/`), Alembic migrations (`app/migrations/`)
  - `app/services.py` — sync rules (server_seq, last-write-wins, merge). `app/catalog.py` — CRUD
    operations shared by the JSON API (`app/api/`) and the web UI (`app/web/`)
- `app/` — Flutter Android app: `lib/src/domain/` (normalization rules, ported 1:1 from the
  server), `lib/src/data/` (drift database + repository), `lib/src/ui/` (screens)
- `docs/sync.md` — sync protocol spec. Clients must follow its normalization rules for GTINs and
  categories.

## Commands (run from `server/`)

```bash
.venv/bin/pip install -e '.[dev]'                         # setup (venv: python3 -m venv .venv)
.venv/bin/pytest -q                                       # all tests
.venv/bin/uvicorn app.main:create_app --factory --reload  # dev server (needs SB_API_TOKEN)
.venv/bin/alembic revision --autogenerate -m "..."        # after changing app/models.py
```

## Commands (run from `app/`)

```bash
flutter test                      # unit + widget tests
flutter analyze
dart run build_runner build       # after changing lib/src/data/database.dart
flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Widget tests that show drift streams must end with `unmount(tester)` (see
`test/widget_test.dart`), or drift's cleanup timer fails the test.

## Rules

- **The repo is public.** Before every push, check the staged files and the commit metadata for
  tokens, `.env` files, database files and personal email addresses. Test tokens must be
  obviously fake.
- Commit as the repo-local git identity (GitHub noreply address). Never use another email.
- Every change to `app/models.py` needs a reviewed Alembic migration.
  `tests/test_migrations.py` enforces this.
- Every server-side change to a product or identifier must go through `touch()` /
  `fresh_timestamp()` in `app/services.py`, so it gets a new `server_seq` and wins last-write-wins.
- Keep `docs/sync.md` in step with any change to synced fields or rules.
- Normalization rules (`server/app/identifiers.py`, `server/app/categories.py`) and their Dart
  ports (`app/lib/src/domain/`) must change together, with the same test vectors on both sides.
- When a task is finished, update `ROADMAP.md` in the same commit.
- When the user says "wrap up": commit, update `ROADMAP.md`, push (after the audit above), and
  record in memory anything the code doesn't capture.
