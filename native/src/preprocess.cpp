// Preserve separate FP32 multiply/add and resize rounding; these are model behavior.
#include "native_bridge.h"
#include "pipeline.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <opencv2/imgproc.hpp>
namespace textpicker {
static int even_round(double v) {
    return int(std::nearbyint(v));
}
Tensor detector_input(const cv::Mat &original, cv::Size &source) {
    require(original.type() == CV_8UC3 && original.rows > 0 && original.cols > 0, "Expected BGR image");
    cv::Mat image = original;
    if (image.rows + image.cols < 64)
        cv::copyMakeBorder(original, image, 0, std::max(32 - original.rows, 0), 0,
                           std::max(32 - original.cols, 0), cv::BORDER_CONSTANT, 0);
    source = image.size();
    double ratio = std::min(1., 1280. / std::max(image.rows, image.cols));
    int h = std::max(32, even_round(int(image.rows * ratio) / 32.) * 32);
    int w = std::max(32, even_round(int(image.cols * ratio) / 32.) * 32);
    cv::Mat resized, normalized;
    cv::resize(image, resized, {w, h});
    resized.convertTo(normalized, CV_32FC3);
    cv::Scalar scale(float(1. / (255. * .229)), float(1. / (255. * .224)), float(1. / (255. * .225)));
    cv::Scalar bias(float(-.485 / .229), float(-.456 / .224), float(-.406 / .225));
    cv::multiply(normalized, scale, normalized);
    cv::add(normalized, bias, normalized);
    Tensor out({1, 3, h, w}, false);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
            for (int c = 0; c < 3; ++c)
                out.data[(c * h + y) * w + x] = normalized.at<cv::Vec3f>(y, x)[c];
    return out;
}
Tensor recognizer_input(const std::vector<cv::Mat> &images) {
    require(!images.empty() && images.size() <= 6, "Invalid recognition batch");
    double ratio = 320. / 48;
    for (const auto &im : images) {
        require(im.type() == CV_8UC3 && im.rows > 0 && im.cols > 0, "Invalid recognition crop");
        ratio = std::max(ratio, im.cols / double(im.rows));
    }
    require(48 * ratio < 4097, "Text line exceeds native width bound; capture a smaller region");
    int width = int(48 * ratio);
    Tensor out({int(images.size()), 3, 48, width});
    for (size_t i = 0; i < images.size(); ++i) {
        const auto &im = images[i];
        int rw = std::min(width, int(std::ceil(48 * (im.cols / double(im.rows)))));
        cv::Mat resized;
        cv::resize(im, resized, {rw, 48});
        for (int y = 0; y < 48; ++y)
            for (int x = 0; x < rw; ++x)
                for (int c = 0; c < 3; ++c)
                    out.data[((i * 3 + c) * 48 + y) * width + x] =
                        (float(resized.at<cv::Vec3b>(y, x)[c]) / 255.f - .5f) / .5f;
    }
    return out;
}
} // namespace textpicker
