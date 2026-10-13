#include "engine.hpp"
#include <algorithm>
#include <cmath>
#include <iostream>
using namespace textpicker;
static int checks = 0;
static void check(bool x) {
    require(x, "Primitive test failed");
    ++checks;
}
static Tensor sample(std::vector<int> shape, float phase = 0) {
    Tensor t(shape);
    for (size_t i = 0; i < t.data.size(); ++i)
        t.data[i] = std::sin(float(i) * 0.173f + phase) * 0.8f;
    return t;
}
static void close(const Tensor &a, const Tensor &b, float tol = 2e-5f) {
    check(a.shape == b.shape);
    float error = 0;
    for (size_t i = 0; i < a.data.size(); ++i)
        error = std::max(error, std::abs(a.data[i] - b.data[i]));
    check(error <= tol);
}
static void test_conv(int groups, int oc, int kh, int kw, int sh, int sw, int ph, int pw) {
    auto x = sample({2, 4, 7, 9});
    int icg = 4 / groups, ocg = oc / groups;
    auto weight = sample({oc, icg, kh, kw}, 0.4f), bias = sample({oc}, 0.3f);
    auto y = conv(x, weight.data.data(), bias.data.data(), oc, icg, kh, kw, sh, sw, ph, pw, groups);
    int oh = (7 + 2 * ph - kh) / sh + 1, ow = (9 + 2 * pw - kw) / sw + 1;
    Tensor ref({2, oc, oh, ow});
    for (int b = 0; b < 2; ++b)
        for (int c = 0; c < oc; ++c)
            for (int oy = 0; oy < oh; ++oy)
                for (int ox = 0; ox < ow; ++ox) {
                    double sum = bias.data[c];
                    int g = c / ocg;
                    for (int ic = 0; ic < icg; ++ic)
                        for (int ky = 0; ky < kh; ++ky)
                            for (int kx = 0; kx < kw; ++kx) {
                                int iy = oy * sh - ph + ky, ix = ox * sw - pw + kx;
                                if (iy >= 0 && iy < 7 && ix >= 0 && ix < 9)
                                    sum += double(x.data[((b * 4 + g * icg + ic) * 7 + iy) * 9 + ix]) *
                                           weight.data[((c * icg + ic) * kh + ky) * kw + kx];
                            }
                    ref.data[((b * oc + c) * oh + oy) * ow + ox] = float(sum);
                }
    close(y, ref);
}
int run_tests() {
    try {
        test_conv(1, 6, 3, 2, 2, 1, 1, 1);
        test_conv(2, 6, 3, 3, 1, 2, 1, 1);
        test_conv(4, 4, 9, 9, 1, 1, 4, 4);
        test_conv(4, 4, 13, 13, 1, 1, 6, 6);
        auto source = sample({2, 3, 13, 17});
        for (int factor : {1, 2, 4, 8}) {
            auto up = upsample(source, factor);
            Tensor expected({2, 3, 13 * factor, 17 * factor}, false);
            for (int bc = 0; bc < 6; ++bc)
                for (int y = 0; y < 13 * factor; ++y)
                    for (int x = 0; x < 17 * factor; ++x)
                        expected.data[(bc * 13 * factor + y) * 17 * factor + x] =
                            source.data[(bc * 13 + y / factor) * 17 + x / factor];
            close(up, expected, 0);
        }
        for (int height : {3, 130}) {
            int width = 129, ic = 3, oc = 5;
            auto tx = sample({2, ic, height, width}), tw = sample({ic, oc, 2, 2}), tb = sample({oc});
            auto actual = transpose2(tx, tw.data.data(), tb.data.data(), ic, oc);
            Tensor expected({2, oc, height * 2, width * 2}, false);
            for (int n = 0; n < 2; ++n)
                for (int c = 0; c < oc; ++c)
                    for (int y = 0; y < height; ++y)
                        for (int x = 0; x < width; ++x)
                            for (int ky = 0; ky < 2; ++ky)
                                for (int kx = 0; kx < 2; ++kx) {
                                    double sum = tb.data[c];
                                    for (int i = 0; i < ic; ++i)
                                        sum += double(tx.data[((n * ic + i) * height + y) * width + x]) *
                                               tw.data[((i * oc + c) * 2 + ky) * 2 + kx];
                                    expected.data[((n * oc + c) * height * 2 + y * 2 + ky) * width * 2 +
                                                  x * 2 + kx] = float(sum);
                                }
            close(actual, expected, 2e-6f);
        }
        auto nonlinear = sample({100003});
        for (auto kind : {Activation::HardSigmoidClip, Activation::Sigmoid}) {
            auto actual = activate(nonlinear, kind);
            Tensor expected(nonlinear.shape, false);
            for (size_t i = 0; i < nonlinear.data.size(); ++i) {
                double x = nonlinear.data[i];
                expected.data[i] = float(kind == Activation::Sigmoid ? 1. / (1. + std::exp(-x))
                                                                     : std::clamp(x * .2 + .5, 0., 1.));
            }
            close(actual, expected, 1e-7f);
        }
        test_conv(4, 4, 5, 3, 2, 1, 2, 1);
        test_conv(4, 4, 3, 3, 1, 1, 0, 0);
        test_conv(1, 6, 1, 1, 1, 1, 0, 0);
        test_conv(2, 6, 1, 1, 1, 1, 0, 0);
        auto x = sample({2, 3, 4}), w = sample({5, 4}, 0.2f), b = sample({5}, 0.3f);
        auto l = linear(x, w.data.data(), b.data.data(), 4, 5);
        Tensor lr({2, 3, 5});
        for (int r = 0; r < 6; ++r)
            for (int j = 0; j < 5; ++j) {
                double sum = b.data[j];
                for (int i = 0; i < 4; ++i)
                    sum += double(x.data[r * 4 + i]) * w.data[j * 4 + i];
                lr.data[r * 5 + j] = float(sum);
            }
        close(l, lr);
        auto gamma = sample({4}, 0.7f), beta = sample({4}, 0.9f);
        auto norm = layer_norm(x, gamma.data.data(), beta.data.data(), 1e-5f);
        Tensor nr(x.shape);
        for (int r = 0; r < 6; ++r) {
            double mean = 0, var = 0;
            for (int c = 0; c < 4; ++c)
                mean += x.data[r * 4 + c] / 4.;
            for (int c = 0; c < 4; ++c)
                var += std::pow(x.data[r * 4 + c] - mean, 2) / 4.;
            for (int c = 0; c < 4; ++c)
                nr.data[r * 4 + c] =
                    float((x.data[r * 4 + c] - mean) / std::sqrt(var + 1e-5) * gamma.data[c] + beta.data[c]);
        }
        close(norm, nr, 1e-6f);
        auto image = sample({2, 3, 5, 7});
        close(from_sequence(to_sequence(image), image.shape), image, 0);
        auto pad = pad_bottom_right(image);
        check(pad.shape == std::vector<int>({2, 3, 6, 8}));
        for (int bc = 0; bc < 6; ++bc)
            for (int r = 0; r < 6; ++r)
                for (int c = 0; c < 8; ++c)
                    check(pad.data[(bc * 6 + r) * 8 + c] ==
                          (r < 5 && c < 7 ? image.data[(bc * 5 + r) * 7 + c] : 0));
        auto cat = concat_channels(image, image);
        check(cat.shape == std::vector<int>({2, 6, 5, 7}));
        for (int batch = 0; batch < 2; ++batch)
            for (int c = 0; c < 6; ++c)
                for (int p = 0; p < 35; ++p)
                    check(cat.data[(batch * 6 + c) * 35 + p] == image.data[(batch * 3 + c % 3) * 35 + p]);
        for (bool avg : {false, true}) {
            auto p = pool(image, 2, 3, 2, 2, avg);
            Tensor ref({2, 3, 2, 3});
            for (int bc = 0; bc < 6; ++bc)
                for (int r = 0; r < 2; ++r)
                    for (int c = 0; c < 3; ++c) {
                        float value = avg ? 0.f : -INFINITY;
                        for (int dy = 0; dy < 2; ++dy)
                            for (int dx = 0; dx < 3; ++dx) {
                                float v = image.data[(bc * 5 + r * 2 + dy) * 7 + c * 2 + dx];
                                value = avg ? value + v : std::max(value, v);
                            }
                        ref.data[(bc * 2 + r) * 3 + c] = avg ? value / 6 : value;
                    }
            close(p, ref, 0);
        }
        auto mean = spatial_mean(image);
        auto scaled = channel_multiply(image, mean);
        auto sum = add(image, image);
        for (int bc = 0; bc < 6; ++bc) {
            double m = 0;
            for (int p = 0; p < 35; ++p)
                m += image.data[bc * 35 + p] / 35.;
            check(std::abs(m - mean.data[bc]) < 1e-6);
            for (int p = 0; p < 35; ++p) {
                check(std::abs(scaled.data[bc * 35 + p] - image.data[bc * 35 + p] * mean.data[bc]) < 1e-6);
                check(sum.data[bc * 35 + p] == 2 * image.data[bc * 35 + p]);
            }
        }
        Tensor range({200001});
        for (size_t i = 0; i < range.data.size(); ++i)
            range.data[i] = -14.f + 28.f * float(i) / 200000.f;
        auto gelu = activate(range, Activation::GELU);
        double max_error = 0;
        for (size_t i = 0; i < range.data.size(); ++i) {
            double a = range.data[i], ref = 0.5 * a * (1 + std::erf(a / std::sqrt(2.)));
            max_error = std::max(max_error, std::abs(double(gelu.data[i]) - ref));
        }
        check(max_error < 1e-6);
        for (auto kind : {Activation::ReLU, Activation::SiLU, Activation::HardSigmoid}) {
            auto out = activate(range, kind);
            double err = 0;
            for (size_t i = 0; i < range.data.size(); ++i) {
                double a = range.data[i];
                double ref = kind == Activation::ReLU   ? std::max(0., a)
                             : kind == Activation::SiLU ? a / (1 + std::exp(-a))
                                                        : std::clamp(a / 6. + 0.5, 0., 1.);
                err = std::max(err, std::abs(out.data[i] - ref));
            }
            check(err < 2e-6);
        }
        auto q = sample({2, 5, 8}, 0.1f), k = sample({2, 5, 8}, 0.5f), v = sample({2, 5, 8}, 0.7f);
        auto att = attention(q, k, v, 2);
        Tensor ar(q.shape);
        for (int batch = 0; batch < 2; ++batch)
            for (int h = 0; h < 2; ++h)
                for (int t = 0; t < 5; ++t) {
                    double scores[5], den = 0;
                    for (int j = 0; j < 5; ++j) {
                        double dot = 0;
                        for (int c = 0; c < 4; ++c)
                            dot += double(q.data[(batch * 5 + t) * 8 + h * 4 + c]) *
                                   k.data[(batch * 5 + j) * 8 + h * 4 + c];
                        scores[j] = std::exp(dot / 2);
                        den += scores[j];
                    }
                    for (int c = 0; c < 4; ++c) {
                        double total = 0;
                        for (int j = 0; j < 5; ++j)
                            total += scores[j] / den * v.data[(batch * 5 + j) * 8 + h * 4 + c];
                        ar.data[(batch * 5 + t) * 8 + h * 4 + c] = float(total);
                    }
                }
        close(att, ar, 1e-6f);
        Tensor logits({1, 7, 4});
        std::fill(logits.data.begin(), logits.data.end(), -10.f);
        std::vector<int> winners = {1, 1, 0, 1, 2, 0, 3};
        for (int i = 0; i < 7; ++i)
            logits.data[i * 4 + winners[i]] = 10.f;
        auto decoded = decode(logits, {"_", "A", "ü", " "});
        check(decoded[0].text == "AAü " && decoded[0].score > 0.999f && decoded[0].tokens == winners);
        Tensor blank({1, 4, 4});
        decoded = decode(blank, {"_", "A", "ü", " "});
        check(decoded[0].text.empty() && decoded[0].score == 0);
        bool rejected = false;
        try {
            Tensor invalid({0, 3});
        } catch (...) {
            rejected = true;
        }
        check(rejected);
        rejected = false;
        try {
            Tensor invalid({INT32_MAX, INT32_MAX});
        } catch (...) {
            rejected = true;
        }
        check(rejected);
        rejected = false;
        try {
            add(image, x);
        } catch (...) {
            rejected = true;
        }
        check(rejected);
        const auto active = buffer_stats().active_bytes;
        {
            FloatBuffer a(17);
            for (float v : a)
                check(v == 0);
            std::fill(a.begin(), a.end(), 7.f);
            FloatBuffer copied(a);
            check(copied[4] == 7);
            FloatBuffer moved(std::move(a));
            check(a.size() == 0 && moved.size() == 17 && moved[4] == 7);
            copied = moved;
            copied[4] = 3;
            check(moved[4] == 7);
            moved.release();
            moved.release();
            check(moved.size() == 0);
            FloatBuffer cleared(17);
            for (float v : cleared)
                check(v == 0);
            FloatBuffer large(9 * 1024 * 1024, false);
            large[0] = 3;
            large[large.size() - 1] = 4;
        }
        check(buffer_stats().active_bytes == active);
        check(buffer_stats().cached_bytes <= 32 * 1024 * 1024);
        auto preserved = sample({1, 2, 3});
        auto inplace = activate_reuse(Tensor(preserved), Activation::GELU);
        close(inplace, activate(preserved, Activation::GELU), 0);
        close(add_reuse(Tensor(preserved), preserved), add(preserved, preserved), 0);
        close(channel_multiply_reuse(Tensor(image), mean), scaled, 0);
        close(layer_norm_reuse(Tensor(x), gamma.data.data(), beta.data.data(), 1e-5f), norm, 0);
        Tensor tie({1, 3, 4});
        tie.data[1] = 2;
        tie.data[2] = 2;
        tie.data[10] = 2;
        tie.data[11] = 2;
        auto tied = decode(tie, {"_", "A", "ü", " "});
        check(tied[0].tokens == std::vector<int>({1, 0, 2}) && tied[0].text == "Aü");
        check(all_finite(tie));
        tie.data[7] = NAN;
        check(!all_finite(tie));
        tie.data[7] = INFINITY;
        check(!all_finite(tie));
        std::cout << "{\"checks\":" << checks << ",\"gelu_max_abs_vs_double_erf\":" << max_error << "}\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
int main(int argc, char **argv) {
    if (argc == 2) {
        // Deliberate sanitizer-negative controls, run only by the test harness.
        FloatBuffer b(7);
        volatile float *pointer = b.data();
        if (std::string(argv[1]) == "--probe-oob")
            pointer[7] = 1;
        else if (std::string(argv[1]) == "--probe-uaf") {
            b.release();
            pointer[0] = 1;
        } else
            return 2;
        return 0;
    }
    int result = run_tests();
    if (buffer_stats().active_bytes != 0) {
        std::cerr << "Leaked tensor ownership\n";
        return 1;
    }
    return result;
}
