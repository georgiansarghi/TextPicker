// Native port of the frozen mlx4ocr / app/coreml_backend.py pipeline (MIT).
// All inference is the generated C++ executor. OpenCV is a minimal image/geometry subset.
#include "pipeline.hpp"
#include "native_bridge.h"
#include "numpy_order.hpp"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <numeric>
namespace textpicker {
Pipeline::Pipeline(const std::string &dir)
    : detector_(dir + "/detector.weights", detector_bytes(), detector_sha256()),
      recognizer_(dir + "/recognizer.weights"), characters_(load_dictionary(dir + "/characters.bin")) {
    cv::setNumThreads(1); // Pipeline is serial; only our tensor kernels / Accelerate parallelize.
}
void Pipeline::warmup() {
    Tensor d({1, 3, 32, 32});
    auto map = detect(d, detector_);
    require(all_finite(map), "Detector warm-up failed");
    Tensor r({1, 3, 48, 320});
    recognize_text(r, recognizer_, characters_);
}
std::string Pipeline::predict(const cv::Mat &image, const std::filesystem::path &trace) {
    require(image.type() == CV_8UC3 && image.rows > 0 && image.cols > 0 &&
                image.rows <= TEXTPICKER_MAX_IMAGE_SIDE && image.cols <= TEXTPICKER_MAX_IMAGE_SIDE &&
                int64_t(image.rows) * image.cols <= TEXTPICKER_MAX_IMAGE_PIXELS,
            "Selection is too large or invalid");
    require(trace.empty() || std::filesystem::create_directory(trace), "Trace directory must be new");
    auto dump = [&](const std::string &name, const Tensor &t) {
        if (!trace.empty())
            write_tensor(trace / (name + ".f32"), t);
    };
    cv::Size source;
    auto input = detector_input(image, source);
    dump("det-input", input);
    auto map = detect(input, detector_);
    require(all_finite(map), "Nonfinite detector output");
    dump("det-map", map);
    auto boxes = detection_boxes(map, source);
    input.release();
    map.release();
    if (!trace.empty()) {
        std::ofstream f(trace / "boxes.json");
        f << '[';
        for (size_t i = 0; i < boxes.size(); ++i) {
            if (i)
                f << ',';
            f << '[';
            for (size_t j = 0; j < 4; ++j) {
                if (j)
                    f << ',';
                f << '[' << boxes[i][j].x << ',' << boxes[i][j].y << ']';
            }
            f << ']';
        }
        f << ']';
    }
    // Do not retain every full-resolution crop simultaneously. Keep <=6 at a time.
    std::vector<double> ratios;
    for (const auto &box : boxes) {
        auto s = crop_size(box);
        require(s.width > 0 && s.height > 0, "Degenerate text region");
        if (s.height / double(s.width) >= 1.5)
            std::swap(s.width, s.height);
        double ratio = s.width / double(s.height);
        require(ratio * 48 < 4097,
                "Text line exceeds native width bound; use ONNX or capture a smaller region");
        ratios.push_back(ratio);
    }
    auto order = numpy_order(ratios);
    std::vector<Decoded> results(boxes.size());
    for (size_t start = 0; start < order.size(); start += 6) {
        std::vector<cv::Mat> crops;
        for (size_t i = start; i < std::min(start + 6, order.size()); ++i) {
            auto crop = crop_region(image, boxes[order[i]]);
            if (!trace.empty()) {
                std::ofstream f(trace / ("crop-" + std::to_string(order[i]) + ".bgr"), std::ios::binary);
                f.write(reinterpret_cast<const char *>(crop.data), crop.total() * crop.elemSize());
            }
            crops.push_back(std::move(crop));
        }
        auto batch = recognizer_input(crops);
        dump("rec-input-" + std::to_string(start / 6), batch);
        crops.clear();
        auto decoded = recognize_text(batch, recognizer_, characters_);
        for (size_t i = 0; i < decoded.size(); ++i)
            results[order[start + i]] = std::move(decoded[i]);
    }
    std::string text;
    for (auto &line : results)
        if (line.score >= .5f && !line.text.empty()) {
            if (!text.empty())
                text += '\n';
            text += line.text;
        }
    require(text.size() <= TEXTPICKER_MAX_TEXT_BYTES, "OCR result exceeds output bound");
    return text;
}
} // namespace textpicker
