#include <CLI/CLI.hpp>
#include <CommonCrypto/CommonDigest.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cerrno>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <numeric>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <unistd.h>
#include <vector>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <sys/stdio.h>

#include "bindings.h"
#include "input_data.hpp"
#include "loaders.hpp"
#include "model.hpp"
#include "random_iter.hpp"

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace {

volatile std::sig_atomic_t cancellationSignal = 0;

void observeCancellation(int signal) {
    cancellationSignal = signal;
}

class EventWriter {
public:
    explicit EventWriter(int descriptor) : descriptor_(descriptor) {
        if (descriptor_ >= 0 && ::fcntl(descriptor_, F_GETFD) == -1) {
            throw std::runtime_error("event file descriptor is not open");
        }
    }

    bool enabled() const { return descriptor_ >= 0; }

    void emit(const std::string &event, json fields = json::object()) {
        if (!enabled()) return;
        fields["event"] = event;
        fields["schema_version"] = 1;
        fields["sequence"] = ++sequence_;
        std::string record = fields.dump();
        record.push_back('\n');
        const char *cursor = record.data();
        std::size_t remaining = record.size();
        while (remaining > 0) {
            const ssize_t written = ::write(descriptor_, cursor, remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                throw std::runtime_error(
                    "cannot write event file descriptor: " + std::string(std::strerror(errno))
                );
            }
            cursor += written;
            remaining -= static_cast<std::size_t>(written);
        }
    }

private:
    int descriptor_;
    std::uint64_t sequence_ = 0;
};

struct TrainingProfileConfig {
    const char *name;
    int iterationLimit;
    int plateauWindow;
    int numDownscales;
};

constexpr std::array<TrainingProfileConfig, 3> trainingProfiles = {{
    {"fast", 3000, 400, 0},
    {"balanced", 7000, 800, 0},
    {"high-detail", 15000, 1500, 0},
}};

const TrainingProfileConfig &trainingProfileNamed(const std::string &name) {
    const auto match = std::find_if(
        trainingProfiles.begin(), trainingProfiles.end(),
        [&](const TrainingProfileConfig &candidate) { return name == candidate.name; }
    );
    if (match == trainingProfiles.end()) {
        throw std::runtime_error("--profile must be fast, balanced, or high-detail");
    }
    return *match;
}

struct TrainingIdentity {
    std::string inputDigest;
    std::string geometryDigest;
};

struct TrainerCheckpointState {
    int iteration = 0;
    int lastImprovementIteration = 0;
    std::vector<double> bestCameraLosses;
    std::optional<double> latestLoss;
    int latestLossIteration = 0;
    double elapsedSeconds = 0;
};

struct CheckpointReceipt {
    int iteration;
    std::string generation;
    std::string payloadDigest;
    std::uintmax_t payloadBytes;
};

constexpr std::uintmax_t maximumCheckpointManifestBytes = 4 * 1024 * 1024;
constexpr std::uintmax_t maximumCheckpointPayloadBytes = 32ULL * 1024 * 1024 * 1024;

void throwSystemError(const std::string &operation, const fs::path &path);

class Sha256Accumulator {
public:
    Sha256Accumulator() {
        if (CC_SHA256_Init(&context_) != 1) {
            throw std::runtime_error("cannot initialize SHA-256");
        }
    }

    void update(const void *bytes, std::size_t count) {
        const auto *cursor = static_cast<const unsigned char *>(bytes);
        while (count > 0) {
            const CC_LONG chunk = static_cast<CC_LONG>(std::min<std::size_t>(
                count, std::numeric_limits<CC_LONG>::max()
            ));
            if (CC_SHA256_Update(&context_, cursor, chunk) != 1) {
                throw std::runtime_error("cannot update SHA-256");
            }
            cursor += chunk;
            count -= chunk;
        }
    }

    void update(const std::string &value) {
        update(value.data(), value.size());
    }

    void updateInteger(std::uint64_t value) {
        unsigned char encoded[8];
        for (int index = 7; index >= 0; --index) {
            encoded[index] = static_cast<unsigned char>(value & 0xff);
            value >>= 8;
        }
        update(encoded, sizeof(encoded));
    }

    std::string finish() {
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        if (CC_SHA256_Final(digest, &context_) != 1) {
            throw std::runtime_error("cannot finish SHA-256");
        }
        std::ostringstream result;
        result << std::hex << std::setfill('0');
        for (unsigned char byte : digest) {
            result << std::setw(2) << static_cast<unsigned int>(byte);
        }
        return result.str();
    }

private:
    CC_SHA256_CTX context_ {};
};

struct OpenFile {
    explicit OpenFile(const fs::path &path) {
        descriptor = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW);
        if (descriptor < 0) throwSystemError("cannot open", path);
    }

    ~OpenFile() {
        if (descriptor >= 0) ::close(descriptor);
    }

    OpenFile(const OpenFile &) = delete;
    OpenFile &operator=(const OpenFile &) = delete;
    int descriptor = -1;
};

struct stat requireRegularFile(const fs::path &path, bool requireSingleLink = false) {
    struct stat metadata {};
    if (::lstat(path.c_str(), &metadata) != 0) throwSystemError("cannot inspect", path);
    if (!S_ISREG(metadata.st_mode) || (requireSingleLink && metadata.st_nlink != 1)) {
        throw std::runtime_error("expected an ordinary, unlinked file: " + path.string());
    }
    return metadata;
}

void hashFileInto(
    Sha256Accumulator &digest,
    const fs::path &path,
    const std::string &relativeName,
    bool requireSingleLink = false
) {
    const struct stat pathMetadata = requireRegularFile(path, requireSingleLink);
    OpenFile file(path);
    struct stat openedMetadata {};
    if (::fstat(file.descriptor, &openedMetadata) != 0) throwSystemError("cannot inspect", path);
    if (!S_ISREG(openedMetadata.st_mode) || openedMetadata.st_dev != pathMetadata.st_dev ||
        openedMetadata.st_ino != pathMetadata.st_ino || openedMetadata.st_size != pathMetadata.st_size) {
        throw std::runtime_error("file changed while opening: " + path.string());
    }

    digest.updateInteger(relativeName.size());
    digest.update(relativeName);
    digest.updateInteger(static_cast<std::uint64_t>(openedMetadata.st_size));
    std::array<unsigned char, 1024 * 1024> buffer {};
    std::uint64_t consumed = 0;
    while (true) {
        const ssize_t count = ::read(file.descriptor, buffer.data(), buffer.size());
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) throwSystemError("cannot read", path);
        if (count == 0) break;
        digest.update(buffer.data(), static_cast<std::size_t>(count));
        consumed += static_cast<std::uint64_t>(count);
    }
    if (consumed != static_cast<std::uint64_t>(openedMetadata.st_size)) {
        throw std::runtime_error("file size changed while hashing: " + path.string());
    }
}

