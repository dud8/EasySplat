// Copyright (c) 2026 EasySplat contributors
// SPDX-License-Identifier: MIT

#include "colmap/exe/local_vocab_retriever.h"

#include "colmap/controllers/option_manager.h"
#include "colmap/feature/types.h"
#include "colmap/math/random.h"
#include "colmap/retrieval/visual_index.h"
#include "colmap/util/logging.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <functional>
#include <limits>
#include <memory>
#include <numeric>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sqlite3.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

namespace colmap {
namespace {

constexpr int kDescriptorColumns = 128;
constexpr int64_t kMaxDatabaseImages = 100'000;
constexpr uint64_t kMebibyte = 1024ULL * 1024ULL;
constexpr uint64_t kDefaultMemoryBudgetBytes = 2ULL * 1024ULL * kMebibyte;
constexpr uint64_t kMinimumMemoryBudgetBytes = 64ULL * kMebibyte;
constexpr uint64_t kMaximumMemoryBudgetBytes = 256ULL * 1024ULL * kMebibyte;
constexpr uint64_t kFixedRetrievalOverheadBytes = 64ULL * kMebibyte;
constexpr uint64_t kFloatDescriptorBytes = kDescriptorColumns * sizeof(float);
constexpr uint64_t kByteDescriptorBytes = kDescriptorColumns * sizeof(uint8_t);
// One-neighbor indexing retains a 32-byte inverted-file entry today. The
// larger allowance covers vector growth, word assignment, and score storage.
constexpr uint64_t kVisualIndexBytesPerDescriptor = 96;
// Centroids, FAISS copies, Hamming projection state, and inverted-file vectors.
constexpr uint64_t kVisualIndexBytesPerWord = 4096;
constexpr uint64_t kPerImageStateBytes = 4096;
constexpr uint64_t kPairStateBytes = 96;
constexpr uint64_t kInputIdentityStateBytes = 64;
constexpr uint64_t kExcludedImageStateBytes = 64;
constexpr uint64_t kMaximumImageNameBytes = 1024;
constexpr uint64_t kMaximumQueryLineBytes = kMaximumImageNameBytes;
constexpr uint64_t kMaximumExcludedPairLineBytes =
    2 * kMaximumImageNameBytes + 16;
constexpr uint64_t kMaximumImageGroupLineBytes =
    kMaximumImageNameBytes + 1 + 20;
constexpr uint64_t kMaximumQueryListLines =
    static_cast<uint64_t>(kMaxDatabaseImages);
constexpr std::string_view kRetrievalOutcomesMagic =
    "EASYSPLAT_RETRIEVAL_OUTCOMES_V2";
constexpr std::string_view kRetrievalOutcomesV3Magic =
    "EASYSPLAT_RETRIEVAL_OUTCOMES_V3";
constexpr std::string_view kRetrievalEngine = "localSiftVocabularyV2";
constexpr std::string_view kCrossGroupPolicy = "crossGroupV1";

constexpr uint64_t kSealedThreeThousandFrameFeatureCount = 3000ULL * 512ULL;
constexpr uint64_t kSealedThreeThousandFrameEstimate =
    kFixedRetrievalOverheadBytes +
    kSealedThreeThousandFrameFeatureCount *
        (kFloatDescriptorBytes + sizeof(FeatureKeypoint) +
         kByteDescriptorBytes + kVisualIndexBytesPerDescriptor) +
    65'536ULL * (kFloatDescriptorBytes + sizeof(uint64_t)) +
    3000ULL * kPerImageStateBytes + 512ULL * kVisualIndexBytesPerWord +
    3000ULL * 8ULL * (2ULL * (2ULL * 128ULL + 2ULL) + kPairStateBytes) +
    20ULL * 512ULL * 512ULL * kPairStateBytes +
    3000ULL * kExcludedImageStateBytes +
    3000ULL *
        (3ULL * (kMaximumImageGroupLineBytes + 1) + kInputIdentityStateBytes) +
    3ULL * (512ULL * 6ULL * sizeof(float)) +
    2ULL * (512ULL * kByteDescriptorBytes) +
    512ULL * (sizeof(size_t) + sizeof(float) + kByteDescriptorBytes);
static_assert(kSealedThreeThousandFrameEstimate <= kDefaultMemoryBudgetBytes,
              "the default budget must admit 3,000 images with 512 features");
constexpr uint64_t kMaximumShapeDescriptorBytes =
    100'000ULL * 8192ULL * kFloatDescriptorBytes;
static_assert(kMaximumShapeDescriptorBytes > kMaximumMemoryBudgetBytes,
              "the CLI budget cap must reject the maximum database shape");

struct RetrieverOptions {
  std::filesystem::path database_path;
  std::filesystem::path output_pair_list_path;
  std::string request_digest;
  int query_stride = 0;
  std::filesystem::path query_image_list_path;
  std::filesystem::path excluded_pair_list_path;
  std::filesystem::path image_group_list_path;
  std::string image_group_list_digest;
  int num_images = 20;
  int returned_neighbor_count = 8;
  int minimum_frame_separation = 0;
  int num_visual_words = 512;
  int max_features_per_image = 512;
  int max_training_descriptors = 65'536;
  std::string memory_budget_bytes_argument =
      std::to_string(kDefaultMemoryBudgetBytes);
  uint64_t memory_budget_bytes = kDefaultMemoryBudgetBytes;
  int num_iterations = 10;
  int num_rounds = 1;
  int num_checks = 64;
  int num_threads = -1;
};

[[noreturn]] void Fail(const std::string &message) {
  throw std::runtime_error(message);
}

std::string ErrnoMessage(const std::string &action,
                         const std::filesystem::path &path) {
  return action + ": " + path.string() + ": " + std::strerror(errno);
}

uint64_t ParseMemoryBudget(std::string_view argument) {
  uint64_t value = 0;
  const auto parsed = std::from_chars(argument.data(),
                                      argument.data() + argument.size(), value);
  if (argument.empty() || parsed.ec != std::errc() ||
      parsed.ptr != argument.data() + argument.size()) {
    Fail("--memory_budget_bytes must be an unsigned integer");
  }
  return value;
}

void ValidateBounds(const RetrieverOptions &options) {
  const auto require_range = [](const char *name, int value, int minimum,
                                int maximum) {
    if (value < minimum || value > maximum) {
      Fail(std::string("--") + name + " must be between " +
           std::to_string(minimum) + " and " + std::to_string(maximum));
    }
  };
  require_range("num_images", options.num_images, 1, 256);
  require_range("query_stride", options.query_stride, 1, 1'000'000);
  if (options.request_digest.size() != 64 ||
      !std::all_of(options.request_digest.begin(), options.request_digest.end(),
                   [](const char character) {
                     return (character >= '0' && character <= '9') ||
                            (character >= 'a' && character <= 'f');
                   })) {
    Fail("--request_digest must be exactly 64 lowercase SHA-256 characters");
  }
  if (options.image_group_list_path.empty() !=
      options.image_group_list_digest.empty()) {
    Fail("--image_group_list_path and --image_group_list_digest must be "
         "provided together");
  }
  if (!options.image_group_list_digest.empty() &&
      (options.image_group_list_digest.size() != 64 ||
       !std::all_of(options.image_group_list_digest.begin(),
                    options.image_group_list_digest.end(),
                    [](const char character) {
                      return (character >= '0' && character <= '9') ||
                             (character >= 'a' && character <= 'f');
                    }))) {
    Fail("--image_group_list_digest must be exactly 64 lowercase SHA-256 "
         "characters");
  }
  require_range("returned_neighbor_count", options.returned_neighbor_count, 1,
                64);
  if (options.returned_neighbor_count > options.num_images) {
    Fail("--returned_neighbor_count cannot exceed --num_images");
  }
  require_range("minimum_frame_separation", options.minimum_frame_separation, 0,
                1'000'000);
  require_range("num_visual_words", options.num_visual_words, 2, 8192);
  require_range("max_features_per_image", options.max_features_per_image, 2,
                8192);
  require_range("max_training_descriptors", options.max_training_descriptors,
                512, 262'144);
  if (options.memory_budget_bytes < kMinimumMemoryBudgetBytes ||
      options.memory_budget_bytes > kMaximumMemoryBudgetBytes) {
    Fail("--memory_budget_bytes must be between " +
         std::to_string(kMinimumMemoryBudgetBytes) + " and " +
         std::to_string(kMaximumMemoryBudgetBytes));
  }
  require_range("num_iterations", options.num_iterations, 1, 100);
  require_range("num_rounds", options.num_rounds, 1, 3);
  require_range("num_checks", options.num_checks, 1, 1024);
  if (options.num_threads == 0 || options.num_threads < -1 ||
      options.num_threads > 64) {
    Fail("--num_threads must be -1 or between 1 and 64");
  }
}

struct FileIdentity {
  dev_t device;
  ino_t inode;
  uint64_t bytes;
};

bool SameFile(const FileIdentity &first, const FileIdentity &second) {
  return first.device == second.device && first.inode == second.inode;
}

bool SameObject(const struct stat &first, const struct stat &second) {
  return first.st_dev == second.st_dev && first.st_ino == second.st_ino;
}

bool SameTimestamp(const struct timespec &first,
                   const struct timespec &second) {
  return first.tv_sec == second.tv_sec && first.tv_nsec == second.tv_nsec;
}

class FileDescriptor {
public:
  FileDescriptor() = default;
  explicit FileDescriptor(int descriptor) : descriptor_(descriptor) {}

  FileDescriptor(const FileDescriptor &) = delete;
  FileDescriptor &operator=(const FileDescriptor &) = delete;

  FileDescriptor(FileDescriptor &&other) noexcept
      : descriptor_(std::exchange(other.descriptor_, -1)) {}

  FileDescriptor &operator=(FileDescriptor &&other) noexcept {
    if (this != &other) {
      Reset();
      descriptor_ = std::exchange(other.descriptor_, -1);
    }
    return *this;
  }

  ~FileDescriptor() { Reset(); }

  int get() const { return descriptor_; }

private:
  void Reset() {
    if (descriptor_ >= 0) {
      static_cast<void>(::close(descriptor_));
      descriptor_ = -1;
    }
  }

  int descriptor_ = -1;
};

class DatabaseInputBinding {
public:
  explicit DatabaseInputBinding(const std::filesystem::path &path)
      : path_(path) {
    if (!path_.is_absolute()) {
      Fail("database path must be an absolute path");
    }
    const int descriptor =
        ::open(path_.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
      Fail(ErrnoMessage("could not open database path", path_));
    }
    descriptor_ = FileDescriptor(descriptor);

    struct stat status{};
    if (::fstat(descriptor_.get(), &status) != 0) {
      Fail(ErrnoMessage("could not inspect opened database path", path_));
    }
    if (!S_ISREG(status.st_mode) || status.st_size < 0) {
      Fail("database path is not a regular file: " + path_.string());
    }
    if (status.st_nlink != 1) {
      Fail("database path must have exactly one hard link: " + path_.string());
    }
    identity_ = {status.st_dev, status.st_ino,
                 static_cast<uint64_t>(status.st_size)};
    modification_time_ = status.st_mtimespec;
    change_time_ = status.st_ctimespec;
    ValidatePath();
  }

  DatabaseInputBinding(const DatabaseInputBinding &) = delete;
  DatabaseInputBinding &operator=(const DatabaseInputBinding &) = delete;

  const FileIdentity &identity() const { return identity_; }

  std::filesystem::path SQLitePath() const {
    return std::filesystem::path("/dev/fd/") /
           std::to_string(descriptor_.get());
  }

  void ValidatePath() const {
    struct stat opened{};
    struct stat named{};
    if (::fstat(descriptor_.get(), &opened) != 0 ||
        ::lstat(path_.c_str(), &named) != 0 || !S_ISREG(opened.st_mode) ||
        !S_ISREG(named.st_mode) || opened.st_nlink != 1 ||
        named.st_nlink != 1 || opened.st_size < 0 || named.st_size < 0 ||
        opened.st_dev != identity_.device || opened.st_ino != identity_.inode ||
        named.st_dev != identity_.device || named.st_ino != identity_.inode ||
        static_cast<uint64_t>(opened.st_size) != identity_.bytes ||
        static_cast<uint64_t>(named.st_size) != identity_.bytes ||
        !SameTimestamp(opened.st_mtimespec, modification_time_) ||
        !SameTimestamp(named.st_mtimespec, modification_time_) ||
        !SameTimestamp(opened.st_ctimespec, change_time_) ||
        !SameTimestamp(named.st_ctimespec, change_time_)) {
      Fail("database path changed while retrieval was using it: " +
           path_.string());
    }
  }

private:
  const std::filesystem::path path_;
  FileDescriptor descriptor_;
  FileIdentity identity_{};
  struct timespec modification_time_{};
  struct timespec change_time_{};
};

// Opens a directory, refusing the whole path when any part of it is a symbolic
// link. O_NOFOLLOW_ANY asks the kernel for that in one call, so no parent
// directory has to be readable — which is what a walk from the root needs and
// what the App Sandbox does not allow.
inline FileDescriptor
OpenDirectoryRefusingSymlinks(const std::filesystem::path &path,
                              const char *description) {
  int flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC;
#ifdef O_NOFOLLOW_ANY
  flags |= O_NOFOLLOW_ANY;
#else
  flags |= O_NOFOLLOW;
#endif
  int descriptor = -1;
  do {
    descriptor = ::open(path.c_str(), flags);
  } while (descriptor < 0 && errno == EINTR);
  if (descriptor < 0) {
    Fail(ErrnoMessage(std::string("could not open ") + description, path));
  }
  return FileDescriptor(descriptor);
}

class OutputPathBinding {
public:
  explicit OutputPathBinding(const std::filesystem::path &output)
      : output_(output), parent_path_(ValidatedParentPath(output)),
        output_leaf_(output.filename().string()) {
    std::vector<std::string> names;
    for (const std::filesystem::path &part : parent_path_.relative_path()) {
      const std::string name = part.string();
      if (name.empty() || name == "." || name == ".." ||
          name.find('/') != std::string::npos) {
        Fail("output pair list directory contains an invalid path component: " +
             parent_path_.string());
      }
      names.push_back(name);
    }

    // Bind the deepest directory first, then climb.
    //
    // This used to open "/" and walk down a component at a time. A process
    // under the App Sandbox may not open /Users, so that walk failed at its
    // first step whatever directory it was asked for, and retrieval could never
    // write its pair list. OpenDirectoryRefusingSymlinks applies the
    // no-symbolic-link rule to the whole path in one call and needs no read
    // access to any parent directory.
    FileDescriptor deepest =
        OpenDirectoryRefusingSymlinks(parent_path_, "output pair list directory");
    struct stat deepest_identity{};
    if (::fstat(deepest.get(), &deepest_identity) != 0 ||
        !S_ISDIR(deepest_identity.st_mode)) {
      Fail(ErrnoMessage("could not inspect output pair list directory",
                        parent_path_));
    }

    std::size_t bound_index = names.size();
    std::vector<DirectoryComponent> bound;
    bound.push_back(DirectoryComponent{
        bound_index == 0 ? std::string("/") : names[bound_index - 1],
        std::move(deepest), deepest_identity});

    // Climbing ends where the process stops being allowed to look. Everything
    // it can observe stays watched; what it cannot reach is the sandbox's
    // business. Any other refusal means this process could have watched the
    // directory and did not, so it fails rather than binding less than the path
    // deserves.
    while (bound_index > 0) {
      int parent_descriptor = -1;
      do {
        parent_descriptor = ::openat(bound.back().descriptor.get(), "..",
                                     O_RDONLY | O_DIRECTORY | O_CLOEXEC);
      } while (parent_descriptor < 0 && errno == EINTR);
      if (parent_descriptor < 0) {
        if (errno != EPERM) {
          Fail(ErrnoMessage(
              "could not open output pair list directory component",
              parent_path_));
        }
        break;
      }
      FileDescriptor parent(parent_descriptor);
      struct stat parent_identity{};
      struct stat named{};
      if (::fstat(parent.get(), &parent_identity) != 0 ||
          !S_ISDIR(parent_identity.st_mode) ||
          ::fstatat(parent.get(), bound.back().name.c_str(), &named,
                    AT_SYMLINK_NOFOLLOW) != 0 ||
          !S_ISDIR(named.st_mode) ||
          !SameObject(bound.back().identity, named)) {
        Fail("output pair list directory changed while it was opened: " +
             parent_path_.string());
      }
      --bound_index;
      bound.push_back(DirectoryComponent{
          bound_index == 0 ? std::string("/") : names[bound_index - 1],
          std::move(parent), parent_identity});
    }

    std::reverse(bound.begin(), bound.end());
    root_descriptor_ = std::move(bound.front().descriptor);
    root_identity_ = bound.front().identity;
    for (std::size_t index = 1; index < bound.size(); ++index) {
      components_.push_back(std::move(bound[index]));
    }
    ValidateDirectoryChain();
    CaptureInitialOutput();
  }

  OutputPathBinding(const OutputPathBinding &) = delete;
  OutputPathBinding &operator=(const OutputPathBinding &) = delete;

  int directory_descriptor() const {
    return components_.empty() ? root_descriptor_.get()
                               : components_.back().descriptor.get();
  }

  const std::filesystem::path &output_path() const { return output_; }
  const std::string &output_leaf() const { return output_leaf_; }
  const std::optional<FileIdentity> &initial_output_identity() const {
    return initial_output_identity_;
  }

  void ValidateBoundDirectory() const { ValidateDirectoryChain(); }

  bool TryCreateInitialOutputLink(const std::string &leaf) const {
    if (!initial_output_identity_.has_value()) {
      Fail("cannot create a rollback link without an initial output");
    }
    if (::linkat(directory_descriptor(), output_leaf_.c_str(),
                 directory_descriptor(), leaf.c_str(), 0) != 0) {
      if (errno == EEXIST) {
        return false;
      }
      Fail(ErrnoMessage("could not preserve the existing output pair list",
                        output_));
    }

    struct stat linked{};
    struct stat opened{};
    if (::fstatat(directory_descriptor(), leaf.c_str(), &linked,
                  AT_SYMLINK_NOFOLLOW) != 0 ||
        ::fstat(initial_output_descriptor_.get(), &opened) != 0 ||
        !S_ISREG(linked.st_mode) || !SameObject(linked, opened) ||
        linked.st_dev != initial_output_identity_->device ||
        linked.st_ino != initial_output_identity_->inode) {
      const FileIdentity linked_identity{
          linked.st_dev, linked.st_ino,
          linked.st_size < 0 ? 0 : static_cast<uint64_t>(linked.st_size)};
      RemoveTemporaryIfOwned(leaf, linked_identity);
      Fail("existing output pair list changed while it was preserved: " +
           output_.string());
    }
    return true;
  }

  void RemoveInitialOutputLink(const std::string &leaf) const {
    if (!initial_output_identity_.has_value()) {
      Fail("cannot remove a rollback link without an initial output");
    }
    struct stat linked{};
    if (::fstatat(directory_descriptor(), leaf.c_str(), &linked,
                  AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISREG(linked.st_mode) ||
        linked.st_dev != initial_output_identity_->device ||
        linked.st_ino != initial_output_identity_->inode) {
      Fail("preserved output pair list changed before cleanup: " +
           output_.string());
    }
    if (::unlinkat(directory_descriptor(), leaf.c_str(), 0) != 0) {
      Fail(
          ErrnoMessage("could not remove preserved output pair list", output_));
    }
  }

  void
  RestoreAfterFailedPublication(const std::string &rollback_leaf,
                                const FileIdentity &published_identity) const {
    if (initial_output_identity_.has_value()) {
      struct stat rollback{};
      struct stat opened{};
      if (::fstatat(directory_descriptor(), rollback_leaf.c_str(), &rollback,
                    AT_SYMLINK_NOFOLLOW) != 0 ||
          ::fstat(initial_output_descriptor_.get(), &opened) != 0 ||
          !S_ISREG(rollback.st_mode) || !SameObject(rollback, opened) ||
          rollback.st_dev != initial_output_identity_->device ||
          rollback.st_ino != initial_output_identity_->inode) {
        Fail("could not prove the preserved output before rollback: " +
             output_.string());
      }
      if (::renameat(directory_descriptor(), rollback_leaf.c_str(),
                     directory_descriptor(), output_leaf_.c_str()) != 0) {
        Fail(ErrnoMessage("could not restore the existing output pair list",
                          output_));
      }
      struct stat restored{};
      if (::fstatat(directory_descriptor(), output_leaf_.c_str(), &restored,
                    AT_SYMLINK_NOFOLLOW) != 0 ||
          !S_ISREG(restored.st_mode) || !SameObject(restored, opened)) {
        Fail("restored output pair list did not match its original file: " +
             output_.string());
      }
    } else {
      struct stat published{};
      if (::fstatat(directory_descriptor(), output_leaf_.c_str(), &published,
                    AT_SYMLINK_NOFOLLOW) != 0 ||
          !S_ISREG(published.st_mode) ||
          published.st_dev != published_identity.device ||
          published.st_ino != published_identity.inode) {
        Fail("could not prove the published output before rollback: " +
             output_.string());
      }
      if (::unlinkat(directory_descriptor(), output_leaf_.c_str(), 0) != 0) {
        Fail(ErrnoMessage("could not remove an unbound output pair list",
                          output_));
      }
    }
    if (::fsync(directory_descriptor()) != 0) {
      Fail(
          ErrnoMessage("could not sync the restored output pair list directory",
                       parent_path_));
    }
  }

  void ValidateForPublication() const {
    ValidateDirectoryChain();
    struct stat named{};
    if (::fstatat(directory_descriptor(), output_leaf_.c_str(), &named,
                  AT_SYMLINK_NOFOLLOW) != 0) {
      if (errno == ENOENT && !initial_output_identity_.has_value()) {
        return;
      }
      Fail(ErrnoMessage("could not revalidate output pair list", output_));
    }
    if (!S_ISREG(named.st_mode) || named.st_size < 0 ||
        !initial_output_identity_.has_value()) {
      Fail("output pair list changed during retrieval: " + output_.string());
    }
    struct stat opened{};
    if (::fstat(initial_output_descriptor_.get(), &opened) != 0 ||
        !S_ISREG(opened.st_mode) || !SameObject(opened, named) ||
        opened.st_dev != initial_output_identity_->device ||
        opened.st_ino != initial_output_identity_->inode) {
      Fail("output pair list changed during retrieval: " + output_.string());
    }
  }

  void ValidateTemporary(const std::string &leaf,
                         const FileIdentity &identity) const {
    struct stat named{};
    if (::fstatat(directory_descriptor(), leaf.c_str(), &named,
                  AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISREG(named.st_mode) || named.st_dev != identity.device ||
        named.st_ino != identity.inode) {
      Fail("temporary pair list changed before publication: " +
           output_.string());
    }
  }

  void RemoveTemporaryIfOwned(const std::string &leaf,
                              const FileIdentity &identity) const noexcept {
    struct stat named{};
    if (::fstatat(directory_descriptor(), leaf.c_str(), &named,
                  AT_SYMLINK_NOFOLLOW) == 0 &&
        S_ISREG(named.st_mode) && named.st_dev == identity.device &&
        named.st_ino == identity.inode) {
      static_cast<void>(::unlinkat(directory_descriptor(), leaf.c_str(), 0));
    }
  }

private:
  struct DirectoryComponent {
    std::string name;
    FileDescriptor descriptor;
    struct stat identity;
  };

  static std::filesystem::path
  ValidatedParentPath(const std::filesystem::path &output) {
    if (!output.is_absolute()) {
      Fail("output pair list path must be absolute");
    }
    const std::filesystem::path parent = output.parent_path();
    if (parent.empty() || output.filename().empty() ||
        output.filename() == "." || output.filename() == ".." ||
        output.lexically_normal() != output) {
      Fail("output pair list path is invalid: " + output.string());
    }
    return parent;
  }

  void ValidateDirectoryChain() const {
    // The bound descriptors follow their directories wherever those go, so on
    // their own they cannot tell that the path now leads somewhere else.
    // Resolve it again and require it to still arrive at what was bound.
    FileDescriptor resolved =
        OpenDirectoryRefusingSymlinks(parent_path_, "output pair list directory");
    struct stat resolved_identity{};
    struct stat deepest{};
    if (::fstat(resolved.get(), &resolved_identity) != 0 ||
        ::fstat(directory_descriptor(), &deepest) != 0 ||
        !S_ISDIR(resolved_identity.st_mode) ||
        !SameObject(resolved_identity, deepest)) {
      Fail("output pair list directory changed during retrieval: " +
           parent_path_.string());
    }
    struct stat root{};
    if (::fstat(root_descriptor_.get(), &root) != 0 || !S_ISDIR(root.st_mode) ||
        !SameObject(root, root_identity_)) {
      Fail("output pair list directory changed during retrieval: " +
           parent_path_.string());
    }
    int parent_descriptor = root_descriptor_.get();
    for (const DirectoryComponent &component : components_) {
      struct stat opened{};
      struct stat named{};
      if (::fstat(component.descriptor.get(), &opened) != 0 ||
          ::fstatat(parent_descriptor, component.name.c_str(), &named,
                    AT_SYMLINK_NOFOLLOW) != 0 ||
          !S_ISDIR(opened.st_mode) || !S_ISDIR(named.st_mode) ||
          !SameObject(component.identity, opened) ||
          !SameObject(opened, named)) {
        Fail("output pair list directory changed during retrieval: " +
             parent_path_.string());
      }
      parent_descriptor = component.descriptor.get();
    }
  }

  void CaptureInitialOutput() {
    struct stat named{};
    if (::fstatat(directory_descriptor(), output_leaf_.c_str(), &named,
                  AT_SYMLINK_NOFOLLOW) != 0) {
      if (errno == ENOENT) {
        return;
      }
      Fail(ErrnoMessage("could not inspect output pair list", output_));
    }
    if (!S_ISREG(named.st_mode) || named.st_size < 0) {
      Fail("output pair list is not a regular file: " + output_.string());
    }
    int flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW;
#ifdef O_RESOLVE_BENEATH
    flags |= O_RESOLVE_BENEATH;
#endif
    const int descriptor =
        ::openat(directory_descriptor(), output_leaf_.c_str(), flags);
    if (descriptor < 0) {
      Fail(ErrnoMessage("could not open output pair list", output_));
    }
    initial_output_descriptor_ = FileDescriptor(descriptor);
    struct stat opened{};
    struct stat rebound{};
    if (::fstat(initial_output_descriptor_.get(), &opened) != 0 ||
        ::fstatat(directory_descriptor(), output_leaf_.c_str(), &rebound,
                  AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISREG(opened.st_mode) || opened.st_size < 0 ||
        !SameObject(named, opened) || !SameObject(opened, rebound)) {
      Fail("output pair list changed while it was opened: " + output_.string());
    }
    initial_output_identity_ = FileIdentity{
        opened.st_dev, opened.st_ino, static_cast<uint64_t>(opened.st_size)};
  }

  std::filesystem::path output_;
  std::filesystem::path parent_path_;
  std::string output_leaf_;
  FileDescriptor root_descriptor_;
  struct stat root_identity_{};
  std::vector<DirectoryComponent> components_;
  FileDescriptor initial_output_descriptor_;
  std::optional<FileIdentity> initial_output_identity_;
};

class StableInputBinding {
public:
  StableInputBinding(const std::filesystem::path &path, std::string label)
      : path_(path), label_(std::move(label)) {
    if (!path_.is_absolute()) {
      Fail(label_ + " must be an absolute path");
    }
    const int descriptor =
        ::open(path_.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
      Fail(ErrnoMessage("could not open " + label_, path_));
    }
    descriptor_ = FileDescriptor(descriptor);

    struct stat status{};
    if (::fstat(descriptor_.get(), &status) != 0) {
      Fail(ErrnoMessage("could not inspect opened " + label_, path_));
    }
    if (!S_ISREG(status.st_mode) || status.st_size < 0) {
      Fail(label_ + " is not a regular file: " + path_.string());
    }
    if (status.st_nlink != 1) {
      Fail(label_ + " must have exactly one hard link: " + path_.string());
    }
    identity_ = {status.st_dev, status.st_ino,
                 static_cast<uint64_t>(status.st_size)};
    modification_time_ = status.st_mtimespec;
    change_time_ = status.st_ctimespec;
    ValidatePath();
  }

  StableInputBinding(const StableInputBinding &) = delete;
  StableInputBinding &operator=(const StableInputBinding &) = delete;
  StableInputBinding(StableInputBinding &&) noexcept = default;
  StableInputBinding &operator=(StableInputBinding &&) noexcept = default;

  const FileIdentity &identity() const { return identity_; }

  std::string_view ReadSnapshot(uint64_t maximum_bytes) {
    if (identity_.bytes > maximum_bytes) {
      Fail(label_ + " exceeds the supported size bound");
    }
    ValidatePath();
    std::string first = ReadCurrentContents();
    ValidatePath();
    std::string second = ReadCurrentContents();
    ValidatePath();
    if (first != second) {
      Fail(label_ +
           " changed while retrieval was reading it: " + path_.string());
    }
    snapshot_ = std::move(second);
    return *snapshot_;
  }

  void ValidateUnchanged() const {
    ValidatePath();
    if (!snapshot_.has_value() || ReadCurrentContents() != *snapshot_) {
      Fail(label_ + " changed while retrieval was using it: " + path_.string());
    }
    ValidatePath();
  }

private:
  void ValidatePath() const {
    struct stat opened{};
    struct stat named{};
    if (::fstat(descriptor_.get(), &opened) != 0 ||
        ::lstat(path_.c_str(), &named) != 0 || !S_ISREG(opened.st_mode) ||
        !S_ISREG(named.st_mode) || opened.st_nlink != 1 ||
        named.st_nlink != 1 || opened.st_size < 0 || named.st_size < 0 ||
        opened.st_dev != identity_.device || opened.st_ino != identity_.inode ||
        named.st_dev != identity_.device || named.st_ino != identity_.inode ||
        static_cast<uint64_t>(opened.st_size) != identity_.bytes ||
        static_cast<uint64_t>(named.st_size) != identity_.bytes ||
        !SameTimestamp(opened.st_mtimespec, modification_time_) ||
        !SameTimestamp(named.st_mtimespec, modification_time_) ||
        !SameTimestamp(opened.st_ctimespec, change_time_) ||
        !SameTimestamp(named.st_ctimespec, change_time_)) {
      Fail(label_ +
           " path changed while retrieval was using it: " + path_.string());
    }
  }

  std::string ReadCurrentContents() const {
    if (identity_.bytes >
        static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
      Fail(label_ + " cannot fit in process memory");
    }
    std::string contents(static_cast<size_t>(identity_.bytes), '\0');
    size_t offset = 0;
    while (offset < contents.size()) {
      const ssize_t count =
          ::pread(descriptor_.get(), contents.data() + offset,
                  contents.size() - offset, static_cast<off_t>(offset));
      if (count < 0) {
        if (errno == EINTR) {
          continue;
        }
        Fail(ErrnoMessage("could not read " + label_, path_));
      }
      if (count == 0) {
        Fail(label_ +
             " changed while retrieval was reading it: " + path_.string());
      }
      offset += static_cast<size_t>(count);
    }
    return contents;
  }

  std::filesystem::path path_;
  std::string label_;
  FileDescriptor descriptor_;
  FileIdentity identity_{};
  struct timespec modification_time_{};
  struct timespec change_time_{};
  std::optional<std::string> snapshot_;
};

struct OptionalInputs {
  std::optional<StableInputBinding> query_images;
  std::optional<StableInputBinding> excluded_pairs;
  std::optional<StableInputBinding> image_groups;

  void ValidateUnchanged() const {
    if (query_images.has_value()) {
      query_images->ValidateUnchanged();
    }
    if (excluded_pairs.has_value()) {
      excluded_pairs->ValidateUnchanged();
    }
    if (image_groups.has_value()) {
      image_groups->ValidateUnchanged();
    }
  }
};

class DatabaseSidecarBindings {
public:
  explicit DatabaseSidecarBindings(const std::filesystem::path &database_path) {
    for (const char *suffix : {"-wal", "-journal", "-shm"}) {
      Sidecar sidecar;
      sidecar.path = database_path.string() + suffix;
      struct stat status{};
      if (::lstat(sidecar.path.c_str(), &status) == 0) {
        if (!S_ISREG(status.st_mode) || status.st_size < 0 ||
            status.st_nlink != 1) {
          Fail("retrieval database has an unsafe SQLite " +
               std::string(suffix + 1) + " sidecar");
        }
        if ((std::string_view(suffix) == "-wal" ||
             std::string_view(suffix) == "-journal") &&
            status.st_size > 0) {
          Fail("retrieval database has a pending SQLite " +
               std::string(suffix + 1) + " sidecar");
        }
        sidecar.identity = status;
      } else if (errno != ENOENT) {
        Fail(ErrnoMessage("could not inspect retrieval database sidecar",
                          sidecar.path));
      }
      sidecars_.push_back(std::move(sidecar));
    }
  }

  void ValidateUnchanged() const {
    for (const Sidecar &sidecar : sidecars_) {
      struct stat status{};
      if (::lstat(sidecar.path.c_str(), &status) != 0) {
        if (errno == ENOENT && !sidecar.identity.has_value()) {
          continue;
        }
        Fail("retrieval database SQLite sidecar changed during retrieval: " +
             sidecar.path.string());
      }
      if (!sidecar.identity.has_value() || !S_ISREG(status.st_mode) ||
          status.st_nlink != 1 ||
          !SameObject(status, sidecar.identity.value()) ||
          status.st_size != sidecar.identity->st_size ||
          !SameTimestamp(status.st_mtimespec, sidecar.identity->st_mtimespec) ||
          !SameTimestamp(status.st_ctimespec, sidecar.identity->st_ctimespec)) {
        Fail("retrieval database SQLite sidecar changed during retrieval: " +
             sidecar.path.string());
      }
    }
  }

private:
  struct Sidecar {
    std::filesystem::path path;
    std::optional<struct stat> identity;
  };

  std::vector<Sidecar> sidecars_;
};

std::string EncodeSQLiteURIPath(std::string_view path) {
  constexpr char kHex[] = "0123456789ABCDEF";
  std::string encoded;
  encoded.reserve(path.size() + 16);
  for (const unsigned char character : path) {
    const bool unreserved = (character >= 'a' && character <= 'z') ||
                            (character >= 'A' && character <= 'Z') ||
                            (character >= '0' && character <= '9') ||
                            character == '-' || character == '.' ||
                            character == '_' || character == '~' ||
                            character == '/';
    if (unreserved) {
      encoded.push_back(static_cast<char>(character));
    } else {
      encoded.push_back('%');
      encoded.push_back(kHex[character >> 4]);
      encoded.push_back(kHex[character & 0x0f]);
    }
  }
  return encoded;
}

class SQLiteDatabase {
public:
  explicit SQLiteDatabase(const DatabaseInputBinding &binding) {
    const std::filesystem::path path = binding.SQLitePath();
    const std::string uri =
        "file://" + EncodeSQLiteURIPath(path.string()) + "?mode=ro&immutable=1";
    const int result = sqlite3_open_v2(
        uri.c_str(), &database_,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nullptr);
    if (result != SQLITE_OK) {
      const std::string detail = database_ == nullptr
                                     ? sqlite3_errstr(result)
                                     : sqlite3_errmsg(database_);
      if (database_ != nullptr) {
        sqlite3_close(database_);
        database_ = nullptr;
      }
      Fail("could not open retrieval database read-only: " + detail);
    }
    if (sqlite3_db_readonly(database_, "main") != 1) {
      sqlite3_close(database_);
      database_ = nullptr;
      Fail("retrieval database did not open read-only");
    }
    try {
      Execute("PRAGMA query_only = ON");
      Execute("BEGIN");
    } catch (...) {
      sqlite3_close(database_);
      database_ = nullptr;
      throw;
    }
  }

  SQLiteDatabase(const SQLiteDatabase &) = delete;
  SQLiteDatabase &operator=(const SQLiteDatabase &) = delete;

  ~SQLiteDatabase() {
    if (database_ != nullptr) {
      sqlite3_close(database_);
    }
  }

  sqlite3 *get() const { return database_; }

  void Execute(const char *sql) {
    char *error = nullptr;
    const int result = sqlite3_exec(database_, sql, nullptr, nullptr, &error);
    if (result != SQLITE_OK) {
      const std::string detail =
          error == nullptr ? sqlite3_errmsg(database_) : std::string(error);
      sqlite3_free(error);
      Fail("SQLite command failed: " + detail);
    }
  }

private:
  sqlite3 *database_ = nullptr;
};

class SQLiteStatement {
public:
  SQLiteStatement(sqlite3 *database, const std::string &sql)
      : database_(database) {
    const int result =
        sqlite3_prepare_v2(database_, sql.c_str(), static_cast<int>(sql.size()),
                           &statement_, nullptr);
    if (result != SQLITE_OK) {
      Fail("could not prepare retrieval database query: " +
           std::string(sqlite3_errmsg(database_)));
    }
  }

  SQLiteStatement(const SQLiteStatement &) = delete;
  SQLiteStatement &operator=(const SQLiteStatement &) = delete;

  ~SQLiteStatement() {
    if (statement_ != nullptr) {
      sqlite3_finalize(statement_);
    }
  }

  sqlite3_stmt *get() const { return statement_; }

  bool Step() {
    const int result = sqlite3_step(statement_);
    if (result == SQLITE_ROW) {
      return true;
    }
    if (result == SQLITE_DONE) {
      return false;
    }
    Fail("could not read retrieval database: " +
         std::string(sqlite3_errmsg(database_)));
  }

private:
  sqlite3 *database_;
  sqlite3_stmt *statement_ = nullptr;
};

std::unordered_set<std::string> TableColumns(sqlite3 *database,
                                             const char *table) {
  SQLiteStatement statement(database,
                            "PRAGMA table_info(" + std::string(table) + ")");
  std::unordered_set<std::string> columns;
  while (statement.Step()) {
    if (sqlite3_column_type(statement.get(), 1) != SQLITE_TEXT) {
      Fail("retrieval database has an invalid " + std::string(table) +
           " table");
    }
    const auto *text = sqlite3_column_text(statement.get(), 1);
    const int bytes = sqlite3_column_bytes(statement.get(), 1);
    if (text == nullptr || bytes <= 0) {
      Fail("retrieval database has an invalid " + std::string(table) +
           " table");
    }
    columns.emplace(reinterpret_cast<const char *>(text), bytes);
  }
  return columns;
}

bool ValidateSchema(sqlite3 *database) {
  const std::array<std::pair<const char *, std::array<const char *, 2>>, 1>
      image_schema = {{{"images", {"image_id", "name"}}}};
  for (const auto &[table, required] : image_schema) {
    const auto columns = TableColumns(database, table);
    for (const char *column : required) {
      if (columns.find(column) == columns.end()) {
        Fail("retrieval database has an invalid " + std::string(table) +
             " table");
      }
    }
  }
  bool descriptor_has_type = false;
  for (const char *table : {"keypoints", "descriptors"}) {
    const auto columns = TableColumns(database, table);
    for (const char *column : {"image_id", "rows", "cols", "data"}) {
      if (columns.find(column) == columns.end()) {
        Fail("retrieval database has an invalid " + std::string(table) +
             " table");
      }
    }
    if (std::string_view(table) == "descriptors") {
      descriptor_has_type = columns.find("type") != columns.end();
    }
  }
  return descriptor_has_type;
}

struct RawMatrix {
  int64_t rows = 0;
  int64_t columns = 0;
  std::vector<uint8_t> bytes;
};

struct MatrixMetadata {
  bool present = false;
  int64_t rows = 0;
  int64_t columns = 0;
  uint64_t bytes = 0;
};

struct ImageFeatureMetadata {
  MatrixMetadata keypoints;
  MatrixMetadata descriptors;
  uint64_t selected_rows = 0;
};

uint64_t CheckedMatrixBytes(int64_t rows, int64_t columns,
                            uint64_t element_size, const char *table,
                            int image_id) {
  if (rows < 0 || columns < 0) {
    Fail("retrieval database has invalid " + std::string(table) +
         " dimensions for image ID " + std::to_string(image_id));
  }
  const uint64_t unsigned_rows = static_cast<uint64_t>(rows);
  const uint64_t unsigned_columns = static_cast<uint64_t>(columns);
  if (unsigned_columns != 0 &&
      unsigned_rows > std::numeric_limits<uint64_t>::max() / unsigned_columns) {
    Fail("retrieval database has overflowing " + std::string(table) +
         " dimensions for image ID " + std::to_string(image_id));
  }
  const uint64_t elements = unsigned_rows * unsigned_columns;
  if (element_size != 0 &&
      elements > std::numeric_limits<uint64_t>::max() / element_size) {
    Fail("retrieval database has overflowing " + std::string(table) +
         " dimensions for image ID " + std::to_string(image_id));
  }
  const uint64_t bytes = elements * element_size;
  if (bytes > static_cast<uint64_t>(std::numeric_limits<int>::max())) {
    Fail("retrieval database " + std::string(table) +
         " blob exceeds the supported bound for image ID " +
         std::to_string(image_id));
  }
  return bytes;
}

RawMatrix ReadMatrix(sqlite3 *database, const char *table, int image_id,
                     const MatrixMetadata &metadata) {
  if (!metadata.present) {
    return {};
  }
  SQLiteStatement statement(database, "SELECT data FROM " + std::string(table) +
                                          " WHERE image_id = ?");
  if (sqlite3_bind_int(statement.get(), 1, image_id) != SQLITE_OK) {
    Fail("could not bind retrieval database image ID");
  }
  if (!statement.Step()) {
    Fail("retrieval database changed while reading " + std::string(table) +
         " for image ID " + std::to_string(image_id));
  }
  RawMatrix matrix;
  matrix.rows = metadata.rows;
  matrix.columns = metadata.columns;
  const int blob_type = sqlite3_column_type(statement.get(), 0);
  const int actual = sqlite3_column_bytes(statement.get(), 0);
  if ((blob_type != SQLITE_BLOB && blob_type != SQLITE_NULL) || actual < 0 ||
      static_cast<uint64_t>(actual) != metadata.bytes) {
    Fail("retrieval database has an invalid " + std::string(table) +
         " blob for image ID " + std::to_string(image_id));
  }
  matrix.bytes.resize(static_cast<size_t>(metadata.bytes));
  if (metadata.bytes > 0) {
    const void *blob_data = sqlite3_column_blob(statement.get(), 0);
    if (blob_data == nullptr) {
      const int sqlite_error = sqlite3_errcode(database);
      Fail("could not read retrieval database " + std::string(table) +
           " blob for image ID " + std::to_string(image_id) + " (SQLite code " +
           std::to_string(sqlite_error) + ")");
    }
    std::memcpy(matrix.bytes.data(), blob_data, matrix.bytes.size());
  }
  if (statement.Step()) {
    Fail("retrieval database has duplicate " + std::string(table) +
         " rows for image ID " + std::to_string(image_id));
  }
  return matrix;
}

uint64_t CheckedMemoryAdd(uint64_t first, uint64_t second) {
  if (first > std::numeric_limits<uint64_t>::max() - second) {
    Fail("retrieval memory estimate overflowed");
  }
  return first + second;
}

uint64_t CheckedMemoryMultiply(uint64_t first, uint64_t second) {
  if (second != 0 && first > std::numeric_limits<uint64_t>::max() / second) {
    Fail("retrieval memory estimate overflowed");
  }
  return first * second;
}

void AddMemoryProduct(uint64_t *estimate, uint64_t count, uint64_t bytes) {
  *estimate = CheckedMemoryAdd(*estimate, CheckedMemoryMultiply(count, bytes));
}

struct ImageFeatures {
  int retrieval_id;
  std::string name;
  FeatureKeypoints keypoints;
  FeatureDescriptorsFloat descriptors;
};

struct ImageRecord {
  int image_id;
  std::string name;
};

bool ContainsWhitespace(std::string_view value) {
  return std::any_of(value.begin(), value.end(), [](const unsigned char byte) {
    return std::isspace(byte) != 0;
  });
}

bool BytewiseLess(std::string_view first, std::string_view second) {
  return std::lexicographical_compare(
      first.begin(), first.end(), second.begin(), second.end(),
      [](const char first_byte, const char second_byte) {
        return static_cast<unsigned char>(first_byte) <
               static_cast<unsigned char>(second_byte);
      });
}

struct ImageTableMetadata {
  uint64_t count = 0;
  uint64_t total_name_bytes = 0;
  uint64_t minimum_name_bytes = 0;
  uint64_t maximum_name_bytes = 0;
};

ImageTableMetadata ReadImageTableMetadata(sqlite3 *database) {
  SQLiteStatement statement(
      database, "SELECT COUNT(*), "
                "COALESCE(SUM(CASE WHEN typeof(name) = 'text' THEN "
                "length(CAST(name AS BLOB)) ELSE 0 END), 0), "
                "COALESCE(MIN(CASE WHEN typeof(name) = 'text' THEN "
                "length(CAST(name AS BLOB)) ELSE NULL END), 0), "
                "COALESCE(MAX(CASE WHEN typeof(name) = 'text' THEN "
                "length(CAST(name AS BLOB)) ELSE 0 END), 0), "
                "COALESCE(SUM(CASE WHEN typeof(image_id) = 'integer' AND "
                "typeof(name) = 'text' THEN 0 ELSE 1 END), 0) FROM images");
  if (!statement.Step()) {
    Fail("retrieval database has an invalid images table");
  }
  for (int column = 0; column < 5; ++column) {
    if (sqlite3_column_type(statement.get(), column) != SQLITE_INTEGER) {
      Fail("retrieval database has an invalid images table");
    }
  }
  const int64_t raw_count = sqlite3_column_int64(statement.get(), 0);
  const int64_t raw_total_name_bytes = sqlite3_column_int64(statement.get(), 1);
  const int64_t raw_minimum_name_bytes =
      sqlite3_column_int64(statement.get(), 2);
  const int64_t raw_maximum_name_bytes =
      sqlite3_column_int64(statement.get(), 3);
  const int64_t invalid_rows = sqlite3_column_int64(statement.get(), 4);
  if (raw_count < 0 || raw_total_name_bytes < 0 || raw_minimum_name_bytes < 0 ||
      raw_maximum_name_bytes < 0 || invalid_rows != 0) {
    Fail("retrieval database has an invalid images table");
  }
  ImageTableMetadata metadata{static_cast<uint64_t>(raw_count),
                              static_cast<uint64_t>(raw_total_name_bytes),
                              static_cast<uint64_t>(raw_minimum_name_bytes),
                              static_cast<uint64_t>(raw_maximum_name_bytes)};
  if (metadata.count < 2) {
    Fail("retrieval database contains fewer than two images");
  }
  if (metadata.count > static_cast<uint64_t>(kMaxDatabaseImages)) {
    Fail("retrieval database contains too many images");
  }
  if (metadata.minimum_name_bytes == 0 || metadata.maximum_name_bytes == 0) {
    Fail("retrieval database contains an invalid image name");
  }
  if (metadata.maximum_name_bytes > kMaximumImageNameBytes) {
    Fail("retrieval database image name exceeds " +
         std::to_string(kMaximumImageNameBytes) + " bytes");
  }
  if (metadata.total_name_bytes >
      CheckedMemoryMultiply(metadata.count, kMaximumImageNameBytes)) {
    Fail("retrieval database has invalid image-name metadata");
  }
  if (statement.Step()) {
    Fail("retrieval database returned duplicate image metadata");
  }
  return metadata;
}

uint64_t MaximumUndirectedPairs(uint64_t image_count) {
  if (image_count < 2) {
    return 0;
  }
  return CheckedMemoryMultiply(image_count, image_count - 1) / 2;
}

uint64_t MaximumExclusionListLines(uint64_t image_count) {
  const uint64_t comment_allowance = std::min<uint64_t>(
      static_cast<uint64_t>(kMaxDatabaseImages),
      CheckedMemoryAdd(CheckedMemoryMultiply(image_count, 4), 1024));
  return CheckedMemoryAdd(MaximumUndirectedPairs(image_count),
                          comment_allowance);
}

void ValidateOptionalInputSizes(const ImageTableMetadata &images,
                                const OptionalInputs &inputs) {
  if (inputs.query_images.has_value()) {
    const uint64_t maximum_query_bytes = CheckedMemoryMultiply(
        kMaximumQueryListLines, kMaximumQueryLineBytes + 1);
    if (inputs.query_images->identity().bytes > maximum_query_bytes) {
      Fail("query image list exceeds the supported size bound");
    }
  }
  if (inputs.excluded_pairs.has_value()) {
    const uint64_t maximum_exclusion_bytes =
        CheckedMemoryMultiply(MaximumExclusionListLines(images.count),
                              kMaximumExcludedPairLineBytes + 1);
    if (inputs.excluded_pairs->identity().bytes > maximum_exclusion_bytes) {
      Fail("excluded pair list exceeds the supported size bound");
    }
  }
  if (inputs.image_groups.has_value()) {
    const uint64_t maximum_group_bytes =
        CheckedMemoryMultiply(images.count, kMaximumImageGroupLineBytes + 1);
    if (inputs.image_groups->identity().bytes > maximum_group_bytes) {
      Fail("image group list exceeds the supported size bound");
    }
  }
}

uint64_t EstimateInputMemory(const ImageTableMetadata &images,
                             const OptionalInputs &inputs) {
  uint64_t estimate = kFixedRetrievalOverheadBytes;
  AddMemoryProduct(&estimate, images.total_name_bytes, 4);
  AddMemoryProduct(&estimate, images.count, kPerImageStateBytes);
  if (inputs.query_images.has_value()) {
    AddMemoryProduct(&estimate, inputs.query_images->identity().bytes, 2);
    AddMemoryProduct(&estimate, images.count, kInputIdentityStateBytes);
  }
  if (inputs.excluded_pairs.has_value()) {
    AddMemoryProduct(&estimate, inputs.excluded_pairs->identity().bytes, 2);
    const uint64_t minimum_pair_line_bytes = CheckedMemoryAdd(
        CheckedMemoryMultiply(images.minimum_name_bytes, 2), 1);
    const uint64_t possible_pairs = std::min<uint64_t>(
        MaximumUndirectedPairs(images.count),
        CheckedMemoryAdd(inputs.excluded_pairs->identity().bytes /
                             minimum_pair_line_bytes,
                         1));
    AddMemoryProduct(&estimate, possible_pairs, kPairStateBytes);
  }
  if (inputs.image_groups.has_value()) {
    AddMemoryProduct(&estimate, inputs.image_groups->identity().bytes, 3);
    AddMemoryProduct(&estimate, images.count, kInputIdentityStateBytes);
  }
  return estimate;
}

void RequireMemoryBudget(uint64_t estimate, uint64_t budget) {
  if (estimate > budget) {
    Fail("retrieval memory budget is too small: conservative estimate " +
         std::to_string(estimate) + " bytes exceeds " + std::to_string(budget) +
         " bytes");
  }
}

std::vector<ImageRecord> ReadImages(sqlite3 *database,
                                    const ImageTableMetadata &metadata) {
  SQLiteStatement statement(
      database,
      "SELECT image_id, name FROM images ORDER BY name COLLATE BINARY");
  std::vector<ImageRecord> images;
  images.reserve(static_cast<size_t>(metadata.count));
  std::unordered_set<int> identifiers;
  std::unordered_set<std::string> names;
  while (statement.Step()) {
    if (sqlite3_column_type(statement.get(), 0) != SQLITE_INTEGER ||
        sqlite3_column_type(statement.get(), 1) != SQLITE_TEXT) {
      Fail("retrieval database has an invalid images table");
    }
    const int64_t raw_identifier = sqlite3_column_int64(statement.get(), 0);
    if (raw_identifier <= 0 ||
        raw_identifier > std::numeric_limits<int>::max()) {
      Fail("retrieval database contains an unsupported image identifier");
    }
    const auto *name_data = sqlite3_column_text(statement.get(), 1);
    const int name_size = sqlite3_column_bytes(statement.get(), 1);
    if (name_data == nullptr || name_size <= 0 ||
        static_cast<uint64_t>(name_size) > kMaximumImageNameBytes) {
      Fail("retrieval database contains an invalid image name");
    }
    std::string name(reinterpret_cast<const char *>(name_data), name_size);
    if (name.empty() || name.find('\0') != std::string::npos ||
        ContainsWhitespace(name)) {
      Fail("retrieval database contains an invalid image name");
    }
    const int identifier = static_cast<int>(raw_identifier);
    if (!identifiers.insert(identifier).second) {
      Fail("retrieval database contains duplicate image identifiers");
    }
    if (!names.insert(name).second) {
      Fail("retrieval database contains duplicate image names");
    }
    images.push_back({identifier, std::move(name)});
  }
  if (images.size() != static_cast<size_t>(metadata.count)) {
    Fail("retrieval database changed while reading image names");
  }
  return images;
}

std::unordered_map<int, MatrixMetadata>
ReadMatrixMetadata(sqlite3 *database, const char *table, uint64_t element_size,
                   bool descriptor_has_type,
                   const std::unordered_set<int> &known_image_ids) {
  std::string sql = "SELECT image_id, rows, cols, typeof(data), length(data)";
  if (descriptor_has_type && std::string_view(table) == "descriptors") {
    sql += ", type";
  }
  sql += " FROM " + std::string(table) + " ORDER BY image_id";
  SQLiteStatement statement(database, sql);
  std::unordered_map<int, MatrixMetadata> metadata_by_id;
  while (statement.Step()) {
    if (sqlite3_column_type(statement.get(), 0) != SQLITE_INTEGER) {
      Fail("retrieval database has an invalid " + std::string(table) +
           " image ID");
    }
    const int64_t raw_image_id = sqlite3_column_int64(statement.get(), 0);
    if (raw_image_id <= 0 || raw_image_id > std::numeric_limits<int>::max()) {
      Fail("retrieval database has an invalid " + std::string(table) +
           " image ID");
    }
    const int image_id = static_cast<int>(raw_image_id);
    if (known_image_ids.find(image_id) == known_image_ids.end()) {
      Fail("retrieval database " + std::string(table) +
           " row references unknown image ID " + std::to_string(image_id));
    }
    if (sqlite3_column_type(statement.get(), 1) != SQLITE_INTEGER ||
        sqlite3_column_type(statement.get(), 2) != SQLITE_INTEGER) {
      Fail("retrieval database has invalid " + std::string(table) +
           " dimensions for image ID " + std::to_string(image_id));
    }

    MatrixMetadata metadata;
    metadata.present = true;
    metadata.rows = sqlite3_column_int64(statement.get(), 1);
    metadata.columns = sqlite3_column_int64(statement.get(), 2);
    if (std::string_view(table) == "keypoints") {
      if (metadata.columns != 4 && metadata.columns != 6) {
        Fail("retrieval keypoints must use exactly four or six columns for "
             "image ID " +
             std::to_string(image_id));
      }
    } else if (metadata.columns != kDescriptorColumns) {
      Fail("retrieval descriptors must use 128 columns for image ID " +
           std::to_string(image_id));
    }
    if (descriptor_has_type && std::string_view(table) == "descriptors") {
      if (sqlite3_column_type(statement.get(), 5) != SQLITE_INTEGER ||
          sqlite3_column_int(statement.get(), 5) != 0) {
        Fail("retrieval database contains an unsupported descriptor type for "
             "image ID " +
             std::to_string(image_id));
      }
    }
    metadata.bytes = CheckedMatrixBytes(metadata.rows, metadata.columns,
                                        element_size, table, image_id);

    if (sqlite3_column_type(statement.get(), 3) != SQLITE_TEXT) {
      Fail("retrieval database has an invalid " + std::string(table) +
           " blob for image ID " + std::to_string(image_id));
    }
    const auto *storage_data = sqlite3_column_text(statement.get(), 3);
    const int storage_size = sqlite3_column_bytes(statement.get(), 3);
    if (storage_data == nullptr || storage_size <= 0) {
      Fail("retrieval database has an invalid " + std::string(table) +
           " blob for image ID " + std::to_string(image_id));
    }
    const std::string storage(reinterpret_cast<const char *>(storage_data),
                              storage_size);
    uint64_t actual_bytes = 0;
    if (storage == "blob") {
      if (sqlite3_column_type(statement.get(), 4) != SQLITE_INTEGER) {
        Fail("retrieval database has an invalid " + std::string(table) +
             " blob for image ID " + std::to_string(image_id));
      }
      const int64_t raw_bytes = sqlite3_column_int64(statement.get(), 4);
      if (raw_bytes < 0) {
        Fail("retrieval database has an invalid " + std::string(table) +
             " blob for image ID " + std::to_string(image_id));
      }
      actual_bytes = static_cast<uint64_t>(raw_bytes);
    } else if (storage != "null" ||
               sqlite3_column_type(statement.get(), 4) != SQLITE_NULL) {
      Fail("retrieval database has an invalid " + std::string(table) +
           " blob for image ID " + std::to_string(image_id));
    }
    if (actual_bytes != metadata.bytes) {
      Fail("retrieval database has an invalid " + std::string(table) +
           " blob for image ID " + std::to_string(image_id));
    }
    if (!metadata_by_id.emplace(image_id, metadata).second) {
      Fail("retrieval database has duplicate " + std::string(table) +
           " rows for image ID " + std::to_string(image_id));
    }
  }
  return metadata_by_id;
}

struct FeaturePreflight {
  std::vector<ImageFeatureMetadata> images;
  uint64_t total_selected_rows = 0;
};

FeaturePreflight ReadFeatureMetadata(sqlite3 *database,
                                     const std::vector<ImageRecord> &records,
                                     bool descriptor_has_type,
                                     int maximum_features) {
  std::unordered_set<int> known_image_ids;
  known_image_ids.reserve(records.size());
  for (const ImageRecord &record : records) {
    known_image_ids.insert(record.image_id);
  }
  const auto keypoints = ReadMatrixMetadata(
      database, "keypoints", sizeof(float), false, known_image_ids);
  const auto descriptors =
      ReadMatrixMetadata(database, "descriptors", sizeof(uint8_t),
                         descriptor_has_type, known_image_ids);

  FeaturePreflight preflight;
  preflight.images.reserve(records.size());
  size_t usable_images = 0;
  for (const ImageRecord &record : records) {
    ImageFeatureMetadata metadata;
    if (const auto found = keypoints.find(record.image_id);
        found != keypoints.end()) {
      metadata.keypoints = found->second;
    }
    if (const auto found = descriptors.find(record.image_id);
        found != descriptors.end()) {
      metadata.descriptors = found->second;
    }
    if (metadata.keypoints.rows != metadata.descriptors.rows) {
      Fail("mismatched retrieval features for image: " + record.name);
    }
    metadata.selected_rows =
        std::min<uint64_t>(static_cast<uint64_t>(metadata.descriptors.rows),
                           static_cast<uint64_t>(maximum_features));
    if (metadata.selected_rows > 0) {
      ++usable_images;
    }
    if (preflight.total_selected_rows >
        std::numeric_limits<uint64_t>::max() - metadata.selected_rows) {
      Fail("retrieval descriptor count overflowed");
    }
    preflight.total_selected_rows += metadata.selected_rows;
    preflight.images.push_back(metadata);
  }
  if (preflight.total_selected_rows < 3) {
    Fail("retrieval requires at least three selected training descriptors");
  }
  if (usable_images < 2) {
    Fail("retrieval requires two images with usable features");
  }
  return preflight;
}

uint64_t EstimateRetrievalMemory(const RetrieverOptions &options,
                                 const std::vector<ImageRecord> &records,
                                 const FeaturePreflight &preflight,
                                 const ImageTableMetadata &image_metadata,
                                 const OptionalInputs &inputs) {
  uint64_t estimate = EstimateInputMemory(image_metadata, inputs);
  AddMemoryProduct(&estimate, preflight.total_selected_rows,
                   kFloatDescriptorBytes);
  AddMemoryProduct(&estimate, preflight.total_selected_rows,
                   sizeof(FeatureKeypoint));
  // The byte-to-float conversion is per image, but counting it for every
  // selected descriptor leaves room for Eigen alignment and allocator slack.
  AddMemoryProduct(&estimate, preflight.total_selected_rows,
                   kByteDescriptorBytes);
  const uint64_t training_rows = std::min<uint64_t>(
      preflight.total_selected_rows,
      static_cast<uint64_t>(options.max_training_descriptors));
  AddMemoryProduct(&estimate, training_rows,
                   kFloatDescriptorBytes + sizeof(uint64_t));
  AddMemoryProduct(&estimate, preflight.total_selected_rows,
                   kVisualIndexBytesPerDescriptor);
  const uint64_t visual_words = std::min<uint64_t>(
      static_cast<uint64_t>(options.num_visual_words), training_rows - 1);
  AddMemoryProduct(&estimate, visual_words, kVisualIndexBytesPerWord);
  uint64_t maximum_transient = 0;
  for (size_t index = 0; index < records.size(); ++index) {
    const ImageFeatureMetadata &metadata = preflight.images[index];
    uint64_t transient = 0;
    // SQLite may hold a blob while RawMatrix owns its copy. Keypoints are then
    // copied once more for finite-value and scale selection.
    AddMemoryProduct(&transient, metadata.keypoints.bytes, 3);
    AddMemoryProduct(&transient, metadata.descriptors.bytes, 2);
    AddMemoryProduct(&transient, static_cast<uint64_t>(metadata.keypoints.rows),
                     sizeof(size_t) + sizeof(float));
    AddMemoryProduct(&transient, metadata.selected_rows, kByteDescriptorBytes);
    maximum_transient = std::max(maximum_transient, transient);
  }
  estimate = CheckedMemoryAdd(estimate, maximum_transient);

  const uint64_t maximum_verification_candidate_count = std::min<uint64_t>(
      records.size(), static_cast<uint64_t>(options.num_images));
  const uint64_t maximum_selected_rows = std::accumulate(
      preflight.images.begin(), preflight.images.end(), uint64_t{0},
      [](uint64_t maximum, const ImageFeatureMetadata &metadata) {
        return std::max(maximum, metadata.selected_rows);
      });
  const uint64_t maximum_verification_match_count = CheckedMemoryMultiply(
      maximum_verification_candidate_count,
      CheckedMemoryMultiply(maximum_selected_rows, maximum_selected_rows));
  AddMemoryProduct(&estimate, maximum_verification_match_count,
                   kPairStateBytes);
  AddMemoryProduct(&estimate, records.size(), kExcludedImageStateBytes);

  const uint64_t maximum_pair_count = CheckedMemoryMultiply(
      records.size(), static_cast<uint64_t>(options.returned_neighbor_count));
  const uint64_t pair_text_bytes = CheckedMemoryAdd(
      CheckedMemoryMultiply(image_metadata.maximum_name_bytes, 2), 2);
  const uint64_t pair_bytes = CheckedMemoryAdd(
      CheckedMemoryMultiply(pair_text_bytes, 2), kPairStateBytes);
  AddMemoryProduct(&estimate, maximum_pair_count, pair_bytes);
  return estimate;
}

ImageFeatures ReadSelectedFeatures(sqlite3 *database, const ImageRecord &image,
                                   const ImageFeatureMetadata &metadata,
                                   int maximum_features, int retrieval_id) {
  const RawMatrix raw_keypoints =
      ReadMatrix(database, "keypoints", image.image_id, metadata.keypoints);
  const RawMatrix raw_descriptors =
      ReadMatrix(database, "descriptors", image.image_id, metadata.descriptors);
  if (raw_keypoints.rows != raw_descriptors.rows) {
    Fail("mismatched retrieval features for image: " + image.name);
  }

  ImageFeatures selected;
  selected.retrieval_id = retrieval_id;
  selected.name = image.name;
  selected.descriptors.type = FeatureExtractorType::SIFT;
  if (raw_keypoints.rows == 0) {
    selected.descriptors.data.resize(0, kDescriptorColumns);
    return selected;
  }

  std::vector<float> keypoint_values(raw_keypoints.bytes.size() /
                                     sizeof(float));
  std::memcpy(keypoint_values.data(), raw_keypoints.bytes.data(),
              raw_keypoints.bytes.size());
  std::vector<size_t> row_indices(static_cast<size_t>(raw_keypoints.rows));
  std::iota(row_indices.begin(), row_indices.end(), 0);
  std::vector<float> scales(row_indices.size());
  for (size_t row = 0; row < row_indices.size(); ++row) {
    const float *values =
        &keypoint_values[row * static_cast<size_t>(raw_keypoints.columns)];
    for (int64_t column = 0; column < raw_keypoints.columns; ++column) {
      if (!std::isfinite(values[column])) {
        Fail("retrieval keypoints must be finite for image: " + image.name);
      }
    }
    if (raw_keypoints.columns == 6) {
      scales[row] =
          std::sqrt(std::abs(values[2] * values[5] - values[3] * values[4]));
    } else {
      scales[row] = values[2];
    }
    if (!std::isfinite(scales[row])) {
      Fail("retrieval keypoint scales must be finite for image: " + image.name);
    }
  }
  std::sort(row_indices.begin(), row_indices.end(),
            [&scales](size_t first, size_t second) {
              if (scales[first] != scales[second]) {
                return scales[first] > scales[second];
              }
              return first < second;
            });
  row_indices.resize(
      std::min(row_indices.size(), static_cast<size_t>(maximum_features)));

  selected.keypoints.reserve(row_indices.size());
  FeatureDescriptorsData byte_descriptors(
      static_cast<Eigen::Index>(row_indices.size()), kDescriptorColumns);
  for (size_t destination = 0; destination < row_indices.size();
       ++destination) {
    const size_t source = row_indices[destination];
    const float *values =
        &keypoint_values[source * static_cast<size_t>(raw_keypoints.columns)];
    if (raw_keypoints.columns == 6) {
      selected.keypoints.emplace_back(values[0], values[1], values[2],
                                      values[3], values[4], values[5]);
    } else {
      selected.keypoints.emplace_back(values[0], values[1], values[2],
                                      values[3]);
    }
    std::memcpy(
        byte_descriptors.row(static_cast<Eigen::Index>(destination)).data(),
        raw_descriptors.bytes.data() + source * kDescriptorColumns,
        kDescriptorColumns);
  }
  selected.descriptors = FeatureDescriptors(FeatureExtractorType::SIFT,
                                            std::move(byte_descriptors))
                             .ToFloat();
  return selected;
}

FeatureDescriptorsFloat
BuildTrainingDescriptors(const std::vector<ImageFeatures> &images,
                         int maximum_training_descriptors) {
  uint64_t total = 0;
  size_t usable_images = 0;
  for (const ImageFeatures &image : images) {
    const uint64_t count = static_cast<uint64_t>(image.descriptors.data.rows());
    if (count > 0) {
      ++usable_images;
    }
    if (total > std::numeric_limits<uint64_t>::max() - count) {
      Fail("retrieval descriptor count overflowed");
    }
    total += count;
  }
  if (total < 3) {
    Fail("retrieval requires at least three selected training descriptors");
  }
  if (usable_images < 2) {
    Fail("retrieval requires two images with usable features");
  }
  const uint64_t training_count =
      std::min<uint64_t>(total, maximum_training_descriptors);
  FeatureDescriptorsFloat training;
  training.type = FeatureExtractorType::SIFT;
  training.data.resize(static_cast<Eigen::Index>(training_count),
                       kDescriptorColumns);

  std::vector<uint64_t> positions(static_cast<size_t>(training_count));
  if (training_count == total) {
    std::iota(positions.begin(), positions.end(), uint64_t{0});
  } else if (training_count == 1) {
    positions.front() = 0;
  } else {
    for (uint64_t index = 0; index < training_count; ++index) {
      positions[static_cast<size_t>(index)] =
          index * (total - 1) / (training_count - 1);
    }
  }

  uint64_t source_offset = 0;
  size_t destination = 0;
  for (const ImageFeatures &image : images) {
    const uint64_t source_end =
        source_offset + static_cast<uint64_t>(image.descriptors.data.rows());
    while (destination < positions.size() &&
           positions[destination] < source_end) {
      const uint64_t local = positions[destination] - source_offset;
      training.data.row(static_cast<Eigen::Index>(destination)) =
          image.descriptors.data.row(static_cast<Eigen::Index>(local));
      ++destination;
    }
    source_offset = source_end;
  }
  if (destination != positions.size()) {
    Fail("retrieval training sampling was incomplete");
  }
  return training;
}

std::string Trim(std::string_view value) {
  size_t first = 0;
  while (first < value.size() &&
         std::isspace(static_cast<unsigned char>(value[first])) != 0) {
    ++first;
  }
  size_t last = value.size();
  while (last > first &&
         std::isspace(static_cast<unsigned char>(value[last - 1])) != 0) {
    --last;
  }
  return std::string(value.substr(first, last - first));
}

template <typename Handler>
void StreamLines(std::string_view contents, const char *label,
                 uint64_t maximum_line_bytes, uint64_t maximum_lines,
                 Handler &&handler) {
  std::string line;
  line.reserve(static_cast<size_t>(maximum_line_bytes));
  uint64_t line_count = 0;
  bool pending_line = false;
  const auto emit = [&]() {
    if (line_count >= maximum_lines) {
      Fail(std::string(label) + " contains too many lines");
    }
    ++line_count;
    handler(line);
    line.clear();
    pending_line = false;
  };
  for (const char byte : contents) {
    if (byte == '\n') {
      emit();
      continue;
    }
    if (line.size() >= maximum_line_bytes) {
      Fail(std::string(label) + " contains an overlong line");
    }
    line.push_back(byte);
    pending_line = true;
  }
  if (pending_line) {
    emit();
  }
}

std::vector<int>
ReadQueryIds(StableInputBinding *input,
             const std::vector<ImageFeatures> &images,
             const std::unordered_map<std::string, int> &identifiers_by_name) {
  if (input == nullptr) {
    std::vector<int> identifiers;
    identifiers.reserve(images.size());
    for (const ImageFeatures &image : images) {
      identifiers.push_back(image.retrieval_id);
    }
    return identifiers;
  }
  std::vector<int> identifiers;
  std::unordered_set<int> seen;
  const uint64_t maximum_bytes =
      CheckedMemoryMultiply(kMaximumQueryListLines, kMaximumQueryLineBytes + 1);
  StreamLines(input->ReadSnapshot(maximum_bytes), "query image list",
              kMaximumQueryLineBytes, kMaximumQueryListLines,
              [&](const std::string &line) {
                if (line.empty() || line.front() == '#') {
                  return;
                }
                if (Trim(line) != line || ContainsWhitespace(line)) {
                  Fail("query image list contains an invalid image name");
                }
                const auto image = identifiers_by_name.find(line);
                if (image == identifiers_by_name.end()) {
                  Fail("query image is absent from database: " + line);
                }
                if (!seen.insert(image->second).second) {
                  Fail("query image list contains a duplicate image: " + line);
                }
                identifiers.push_back(image->second);
              });
  if (identifiers.empty()) {
    Fail("query image list did not contain any database images");
  }
  return identifiers;
}

using ImagePair = std::pair<int, int>;

ImagePair UndirectedPair(int first, int second) {
  return first < second ? ImagePair{first, second} : ImagePair{second, first};
}

struct ExcludedPairs {
  std::vector<std::vector<int>> neighbors_by_retrieval_id;
};

ExcludedPairs ReadExcludedPairs(
    StableInputBinding *input,
    const std::unordered_map<std::string, int> &identifiers_by_name,
    uint64_t maximum_lines) {
  ExcludedPairs excluded;
  excluded.neighbors_by_retrieval_id.resize(identifiers_by_name.size() + 1);
  if (input == nullptr) {
    return excluded;
  }
  std::set<ImagePair> unique_pairs;
  const uint64_t maximum_bytes =
      CheckedMemoryMultiply(maximum_lines, kMaximumExcludedPairLineBytes + 1);
  StreamLines(
      input->ReadSnapshot(maximum_bytes), "excluded pair list",
      kMaximumExcludedPairLineBytes, maximum_lines,
      [&](const std::string &line) {
        const std::string trimmed = Trim(line);
        if (trimmed.empty() || trimmed.front() == '#') {
          return;
        }
        std::istringstream fields(trimmed);
        std::string first_name;
        std::string second_name;
        std::string extra;
        if (!(fields >> first_name >> second_name) || fields >> extra) {
          Fail("excluded pair list contains an invalid line");
        }
        const auto first = identifiers_by_name.find(first_name);
        const auto second = identifiers_by_name.find(second_name);
        if (first == identifiers_by_name.end() ||
            second == identifiers_by_name.end()) {
          Fail("excluded pair list contains an image absent from the database");
        }
        if (first->second == second->second) {
          Fail("excluded pair list contains a self pair");
        }
        const ImagePair pair = UndirectedPair(first->second, second->second);
        if (unique_pairs.insert(pair).second) {
          excluded.neighbors_by_retrieval_id[pair.first].push_back(pair.second);
          excluded.neighbors_by_retrieval_id[pair.second].push_back(pair.first);
        }
      });
  for (std::vector<int> &neighbors : excluded.neighbors_by_retrieval_id) {
    std::sort(neighbors.begin(), neighbors.end());
  }
  return excluded;
}

bool IsValidUTF8(std::string_view value) {
  size_t index = 0;
  while (index < value.size()) {
    const uint8_t first = static_cast<uint8_t>(value[index]);
    size_t continuation_count = 0;
    uint32_t codepoint = 0;
    uint32_t minimum = 0;
    if (first <= 0x7f) {
      ++index;
      continue;
    } else if (first >= 0xc2 && first <= 0xdf) {
      continuation_count = 1;
      codepoint = first & 0x1f;
      minimum = 0x80;
    } else if (first >= 0xe0 && first <= 0xef) {
      continuation_count = 2;
      codepoint = first & 0x0f;
      minimum = 0x800;
    } else if (first >= 0xf0 && first <= 0xf4) {
      continuation_count = 3;
      codepoint = first & 0x07;
      minimum = 0x10000;
    } else {
      return false;
    }
    if (continuation_count > value.size() - index - 1) {
      return false;
    }
    for (size_t offset = 1; offset <= continuation_count; ++offset) {
      const uint8_t next = static_cast<uint8_t>(value[index + offset]);
      if ((next & 0xc0) != 0x80) {
        return false;
      }
      codepoint = (codepoint << 6) | (next & 0x3f);
    }
    if (codepoint < minimum || codepoint > 0x10ffff ||
        (codepoint >= 0xd800 && codepoint <= 0xdfff)) {
      return false;
    }
    index += continuation_count + 1;
  }
  return true;
}

std::string LengthPrefixedSHA256(const std::vector<std::string> &fields) {
  std::string payload;
  for (const std::string &field : fields) {
    payload += std::to_string(field.size());
    payload.push_back(':');
    payload += field;
  }
  if (payload.size() > std::numeric_limits<CC_LONG>::max()) {
    Fail("retrieval digest payload exceeds the supported size");
  }
  std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest{};
  if (CC_SHA256(payload.data(), static_cast<CC_LONG>(payload.size()),
                digest.data()) == nullptr) {
    Fail("could not compute retrieval SHA-256 digest");
  }
  constexpr char kHex[] = "0123456789abcdef";
  std::string hexadecimal;
  hexadecimal.reserve(digest.size() * 2);
  for (const unsigned char byte : digest) {
    hexadecimal.push_back(kHex[byte >> 4]);
    hexadecimal.push_back(kHex[byte & 0x0f]);
  }
  return hexadecimal;
}

struct ImageGroups {
  std::string digest;
  std::vector<int> group_by_retrieval_id;
};

ImageGroups ReadImageGroups(
    StableInputBinding *input, const std::string &expected_digest,
    const std::vector<ImageRecord> &records,
    const std::unordered_map<std::string, int> &identifiers_by_name) {
  if (input == nullptr) {
    return {};
  }
  const uint64_t maximum_bytes =
      CheckedMemoryMultiply(records.size(), kMaximumImageGroupLineBytes + 1);
  const std::string_view contents = input->ReadSnapshot(maximum_bytes);
  if (contents.empty() || contents.back() != '\n') {
    Fail("image group list must end with a newline");
  }

  std::vector<std::string> digest_fields;
  digest_fields.reserve(records.size() + 1);
  digest_fields.emplace_back(kCrossGroupPolicy);
  std::vector<uint64_t> groups;
  groups.reserve(records.size());
  size_t line_index = 0;
  StreamLines(contents, "image group list", kMaximumImageGroupLineBytes,
              records.size(), [&](const std::string &line) {
                if (line_index >= records.size()) {
                  Fail("image group list contains too many lines");
                }
                const size_t tab = line.find('\t');
                if (tab == std::string::npos ||
                    line.find('\t', tab + 1) != std::string::npos) {
                  Fail("image group list contains an invalid line");
                }
                const std::string_view name(line.data(), tab);
                const std::string_view group_text(line.data() + tab + 1,
                                                  line.size() - tab - 1);
                if (!IsValidUTF8(name) || name != records[line_index].name) {
                  Fail("image group list is not in bytewise image-name order");
                }
                if (group_text.empty() ||
                    (group_text.size() > 1 && group_text.front() == '0')) {
                  Fail("image group list contains a noncanonical group index");
                }
                uint64_t group = 0;
                const auto parsed = std::from_chars(
                    group_text.data(), group_text.data() + group_text.size(),
                    group);
                if (parsed.ec != std::errc() ||
                    parsed.ptr != group_text.data() + group_text.size() ||
                    group >= records.size()) {
                  Fail("image group list contains an invalid group index");
                }
                digest_fields.push_back(line);
                groups.push_back(group);
                ++line_index;
              });
  if (line_index != records.size()) {
    Fail("image group list must contain every database image exactly once");
  }

  const uint64_t maximum_group =
      *std::max_element(groups.begin(), groups.end());
  if (maximum_group < 1) {
    Fail("image group list must contain at least two groups");
  }
  std::vector<bool> seen_groups(static_cast<size_t>(maximum_group + 1), false);
  for (const uint64_t group : groups) {
    seen_groups[static_cast<size_t>(group)] = true;
  }
  if (std::find(seen_groups.begin(), seen_groups.end(), false) !=
      seen_groups.end()) {
    Fail("image group list group indices must be contiguous from zero");
  }

  const std::string actual_digest = LengthPrefixedSHA256(digest_fields);
  if (actual_digest != expected_digest) {
    Fail("image group list digest does not match its canonical contents");
  }

  ImageGroups image_groups;
  image_groups.digest = actual_digest;
  image_groups.group_by_retrieval_id.assign(records.size() + 1, -1);
  for (size_t index = 0; index < records.size(); ++index) {
    const int retrieval_id = identifiers_by_name.at(records[index].name);
    image_groups.group_by_retrieval_id[retrieval_id] =
        static_cast<int>(groups[index]);
  }
  return image_groups;
}

void WriteAll(int descriptor, const std::string &contents) {
  size_t offset = 0;
  while (offset < contents.size()) {
    const ssize_t written =
        ::write(descriptor, contents.data() + offset, contents.size() - offset);
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      Fail("could not write temporary pair list: " +
           std::string(std::strerror(errno)));
    }
    if (written == 0) {
      Fail("could not complete temporary pair list write");
    }
    offset += static_cast<size_t>(written);
  }
}

std::string TemporaryOutputLeaf() {
  constexpr char kHex[] = "0123456789abcdef";
  std::array<uint8_t, 16> random{};
  ::arc4random_buf(random.data(), random.size());
  std::string leaf = ".easysplat-vocab-";
  leaf.reserve(leaf.size() + random.size() * 2 + 4);
  for (const uint8_t byte : random) {
    leaf.push_back(kHex[byte >> 4]);
    leaf.push_back(kHex[byte & 0x0f]);
  }
  leaf += ".tmp";
  return leaf;
}

void AtomicWrite(const OutputPathBinding &output,
                 const std::vector<std::string> &lines,
                 const std::function<void()> &validate_inputs) {
  std::string contents;
  for (const std::string &line : lines) {
    contents += line;
    contents.push_back('\n');
  }

  output.ValidateForPublication();
  std::string temporary_leaf;
  FileDescriptor temporary_descriptor;
  for (int attempt = 0; attempt < 128; ++attempt) {
    temporary_leaf = TemporaryOutputLeaf();
    int flags = O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW;
#ifdef O_RESOLVE_BENEATH
    flags |= O_RESOLVE_BENEATH;
#endif
    const int descriptor =
        ::openat(output.directory_descriptor(), temporary_leaf.c_str(), flags,
                 S_IRUSR | S_IWUSR);
    if (descriptor >= 0) {
      temporary_descriptor = FileDescriptor(descriptor);
      break;
    }
    if (errno != EEXIST) {
      Fail(ErrnoMessage("could not create temporary pair list",
                        output.output_path()));
    }
  }
  if (temporary_descriptor.get() < 0) {
    Fail("could not allocate a unique temporary pair list: " +
         output.output_path().string());
  }

  struct stat temporary_status{};
  if (::fstat(temporary_descriptor.get(), &temporary_status) != 0 ||
      !S_ISREG(temporary_status.st_mode) || temporary_status.st_size < 0) {
    Fail("could not inspect temporary pair list: " +
         output.output_path().string());
  }
  const FileIdentity temporary_identity{
      temporary_status.st_dev, temporary_status.st_ino,
      static_cast<uint64_t>(temporary_status.st_size)};
  bool published = false;
  bool rollback_link_created = false;
  std::string rollback_leaf;
  try {
    output.ValidateTemporary(temporary_leaf, temporary_identity);
    WriteAll(temporary_descriptor.get(), contents);
    if (::fsync(temporary_descriptor.get()) != 0) {
      Fail(ErrnoMessage("could not sync temporary pair list",
                        output.output_path()));
    }
    validate_inputs();
    output.ValidateForPublication();
    output.ValidateTemporary(temporary_leaf, temporary_identity);
    if (output.initial_output_identity().has_value()) {
      for (int attempt = 0; attempt < 128; ++attempt) {
        rollback_leaf = TemporaryOutputLeaf();
        if (output.TryCreateInitialOutputLink(rollback_leaf)) {
          rollback_link_created = true;
          break;
        }
      }
      if (!rollback_link_created) {
        Fail("could not allocate a unique preserved output pair list: " +
             output.output_path().string());
      }
      output.ValidateForPublication();
      output.ValidateTemporary(temporary_leaf, temporary_identity);
    }

    validate_inputs();

    const int rename_result =
        output.initial_output_identity().has_value()
            ? ::renameat(output.directory_descriptor(), temporary_leaf.c_str(),
                         output.directory_descriptor(),
                         output.output_leaf().c_str())
            : ::renameatx_np(output.directory_descriptor(),
                             temporary_leaf.c_str(),
                             output.directory_descriptor(),
                             output.output_leaf().c_str(), RENAME_EXCL);
    if (rename_result != 0) {
      Fail(ErrnoMessage("could not replace output pair list",
                        output.output_path()));
    }
    published = true;

    struct stat published_status{};
    struct stat opened_status{};
    if (::fstat(temporary_descriptor.get(), &opened_status) != 0 ||
        ::fstatat(output.directory_descriptor(), output.output_leaf().c_str(),
                  &published_status, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISREG(published_status.st_mode) ||
        !SameObject(opened_status, published_status) ||
        published_status.st_dev != temporary_identity.device ||
        published_status.st_ino != temporary_identity.inode) {
      Fail("published pair list identity did not match its temporary file: " +
           output.output_path().string());
    }
    output.ValidateBoundDirectory();
  } catch (...) {
    const std::exception_ptr failure = std::current_exception();
    if (published) {
      output.RestoreAfterFailedPublication(rollback_leaf, temporary_identity);
      rollback_link_created = false;
    } else {
      output.RemoveTemporaryIfOwned(temporary_leaf, temporary_identity);
      if (rollback_link_created) {
        output.RemoveTemporaryIfOwned(rollback_leaf,
                                      *output.initial_output_identity());
        rollback_link_created = false;
      }
    }
    std::rethrow_exception(failure);
  }

  if (rollback_link_created) {
    output.RemoveInitialOutputLink(rollback_leaf);
  }
  if (::fsync(output.directory_descriptor()) != 0) {
    Fail(ErrnoMessage("could not sync output pair list directory",
                      output.output_path().parent_path()));
  }
}

struct QueryOutcome {
  std::string query_name;
  std::vector<std::string> neighbor_names;
};

struct RetrievalResult {
  std::vector<QueryOutcome> query_outcomes;
  std::vector<std::string> pair_lines;
};

std::vector<std::string>
SerializeRetrievalReceipt(const RetrieverOptions &options,
                          const RetrievalResult &result) {
  std::vector<std::string> lines;
  lines.reserve(1 + result.query_outcomes.size() + result.pair_lines.size());
  if (options.image_group_list_path.empty()) {
    lines.push_back(std::string(kRetrievalOutcomesMagic) + " " +
                    std::string(kRetrievalEngine) + " " +
                    std::to_string(options.query_stride) + " " +
                    std::to_string(options.num_images) + " " +
                    std::to_string(options.returned_neighbor_count) + " " +
                    std::to_string(options.minimum_frame_separation) + " " +
                    std::to_string(result.query_outcomes.size()) + " " +
                    options.request_digest);
  } else {
    lines.push_back(std::string(kRetrievalOutcomesV3Magic) + " " +
                    std::string(kRetrievalEngine) + " " +
                    std::to_string(options.query_stride) + " " +
                    std::to_string(options.num_images) + " " +
                    std::to_string(options.returned_neighbor_count) + " " +
                    std::to_string(options.minimum_frame_separation) + " " +
                    std::string(kCrossGroupPolicy) + " " +
                    options.image_group_list_digest + " " +
                    std::to_string(result.query_outcomes.size()) + " " +
                    options.request_digest);
  }
  for (const QueryOutcome &outcome : result.query_outcomes) {
    if (outcome.neighbor_names.empty()) {
      lines.push_back("Q noRankedNeighbors " + outcome.query_name + " 0");
      continue;
    }
    std::string line = "Q ranked " + outcome.query_name + " " +
                       std::to_string(outcome.neighbor_names.size());
    for (const std::string &neighbor_name : outcome.neighbor_names) {
      line += " " + neighbor_name;
    }
    lines.push_back(std::move(line));
  }
  for (const std::string &pair_line : result.pair_lines) {
    lines.push_back("P " + pair_line);
  }
  return lines;
}

RetrievalResult RetrievePairs(const RetrieverOptions &options,
                              SQLiteDatabase &database,
                              OptionalInputs &inputs) {
  const bool descriptor_has_type = ValidateSchema(database.get());
  const ImageTableMetadata image_metadata =
      ReadImageTableMetadata(database.get());
  RequireMemoryBudget(EstimateInputMemory(image_metadata, inputs),
                      options.memory_budget_bytes);
  ValidateOptionalInputSizes(image_metadata, inputs);
  const std::vector<ImageRecord> records =
      ReadImages(database.get(), image_metadata);
  const FeaturePreflight preflight =
      ReadFeatureMetadata(database.get(), records, descriptor_has_type,
                          options.max_features_per_image);
  const uint64_t estimated_memory = EstimateRetrievalMemory(
      options, records, preflight, image_metadata, inputs);
  RequireMemoryBudget(estimated_memory, options.memory_budget_bytes);
  std::vector<ImageFeatures> images;
  images.reserve(records.size());
  for (size_t index = 0; index < records.size(); ++index) {
    const ImageRecord &record = records[index];
    // VisualIndex observes numeric identifiers while truncating tied scores.
    // Lexical rank keeps retrieval independent of feature-writer completion.
    const int retrieval_id = static_cast<int>(index) + 1;
    images.push_back(
        ReadSelectedFeatures(database.get(), record, preflight.images[index],
                             options.max_features_per_image, retrieval_id));
  }
  FeatureDescriptorsFloat training =
      BuildTrainingDescriptors(images, options.max_training_descriptors);

  std::unordered_map<std::string, int> identifiers_by_name;
  std::unordered_map<int, const ImageFeatures *> image_by_id;
  for (size_t index = 0; index < images.size(); ++index) {
    identifiers_by_name.emplace(images[index].name, images[index].retrieval_id);
    image_by_id.emplace(images[index].retrieval_id, &images[index]);
  }
  const std::vector<int> query_ids = ReadQueryIds(
      inputs.query_images.has_value() ? &*inputs.query_images : nullptr, images,
      identifiers_by_name);
  const ExcludedPairs excluded_pairs = ReadExcludedPairs(
      inputs.excluded_pairs.has_value() ? &*inputs.excluded_pairs : nullptr,
      identifiers_by_name, MaximumExclusionListLines(image_metadata.count));
  const ImageGroups image_groups = ReadImageGroups(
      inputs.image_groups.has_value() ? &*inputs.image_groups : nullptr,
      options.image_group_list_digest, records, identifiers_by_name);
  if (!image_groups.group_by_retrieval_id.empty()) {
    std::vector<std::string> request_fields{
        std::string(kRetrievalEngine),
        std::to_string(options.query_stride),
        std::to_string(options.num_images),
        std::to_string(options.returned_neighbor_count),
        std::to_string(options.minimum_frame_separation),
        std::string(kCrossGroupPolicy),
        image_groups.digest,
    };
    request_fields.reserve(request_fields.size() + query_ids.size());
    for (const int query_id : query_ids) {
      request_fields.push_back(image_by_id.at(query_id)->name);
    }
    if (LengthPrefixedSHA256(request_fields) != options.request_digest) {
      Fail("request digest does not bind the cross-group retrieval request");
    }
  }
  const int effective_words = std::min<int>(
      options.num_visual_words, static_cast<int>(training.data.rows() - 1));
  retrieval::VisualIndex::BuildOptions build_options;
  build_options.num_visual_words = effective_words;
  build_options.num_iterations = options.num_iterations;
  build_options.num_rounds = options.num_rounds;
  build_options.num_checks = std::min(options.num_checks, effective_words);
  build_options.num_threads = options.num_threads;
  SetPRNGSeed(0);
  auto visual_index = retrieval::VisualIndex::Create();
  visual_index->Build(build_options, training);

  retrieval::VisualIndex::IndexOptions index_options;
  index_options.num_neighbors = 1;
  index_options.num_checks = std::min(options.num_checks, effective_words);
  index_options.num_threads = options.num_threads;
  for (const ImageFeatures &image : images) {
    visual_index->Add(index_options, image.retrieval_id, image.keypoints,
                      image.descriptors);
  }
  visual_index->Prepare();

  const size_t retrieval_limit = static_cast<size_t>(options.num_images);
  retrieval::VisualIndex::QueryOptions query_options;
  query_options.max_num_images = static_cast<int>(retrieval_limit);
  query_options.num_neighbors = 5;
  query_options.num_images_after_verification =
      static_cast<int>(retrieval_limit);
  query_options.num_checks = std::min(options.num_checks, effective_words);
  query_options.num_threads = options.num_threads;
  query_options.image_group_by_id = image_groups.group_by_retrieval_id.empty()
                                        ? nullptr
                                        : &image_groups.group_by_retrieval_id;

  std::set<ImagePair> emitted;
  RetrievalResult result;
  result.query_outcomes.reserve(query_ids.size());
  for (const int query_id : query_ids) {
    const ImageFeatures &query = *image_by_id.at(query_id);
    QueryOutcome outcome;
    outcome.query_name = query.name;
    query_options.excluded_image_ids.clear();
    query_options.excluded_image_ids.insert(query_id);
    const std::vector<int> &explicit_neighbors =
        excluded_pairs.neighbors_by_retrieval_id.at(query_id);
    query_options.excluded_image_ids.insert(explicit_neighbors.begin(),
                                            explicit_neighbors.end());
    query_options.excluded_image_group =
        image_groups.group_by_retrieval_id.empty()
            ? -1
            : image_groups.group_by_retrieval_id.at(query_id);
    const int temporal_radius =
        std::max(options.minimum_frame_separation - 1, 0);
    query_options.excluded_image_id_begin =
        std::max(query_id - temporal_radius, 1);
    query_options.excluded_image_id_end = std::min(
        query_id + temporal_radius + 1, static_cast<int>(images.size()) + 1);
    std::vector<retrieval::ImageScore> scores;
    visual_index->Query(query_options, query.keypoints, query.descriptors,
                        &scores);
    for (const retrieval::ImageScore &score : scores) {
      if (!std::isfinite(score.score) ||
          image_by_id.find(score.image_id) == image_by_id.end()) {
        Fail("vocabulary retrieval returned an invalid image score");
      }
      if (query_options.IsImageExcluded(score.image_id)) {
        Fail("vocabulary retrieval returned an excluded image score");
      }
    }
    std::sort(scores.begin(), scores.end(),
              [&image_by_id](const retrieval::ImageScore &first,
                             const retrieval::ImageScore &second) {
                if (first.score != second.score) {
                  return first.score > second.score;
                }
                return BytewiseLess(image_by_id.at(first.image_id)->name,
                                    image_by_id.at(second.image_id)->name);
              });
    if (scores.size() > retrieval_limit) {
      Fail("vocabulary retrieval exceeded the bounded candidate pool");
    }

    size_t retained = 0;
    std::unordered_set<int> reported;
    for (const retrieval::ImageScore &score : scores) {
      const int candidate_id = score.image_id;
      const auto pair = UndirectedPair(query_id, candidate_id);
      if (!reported.insert(candidate_id).second) {
        Fail("vocabulary retrieval returned a duplicate reported neighbor");
      }
      outcome.neighbor_names.push_back(image_by_id.at(candidate_id)->name);
      if (emitted.insert(pair).second) {
        result.pair_lines.push_back(query.name + " " +
                                    image_by_id.at(candidate_id)->name);
      }
      ++retained;
      if (retained >= static_cast<size_t>(options.returned_neighbor_count)) {
        break;
      }
    }
    std::sort(outcome.neighbor_names.begin(), outcome.neighbor_names.end(),
              BytewiseLess);
    result.query_outcomes.push_back(std::move(outcome));
  }
  std::sort(result.pair_lines.begin(), result.pair_lines.end(), BytewiseLess);
  return result;
}

int Run(const RetrieverOptions &options) {
  ValidateBounds(options);
  const DatabaseInputBinding database_binding(options.database_path);
  const DatabaseSidecarBindings database_sidecars(options.database_path);
  const FileIdentity database_identity = database_binding.identity();
  const OutputPathBinding output_binding(options.output_pair_list_path);
  const std::optional<FileIdentity> output_identity =
      output_binding.initial_output_identity();
  if (output_identity.has_value() &&
      SameFile(database_identity, output_identity.value())) {
    Fail("output pair list must not replace the retrieval database");
  }
  OptionalInputs inputs;
  if (!options.query_image_list_path.empty()) {
    inputs.query_images.emplace(options.query_image_list_path,
                                "query image list");
  }
  if (!options.excluded_pair_list_path.empty()) {
    inputs.excluded_pairs.emplace(options.excluded_pair_list_path,
                                  "excluded pair list");
  }
  if (!options.image_group_list_path.empty()) {
    inputs.image_groups.emplace(options.image_group_list_path,
                                "image group list");
  }
  if (output_identity.has_value() && inputs.query_images.has_value() &&
      SameFile(output_identity.value(), inputs.query_images->identity())) {
    Fail("output pair list must not replace the query image list");
  }
  if (output_identity.has_value() && inputs.excluded_pairs.has_value() &&
      SameFile(output_identity.value(), inputs.excluded_pairs->identity())) {
    Fail("output pair list must not replace the excluded pair list");
  }
  if (output_identity.has_value() && inputs.image_groups.has_value() &&
      SameFile(output_identity.value(), inputs.image_groups->identity())) {
    Fail("output pair list must not replace the image group list");
  }
  database_binding.ValidatePath();
  database_sidecars.ValidateUnchanged();
  database_binding.ValidatePath();
  SQLiteDatabase database(database_binding);
  database_binding.ValidatePath();
  database_sidecars.ValidateUnchanged();
  const RetrievalResult result = RetrievePairs(options, database, inputs);
  inputs.ValidateUnchanged();
  database_binding.ValidatePath();
  database_sidecars.ValidateUnchanged();
  const std::vector<std::string> receipt_lines =
      SerializeRetrievalReceipt(options, result);
  database_binding.ValidatePath();
  AtomicWrite(output_binding, receipt_lines, [&]() {
    database_binding.ValidatePath();
    database_sidecars.ValidateUnchanged();
    inputs.ValidateUnchanged();
  });
  LOG(INFO) << "Retrieved query outcomes: " << result.query_outcomes.size()
            << "; novel image pairs: " << result.pair_lines.size();
  return EXIT_SUCCESS;
}

} // namespace

int RunLocalVocabularyRetriever(int argc, char **argv) {
  RetrieverOptions values;
  OptionManager options(/*add_project_options=*/false);
  options.AddRequiredOption("database_path", &values.database_path);
  options.AddRequiredOption("output_pair_list_path",
                            &values.output_pair_list_path);
  options.AddRequiredOption("request_digest", &values.request_digest);
  options.AddRequiredOption("query_stride", &values.query_stride);
  options.AddDefaultOption("query_image_list_path",
                           &values.query_image_list_path);
  options.AddDefaultOption("excluded_pair_list_path",
                           &values.excluded_pair_list_path);
  options.AddDefaultOption("image_group_list_path",
                           &values.image_group_list_path);
  options.AddDefaultOption("image_group_list_digest",
                           &values.image_group_list_digest);
  options.AddDefaultOption("num_images", &values.num_images);
  options.AddDefaultOption("returned_neighbor_count",
                           &values.returned_neighbor_count);
  options.AddDefaultOption("minimum_frame_separation",
                           &values.minimum_frame_separation);
  options.AddDefaultOption("num_visual_words", &values.num_visual_words);
  options.AddDefaultOption("max_features_per_image",
                           &values.max_features_per_image);
  options.AddDefaultOption("max_training_descriptors",
                           &values.max_training_descriptors);
  options.AddDefaultOption("memory_budget_bytes",
                           &values.memory_budget_bytes_argument);
  options.AddDefaultOption("num_iterations", &values.num_iterations);
  options.AddDefaultOption("num_rounds", &values.num_rounds);
  options.AddDefaultOption("num_checks", &values.num_checks);
  options.AddDefaultOption("num_threads", &values.num_threads);
  if (!options.Parse(argc, argv)) {
    return EXIT_FAILURE;
  }
  try {
    values.memory_budget_bytes =
        ParseMemoryBudget(values.memory_budget_bytes_argument);
    return Run(values);
  } catch (const std::exception &error) {
    LOG(ERROR) << "Local vocabulary retrieval failed: " << error.what();
    return EXIT_FAILURE;
  }
}

} // namespace colmap
