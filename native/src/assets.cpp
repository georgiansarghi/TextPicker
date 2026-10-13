#include "engine.hpp"
#include <CommonCrypto/CommonDigest.h>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace textpicker {
namespace {
class ReadOnlyFile {
  public:
    const int fd;
    explicit ReadOnlyFile(const std::string &path)
        : fd(open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK)) {
        require(fd >= 0, "Cannot open native model asset");
    }
    ~ReadOnlyFile() {
        close(fd);
    }
    ReadOnlyFile(const ReadOnlyFile &) = delete;
    ReadOnlyFile &operator=(const ReadOnlyFile &) = delete;

    size_t size(size_t maximum) const {
        struct stat info{};
        require(fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0 &&
                    uint64_t(info.st_size) <= maximum,
                "Invalid native model asset size/type");
        return size_t(info.st_size);
    }
};
} // namespace

std::string sha256(const void *bytes, size_t count) {
    require(count <= UINT32_MAX, "Hash input too large");
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, CC_LONG(count), hash);
    std::ostringstream out;
    for (auto byte : hash)
        out << std::hex << std::setw(2) << std::setfill('0') << int(byte);
    return out.str();
}

Weights::Weights(const std::string &path) : Weights(path, weights_bytes(), weights_sha256()) {}

Weights::Weights(const std::string &path, size_t expected_bytes, const char *expected_hash) {
    require(expected_bytes >= 64 && expected_bytes <= UINT32_MAX && expected_hash,
            "Invalid model descriptor");
    ReadOnlyFile file(path);
    length_ = file.size(expected_bytes);
    require(length_ == expected_bytes, "Incorrect weight file size");
    mapping_ = mmap(nullptr, length_, PROT_READ, MAP_PRIVATE, file.fd, 0);
    if (mapping_ == MAP_FAILED) {
        mapping_ = nullptr;
        throw std::runtime_error("Cannot map weights");
    }
    try {
        require(std::memcmp(mapping_, "TOCRW001", 8) == 0 && sha256(mapping_, length_) == expected_hash,
                "Weight integrity mismatch");
    } catch (...) {
        munmap(mapping_, length_);
        mapping_ = nullptr;
        throw;
    }
}

Weights::~Weights() {
    if (mapping_)
        munmap(mapping_, length_);
}

const float *Weights::at(size_t offset) const {
    require(offset >= 64 && offset % 64 == 0 && offset <= length_ - sizeof(float),
            "Invalid compiled weight offset");
    return reinterpret_cast<const float *>(static_cast<const char *>(mapping_) + offset);
}

std::vector<std::string> load_dictionary(const std::string &path) {
    ReadOnlyFile file(path);
    std::string bytes(file.size(1024 * 1024), '\0');
    size_t offset = 0;
    while (offset < bytes.size()) {
        auto count = read(file.fd, bytes.data() + offset, bytes.size() - offset);
        if (count < 0 && errno == EINTR)
            continue;
        require(count > 0, "Cannot read complete dictionary");
        offset += size_t(count);
    }
    require(sha256(bytes.data(), bytes.size()) == dictionary_sha256(), "Dictionary integrity mismatch");
    offset = 0;
    auto take = [&]() {
        require(bytes.size() - offset >= sizeof(uint32_t), "Truncated dictionary");
        uint32_t value;
        std::memcpy(&value, bytes.data() + offset, sizeof(value));
        offset += sizeof(value);
        return value;
    };
    const uint32_t count = take();
    require(count == 18710, "Incorrect alphabet size");
    std::vector<std::string> result;
    result.reserve(count);
    for (uint32_t i = 0; i < count; ++i) {
        const auto length = take();
        require(length <= bytes.size() - offset, "Truncated character");
        result.emplace_back(bytes.substr(offset, length));
        offset += length;
    }
    require(offset == bytes.size(), "Trailing dictionary bytes");
    return result;
}
} // namespace textpicker
