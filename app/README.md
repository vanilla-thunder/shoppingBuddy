# shoppingBuddy app

An offline-first Android app: scan a barcode and see your rating, or add the product if it's
unknown. Data lives in a local SQLite database (drift). Sync with the server is the next
milestone; see `../ROADMAP.md` and `../docs/sync.md`.

```bash
flutter test
flutter build apk --debug
```
