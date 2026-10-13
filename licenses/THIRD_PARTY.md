# Third-party components

TextPicker uses **PP-OCRv6 Small** detector/recognizer weights from PaddlePaddle
(Apache-2.0). The native executor uses the resolved FP32 tensors and complete
dictionary; `native/models/manifest.json` pins their hashes. Model binaries are
supplied separately from Git and included in built apps.

The native worker statically links:

- **OpenCV 5.0.0**: minimal core/imgproc/geometry/flann subset (Apache-2.0).
- **Carotene** ARM HAL (NVIDIA, BSD-3-Clause).
- **KleidiCV 26.03** (Arm, Apache-2.0).
- **zlib** (zlib license).
- **Clipper 6.4.2** (Angus Johnson 2010–2017, Boost-1.0).

Graph equations and pipeline behavior are adapted from **mlx4ocr 0.1.2**, commit
`2d5bb458607d97112555fed27901bdde603c934d` (MIT). A small **NumPy generic argsort**
adaptation is BSD-licensed. The app does not bundle either Python package.

The adjacent license files are copied into `Contents/Resources/Licenses/`.
ImageIO, CoreGraphics, Accelerate, AppKit and ScreenCaptureKit are macOS system
frameworks. Python, NumPy and Pillow are development/test tools only.

The app is locally ad-hoc signed, not notarized. This inventory is not a substitute
for a redistribution, model-license or signing review.
