#pragma once
// NumPy generic aquicksort/aheapsort tie order, adapted from NumPy 2.3.4
// (BSD-3-Clause; native-deps/NumPy-LICENSE.txt). Matches the pinned ARM64
// NumPy 2.5.4 reference. Only finite nonnegative crop ratios are accepted.
// Signed indices avoid forming NumPy's historical one-before-begin pointers.
#include <algorithm>
#include <bit>
#include <cmath>
#include <numeric>
#include <stdexcept>
#include <vector>
namespace textpicker {
inline std::vector<size_t> numpy_order(const std::vector<double> &values) {
    if (values.size() > 3000)
        throw std::runtime_error("Too many text regions");
    for (double v : values)
        if (!std::isfinite(v) || v < 0)
            throw std::runtime_error("Invalid crop ratio");
    std::vector<size_t> order(values.size());
    std::iota(order.begin(), order.end(), 0);
    if (order.empty())
        return order;
    auto heap = [&](int lo, int hi) {
        int n = hi - lo + 1;
        auto a = [&](int i) -> size_t & { return order[lo + i - 1]; };
        auto sift = [&](int i, int n, size_t tmp) {
            int j = i * 2;
            while (j <= n) {
                if (j < n && values[a(j)] < values[a(j + 1)])
                    ++j;
                if (!(values[tmp] < values[a(j)]))
                    break;
                a(i) = a(j);
                i = j;
                j *= 2;
            }
            a(i) = tmp;
        };
        for (int l = n / 2; l > 0; --l)
            sift(l, n, a(l));
        while (n > 1) {
            size_t tmp = a(n);
            a(n) = a(1);
            --n;
            sift(1, n, tmp);
        }
    };
    struct Range {
        int lo, hi, depth;
    };
    std::vector<Range> stack{{0, int(order.size()) - 1, int(std::bit_width(order.size()) - 1) * 2}};
    while (!stack.empty()) {
        auto [lo, hi, depth] = stack.back();
        stack.pop_back();
        if (depth < 0) {
            heap(lo, hi);
            continue;
        }
        while (hi - lo > 15) {
            int mid = lo + (hi - lo) / 2;
            if (values[order[mid]] < values[order[lo]])
                std::swap(order[mid], order[lo]);
            if (values[order[hi]] < values[order[mid]])
                std::swap(order[hi], order[mid]);
            if (values[order[mid]] < values[order[lo]])
                std::swap(order[mid], order[lo]);
            double pivot = values[order[mid]];
            int i = lo, j = hi - 1;
            std::swap(order[mid], order[j]);
            for (;;) {
                do {
                    ++i;
                } while (values[order[i]] < pivot);
                do {
                    --j;
                } while (pivot < values[order[j]]);
                if (i >= j)
                    break;
                std::swap(order[i], order[j]);
            }
            std::swap(order[i], order[hi - 1]);
            --depth;
            if (i - lo < hi - i) {
                stack.push_back({i + 1, hi, depth});
                hi = i - 1;
            } else {
                stack.push_back({lo, i - 1, depth});
                lo = i + 1;
            }
        }
        for (int i = lo + 1; i <= hi; ++i) {
            size_t value = order[i];
            int j = i;
            while (j > lo && values[value] < values[order[j - 1]]) {
                order[j] = order[j - 1];
                --j;
            }
            order[j] = value;
        }
    }
    return order;
}
} // namespace textpicker
