#include "engine.hpp"
#include "parallel.hpp"
#include <Accelerate/Accelerate.h>
namespace textpicker {
Tensor upsample(const Tensor &x, int factor) {
    require(x.shape.size() == 4 && factor >= 1 && factor <= 8, "Invalid nearest upsample");
    int n = x.shape[0], c = x.shape[1], h = x.shape[2], w = x.shape[3], oh = h * factor, ow = w * factor;
    Tensor y({n, c, oh, ow}, false);
    parallel_for(n * c, y.data.size(), [&](size_t begin, size_t end) {
        for (size_t bc = begin; bc < end; ++bc)
            for (int r = 0; r < oh; ++r)
                for (int col = 0; col < ow; ++col)
                    y.data[(bc * oh + r) * ow + col] = x.data[(bc * h + r / factor) * w + col / factor];
    });
    return y;
}
Tensor transpose2(const Tensor &x, const float *weights, const float *bias, int ic, int oc) {
    require(x.shape.size() == 4 && x.shape[1] == ic, "Transpose convolution input mismatch");
    int n = x.shape[0], h = x.shape[2], w = x.shape[3], pixels = h * w;
    Tensor y({n, oc, h * 2, w * 2}, false);
    // The frozen detector has only non-overlapping 2x2/stride-2 transposed kernels.
    Tensor projected({oc * 4, pixels}, false);
    for (int b = 0; b < n; ++b) {
        cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, oc * 4, pixels, ic, 1.f, weights, oc * 4,
                    x.data.data() + size_t(b) * ic * pixels, pixels, 0.f, projected.data.data(), pixels);
        parallel_for(oc, y.data.size() / n, [&](size_t begin, size_t end) {
            for (size_t c = begin; c < end; ++c)
                for (int ky = 0; ky < 2; ++ky)
                    for (int kx = 0; kx < 2; ++kx)
                        for (int r = 0; r < h; ++r)
                            for (int col = 0; col < w; ++col)
                                y.data[((size_t(b) * oc + c) * (h * 2) + r * 2 + ky) * (w * 2) + col * 2 +
                                       kx] = projected.data[(c * 4 + ky * 2 + kx) * pixels + r * w + col] +
                                             (bias ? bias[c] : 0.f);
        });
    }
    return y;
}
} // namespace textpicker
