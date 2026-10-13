#pragma once
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <dispatch/dispatch.h>
#include <stdexcept>
namespace textpicker {
inline size_t kernel_workers() {
    static const size_t workers = []() -> size_t {
        const char *v = std::getenv("TEXTPICKER_THREADS");
        if (!v || !std::strcmp(v, "4"))
            return 4;
        if (!std::strcmp(v, "1"))
            return 1;
        if (!std::strcmp(v, "2"))
            return 2;
        throw std::runtime_error("TEXTPICKER_THREADS must be 1, 2 or 4");
    }();
    return workers;
}
// Synchronous range partitioning, never nested by the engine. Tensor ownership,
// allocations and profiling stay on the caller thread; callbacks own disjoint
// output ranges. BLAS calls happen outside these parallel regions.
template <class F> void parallel_for(size_t count, size_t work, F fn) {
    size_t tasks = work < 65536 ? 1 : std::min(count, kernel_workers());
    if (tasks <= 1) {
        fn(0, count);
        return;
    }
    struct Job {
        size_t count, tasks;
        F &fn;
    } job{count, tasks, fn};
    dispatch_apply_f(tasks, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), &job,
                     [](void *opaque, size_t i) {
                         auto &j = *static_cast<Job *>(opaque);
                         j.fn(j.count * i / j.tasks, j.count * (i + 1) / j.tasks);
                     });
}
} // namespace textpicker
