#include "pipeline.hpp"
#include <chrono>
#include <fstream>
#include <iostream>
#include <sys/resource.h>
using namespace textpicker;
int main(int argc, char **argv) {
    try {
        require(argc == 5 || argc == 6, "models input.bgr width height [new-trace-directory]");
        int w = std::stoi(argv[3]), h = std::stoi(argv[4]);
        require(w > 0 && h > 0 && w <= 32768 && h <= 32768 && int64_t(w) * h <= 20000000, "Invalid image");
        cv::Mat image(h, w, CV_8UC3);
        std::ifstream f(argv[2], std::ios::binary | std::ios::ate);
        require(bool(f) && f.tellg() == std::streamoff(w * h * 3), "Invalid input file");
        f.seekg(0);
        f.read(reinterpret_cast<char *>(image.data), w * h * 3);
        require(bool(f), "Read failed");
        Pipeline engine(argv[1]);
        auto start = std::chrono::steady_clock::now();
        auto text = engine.predict(image, argc == 6 ? argv[5] : "");
        auto ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
        rusage r{};
        getrusage(RUSAGE_SELF, &r);
        std::cout << "{\"text\":" << json_string(text) << ",\"ms\":" << ms
                  << ",\"peak_rss_bytes\":" << r.ru_maxrss << "}\n";
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
