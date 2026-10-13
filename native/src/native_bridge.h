#pragma once
#include <stddef.h>
#include <stdint.h>

// Shared limits for the Swift decoder and C++ boundary. All sizes are bytes/pixels,
// not points. The worker is single-request-at-a-time; handles are not thread-safe.
enum {
    TEXTPICKER_MAX_IMAGE_PIXELS = 20000000,
    TEXTPICKER_MAX_IMAGE_SIDE = 32768,
    TEXTPICKER_MAX_FILE_BYTES = 128 * 1024 * 1024,
    TEXTPICKER_MAX_TEXT_BYTES = 262144
};

#ifdef __cplusplus
#define TEXTPICKER_NOEXCEPT noexcept
extern "C" {
#else
#define TEXTPICKER_NOEXCEPT
#endif

// Models must be the pinned, immutable assets. Null indicates failure; error()
// remains valid until the next API operation on this thread. No exceptions cross C.
void *textpicker_native_create(const char *directory) TEXTPICKER_NOEXCEPT;
int32_t textpicker_native_warmup(void *engine) TEXTPICKER_NOEXCEPT;
void textpicker_native_destroy(void *engine) TEXTPICKER_NOEXCEPT;

// Input is borrowed opaque BGRA8 for the duration of this synchronous call.
// byte_count must cover height*stride (including the last row's padding).
// The full strided span is bounded to MAX_FILE_BYTES; packed rows are preferred.
// A successful result is owned UTF-8, including the empty string; free exactly
// once with native_free. A failed call never returns partially recognized text.
char *textpicker_native_predict(void *engine, const uint8_t *bgra, size_t byte_count, int32_t width,
                             int32_t height, int32_t stride) TEXTPICKER_NOEXCEPT;
const char *textpicker_native_error(void) TEXTPICKER_NOEXCEPT;
void textpicker_native_free(char *value) TEXTPICKER_NOEXCEPT;
#ifdef __cplusplus
}
#endif
#undef TEXTPICKER_NOEXCEPT
