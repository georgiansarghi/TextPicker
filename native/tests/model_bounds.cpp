#include "engine.hpp"
#include <iostream>

using namespace textpicker;

int main(int argc, char **argv) {
    try {
        require(argc == 2, "Expected model directory");
        const std::string directory = argv[1];
        Weights detector(directory + "/detector.weights", detector_bytes(), detector_sha256());
        Weights recognizer(directory + "/recognizer.weights");
        auto dictionary = load_dictionary(directory + "/characters.bin");
        for (auto shape : {std::vector<int>{1, 3, 32, 1280}, {1, 3, 1280, 32}, {1, 3, 1280, 1280}}) {
            Tensor input(shape);
            auto map = detect(input, detector);
            require(map.shape == std::vector<int>({1, 1, shape[2], shape[3]}) && all_finite(map),
                    "Detector boundary failed");
        }
        Tensor input({6, 3, 48, 4096});
        const auto lines = recognize_text(input, recognizer, dictionary);
        require(lines.size() == 6, "Recognizer boundary failed");
        std::cout << "PASS: detector aspect/area extremes and maximum streamed recognizer batch\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
