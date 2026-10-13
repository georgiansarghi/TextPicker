#pragma once
#include <cstddef>
namespace textpicker {
struct BufferStats {
    size_t active_bytes = 0, peak_active_bytes = 0, cached_bytes = 0, mapped_bytes = 0, peak_mapped_bytes = 0;
    size_t maps = 0, reuses = 0;
};
BufferStats buffer_stats();
// Owning page-aligned float storage. A bounded, synchronized free list reuses
// small working buffers; large buffers are unmapped immediately on last use.
class FloatBuffer {
    float *ptr_ = nullptr;
    size_t count_ = 0, capacity_ = 0;

  public:
    explicit FloatBuffer(size_t count = 0, bool zero = true);
    ~FloatBuffer();
    FloatBuffer(const FloatBuffer &);
    FloatBuffer &operator=(const FloatBuffer &);
    FloatBuffer(FloatBuffer &&) noexcept;
    FloatBuffer &operator=(FloatBuffer &&) noexcept;
    void release() noexcept;
    void swap(FloatBuffer &) noexcept;
    float *data() {
        return ptr_;
    }
    const float *data() const {
        return ptr_;
    }
    size_t size() const {
        return count_;
    }
    float *begin() {
        return ptr_;
    }
    float *end() {
        return count_ ? ptr_ + count_ : ptr_;
    }
    const float *begin() const {
        return ptr_;
    }
    const float *end() const {
        return count_ ? ptr_ + count_ : ptr_;
    }
    float &operator[](size_t i) {
        return ptr_[i];
    }
    const float &operator[](size_t i) const {
        return ptr_[i];
    }
};
} // namespace textpicker