std::pair<std::string, std::uintmax_t> hashFileContent(
    const fs::path &path,
    bool requireSingleLink = false
) {
    const struct stat pathMetadata = requireRegularFile(path, requireSingleLink);
    if (pathMetadata.st_size < 0) {
        throw std::runtime_error("file has an invalid size: " + path.string());
    }
    OpenFile file(path);
    struct stat openedMetadata {};
    if (::fstat(file.descriptor, &openedMetadata) != 0) throwSystemError("cannot inspect", path);
    if (!S_ISREG(openedMetadata.st_mode) || openedMetadata.st_dev != pathMetadata.st_dev ||
        openedMetadata.st_ino != pathMetadata.st_ino || openedMetadata.st_size != pathMetadata.st_size) {
        throw std::runtime_error("file changed while opening: " + path.string());
    }

    Sha256Accumulator digest;
    std::array<unsigned char, 1024 * 1024> buffer {};
    std::uintmax_t consumed = 0;
    while (true) {
        const ssize_t count = ::read(file.descriptor, buffer.data(), buffer.size());
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) throwSystemError("cannot read", path);
        if (count == 0) break;
        digest.update(buffer.data(), static_cast<std::size_t>(count));
        consumed += static_cast<std::uintmax_t>(count);
    }
    if (consumed != static_cast<std::uintmax_t>(openedMetadata.st_size)) {
        throw std::runtime_error("file size changed while hashing: " + path.string());
    }
    return {digest.finish(), consumed};
}

std::string digestFiles(const fs::path &root, const std::vector<std::string> &names) {
    Sha256Accumulator digest;
    digest.update("EasySplat file digest v1");
    for (const std::string &name : names) {
        hashFileInto(digest, root / name, name);
    }
    return digest.finish();
}

TrainingIdentity computeTrainingIdentity(const fs::path &dataset) {
    const fs::path images = dataset / "images";
    const fs::path sparse = dataset / "sparse" / "0";
    if (!fs::is_directory(images) || !fs::is_directory(sparse)) {
        throw std::runtime_error("dataset must contain images and sparse/0 directories");
    }

    std::vector<std::string> imageNames;
    for (const fs::directory_entry &entry : fs::directory_iterator(images)) {
        const fs::file_status status = entry.symlink_status();
        if (!fs::is_regular_file(status)) {
            throw std::runtime_error("dataset images must be ordinary files");
        }
        imageNames.push_back(entry.path().filename().string());
    }
    std::sort(imageNames.begin(), imageNames.end());
    if (imageNames.empty() || std::adjacent_find(imageNames.begin(), imageNames.end()) != imageNames.end()) {
        throw std::runtime_error("dataset image set is empty or ambiguous");
    }

    return TrainingIdentity {
        digestFiles(images, imageNames),
        digestFiles(
            sparse,
            {"cameras.bin", "images.bin", "points3D.bin"}
        ),
    };
}

std::string computeTrainerBuildDigest() {
    std::uint32_t capacity = 0;
    if (_NSGetExecutablePath(nullptr, &capacity) != -1 || capacity == 0 || capacity > 1024 * 1024) {
        throw std::runtime_error("cannot resolve trainer executable path");
    }
    std::vector<char> buffer(capacity);
    if (_NSGetExecutablePath(buffer.data(), &capacity) != 0) {
        throw std::runtime_error("cannot resolve trainer executable path");
    }
    const fs::path executable = fs::canonical(fs::path(buffer.data()));
    const fs::path directory = executable.parent_path();
    return digestFiles(
        directory,
        {executable.filename().string(), "default.metallib"}
    );
}

void throwSystemError(const std::string &operation, const fs::path &path) {
    throw std::runtime_error(operation + " " + path.string() + ": " + std::strerror(errno));
}

void syncFile(const fs::path &path) {
    int descriptor = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW);
    if (descriptor < 0) throwSystemError("cannot open", path);
    if (::fsync(descriptor) != 0) {
        int savedErrno = errno;
        ::close(descriptor);
        errno = savedErrno;
        throwSystemError("cannot sync", path);
    }
    if (::close(descriptor) != 0) throwSystemError("cannot close", path);
}

void syncDirectory(const fs::path &path) {
    int descriptor = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW);
    if (descriptor < 0) throwSystemError("cannot open directory", path);
    if (::fsync(descriptor) != 0) {
        int savedErrno = errno;
        ::close(descriptor);
        errno = savedErrno;
        throwSystemError("cannot sync directory", path);
    }
    if (::close(descriptor) != 0) throwSystemError("cannot close directory", path);
}

struct CheckpointContext {
    const TrainingProfileConfig &profile;
    std::uint64_t seed;
    std::size_t cameraCount;
    TrainingIdentity identity;
    std::string trainerBuildDigest;
};

class CheckpointCompatibilityError : public std::runtime_error {
public:
    CheckpointCompatibilityError(std::string reason, std::string message)
        : std::runtime_error(std::move(message)), reason_(std::move(reason)) {}

    const std::string &reason() const { return reason_; }

private:
    std::string reason_;
};

struct ValidatedCheckpoint {
    CheckpointReceipt receipt;
    TrainerCheckpointState trainerState;
    int gaussianCount;
    int backingCapacity;
    fs::path payloadPath;
};

class ScopedDirectoryRemoval {
public:
    explicit ScopedDirectoryRemoval(fs::path path) : path_(std::move(path)) {}
    ~ScopedDirectoryRemoval() {
        if (!active_) return;
        std::error_code ignored;
        fs::remove_all(path_, ignored);
    }
    void release() { active_ = false; }

private:
    fs::path path_;
    bool active_ = true;
};

bool isLowercaseHex(const std::string &value, std::size_t length = 64) {
    return value.size() == length && std::all_of(value.begin(), value.end(), [](char character) {
        return (character >= '0' && character <= '9') ||
            (character >= 'a' && character <= 'f');
    });
}

void requirePlainDirectory(const fs::path &path) {
    struct stat metadata {};
    if (::lstat(path.c_str(), &metadata) != 0) throwSystemError("cannot inspect directory", path);
    if (!S_ISDIR(metadata.st_mode)) {
        throw std::runtime_error("expected an ordinary directory: " + path.string());
    }
}

std::string readBoundedTextFile(
    const fs::path &path,
    std::uintmax_t maximumBytes,
    bool requireSingleLink = true
) {
    const struct stat metadata = requireRegularFile(path, requireSingleLink);
    if (metadata.st_size < 0 || static_cast<std::uintmax_t>(metadata.st_size) > maximumBytes) {
        throw std::runtime_error("file exceeds its size limit: " + path.string());
    }
    OpenFile file(path);
    std::string contents(static_cast<std::size_t>(metadata.st_size), '\0');
    std::size_t consumed = 0;
    while (consumed < contents.size()) {
        const ssize_t count = ::read(
            file.descriptor,
            contents.data() + consumed,
            contents.size() - consumed
        );
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) throwSystemError("cannot read", path);
        consumed += static_cast<std::size_t>(count);
    }
    return contents;
}

