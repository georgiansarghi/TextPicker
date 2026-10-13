#include "engine.hpp"
#include <chrono>
#include <fstream>
#include <iostream>
using namespace textpicker;
int main(int argc, char **argv) {
    try {
        require(argc == 6, "weights input height width output");
        int h = std::stoi(argv[3]), w = std::stoi(argv[4]);
        require(h >= 32 && h <= 1280 && w >= 32 && w <= 1280, "Invalid dimensions");
        Weights weights(argv[1], detector_bytes(), detector_sha256());
        Tensor x({1, 3, h, w}, false);
        std::ifstream f(argv[2], std::ios::binary | std::ios::ate);
        require(bool(f) && f.tellg() == std::streamoff(x.data.size() * 4), "Invalid input file");
        f.seekg(0);
        f.read(reinterpret_cast<char *>(x.data.data()), x.data.size() * 4);
        require(bool(f), "Input read failed");
        auto start = std::chrono::steady_clock::now();
        auto y = detect(x, weights);
        require(all_finite(y), "Nonfinite output");
        double elapsed =
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
        write_tensor(argv[5], y);
        std::cout << "{\"ms\":" << elapsed << "}\n";
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
