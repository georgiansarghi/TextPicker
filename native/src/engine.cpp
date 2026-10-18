// Narrow FP32 CPU kernels for the frozen PP-OCRv6 Small recognizer.
// Equations: mlx4ocr (MIT), as recorded in the frozen Torch mirror.
#include "engine.hpp"
#include "parallel.hpp"
#include <Accelerate/Accelerate.h>
#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <atomic>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

namespace textpicker {
// Timing belongs at the request boundary. Kernels never collect global mutable
// profiling state or write diagnostics based on inherited environment variables.
void require(bool b, const char *message) {
    if (!b)
        throw std::runtime_error(message);
}
size_t elements(const std::vector<int> &shape) {
    require(!shape.empty() && shape.size() <= 4, "Invalid tensor rank");
    size_t count = 1;
    for (int dim : shape) {
        require(dim > 0 && size_t(dim) <= 64 * 1024 * 1024 / count, "Tensor exceeds 64M float bound");
        count *= size_t(dim);
    }
    return count;
}
Tensor::Tensor(std::vector<int> dimensions, bool zero)
    : shape(std::move(dimensions)), data(elements(shape), zero) {}
void write_tensor(const std::filesystem::path &path, const Tensor &t) {
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    f.write(reinterpret_cast<const char *>(t.data.data()), std::streamsize(t.data.size() * 4));
    require(bool(f), "Cannot write tensor");
}
void Trace::record(const std::string &name, const Tensor &tensor) {
    write_tensor(directory / (name + ".f32"), tensor);
    std::ofstream shapes(directory / "shapes.tsv", std::ios::app);
    shapes << name;
    for (int s : tensor.shape)
        shapes << '\t' << s;
    shapes << '\n';
    require(bool(shapes), "Cannot write trace shapes");
}

Tensor conv(const Tensor &x, const float *weight, const float *bias, int oc, int icg, int kh, int kw, int sh,
            int sw, int ph, int pw, int groups) {
    require(x.shape.size() == 4, "Convolution needs NCHW");
    int n = x.shape[0], ic = x.shape[1], ih = x.shape[2], iw = x.shape[3];
    require(oc > 0 && oc <= 4096 && icg > 0 && icg <= 4096 && groups > 0 && groups <= 4096 && kh > 0 &&
                kh <= 31 && kw > 0 && kw <= 31 && sh > 0 && sh <= 8 && sw > 0 && sw <= 8 && ph >= 0 &&
                ph <= 31 && pw >= 0 && pw <= 31,
            "Invalid frozen convolution parameters");
    require(ic == icg * groups && oc % groups == 0, "Convolution channels mismatch");
    require(kh <= ih + 2 * ph && kw <= iw + 2 * pw, "Convolution kernel exceeds padded input");
    int oh = (ih + 2 * ph - kh) / sh + 1, ow = (iw + 2 * pw - kw) / sw + 1;
    Tensor y({n, oc, oh, ow}, groups == ic && oc == ic && icg == 1);
    int ip = ih * iw, op = oh * ow, ocg = oc / groups;
    // Depthwise: avoid a large im2col buffer and tiny GEMM calls.
    if (groups == ic && oc == ic && icg == 1) {
        parallel_for(n * ic, y.data.size(), [&](size_t begin, size_t end) {
            for (size_t bc = begin; bc < end; ++bc) {
                int b = int(bc) / ic, c = int(bc) % ic;
                const float *src = x.data.data() + (b * ic + c) * ip;
                float *dst = y.data.data() + (b * oc + c) * op;
                for (int ky = 0; ky < kh; ++ky)
                    for (int kx = 0; kx < kw; ++kx) {
                        float w = weight[(c * kh + ky) * kw + kx];
                        for (int oy = 0; oy < oh; ++oy) {
                            int iy = oy * sh - ph + ky;
                            if (iy < 0 || iy >= ih)
                                continue;
                            int lo = std::max(0, (pw - kx + sw - 1) / sw);
                            int hi = std::min(ow, (iw + pw - kx + sw - 1) / sw);
                            for (int ox = lo; ox < hi; ++ox)
                                dst[oy * ow + ox] += src[iy * iw + ox * sw - pw + kx] * w;
                        }
                    }
                if (bias)
                    for (int p = 0; p < op; ++p)
                        dst[p] += bias[c];
            }
        });
        return y;
    }
    const int k = icg * kh * kw;
    const bool pointwise = kh == 1 && kw == 1 && sh == 1 && sw == 1 && ph == 0 && pw == 0;
    // Bound packing memory. Tile spatial columns instead of materializing all im2col.
    constexpr int tile = 1024;
    std::vector<float> packed(pointwise ? 0 : elements({k, std::min(op, tile)}));
    for (int b = 0; b < n; ++b)
        for (int g = 0; g < groups; ++g) {
            const float *src = x.data.data() + (b * ic + g * icg) * ip;
            const float *w = weight + g * ocg * k;
            float *dst = y.data.data() + (b * oc + g * ocg) * op;
            if (pointwise) {
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, ocg, op, k, 1.f, w, k, src, op, 0.f,
                            dst, op);
            } else
                for (int start = 0; start < op; start += tile) {
                    int count = std::min(tile, op - start);
                    parallel_for(k, size_t(k) * count, [&](size_t begin, size_t end) {
                        for (size_t row = begin; row < end; ++row) {
                            int c = int(row) / (kh * kw), ky = (int(row) / kw) % kh, kx = int(row) % kw;
                            const float *plane = src + c * ip;
                            float *out = packed.data() + row * count;
                            // Output columns [lo, hi) read inside the input row. Copy each
                            // output-row segment and zero only its padded borders; the packed
                            // values are identical to a per-element bounds check.
                            int lo = std::max(0, (pw - kx + sw - 1) / sw);
                            int hi = std::min(ow, (iw + pw - kx + sw - 1) / sw);
                            for (int j = 0; j < count;) {
                                int p = start + j, oy = p / ow, ox = p % ow, n = std::min(count - j, ow - ox);
                                int iy = oy * sh - ph + ky;
                                float *dst = out + j;
                                if (iy < 0 || iy >= ih) {
                                    std::fill(dst, dst + n, 0.f);
                                } else {
                                    // Valid columns a..b-1, as offsets into this segment.
                                    int a = std::clamp(lo, ox, ox + n) - ox, b = std::clamp(hi, ox + a, ox + n) - ox;
                                    std::fill(dst, dst + a, 0.f);
                                    if (b > a) {
                                        const float *in = plane + iy * iw + (ox + a) * sw - pw + kx;
                                        if (sw == 1)
                                            std::memcpy(dst + a, in, size_t(b - a) * sizeof(float));
                                        else
                                            for (int q = 0; q < b - a; ++q)
                                                dst[a + q] = in[q * sw];
                                    }
                                    std::fill(dst + b, dst + n, 0.f);
                                }
                                j += n;
                            }
                        }
                    });
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, ocg, count, k, 1.f, w, k,
                                packed.data(), count, 0.f, dst + start, op);
                }
            if (bias)
                for (int c = 0; c < ocg; ++c)
                    for (int p = 0; p < op; ++p)
                        dst[c * op + p] += bias[g * ocg + c];
        }
    return y;
}
Tensor linear(const Tensor &x, const float *w, const float *bias, int in, int out) {
    require(x.shape.back() == in, "Linear input dimension mismatch");
    auto shape = x.shape;
    shape.back() = out;
    Tensor y(shape, false);
    int rows = int(x.data.size() / in);
    // Large classifier outputs can make BLAS reserve large internal workspaces.
    // Bound its row dimension without changing the output tensor or vocabulary.
    const int tile = out >= 4096 ? 256 : rows;
    for (int r = 0; r < rows; r += tile)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, std::min(tile, rows - r), out, in, 1.f,
                    x.data.data() + size_t(r) * in, in, w, in, 0.f, y.data.data() + size_t(r) * out, out);
    if (bias)
        for (int r = 0; r < rows; ++r)
            for (int c = 0; c < out; ++c)
                y.data[r * out + c] += bias[c];
    return y;
}
Tensor activate(const Tensor &x, Activation kind) {
    return activate_reuse(Tensor(x), kind);
}
Tensor activate_reuse(Tensor y, Activation kind) {
#ifndef TEXTPICKER_REFERENCE_ERF
    if (kind == Activation::GELU) {
        // Evaluate the erf-form GELU (NOT the usual tanh-form GELU substitute).
        // Abramowitz-Stegun 7.1.26: real-arithmetic erf error <=1.5e-7.
        // Float rounding adds error; tests bound the actual GELU error separately.
        parallel_for((y.data.size() + 2047) / 2048, y.data.size(), [&](size_t begin, size_t end) {
            alignas(64) float scratch[2048];
            for (size_t block = begin; block < end; ++block) {
                size_t start = block * 2048;
                int count = int(std::min(size_t(2048), y.data.size() - start));
                float *dst = y.data.data() + start;
                for (int i = 0; i < count; ++i)
                    scratch[i] = -0.5f * dst[i] * dst[i];
                vvexpf(scratch, scratch, &count);
                for (int i = 0; i < count; ++i) {
                    float a = dst[i], u = std::abs(a) * 0.7071067811865475f;
                    float t = 1.f / (1.f + 0.3275911f * u);
                    float p =
                        (((((1.061405429f * t - 1.453152027f) * t) + 1.421413741f) * t - 0.284496736f) * t +
                         0.254829592f) *
                        t;
                    float e = std::copysign(1.f - p * scratch[i], a);
                    dst[i] = 0.5f * a * (1.f + e);
                }
            }
        });
        return y;
    }
#endif
    for (size_t i = 0; i < y.data.size(); ++i) {
        float a = y.data[i];
        switch (kind) {
        case Activation::ReLU:
            y.data[i] = std::max(0.f, a);
            break;
        case Activation::HardSigmoidClip:
            y.data[i] = std::clamp(a * 0.2f + 0.5f, 0.f, 1.f);
            break;
        case Activation::Sigmoid:
            y.data[i] = 1.f / (1.f + std::exp(-a));
            break;
        case Activation::SiLU:
            y.data[i] = a / (1.f + std::exp(-a));
            break;
        case Activation::HardSigmoid:
            y.data[i] = std::clamp(a / 6.f + 0.5f, 0.f, 1.f);
            break;
        case Activation::GELU:
            y.data[i] = 0.5f * a * (1.f + std::erf(a * 0.7071067811865475f));
            break;
        }
    }
    return y;
}
Tensor pool(const Tensor &x, int kh, int kw, int sh, int sw, bool average) {
    require(x.shape.size() == 4, "Pool needs NCHW");
    int n = x.shape[0], c = x.shape[1], h = x.shape[2], w = x.shape[3];
    require(kh > 0 && kw > 0 && sh > 0 && sw > 0 && kh <= h && kw <= w, "Invalid pooling parameters");
    int oh = (h - kh) / sh + 1, ow = (w - kw) / sw + 1;
    Tensor y({n, c, oh, ow}, false);
    parallel_for(n * c, y.data.size(), [&](size_t begin, size_t end) {
        for (int bc = int(begin); bc < int(end); ++bc)
            for (int oy = 0; oy < oh; ++oy)
                for (int ox = 0; ox < ow; ++ox) {
                    float value = average ? 0.f : -std::numeric_limits<float>::infinity();
                    for (int ky = 0; ky < kh; ++ky)
                        for (int kx = 0; kx < kw; ++kx) {
                            float v = x.data[(bc * h + oy * sh + ky) * w + ox * sw + kx];
                            value = average ? value + v : std::max(value, v);
                        }
                    y.data[(bc * oh + oy) * ow + ox] = average ? value / float(kh * kw) : value;
                }
    });
    return y;
}
Tensor pad_bottom_right(const Tensor &x) {
    require(x.shape.size() == 4, "Padding needs NCHW");
    int n = x.shape[0], c = x.shape[1], h = x.shape[2], w = x.shape[3];
    Tensor y({n, c, h + 1, w + 1});
    for (int bc = 0; bc < n * c; ++bc)
        for (int row = 0; row < h; ++row)
            std::copy_n(x.data.data() + (bc * h + row) * w, w,
                        y.data.data() + (bc * (h + 1) + row) * (w + 1));
    return y;
}
Tensor concat_channels(const Tensor &a, const Tensor &b) {
    require(a.shape.size() == 4 && b.shape.size() == 4 && a.shape[0] == b.shape[0] &&
                a.shape[2] == b.shape[2] && a.shape[3] == b.shape[3],
            "Concat shape mismatch");
    int n = a.shape[0], c = a.shape[1] + b.shape[1], h = a.shape[2], w = a.shape[3];
    Tensor y({n, c, h, w}, false);
    size_t as = size_t(a.shape[1]) * h * w, bs = size_t(b.shape[1]) * h * w;
    for (int i = 0; i < n; ++i) {
        std::copy_n(a.data.data() + i * as, as, y.data.data() + i * (as + bs));
        std::copy_n(b.data.data() + i * bs, bs, y.data.data() + i * (as + bs) + as);
    }
    return y;
}
Tensor add(const Tensor &a, const Tensor &b) {
    require(a.shape == b.shape, "Add shape mismatch");
    Tensor y(a.shape, false);
    vDSP_vadd(a.data.data(), 1, b.data.data(), 1, y.data.data(), 1, y.data.size());
    return y;
}
Tensor add_reuse(Tensor a, const Tensor &b) {
    require(a.shape == b.shape, "Add shape mismatch");
    vDSP_vadd(a.data.data(), 1, b.data.data(), 1, a.data.data(), 1, a.data.size());
    return a;
}
Tensor spatial_mean(const Tensor &x) {
    require(x.shape.size() == 4, "Mean needs NCHW");
    int n = x.shape[0], c = x.shape[1], pixels = x.shape[2] * x.shape[3];
    Tensor y({n, c, 1, 1}, false);
    parallel_for(n * c, x.data.size(), [&](size_t begin, size_t end) {
        for (size_t i = begin; i < end; ++i) {
            double sum = 0;
            for (int j = 0; j < pixels; ++j)
                sum += x.data[i * pixels + j];
            y.data[i] = float(sum / pixels);
        }
    });
    return y;
}
Tensor channel_multiply(const Tensor &x, const Tensor &gate) {
    return channel_multiply_reuse(Tensor(x), gate);
}
Tensor channel_multiply_reuse(Tensor x, const Tensor &gate) {
    require(x.shape.size() == 4 && gate.shape == std::vector<int>({x.shape[0], x.shape[1], 1, 1}),
            "Gate shape mismatch");
    int count = x.shape[2] * x.shape[3];
    for (size_t i = 0; i < gate.data.size(); ++i)
        vDSP_vsmul(x.data.data() + i * count, 1, &gate.data[i], x.data.data() + i * count, 1, count);
    return x;
}
Tensor to_sequence(const Tensor &x) {
    require(x.shape.size() == 4, "Sequence conversion needs NCHW");
    int b = x.shape[0], c = x.shape[1], l = x.shape[2] * x.shape[3];
    Tensor y({b, l, c}, false);
    for (int n = 0; n < b; ++n)
        for (int i = 0; i < l; ++i)
            for (int j = 0; j < c; ++j)
                y.data[(n * l + i) * c + j] = x.data[(n * c + j) * l + i];
    return y;
}
Tensor from_sequence(const Tensor &x, const std::vector<int> &shape) {
    require(shape.size() == 4 && x.shape == std::vector<int>({shape[0], shape[2] * shape[3], shape[1]}),
            "Spatial conversion shape mismatch");
    Tensor y(shape, false);
    int b = shape[0], c = shape[1], l = shape[2] * shape[3];
    for (int n = 0; n < b; ++n)
        for (int i = 0; i < l; ++i)
            for (int j = 0; j < c; ++j)
                y.data[(n * c + j) * l + i] = x.data[(n * l + i) * c + j];
    return y;
}
Tensor layer_norm(const Tensor &x, const float *weight, const float *bias, float eps) {
    return layer_norm_reuse(Tensor(x), weight, bias, eps);
}
Tensor layer_norm_reuse(Tensor y, const float *weight, const float *bias, float eps) {
    require(weight && bias && eps > 0, "Invalid layer norm constants");
    int c = y.shape.back();
    size_t rows = y.data.size() / c;
    for (size_t r = 0; r < rows; ++r) {
        const float *src = y.data.data() + r * c;
        float *dst = y.data.data() + r * c;
        double sum = 0;
        for (int j = 0; j < c; ++j)
            sum += src[j];
        double mean = sum / c;
        double variance = 0;
        for (int j = 0; j < c; ++j) {
            double d = src[j] - mean;
            variance += d * d;
        }
        float inv = float(1 / std::sqrt(variance / c + eps)), m = float(mean);
        for (int j = 0; j < c; ++j)
            dst[j] = (src[j] - m) * inv * weight[j] + bias[j];
    }
    return y;
}
static void softmax_rows(float *ptr, int rows, int cols) {
    for (int r = 0; r < rows; ++r) {
        float *row = ptr + r * cols;
        float mx = *std::max_element(row, row + cols), minus = -mx;
        vDSP_vsadd(row, 1, &minus, row, 1, cols);
        vvexpf(row, row, &cols);
        float sum = 0;
        vDSP_sve(row, 1, &sum, cols);
        float inv = 1.f / sum;
        vDSP_vsmul(row, 1, &inv, row, 1, cols);
    }
}
Tensor attention(const Tensor &q, const Tensor &k, const Tensor &v, int heads) {
    require(q.shape.size() == 3 && q.shape == k.shape && k.shape == v.shape, "Attention shape mismatch");
    int b = q.shape[0], l = q.shape[1], c = q.shape[2];
    require(heads > 0 && c % heads == 0, "Attention head mismatch");
    int d = c / heads;
    float scale = 1.f / std::sqrt(float(d));
    Tensor y(q.shape, false);
    const auto features = elements({l, d}), matrix = elements({l, l});
    std::vector<float> qs(features), ks(features), vs(features), scores(matrix), result(features);
    for (int n = 0; n < b; ++n)
        for (int h = 0; h < heads; ++h) {
            for (int i = 0; i < l; ++i)
                for (int j = 0; j < d; ++j) {
                    int src = (n * l + i) * c + h * d + j, dst = i * d + j;
                    qs[dst] = q.data[src] * scale;
                    ks[dst] = k.data[src];
                    vs[dst] = v.data[src];
                }
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, l, l, d, 1.f, qs.data(), d, ks.data(), d,
                        0.f, scores.data(), l);
            softmax_rows(scores.data(), l, l);
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, l, d, l, 1.f, scores.data(), l, vs.data(),
                        d, 0.f, result.data(), d);
            for (int i = 0; i < l; ++i)
                for (int j = 0; j < d; ++j)
                    y.data[(n * l + i) * c + h * d + j] = result[i * d + j];
        }
    return y;
}
std::vector<Decoded> decode(const Tensor &logits, const std::vector<std::string> &chars) {
    require(logits.shape.size() == 3 && logits.shape[2] == int(chars.size()), "Decoder shape mismatch");
    int b = logits.shape[0], l = logits.shape[1], c = logits.shape[2];
    std::vector<Decoded> result;
    std::vector<float> scratch(c);
    for (int n = 0; n < b; ++n) {
        Decoded row{"", 0, {}};
        int previous = -1, kept = 0;
        for (int t = 0; t < l; ++t) {
            const float *src = logits.data.data() + (n * l + t) * c;
            float maximum;
            vDSP_Length index;
            vDSP_maxvi(src, 1, &maximum, &index, c);
            int token = int(index);
            row.tokens.push_back(token);
            if (token && token != previous) {
                row.text += chars[token];
                ++kept;
                float minus = -src[token];
                vDSP_vsadd(src, 1, &minus, scratch.data(), 1, c);
                vvexpf(scratch.data(), scratch.data(), &c);
                float sum = 0;
                vDSP_sve(scratch.data(), 1, &sum, c);
                row.score += 1.f / sum;
            }
            previous = token;
        }
        row.score = kept ? row.score / kept : 0.f;
        result.push_back(std::move(row));
    }
    return result;
}
bool all_finite(const Tensor &x) {
    std::atomic<bool> valid{true};
    parallel_for(x.data.size(), x.data.size(), [&](size_t begin, size_t end) {
        unsigned flags = 0;
        for (size_t i = begin; i < end; ++i)
            flags |= (std::bit_cast<uint32_t>(x.data[i]) & 0x7f800000u) == 0x7f800000u;
        if (flags)
            valid.store(false, std::memory_order_relaxed);
    });
    return valid.load(std::memory_order_relaxed);
}
std::vector<Decoded> recognize_text(const Tensor &x, const Weights &weights,
                                    const std::vector<std::string> &chars) {
    require(x.shape.size() == 4 && x.shape[0] >= 1 && x.shape[0] <= 6 && x.shape[1] == 3 &&
                x.shape[2] == 48 && x.shape[3] >= 320 && x.shape[3] <= 4096,
            "Invalid recognition input shape");
    if (x.shape[0] == 1) {
        auto logits = recognize(x, weights);
        require(all_finite(logits), "Non-finite model output");
        return decode(logits, chars);
    }
    Tensor line({1, 3, 48, x.shape[3]}, false);
    std::vector<Decoded> result;
    result.reserve(x.shape[0]);
    for (int i = 0; i < x.shape[0]; ++i) {
        std::copy_n(x.data.data() + size_t(i) * line.data.size(), line.data.size(), line.data.data());
        auto logits = recognize(line, weights);
        require(all_finite(logits), "Non-finite model output");
        auto decoded = decode(logits, chars);
        result.push_back(std::move(decoded[0]));
    }
    return result;
}
std::string json_string(const std::string &s) {
    std::ostringstream o;
    o << '"';
    for (unsigned char c : s) {
        if (c == '"' || c == '\\')
            o << '\\' << c;
        else if (c < 32)
            o << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(c);
        else
            o << c;
    }
    o << '"';
    return o.str();
}
} // namespace textpicker