void writeAll(int descriptor, const std::string &contents, const fs::path &path) {
    const char *cursor = contents.data();
    std::size_t remaining = contents.size();
    while (remaining > 0) {
        const ssize_t written = ::write(descriptor, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) throwSystemError("cannot write", path);
        cursor += written;
        remaining -= static_cast<std::size_t>(written);
    }
}

void writeExclusiveFile(const fs::path &path, const std::string &contents) {
    const int descriptor = ::open(
        path.c_str(),
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
    );
    if (descriptor < 0) throwSystemError("cannot create", path);
    try {
        writeAll(descriptor, contents, path);
        if (::fsync(descriptor) != 0) throwSystemError("cannot sync", path);
        if (::close(descriptor) != 0) throwSystemError("cannot close", path);
    } catch (...) {
        const int savedErrno = errno;
        ::close(descriptor);
        errno = savedErrno;
        throw;
    }
}

std::optional<std::string> readCurrentGeneration(const fs::path &checkpointRoot) {
    const fs::path current = checkpointRoot / "CURRENT";
    struct stat metadata {};
    if (::lstat(current.c_str(), &metadata) != 0) {
        if (errno == ENOENT) return std::nullopt;
        throwSystemError("cannot inspect", current);
    }
    std::string generation = readBoundedTextFile(current, 128);
    if (!generation.empty() && generation.back() == '\n') generation.pop_back();
    if (generation.size() != 73 || generation[8] != '-' ||
        !std::all_of(generation.begin(), generation.begin() + 8, [](char value) {
            return value >= '0' && value <= '9';
        }) ||
        !isLowercaseHex(generation.substr(9))) {
        throw std::runtime_error("checkpoint CURRENT entry is invalid");
    }
    return generation;
}

fs::path prepareCheckpointRoot(const fs::path &checkpointRoot) {
    if (checkpointRoot.empty() || checkpointRoot.filename().empty()) {
        throw std::runtime_error("checkpoint path must name a directory");
    }
    requirePlainDirectory(checkpointRoot.parent_path());
    struct stat metadata {};
    if (::lstat(checkpointRoot.c_str(), &metadata) != 0) {
        if (errno != ENOENT) throwSystemError("cannot inspect checkpoint root", checkpointRoot);
        if (::mkdir(checkpointRoot.c_str(), S_IRWXU) != 0) {
            throwSystemError("cannot create checkpoint root", checkpointRoot);
        }
    } else if (!S_ISDIR(metadata.st_mode)) {
        throw std::runtime_error("checkpoint root must be an ordinary directory");
    }
    if (::chmod(checkpointRoot.c_str(), S_IRWXU) != 0) {
        throwSystemError("cannot protect checkpoint root", checkpointRoot);
    }

    const fs::path generations = checkpointRoot / "generations";
    if (::lstat(generations.c_str(), &metadata) != 0) {
        if (errno != ENOENT) throwSystemError("cannot inspect checkpoint generations", generations);
        if (::mkdir(generations.c_str(), S_IRWXU) != 0) {
            throwSystemError("cannot create checkpoint generations", generations);
        }
    } else if (!S_ISDIR(metadata.st_mode)) {
        throw std::runtime_error("checkpoint generations must be an ordinary directory");
    }
    if (::chmod(generations.c_str(), S_IRWXU) != 0) {
        throwSystemError("cannot protect checkpoint generations", generations);
    }
    return generations;
}

std::set<std::string> checkpointManifestKeys() {
    return {
        "backing_capacity", "best_camera_losses", "camera_count", "camera_draw_count",
        "elapsed_seconds", "gaussian_count", "geometry_digest", "input_digest",
        "iteration", "iteration_limit", "last_improvement_iteration", "latest_loss",
        "latest_loss_iteration", "payload_bytes", "payload_file", "payload_schema",
        "payload_sha256", "plateau_window", "profile", "schema_version", "seed",
        "trainer_build_digest", "trainer_version"
    };
}

