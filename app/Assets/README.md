# TextPicker artwork

The production icon is **Porcelain**: warm ivory and iris, with the inner mark
enlarged 16% and the refined spacing preserved. It was selected from the earlier
naming/icon studies in `design/icon-concepts/v3-pluck-colors/`.

- `TextPicker.icns`: the approved Mac icon, copied byte-for-byte into every build.
- `TextPicker.png`: 1024×1024 RGBA source raster.
- `TextPicker.svg`: editable vector master with current product metadata.
- `icon.json`: hashes for the three canonical assets.
- `warmup.png`: existing synthetic OCR warm-up fixture, not icon artwork.

The release verifier rejects a bundle with a different icon or product identity.
`app/tests/branding_tests.py` also checks the source hashes, selected design match,
and absence of obsolete branding in active source and the entire packaged app.
The menu-bar icon remains a monochrome system symbol, separate from the full-color
app icon. Historical design studies and release evidence remain preserved.
