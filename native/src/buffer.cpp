#include "buffer.hpp"
#include <algorithm>
#include <array>
#include <cstring>
#include <mutex>
#include <new>
#include <stdexcept>
#include <sys/mman.h>
#include <unistd.h>
#if __has_feature(address_sanitizer)
#include <sanitizer/asan_interface.h>
#else
#define ASAN_POISON_MEMORY_REGION(p, n) ((void)0)
#define ASAN_UNPOISON_MEMORY_REGION(p, n) ((void)0)
#endif
namespace textpicker {
namespace {
constexpr size_t budget = 32 * 1024 * 1024;
struct Block {
    float *pointer = nullptr;
    size_t bytes = 0;
};
struct Arena {
    std::array<Block, 64> free{};
    size_t page = size_t(getpagesize());
    BufferStats stats;
    std::mutex mutex;
    ~Arena() {
        for (auto b : free)
            if (b.pointer)
                munmap(b.pointer, b.bytes);
    }
    Block take(size_t bytes, bool zero) {
        std::lock_guard guard(mutex);
        const size_t capacity = (bytes + page - 1) / page * page;
        size_t best = free.size();
        for (size_t i = 0; i < free.size(); ++i)
            if (free[i].pointer && free[i].bytes >= capacity &&
                (best == free.size() || free[i].bytes < free[best].bytes))
                best = i;
        Block block;
        if (best < free.size()) {
            block = free[best];
            free[best] = {};
            stats.cached_bytes -= block.bytes;
            ++stats.reuses;
            ASAN_UNPOISON_MEMORY_REGION(block.pointer, block.bytes);
            if (zero)
                std::memset(block.pointer, 0, bytes);
        } else {
            void *p = mmap(nullptr, capacity, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
            if (p == MAP_FAILED)
                throw std::bad_alloc();
            block = {static_cast<float *>(p), capacity};
            stats.mapped_bytes += capacity;
            ++stats.maps;
            stats.peak_mapped_bytes = std::max(stats.peak_mapped_bytes, stats.mapped_bytes);
            ASAN_UNPOISON_MEMORY_REGION(block.pointer, block.bytes);
            // Anonymous mappings are initially zero, without explicitly touching pages.
        }
        stats.active_bytes += bytes;
        stats.peak_active_bytes = std::max(stats.peak_active_bytes, stats.active_bytes);
        ASAN_POISON_MEMORY_REGION(reinterpret_cast<char *>(block.pointer) + bytes, block.bytes - bytes);
        return block;
    }
    void give(Block block, size_t used) noexcept {
        std::lock_guard guard(mutex);
        stats.active_bytes -= used;
        // Keep bounded scratch space, not a cache of the maximum-sized logits.
        if (block.bytes <= budget - stats.cached_bytes) {
            for (auto &slot : free)
                if (!slot.pointer) {
                    slot = block;
                    stats.cached_bytes += block.bytes;
                    ASAN_POISON_MEMORY_REGION(block.pointer, block.bytes);
                    return;
                }
        }
        ASAN_UNPOISON_MEMORY_REGION(block.pointer, block.bytes);
        munmap(block.pointer, block.bytes);
        stats.mapped_bytes -= block.bytes;
    }
};
Arena &pool() {
    static Arena arena;
    return arena;
}
} // namespace
BufferStats buffer_stats() {
    auto &arena = pool();
    std::lock_guard guard(arena.mutex);
    return arena.stats;
}
FloatBuffer::FloatBuffer(size_t count, bool zero) : count_(count) {
    if (count > 64 * 1024 * 1024)
        throw std::length_error("Float buffer exceeds 64M elements");
    if (count) {
        auto block = pool().take(count * 4, zero);
        ptr_ = block.pointer;
        capacity_ = block.bytes;
    }
}
FloatBuffer::~FloatBuffer() {
    release();
}
void FloatBuffer::release() noexcept {
    if (ptr_)
        pool().give({ptr_, capacity_}, count_ * 4);
    ptr_ = nullptr;
    count_ = capacity_ = 0;
}
FloatBuffer::FloatBuffer(const FloatBuffer &other) : FloatBuffer(other.count_, false) {
    if (count_)
        std::memcpy(ptr_, other.ptr_, count_ * 4);
}
FloatBuffer &FloatBuffer::operator=(const FloatBuffer &other) {
    if (this != &other) {
        FloatBuffer copy(other);
        swap(copy);
    }
    return *this;
}
FloatBuffer::FloatBuffer(FloatBuffer &&other) noexcept {
    swap(other);
}
FloatBuffer &FloatBuffer::operator=(FloatBuffer &&other) noexcept {
    if (this != &other) {
        release();
        swap(other);
    }
    return *this;
}
void FloatBuffer::swap(FloatBuffer &other) noexcept {
    std::swap(ptr_, other.ptr_);
    std::swap(count_, other.count_);
    std::swap(capacity_, other.capacity_);
}
} // namespace textpicker