ValidatedCheckpoint validateCheckpointGeneration(
    const fs::path &checkpointRoot,
    const std::string &generation,
    const CheckpointContext &context
) {
    const fs::path generationPath = checkpointRoot / "generations" / generation;
    requirePlainDirectory(generationPath);
    std::set<std::string> actualFiles;
    for (const fs::directory_entry &entry : fs::directory_iterator(generationPath)) {
        actualFiles.insert(entry.path().filename().string());
    }
    if (actualFiles != std::set<std::string>{"manifest.json", "state.msplat"}) {
        throw std::runtime_error("checkpoint generation has unexpected contents");
    }

    const fs::path manifestPath = generationPath / "manifest.json";
    const fs::path payloadPath = generationPath / "state.msplat";
    const std::string manifestText = readBoundedTextFile(
        manifestPath,
        maximumCheckpointManifestBytes
    );
    json manifest = json::parse(manifestText);
    if (!manifest.is_object()) throw std::runtime_error("checkpoint manifest must be an object");
    std::set<std::string> actualKeys;
    for (auto iterator = manifest.begin(); iterator != manifest.end(); ++iterator) {
        actualKeys.insert(iterator.key());
    }
    if (actualKeys != checkpointManifestKeys()) {
        throw std::runtime_error("checkpoint manifest keys do not match schema 1");
    }

    const int schemaVersion = manifest.at("schema_version").get<int>();
    const int payloadSchema = manifest.at("payload_schema").get<int>();
    const std::string trainerVersion = manifest.at("trainer_version").get<std::string>();
    const std::string trainerDigest = manifest.at("trainer_build_digest").get<std::string>();
    const std::string profile = manifest.at("profile").get<std::string>();
    const std::uint64_t seed = manifest.at("seed").get<std::uint64_t>();
    const std::size_t cameraCount = manifest.at("camera_count").get<std::size_t>();
    const std::string inputDigest = manifest.at("input_digest").get<std::string>();
    const std::string geometryDigest = manifest.at("geometry_digest").get<std::string>();
    const int iteration = manifest.at("iteration").get<int>();
    const int cameraDrawCount = manifest.at("camera_draw_count").get<int>();
    const int iterationLimit = manifest.at("iteration_limit").get<int>();
    const int plateauWindow = manifest.at("plateau_window").get<int>();
    const int gaussianCount = manifest.at("gaussian_count").get<int>();
    const int backingCapacity = manifest.at("backing_capacity").get<int>();
    const std::string payloadFile = manifest.at("payload_file").get<std::string>();
    const std::string payloadDigest = manifest.at("payload_sha256").get<std::string>();
    const std::uintmax_t payloadBytes = manifest.at("payload_bytes").get<std::uintmax_t>();
    const int lastImprovement = manifest.at("last_improvement_iteration").get<int>();
    const int latestLossIteration = manifest.at("latest_loss_iteration").get<int>();
    const double elapsedSeconds = manifest.at("elapsed_seconds").get<double>();

    if (schemaVersion != 1 || payloadSchema != 2 || !isLowercaseHex(trainerDigest) ||
        !isLowercaseHex(inputDigest) || !isLowercaseHex(geometryDigest) || cameraCount == 0 ||
        iteration < 0 || iteration >= iterationLimit || cameraDrawCount != iteration ||
        iterationLimit <= 0 || plateauWindow <= 0 ||
        gaussianCount <= 0 || backingCapacity < gaussianCount || payloadFile != "state.msplat" ||
        !isLowercaseHex(payloadDigest) || payloadBytes == 0 ||
        payloadBytes > maximumCheckpointPayloadBytes || lastImprovement < 0 ||
        lastImprovement > std::max(iteration, 500) || latestLossIteration < 0 ||
        latestLossIteration > iteration || !std::isfinite(elapsedSeconds) || elapsedSeconds < 0) {
        throw std::runtime_error("checkpoint manifest does not match this training run");
    }

    const json &bestLosses = manifest.at("best_camera_losses");
    if (!bestLosses.is_array() || bestLosses.size() != cameraCount) {
        throw std::runtime_error("checkpoint camera-loss state is invalid");
    }
    std::vector<double> decodedBestLosses;
    decodedBestLosses.reserve(cameraCount);
    for (const json &value : bestLosses) {
        if (value.is_null()) {
            decodedBestLosses.push_back(std::numeric_limits<double>::infinity());
        } else {
            const double loss = value.get<double>();
            if (!std::isfinite(loss) || loss < 0) {
                throw std::runtime_error("checkpoint camera loss is invalid");
            }
            decodedBestLosses.push_back(loss);
        }
    }

    std::optional<double> latestLoss;
    const json &latestLossValue = manifest.at("latest_loss");
    if (!latestLossValue.is_null()) {
        const double decoded = latestLossValue.get<double>();
        if (!std::isfinite(decoded) || decoded < 0 || latestLossIteration == 0) {
            throw std::runtime_error("checkpoint latest loss is invalid");
        }
        latestLoss = decoded;
    } else if (latestLossIteration != 0) {
        throw std::runtime_error("checkpoint latest-loss iteration is inconsistent");
    }

    const auto [actualDigest, actualBytes] = hashFileContent(payloadPath, true);
    if (actualBytes != payloadBytes || actualDigest != payloadDigest) {
        throw std::runtime_error("checkpoint payload hash or size does not match its manifest");
    }

    const int generationIteration = std::stoi(generation.substr(0, 8));
    Sha256Accumulator manifestDigest;
    manifestDigest.update(manifestText);
    if (generationIteration != iteration || generation.substr(9) != manifestDigest.finish()) {
        throw std::runtime_error("checkpoint generation name does not match its manifest");
    }

    if (trainerVersion != APP_VERSION || trainerDigest != context.trainerBuildDigest) {
        throw CheckpointCompatibilityError(
            "trainer_changed",
            "checkpoint trainer build does not match the installed trainer"
        );
    }
    if (profile != context.profile.name || seed != context.seed ||
        iterationLimit != context.profile.iterationLimit ||
        plateauWindow != context.profile.plateauWindow) {
        throw CheckpointCompatibilityError(
            "run_contract_changed",
            "checkpoint profile, seed, or budget no longer matches"
        );
    }
    if (cameraCount != context.cameraCount || inputDigest != context.identity.inputDigest) {
        throw CheckpointCompatibilityError(
            "input_changed",
            "checkpoint input set no longer matches"
        );
    }
    if (geometryDigest != context.identity.geometryDigest) {
        throw CheckpointCompatibilityError(
            "geometry_changed",
            "checkpoint geometry no longer matches"
        );
    }

    return ValidatedCheckpoint {
        CheckpointReceipt {iteration, generation, payloadDigest, payloadBytes},
        TrainerCheckpointState {
            iteration,
            lastImprovement,
            std::move(decodedBestLosses),
            latestLoss,
            latestLossIteration,
            elapsedSeconds,
        },
        gaussianCount,
        backingCapacity,
        payloadPath,
    };
}

ValidatedCheckpoint loadCheckpoint(
    Model &model,
    const fs::path &checkpointRoot,
    const CheckpointContext &context
) {
    requirePlainDirectory(checkpointRoot);
    requirePlainDirectory(checkpointRoot / "generations");
    const std::optional<std::string> generation = readCurrentGeneration(checkpointRoot);
    if (!generation) throw std::runtime_error("checkpoint has no CURRENT generation");
    ValidatedCheckpoint checkpoint = validateCheckpointGeneration(
        checkpointRoot,
        *generation,
        context
    );
    const int loadedIteration = model.loadCheckpoint(checkpoint.payloadPath.string());
    if (loadedIteration != checkpoint.receipt.iteration ||
        model.num_active != checkpoint.gaussianCount ||
        model.buf_capacity != checkpoint.backingCapacity) {
        throw std::runtime_error("checkpoint payload state does not match its manifest");
    }
    return checkpoint;
}

std::string checkpointManifestText(
    const Model &model,
    const CheckpointContext &context,
    const TrainerCheckpointState &state,
    const std::string &payloadDigest,
    std::uintmax_t payloadBytes
) {
    json bestLosses = json::array();
    for (double loss : state.bestCameraLosses) {
        if (std::isfinite(loss)) bestLosses.push_back(loss);
        else bestLosses.push_back(nullptr);
    }
    json manifest = {
        {"backing_capacity", model.buf_capacity},
        {"best_camera_losses", std::move(bestLosses)},
        {"camera_count", context.cameraCount},
        {"camera_draw_count", state.iteration},
        {"elapsed_seconds", state.elapsedSeconds},
        {"gaussian_count", model.num_active},
        {"geometry_digest", context.identity.geometryDigest},
        {"input_digest", context.identity.inputDigest},
        {"iteration", state.iteration},
        {"iteration_limit", context.profile.iterationLimit},
        {"last_improvement_iteration", state.lastImprovementIteration},
        {"latest_loss", state.latestLoss ? json(*state.latestLoss) : json(nullptr)},
        {"latest_loss_iteration", state.latestLossIteration},
        {"payload_bytes", payloadBytes},
        {"payload_file", "state.msplat"},
        {"payload_schema", 2},
        {"payload_sha256", payloadDigest},
        {"plateau_window", context.profile.plateauWindow},
        {"profile", context.profile.name},
        {"schema_version", 1},
        {"seed", context.seed},
        {"trainer_build_digest", context.trainerBuildDigest},
        {"trainer_version", APP_VERSION},
    };
    std::string text = manifest.dump(2);
    text.push_back('\n');
    if (text.size() > maximumCheckpointManifestBytes) {
        throw std::runtime_error("checkpoint manifest exceeds its size limit");
    }
    return text;
}

