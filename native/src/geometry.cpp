// DB box geometry ported from mlx4ocr (MIT). See licenses/mlx4ocr-MIT.txt.
#include "clipper.hpp"
#include "native_bridge.h"
#include "pipeline.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <opencv2/geometry.hpp>
#include <opencv2/imgproc.hpp>
namespace textpicker {
static int even_round(double value) {
    return int(std::nearbyint(value));
}
static std::pair<std::vector<cv::Point2f>, float> mini_box(const std::vector<cv::Point2f> &points) {
    auto rect = cv::minAreaRect(points);
    std::array<cv::Point2f, 4> p;
    rect.points(p.data());
    std::stable_sort(p.begin(), p.end(), [](auto a, auto b) { return a.x < b.x; });
    int a = 1, b = 0, c = 2, d = 3;
    if (p[1].y > p[0].y) {
        a = 0;
        b = 1;
    }
    if (p[3].y > p[2].y) {
        c = 3;
        d = 2;
    }
    return {{p[a], p[d], p[c], p[b]}, std::min(rect.size.width, rect.size.height)};
}
std::vector<std::vector<cv::Point2f>> detection_boxes(const Tensor &pred, cv::Size source) {
    require(pred.shape.size() == 4 && pred.shape[0] == 1 && pred.shape[1] == 1, "Invalid detector map");
    int h = pred.shape[2], w = pred.shape[3];
    cv::Mat map(h, w, CV_32F, const_cast<float *>(pred.data.data())), mask;
    cv::compare(map, .2, mask, cv::CMP_GT);
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(mask, contours, cv::RETR_LIST, cv::CHAIN_APPROX_SIMPLE);
    std::vector<std::vector<cv::Point2f>> boxes;
    for (size_t ci = 0; ci < std::min(size_t(3000), contours.size()); ++ci) {
        std::vector<cv::Point2f> points(contours[ci].begin(), contours[ci].end());
        if (points.empty())
            continue;
        auto [box, side] = mini_box(points);
        if (side < 3)
            continue;
        float minx = box[0].x, maxx = minx, miny = box[0].y, maxy = miny;
        for (auto p : box) {
            minx = std::min(minx, p.x);
            maxx = std::max(maxx, p.x);
            miny = std::min(miny, p.y);
            maxy = std::max(maxy, p.y);
        }
        int x0 = std::clamp(int(std::floor(minx)), 0, w - 1), x1 = std::clamp(int(std::ceil(maxx)), 0, w - 1);
        int y0 = std::clamp(int(std::floor(miny)), 0, h - 1), y1 = std::clamp(int(std::ceil(maxy)), 0, h - 1);
        cv::Mat scoremask = cv::Mat::zeros(y1 - y0 + 1, x1 - x0 + 1, CV_8U);
        std::vector<cv::Point> poly;
        for (auto p : box)
            poly.emplace_back(int(p.x - x0), int(p.y - y0));
        cv::fillPoly(scoremask, std::vector<std::vector<cv::Point>>{poly}, 1);
        if (cv::mean(map(cv::Rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)), scoremask)[0] < .45)
            continue;
        double twicearea = 0, perimeter = 0;
        ClipperLib::Path path;
        for (size_t i = 0; i < 4; ++i) {
            auto p = box[i], q = box[(i + 1) % 4];
            twicearea += double(p.x) * q.y - double(q.x) * p.y;
            perimeter += std::hypot(double(p.x) - q.x, double(p.y) - q.y);
            path.emplace_back(ClipperLib::cInt(p.x), ClipperLib::cInt(p.y));
        }
        if (perimeter <= 0)
            continue;
        ClipperLib::ClipperOffset offset;
        offset.AddPath(path, ClipperLib::jtRound, ClipperLib::etClosedPolygon);
        ClipperLib::Paths expanded;
        offset.Execute(expanded, std::abs(twicearea) * .5 * 1.4 / perimeter);
        if (expanded.size() != 1 || expanded[0].empty())
            continue;
        points.clear();
        for (auto p : expanded[0])
            points.emplace_back(float(p.X), float(p.Y));
        auto result = mini_box(points);
        box = result.first;
        if (result.second < 5)
            continue;
        // NumPy evaluates these float32 operations separately before rint.
        for (auto &p : box) {
            p.x = float(std::clamp(even_round((p.x / float(w)) * float(source.width)), 0, source.width));
            p.y = float(std::clamp(even_round((p.y / float(h)) * float(source.height)), 0, source.height));
        }
        boxes.push_back(box);
    }
    std::stable_sort(boxes.begin(), boxes.end(), [](const auto &a, const auto &b) {
        return a[0].y == b[0].y ? a[0].x < b[0].x : a[0].y < b[0].y;
    });
    for (size_t i = 0; i + 1 < boxes.size(); ++i)
        for (int j = int(i); j >= 0; --j) {
            if (std::abs(boxes[j + 1][0].y - boxes[j][0].y) < 10 && boxes[j + 1][0].x < boxes[j][0].x)
                std::swap(boxes[j], boxes[j + 1]);
            else
                break;
        }
    return boxes;
}
cv::Size crop_size(const std::vector<cv::Point2f> &box) {
    require(box.size() == 4, "Invalid crop box");
    for (const auto &p : box)
        require(std::isfinite(p.x) && std::isfinite(p.y) && std::abs(p.x) <= float(TEXTPICKER_MAX_IMAGE_SIDE) &&
                    std::abs(p.y) <= float(TEXTPICKER_MAX_IMAGE_SIDE),
                "Invalid crop coordinates");
    auto d = [](auto a, auto b) {
        float dx = a.x - b.x, dy = a.y - b.y;
        return std::sqrt(dx * dx + dy * dy);
    };
    return {int(std::max(d(box[0], box[1]), d(box[2], box[3]))),
            int(std::max(d(box[0], box[3]), d(box[1], box[2])))};
}
cv::Mat crop_region(const cv::Mat &image, const std::vector<cv::Point2f> &box) {
    auto size = crop_size(box);
    require(size.width > 0 && size.height > 0 &&
                int64_t(size.width) * size.height <= TEXTPICKER_MAX_IMAGE_PIXELS,
            "Invalid or oversized text crop");
    cv::Point2f target[] = {
        {0, 0}, {float(size.width), 0}, {float(size.width), float(size.height)}, {0, float(size.height)}};
    auto matrix = cv::getPerspectiveTransform(box.data(), target);
    cv::Mat crop;
    cv::warpPerspective(image, crop, matrix, size, cv::INTER_CUBIC, cv::BORDER_REPLICATE);
    if (crop.rows / double(crop.cols) >= 1.5)
        cv::rotate(crop, crop, cv::ROTATE_90_COUNTERCLOCKWISE);
    return crop;
}
} // namespace textpicker
