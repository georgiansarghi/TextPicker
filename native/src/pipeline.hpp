#pragma once
#include "engine.hpp"
#include <opencv2/core.hpp>
namespace textpicker {
// A serial image-to-text engine. Model mappings and dictionary live for the
// worker's lifetime. Trace output is an explicit test/probe argument only;
// the app bridge never enables it.
class Pipeline {
    Weights detector_, recognizer_;
    std::vector<std::string> characters_;

  public:
    explicit Pipeline(const std::string &directory);
    void warmup();
    std::string predict(const cv::Mat &bgr, const std::filesystem::path &trace = {});
};
// Internal stage interfaces, exposed for deterministic parity tests.
Tensor detector_input(const cv::Mat &, cv::Size &);
Tensor recognizer_input(const std::vector<cv::Mat> &);
std::vector<std::vector<cv::Point2f>> detection_boxes(const Tensor &, cv::Size);
// Uses FP32 edge-length arithmetic before integer truncation, like the reference.
cv::Size crop_size(const std::vector<cv::Point2f> &);
cv::Mat crop_region(const cv::Mat &, const std::vector<cv::Point2f> &);
} // namespace textpicker