CheckpointReceipt saveCheckpoint(
    Model &model,
    const fs::path &checkpointRoot,
    const CheckpointContext &context,
    const TrainerCheckpointState &state
) {
    if (state.iteration < 0 || state.iteration >= context.profile.iterationLimit ||
        state.bestCameraLosses.size() != context.cameraCount ||
        state.lastImprovementIteration < 0 ||
        state.lastImprovementIteration > std::max(state.iteration, 500) ||
        !std::isfinite(state.elapsedSeconds) || state.elapsedSeconds < 0) {
        throw std::runtime_error("cannot save inconsistent trainer checkpoint state");
    }
    if ((state.latestLoss.has_value() &&
         (!std::isfinite(*state.latestLoss) || *state.latestLoss < 0 || state.latestLossIteration == 0)) ||
        (!state.latestLoss.has_value() && state.latestLossIteration != 0) ||
        state.latestLossIteration > state.iteration) {
        throw std::runtime_error("cannot save inconsistent checkpoint loss evidence");
    }
    for (double loss : state.bestCameraLosses) {
        if (std::isfinite(loss) && loss < 0) {
            throw std::runtime_error("cannot save an invalid camera loss");
        }
    }

    const fs::path generations = prepareCheckpointRoot(checkpointRoot);
    const std::optional<std::string> previous = readCurrentGeneration(checkpointRoot);
    std::string stagingTemplate = (generations / ".tmp.XXXXXX").string();
    std::vector<char> stagingBuffer(stagingTemplate.begin(), stagingTemplate.end());
    stagingBuffer.push_back('\0');
    char *created = ::mkdtemp(stagingBuffer.data());
    if (!created) throwSystemError("cannot create checkpoint staging directory", generations);
    const fs::path staging(created);
    ScopedDirectoryRemoval stagingCleanup(staging);

    const fs::path payloadPath = staging / "state.msplat";
    model.saveCheckpoint(payloadPath.string(), state.iteration);
    if (::chmod(payloadPath.c_str(), S_IRUSR | S_IWUSR) != 0) {
        throwSystemError("cannot protect checkpoint payload", payloadPath);
    }
    syncFile(payloadPath);
    const auto [payloadDigest, payloadBytes] = hashFileContent(payloadPath, true);
    if (payloadBytes == 0 || payloadBytes > maximumCheckpointPayloadBytes) {
        throw std::runtime_error("checkpoint payload exceeds its size limit");
    }

    const std::string manifestText = checkpointManifestText(
        model,
        context,
        state,
        payloadDigest,
        payloadBytes
    );
    const fs::path manifestPath = staging / "manifest.json";
    writeExclusiveFile(manifestPath, manifestText);
    syncDirectory(staging);

    Sha256Accumulator manifestDigest;
    manifestDigest.update(manifestText);
    std::ostringstream generationName;
    generationName << std::setw(8) << std::setfill('0') << state.iteration
                   << '-' << manifestDigest.finish();
    const std::string generation = generationName.str();
    const fs::path published = generations / generation;
    if (::renamex_np(
            staging.c_str(),
            published.c_str(),
            RENAME_EXCL | RENAME_NOFOLLOW_ANY
        ) != 0) {
        if (errno != EEXIST) throwSystemError("cannot publish checkpoint generation", published);
        const ValidatedCheckpoint existing = validateCheckpointGeneration(
            checkpointRoot,
            generation,
            context
        );
        if (existing.receipt.payloadDigest != payloadDigest ||
            existing.receipt.payloadBytes != payloadBytes ||
            existing.receipt.iteration != state.iteration) {
            throw std::runtime_error("existing checkpoint generation does not match staged state");
        }
    } else {
        stagingCleanup.release();
    }
    syncDirectory(generations);

    const std::string currentContents = generation + "\n";
    std::string currentTemplate = (checkpointRoot / ".CURRENT.tmp.XXXXXX").string();
    std::vector<char> currentBuffer(currentTemplate.begin(), currentTemplate.end());
    currentBuffer.push_back('\0');
    const int currentDescriptor = ::mkstemp(currentBuffer.data());
    if (currentDescriptor < 0) throwSystemError("cannot create checkpoint CURRENT staging file", checkpointRoot);
    const fs::path currentTemporary(currentBuffer.data());
    try {
        if (::fchmod(currentDescriptor, S_IRUSR | S_IWUSR) != 0) {
            throwSystemError("cannot protect checkpoint CURRENT staging file", currentTemporary);
        }
        writeAll(currentDescriptor, currentContents, currentTemporary);
        if (::fsync(currentDescriptor) != 0) {
            throwSystemError("cannot sync checkpoint CURRENT staging file", currentTemporary);
        }
        if (::close(currentDescriptor) != 0) {
            throwSystemError("cannot close checkpoint CURRENT staging file", currentTemporary);
        }
    } catch (...) {
        const int savedErrno = errno;
        ::close(currentDescriptor);
        ::unlink(currentTemporary.c_str());
        errno = savedErrno;
        throw;
    }

    const fs::path current = checkpointRoot / "CURRENT";
    struct stat currentMetadata {};
    if (::lstat(current.c_str(), &currentMetadata) == 0 && !S_ISREG(currentMetadata.st_mode)) {
        ::unlink(currentTemporary.c_str());
        throw std::runtime_error("checkpoint CURRENT must be an ordinary file");
    }
    if (::renamex_np(currentTemporary.c_str(), current.c_str(), RENAME_NOFOLLOW_ANY) != 0) {
        const int savedErrno = errno;
        ::unlink(currentTemporary.c_str());
        errno = savedErrno;
        throwSystemError("cannot publish checkpoint CURRENT", current);
    }
    syncDirectory(checkpointRoot);

    for (const fs::directory_entry &entry : fs::directory_iterator(generations)) {
        const std::string name = entry.path().filename().string();
        if (name == generation || (previous && name == *previous)) continue;
        if (name.rfind(".tmp.", 0) == 0 ||
            (name.size() == 73 && name[8] == '-' && isLowercaseHex(name.substr(9)))) {
            std::error_code ignored;
            fs::remove_all(entry.path(), ignored);
        }
    }

    return CheckpointReceipt {state.iteration, generation, payloadDigest, payloadBytes};
}

struct PlyValidation {
    std::uint64_t vertices;
    std::uint64_t properties;
    std::uintmax_t bytes;
};

