# TextPicker artwork

The production icon is **Contour hug / Medium**, in the **Midnight** palette:
deep navy and electric ice, rounded edge-hugging corners and a larger central mark.
The 48-unit contour grows inward to preserve the thin navy outer margin; the
central mark retains the 1.76× scale of the original Contour hug. All three canonical
assets exactly match `design/icon-concepts/v5-contour-weights/01-medium.*`.
The original Contour hug and all earlier studies remain available.

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
