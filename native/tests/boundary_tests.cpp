#include "engine.hpp"
#include "native_bridge.h"
#include "pipeline.hpp"
#include <cmath>
#include <iostream>
#include <limits>
#include <sys/stat.h>
#include <unistd.h>

using namespace textpicker;
static int checks = 0;
static void check(bool condition) {
    ++checks;
    require(condition, "Boundary assertion failed");
}
template <class Function> void rejects(Function function) {
    bool rejected = false;
    try {
        function();
    } catch (const std::exception &) {
        rejected = true;
    }
    check(rejected);
}
int main(int argc, char **argv) {
    try {
        require(argc == 2, "Expected model directory");
        Tensor image({1, 3, 4, 4});
        float weight[27] = {};
        rejects([&] { pool(image, 5, 2, 2, 2, false); });
        rejects([&] { pool(image, 2, 2, 0, 1, false); });
        rejects([&] { conv(image, weight, nullptr, 1, 3, 3, 3, 0, 1, 0, 0, 1); });
        rejects([&] { conv(image, weight, nullptr, 1, 3, 5, 5, 1, 1, 0, 0, 1); });
        rejects([&] { conv(image, weight, nullptr, 1, 3, 3, 3, 1, 1, 0, 0, 0); });
        Tensor long_sequence({1, 10000, 1});
        rejects([&] { attention(long_sequence, long_sequence, long_sequence, 1); });
        rejects([&] { recognizer_input({cv::Mat{}}); });
        rejects([&] { recognizer_input({cv::Mat(1, 5000, CV_8UC3)}); });
        rejects([&] { recognizer_input({cv::Mat(4, 4, CV_8UC1)}); });
        rejects([&] { crop_region(cv::Mat(4, 4, CV_8UC3), {{NAN, 0}, {2, 0}, {2, 2}, {0, 2}}); });
        rejects([&] { crop_region(cv::Mat(4, 4, CV_8UC3), {{0, 0}, {0, 0}, {0, 0}, {0, 0}}); });
        Weights weights(std::string(argv[1]) + "/recognizer.weights");
        rejects([&] { weights.at(std::numeric_limits<size_t>::max() - 63); });
        rejects([&] { weights.at(1); });
        // Special-file inputs must fail immediately instead of blocking open().
        char directory[] = "/tmp/textpicker-native-fifo-XXXXXX";
        require(mkdtemp(directory), "Cannot create test directory");
        std::string fifo = std::string(directory) + "/asset";
        require(mkfifo(fifo.c_str(), 0600) == 0, "Cannot create test FIFO");
        rejects([&] { Weights bad(fifo); });
        rejects([&] { load_dictionary(fifo); });
        unlink(fifo.c_str());
        rmdir(directory);

        check(textpicker_native_create(nullptr) == nullptr);
        check(textpicker_native_warmup(nullptr) == 0);
        textpicker_native_destroy(nullptr);
        textpicker_native_free(nullptr);
        void *engine = textpicker_native_create(argv[1]);
        require(engine, textpicker_native_error());
        check(textpicker_native_warmup(engine) == 1);
        uint8_t bgra[8] = {255, 255, 255, 255, 255, 255, 255, 255};
        for (auto dimensions : {std::vector<int>{0, 1, 4},
                                {-1, 1, 4},
                                {1, 1, -4},
                                {1, 1, 8},
                                {1, 1, std::numeric_limits<int>::max()},
                                {1, 2, 4},
                                {2, 1, 8},
                                {32769, 1, 131076},
                                {5000, 4001, 20000}}) {
            auto result =
                textpicker_native_predict(engine, bgra, 4, dimensions[0], dimensions[1], dimensions[2]);
            check(!result && textpicker_native_error()[0]);
        }
        check(!textpicker_native_predict(engine, nullptr, 4, 1, 1, 4));
        auto result = textpicker_native_predict(engine, bgra, sizeof(bgra), 1, 1, 8);
        check(result && !result[0] && !textpicker_native_error()[0]);
        textpicker_native_free(result);
        textpicker_native_destroy(engine);
        // Remaining live storage here belongs only to the explicit unit tensors.
        const auto expected = (image.data.size() + long_sequence.data.size()) * sizeof(float);
        check(buffer_stats().active_bytes == expected);
        std::cout << "PASS: " << checks << " native boundary checks\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