PlyValidation validateBinaryPly(const fs::path &path) {
    std::ifstream input(path, std::ios::binary);
    if (!input.is_open()) throw std::runtime_error("cannot open PLY for validation");

    std::string line;
    if (!std::getline(input, line) || line != "ply") {
        throw std::runtime_error("PLY header is missing the magic line");
    }
    if (!std::getline(input, line) || line != "format binary_little_endian 1.0") {
        throw std::runtime_error("PLY must use binary_little_endian 1.0");
    }

    std::uint64_t vertices = 0;
    std::uint64_t properties = 0;
    bool sawVertexElement = false;
    bool sawEndHeader = false;
    for (int headerLine = 0; headerLine < 512 && std::getline(input, line); ++headerLine) {
        constexpr std::string_view vertexPrefix = "element vertex ";
        if (line.rfind(vertexPrefix, 0) == 0) {
            if (sawVertexElement) throw std::runtime_error("PLY has duplicate vertex elements");
            const std::string count = line.substr(vertexPrefix.size());
            std::size_t parsed = 0;
            try {
                vertices = std::stoull(count, &parsed);
            } catch (const std::exception &) {
                throw std::runtime_error("PLY vertex count is invalid");
            }
            if (parsed != count.size() || vertices == 0) {
                throw std::runtime_error("PLY vertex count is invalid");
            }
            sawVertexElement = true;
        } else if (sawVertexElement && line.rfind("property float ", 0) == 0) {
            ++properties;
        } else if (line == "end_header") {
            sawEndHeader = true;
            break;
        }
        const auto position = input.tellg();
        if (position < 0 || position > 65536) {
            throw std::runtime_error("PLY header is unreasonably large");
        }
    }

    if (!sawEndHeader || !sawVertexElement || properties < 17) {
        throw std::runtime_error("PLY vertex layout is incomplete");
    }
    const auto payloadOffsetPosition = input.tellg();
    if (payloadOffsetPosition < 0) throw std::runtime_error("PLY payload offset is invalid");
    const auto payloadOffset = static_cast<std::uintmax_t>(payloadOffsetPosition);
    constexpr std::uintmax_t floatBytes = sizeof(float);
    if (properties > std::numeric_limits<std::uintmax_t>::max() / floatBytes) {
        throw std::runtime_error("PLY payload size overflows");
    }
    const std::uintmax_t rowBytes = properties * floatBytes;
    if (vertices > (std::numeric_limits<std::uintmax_t>::max() - payloadOffset) / rowBytes) {
        throw std::runtime_error("PLY payload size overflows");
    }
    const std::uintmax_t expectedBytes = payloadOffset + vertices * rowBytes;
    const std::uintmax_t actualBytes = fs::file_size(path);
    if (actualBytes != expectedBytes) {
        throw std::runtime_error("PLY payload length does not match its header");
    }
    return {vertices, properties, actualBytes};
}

bool savePlyAtomically(Model &model, const fs::path &output, int step) {
    fs::path parent = output.parent_path();
    if (parent.empty()) parent = fs::current_path();
    fs::create_directories(parent);

    fs::path temporary = parent / ("." + output.filename().string() + ".tmp." +
                                   std::to_string(static_cast<long long>(::getpid())) + ".ply");
    std::error_code ignored;
    fs::remove(temporary, ignored);

    try {
        msplat_gpu_sync();
        model.save(temporary.string(), step);
        if (!fs::is_regular_file(temporary) || fs::file_size(temporary) == 0) {
            throw std::runtime_error("msplat produced an empty PLY");
        }
        validateBinaryPly(temporary);
        syncFile(temporary);
        if (cancellationSignal != 0) {
            fs::remove(temporary, ignored);
            return false;
        }
        if (::rename(temporary.c_str(), output.c_str()) != 0) {
            throwSystemError("cannot atomically replace", output);
        }
        syncDirectory(parent);
        return true;
    } catch (...) {
        fs::remove(temporary, ignored);
        throw;
    }
}

} // namespace

