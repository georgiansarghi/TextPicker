#include "native_bridge.h"
#include "pipeline.hpp"
#include <array>
#include <cstdlib>
#include <cstring>
#include <opencv2/imgproc.hpp>

namespace {
// Error reporting itself must not allocate/throw, including on out-of-memory.
thread_local std::array<char, 1024> last_error{};

void failure() noexcept {
    const char *message = "Native OCR failed";
    try {
        throw;
    } catch (const std::bad_alloc &) {
        message = "Not enough memory for this selection; capture a smaller region";
        std::snprintf(last_error.data(), last_error.size(), "%s", message);
    } catch (const std::exception &error) {
        std::snprintf(last_error.data(), last_error.size(), "%s", error.what());
    } catch (...) {
        std::snprintf(last_error.data(), last_error.size(), "%s", message);
    }
}
} // namespace

extern "C" {
void *textpicker_native_create(const char *directory) noexcept {
    try {
        last_error[0] = 0;
        textpicker::require(directory, "Missing native model directory");
        return new textpicker::Pipeline(directory);
    } catch (...) {
        failure();
        return nullptr;
    }
}

int32_t textpicker_native_warmup(void *engine) noexcept {
    try {
        last_error[0] = 0;
        textpicker::require(engine, "Native engine is closed");
        static_cast<textpicker::Pipeline *>(engine)->warmup();
        return 1;
    } catch (...) {
        failure();
        return 0;
    }
}

void textpicker_native_destroy(void *engine) noexcept {
    delete static_cast<textpicker::Pipeline *>(engine);
}

const char *textpicker_native_error() noexcept {
    return last_error.data();
}

void textpicker_native_free(char *value) noexcept {
    std::free(value);
}

char *textpicker_native_predict(void *engine, const uint8_t *bgra, size_t byte_count, int32_t width,
                             int32_t height, int32_t stride) noexcept {
    try {
        last_error[0] = 0;
        textpicker::require(engine && bgra, "Native engine or image is missing");
        textpicker::require(
            width > 0 && height > 0 && width <= TEXTPICKER_MAX_IMAGE_SIDE && height <= TEXTPICKER_MAX_IMAGE_SIDE &&
                int64_t(width) * height <= TEXTPICKER_MAX_IMAGE_PIXELS && stride >= int64_t(width) * 4,
            "Invalid or oversized image");
        // OpenCV forms datalimit at rows*step, even when the last row's padding
        // is not sampled. Require that full extent to belong to the input buffer.
        const uint64_t needed = uint64_t(height) * uint64_t(stride);
        textpicker::require(needed <= TEXTPICKER_MAX_FILE_BYTES, "Invalid or oversized image stride");
        textpicker::require(needed <= byte_count, "Capture buffer is shorter than its dimensions");

        cv::Mat source(height, width, CV_8UC4, const_cast<uint8_t *>(bgra), size_t(stride));
        cv::Mat bgr;
        cv::cvtColor(source, bgr, cv::COLOR_BGRA2BGR);
        const auto text = static_cast<textpicker::Pipeline *>(engine)->predict(bgr);
        char *result = strdup(text.c_str());
        textpicker::require(result, "Native result allocation failed");
        return result;
    } catch (...) {
        failure();
        return nullptr;
    }
}
}
