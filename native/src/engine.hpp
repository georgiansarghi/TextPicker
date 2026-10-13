#pragma once
#include "buffer.hpp"
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace textpicker {
void require(bool condition, const char *message);
size_t elements(const std::vector<int> &shape);
struct Tensor {
    std::vector<int> shape;
    FloatBuffer data;
    explicit Tensor(std::vector<int> dimensions, bool zero = true);
    void release() {
        data.release();
    }
};
class Weights {
    void *mapping_ = nullptr;
    size_t length_ = 0;

  public:
    explicit Weights(const std::string &path);
    Weights(const std::string &path, size_t expected_bytes, const char *expected_hash);
    ~Weights();
    Weights(const Weights &) = delete;
    Weights &operator=(const Weights &) = delete;
    const float *at(size_t offset) const;
};
struct Trace {
    std::filesystem::path directory;
    void record(const std::string &name, const Tensor &tensor);
};
const char *weights_sha256();
size_t weights_bytes();
const char *dictionary_sha256();
std::string sha256(const void *, size_t);
Tensor recognize(const Tensor &, const Weights &, Trace * = nullptr);
Tensor detect(const Tensor &, const Weights &, Trace * = nullptr);
const char *detector_sha256();
size_t detector_bytes();
Tensor transpose2(const Tensor &, const float *, const float *, int, int);
Tensor upsample(const Tensor &, int);
Tensor conv(const Tensor &, const float *, const float *, int, int, int, int, int, int, int, int, int);
Tensor linear(const Tensor &, const float *, const float *, int, int);
Tensor layer_norm(const Tensor &, const float *, const float *, float);
enum class Activation { ReLU, SiLU, HardSigmoid, GELU, HardSigmoidClip, Sigmoid };
Tensor activate(const Tensor &, Activation);
Tensor pool(const Tensor &, int, int, int, int, bool);
Tensor pad_bottom_right(const Tensor &);
Tensor concat_channels(const Tensor &, const Tensor &);
Tensor add(const Tensor &, const Tensor &);
Tensor spatial_mean(const Tensor &);
Tensor channel_multiply(const Tensor &, const Tensor &);
Tensor to_sequence(const Tensor &);
Tensor from_sequence(const Tensor &, const std::vector<int> &);
Tensor attention(const Tensor &, const Tensor &, const Tensor &, int);
// Ownership-taking variants are selected only after static last-use analysis.
Tensor activate_reuse(Tensor, Activation);
Tensor add_reuse(Tensor, const Tensor &);
Tensor channel_multiply_reuse(Tensor, const Tensor &);
Tensor layer_norm_reuse(Tensor, const float *, const float *, float);
struct Decoded {
    std::string text;
    float score;
    std::vector<int> tokens;
};
std::vector<std::string> load_dictionary(const std::string &);
std::vector<Decoded> decode(const Tensor &, const std::vector<std::string> &);
bool all_finite(const Tensor &);
// Text path streams independent lines, never keeping the whole batch of logits.
std::vector<Decoded> recognize_text(const Tensor &, const Weights &, const std::vector<std::string> &);
std::string json_string(const std::string &);
void write_tensor(const std::filesystem::path &, const Tensor &);
} // namespace textpicker