int main(int argc, char *argv[]) {
    CLI::App app{"EasySplat native msplat trainer"};
    app.set_help_flag("-h,--help", "Show this help message");
    app.set_version_flag("--version", APP_VERSION);

    std::string datasetPath;
    std::string outputPath;
    std::string profileName;
    std::string checkpointPath;
    std::string resumePath;
    std::uint64_t seed = 42;
    int eventsFileDescriptor = -1;
    bool selfCheck = false;
    std::string plyToValidate;

    CLI::Option *datasetOption = app.add_option(
        "--dataset", datasetPath, "Canonical COLMAP dataset directory"
    );
    CLI::Option *outputOption = app.add_option("--output", outputPath, "Final PLY output path");
    CLI::Option *profileOption = app.add_option(
        "--profile", profileName, "Training profile: fast, balanced, or high-detail"
    );
    CLI::Option *seedOption = app.add_option(
        "--seed", seed, "Deterministic uint64 camera-order seed"
    );
    CLI::Option *checkpointOption = app.add_option(
        "--checkpoint", checkpointPath, "Atomic optimizer-checkpoint directory"
    );
    app.add_option("--resume", resumePath, "Validated optimizer-checkpoint directory");
    CLI::Option *eventsOption = app.add_option(
        "--events-fd", eventsFileDescriptor, "Descriptor for schema-v1 JSONL events"
    );
    eventsOption->check(CLI::Range(0, std::numeric_limits<int>::max()));
    app.add_flag("--self-check", selfCheck, "Initialize Metal and load the adjacent metallib");
    app.add_option("--validate-ply", plyToValidate, "Validate a binary Gaussian PLY")
        ->check(CLI::ExistingFile);

    CLI11_PARSE(app, argc, argv);

    try {
        struct sigaction ignoreBrokenPipe {};
        ignoreBrokenPipe.sa_handler = SIG_IGN;
        sigemptyset(&ignoreBrokenPipe.sa_mask);
        ignoreBrokenPipe.sa_flags = 0;
        if (sigaction(SIGPIPE, &ignoreBrokenPipe, nullptr) != 0) {
            throw std::runtime_error("failed to configure event-pipe handling");
        }
        EventWriter events(eventsFileDescriptor);
        if (eventsFileDescriptor == STDOUT_FILENO) std::cout.rdbuf(std::cerr.rdbuf());

        if (!plyToValidate.empty()) {
            const PlyValidation validation = validateBinaryPly(plyToValidate);
            events.emit("output_validation", {{"output_bytes", validation.bytes},
                                               {"status", "ok"},
                                               {"vertex_count", validation.vertices}});
            if (!events.enabled()) std::cout << "PLY validation passed\n";
            return 0;
        }
        if (selfCheck) {
            if (msplat_device() == nullptr) {
                throw std::runtime_error("Metal device initialization returned null");
            }
            msplat_gpu_sync();
            events.emit("self_check", {{"status", "ok"}, {"version", APP_VERSION}});
            if (!events.enabled()) std::cout << "Metal self-check passed\n";
            return 0;
        }

        if (datasetOption->count() == 0) throw std::runtime_error("--dataset is required for training");
        if (outputOption->count() == 0) throw std::runtime_error("--output is required for training");
        if (profileOption->count() == 0) throw std::runtime_error("--profile is required for training");
        if (seedOption->count() == 0) throw std::runtime_error("--seed is required for training");
        if (checkpointOption->count() == 0) {
            throw std::runtime_error("--checkpoint is required for training");
        }
        if (eventsOption->count() == 0) throw std::runtime_error("--events-fd is required for training");
        const TrainingProfileConfig &profile = trainingProfileNamed(profileName);
        if (!fs::is_directory(datasetPath)) throw std::runtime_error("dataset directory does not exist");
        if (fs::path(outputPath).extension() != ".ply") throw std::runtime_error("--output must end in .ply");

        struct sigaction action {};
        action.sa_handler = observeCancellation;
        sigemptyset(&action.sa_mask);
        action.sa_flags = 0;
        if (sigaction(SIGINT, &action, nullptr) != 0 || sigaction(SIGTERM, &action, nullptr) != 0) {
            throw std::runtime_error("failed to install cancellation handlers");
        }

        const TrainingIdentity identity = computeTrainingIdentity(datasetPath);
        const std::string trainerBuildDigest = computeTrainerBuildDigest();

        InputData inputData = inputDataFromX(datasetPath);
        for (Camera &camera : inputData.cameras) camera.loadImage(1.0f);

        std::vector<Camera> cameras;
        Camera *unusedValidationCamera = nullptr;
        std::tie(cameras, unusedValidationCamera) = inputData.getCameras(false);
        if (cameras.empty()) throw std::runtime_error("input dataset contains no training cameras");

        constexpr int resolutionSchedule = 3000;
        constexpr int shDegree = 3;
        constexpr int shDegreeInterval = 1000;
        constexpr int refineEvery = 100;
        constexpr int lossSyncBatch = refineEvery;
        constexpr int warmupLength = 500;
        constexpr int resetAlphaEvery = 30;
        constexpr float densifyGradThreshold = 0.0002f;
        constexpr float densifySizeThreshold = 0.01f;
        constexpr int stopScreenSizeAt = 4000;
        constexpr float splitScreenSize = 0.05f;
        constexpr float ssimWeight = 0.2f;
        constexpr float background[3] = {0.6130f, 0.0101f, 0.3984f};

        Model model(inputData, static_cast<int>(cameras.size()), profile.numDownscales,
                    resolutionSchedule, shDegree, shDegreeInterval, refineEvery,
                    warmupLength, resetAlphaEvery, densifyGradThreshold,
                    densifySizeThreshold, stopScreenSizeAt, splitScreenSize,
                    profile.iterationLimit, false, background);

        std::vector<size_t> camIndices(cameras.size());
        std::iota(camIndices.begin(), camIndices.end(), 0);
        InfiniteRandomIterator<size_t> camsIter(camIndices, seed);

        const fs::path requestedCheckpointRoot(checkpointPath);
        const fs::path checkpointParent = requestedCheckpointRoot.parent_path().empty()
            ? fs::current_path()
            : requestedCheckpointRoot.parent_path();
        const fs::path checkpointRoot = fs::canonical(checkpointParent) /
            requestedCheckpointRoot.filename();
        if (!resumePath.empty()) {
            requirePlainDirectory(resumePath);
            if (fs::canonical(resumePath) != fs::canonical(checkpointRoot)) {
                throw std::runtime_error("--resume must identify the --checkpoint directory");
            }
        }
        const CheckpointContext checkpointContext {
            profile,
            seed,
            cameras.size(),
            identity,
            trainerBuildDigest,
        };

        const auto startedAt = std::chrono::steady_clock::now();
        int plateauSampleCount = 0;
        std::vector<float> plateauLosses(lossSyncBatch);
        std::vector<std::size_t> plateauCameraIndices(lossSyncBatch);
        std::vector<double> bestCameraLosses(
            cameras.size(),
            std::numeric_limits<double>::infinity()
        );
        int lastImprovementIteration = warmupLength;
        double latestWindowLoss = std::numeric_limits<double>::quiet_NaN();
        int latestLossIteration = 0;
        int completedIteration = 0;
        double priorElapsedSeconds = 0;
        std::optional<CheckpointReceipt> lastCheckpoint;
        const bool resumed = !resumePath.empty();

        if (resumed) {
            std::optional<ValidatedCheckpoint> validatedCheckpoint;
            try {
                validatedCheckpoint = loadCheckpoint(model, checkpointRoot, checkpointContext);
            } catch (const CheckpointCompatibilityError &error) {
                events.emit("resume_rejected", {{"reason", error.reason()}});
                std::cerr << error.what() << '\n';
                return 78;
            }
            ValidatedCheckpoint checkpoint = std::move(*validatedCheckpoint);
            completedIteration = checkpoint.trainerState.iteration;
            lastImprovementIteration = checkpoint.trainerState.lastImprovementIteration;
            bestCameraLosses = std::move(checkpoint.trainerState.bestCameraLosses);
            if (checkpoint.trainerState.latestLoss) {
                latestWindowLoss = *checkpoint.trainerState.latestLoss;
            }
            latestLossIteration = checkpoint.trainerState.latestLossIteration;
            priorElapsedSeconds = checkpoint.trainerState.elapsedSeconds;
            lastCheckpoint = checkpoint.receipt;
            for (int draw = 0; draw < completedIteration; ++draw) {
                (void)camsIter.next();
            }
        } else {
            lastCheckpoint = saveCheckpoint(
                model,
                checkpointRoot,
                checkpointContext,
                TrainerCheckpointState {
                    0,
                    warmupLength,
                    bestCameraLosses,
                    std::nullopt,
                    0,
                    0,
                }
            );
        }
        const int startingIteration = completedIteration;

        auto emitCheckpoint = [&](const char *eventName, const CheckpointReceipt &receipt) {
            events.emit(eventName, {
                {"checkpoint_generation", receipt.generation},
                {"checkpoint_payload_bytes", receipt.payloadBytes},
                {"checkpoint_payload_sha256", receipt.payloadDigest},
                {"gaussian_count", model.num_active},
                {"geometry_digest", identity.geometryDigest},
                {"input_digest", identity.inputDigest},
                {"iteration", receipt.iteration},
                {"profile", profile.name},
                {"seed", seed},
                {"trainer_build_digest", trainerBuildDigest},
                {"version", APP_VERSION},
            });
        };

        events.emit("started", {{"camera_count", cameras.size()},
                                {"checkpoint_schema", 1},
                                {"geometry_digest", identity.geometryDigest},
                                {"initial_gaussian_count", model.num_active},
                                {"input_digest", identity.inputDigest},
                                {"iteration", completedIteration},
                                {"iteration_limit", profile.iterationLimit},
                                {"payload_schema", 2},
                                {"plateau_window", profile.plateauWindow},
                                {"profile", profile.name},
                                {"resumed", resumed},
                                {"seed", seed},
                                {"trainer_build_digest", trainerBuildDigest},
                                {"version", APP_VERSION}});
        emitCheckpoint(resumed ? "checkpoint_loaded" : "checkpoint_completed", *lastCheckpoint);

        auto lastProgressAt = startedAt;
        auto cumulativeElapsed = [&]() {
            return priorElapsedSeconds + std::chrono::duration<double>(
                std::chrono::steady_clock::now() - startedAt
            ).count();
        };
        auto handleCancellation = [&]() {
            if (cancellationSignal == 0) return false;
            events.emit("cancellation_requested", {{"iteration", completedIteration},
                                                   {"signal", cancellationSignal}});
            msplat_gpu_sync();
            events.emit("cancelled", {
                {"checkpoint_generation", lastCheckpoint->generation},
                {"checkpoint_iteration", lastCheckpoint->iteration},
                {"checkpoint_payload_sha256", lastCheckpoint->payloadDigest},
                {"geometry_digest", identity.geometryDigest},
                {"input_digest", identity.inputDigest},
                {"iteration", completedIteration},
            });
            return true;
        };

        if (handleCancellation()) return 130;
        std::string stopReason = "iteration_limit";
        for (int step = completedIteration + 1; step <= profile.iterationLimit; ++step) {
            if (handleCancellation()) return 130;

            const std::size_t cameraIndex = camsIter.next();
            Camera &camera = cameras[cameraIndex];
            MTensor target = camera.getGPUImage(model.getDownscaleFactor(step));
            model.fullIteration(camera, step, target, ssimWeight);
            model.schedulersStep(step);
            model.afterTrain(step);
            if (step > warmupLength) {
                const float normalization = 1.0f /
                    static_cast<float>(model.lastHeight * model.lastWidth);
                plateauCameraIndices[plateauSampleCount] = cameraIndex;
                msplat_record_last_loss(
                    plateauSampleCount,
                    lossSyncBatch,
                    normalization
                );
                ++plateauSampleCount;
            }
            msplat_commit();
            completedIteration = step;

            bool plateauReached = false;
            if (plateauSampleCount == lossSyncBatch) {
                msplat_sync_loss_window(plateauSampleCount, plateauLosses.data());
                double totalLoss = 0;
                const int firstWindowIteration = step - plateauSampleCount + 1;
                for (int index = 0; index < plateauSampleCount; ++index) {
                    const double loss = plateauLosses[index];
                    const std::size_t sampledCamera = plateauCameraIndices[index];
                    double &bestCameraLoss = bestCameraLosses[sampledCamera];
                    const double improvementThreshold = std::isfinite(bestCameraLoss)
                        ? std::max(1e-7, std::abs(bestCameraLoss) * 1e-4)
                        : 0;
                    if (!std::isfinite(bestCameraLoss) ||
                        loss < bestCameraLoss - improvementThreshold) {
                        bestCameraLoss = loss;
                        lastImprovementIteration = firstWindowIteration + index;
                    }
                    totalLoss += loss;
                }
                latestWindowLoss = totalLoss / static_cast<double>(plateauSampleCount);
                latestLossIteration = step;
                plateauSampleCount = 0;
                plateauReached = step - lastImprovementIteration >= profile.plateauWindow;
            }

            if (handleCancellation()) return 130;

            auto now = std::chrono::steady_clock::now();
            if (step == profile.iterationLimit || now - lastProgressAt >= std::chrono::seconds(1)) {
                msplat_gpu_sync();
                now = std::chrono::steady_clock::now();
                const double sessionElapsed = std::chrono::duration<double>(now - startedAt).count();
                const double elapsed = priorElapsedSeconds + sessionElapsed;
                const int sessionIterations = step - startingIteration;
                const double rate = sessionElapsed > 0
                    ? static_cast<double>(sessionIterations) / sessionElapsed
                    : 0;
                const double eta = rate > 0
                    ? static_cast<double>(profile.iterationLimit - step) / rate
                    : 0;
                json progress = {{"elapsed_seconds", elapsed},
                                 {"eta_seconds", eta},
                                 {"gaussian_count", model.num_active},
                                 {"iteration", step},
                                 {"iteration_limit", profile.iterationLimit},
                                 {"iterations_per_second", rate}};
                if (std::isfinite(latestWindowLoss)) {
                    progress["loss"] = latestWindowLoss;
                    progress["loss_iteration"] = latestLossIteration;
                }
                events.emit("progress", std::move(progress));
                lastProgressAt = now;
            }

            if (plateauReached && step < profile.iterationLimit) {
                stopReason = "plateau";
                events.emit("early_stop", {{"iteration", step},
                                           {"last_improvement_iteration", lastImprovementIteration},
                                           {"loss", latestWindowLoss},
                                           {"loss_iteration", latestLossIteration},
                                           {"plateau_window", profile.plateauWindow},
                                           {"reason", stopReason}});
                break;
            }

            constexpr int checkpointInterval = 500;
            if (step < profile.iterationLimit && step % checkpointInterval == 0) {
                if (plateauSampleCount != 0) {
                    throw std::runtime_error("checkpoint cadence split a pending loss batch");
                }
                lastCheckpoint = saveCheckpoint(
                    model,
                    checkpointRoot,
                    checkpointContext,
                    TrainerCheckpointState {
                        step,
                        lastImprovementIteration,
                        bestCameraLosses,
                        std::isfinite(latestWindowLoss)
                            ? std::optional<double>(latestWindowLoss)
                            : std::nullopt,
                        latestLossIteration,
                        cumulativeElapsed(),
                    }
                );
                emitCheckpoint("checkpoint_completed", *lastCheckpoint);
                if (handleCancellation()) return 130;
            }
        }

        if (handleCancellation()) return 130;

        if (!savePlyAtomically(model, outputPath, completedIteration)) {
            if (handleCancellation()) return 130;
            throw std::runtime_error("final output was not published");
        }
        const std::uintmax_t outputBytes = fs::file_size(outputPath);
        const double elapsed = cumulativeElapsed();

        json completed = {{"elapsed_seconds", elapsed},
                          {"gaussian_count", model.num_active},
                          {"geometry_digest", identity.geometryDigest},
                          {"input_digest", identity.inputDigest},
                          {"iteration", completedIteration},
                          {"iteration_limit", profile.iterationLimit},
                          {"output_bytes", outputBytes},
                          {"plateau_window", profile.plateauWindow},
                          {"profile", profile.name},
                          {"seed", seed},
                          {"stop_reason", stopReason},
                          {"trainer_build_digest", trainerBuildDigest},
                          {"version", APP_VERSION}};
        events.emit("completed", completed);
        if (!events.enabled()) std::cout << "EasySplat training completed: " << outputPath << '\n';
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "easysplat-train: " << error.what() << '\n';
        return 1;
    }
}
