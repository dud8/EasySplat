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
#include <filesystem>
#include <fstream>
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

#include <fcntl.h>
#include <sqlite3.h>
#include <sys/stat.h>
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
constexpr uint64_t kMaximumImageNameBytes = 1024;
constexpr uint64_t kMaximumQueryLineBytes = kMaximumImageNameBytes;
constexpr uint64_t kMaximumExcludedPairLineBytes =
    2 * kMaximumImageNameBytes + 16;
constexpr uint64_t kMaximumQueryListLines =
    static_cast<uint64_t>(kMaxDatabaseImages);

constexpr uint64_t kSealedThreeThousandFrameFeatureCount = 3000ULL * 512ULL;
constexpr uint64_t kSealedThreeThousandFrameEstimate =
    kFixedRetrievalOverheadBytes +
    kSealedThreeThousandFrameFeatureCount *
        (kFloatDescriptorBytes + sizeof(FeatureKeypoint) +
         kByteDescriptorBytes + kVisualIndexBytesPerDescriptor) +
    65'536ULL * (kFloatDescriptorBytes + sizeof(uint64_t)) +
    3000ULL * kPerImageStateBytes + 512ULL * kVisualIndexBytesPerWord +
    3000ULL * 8ULL * (2ULL * (2ULL * 128ULL + 2ULL) + kPairStateBytes) +
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
  std::filesystem::path query_image_list_path;
  std::filesystem::path excluded_pair_list_path;
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

[[noreturn]] void Fail(const std::string& message) {
  throw std::runtime_error(message);
}

std::string ErrnoMessage(const std::string& action,
                         const std::filesystem::path& path) {
  return action + ": " + path.string() + ": " + std::strerror(errno);
}

std::string ErrnoMessage(const std::string& action,
                         const std::filesystem::path& path,
                         int error) {
  return action + ": " + path.string() + ": " + std::strerror(error);
}

uint64_t ParseMemoryBudget(std::string_view argument) {
  uint64_t value = 0;
  const auto parsed = std::from_chars(
      argument.data(), argument.data() + argument.size(), value);
  if (argument.empty() || parsed.ec != std::errc() ||
      parsed.ptr != argument.data() + argument.size()) {
    Fail("--memory_budget_bytes must be an unsigned integer");
  }
  return value;
}

void ValidateBounds(const RetrieverOptions& options) {
  const auto require_range =
      [](const char* name, int value, int minimum, int maximum) {
        if (value < minimum || value > maximum) {
          Fail(std::string("--") + name + " must be between " +
               std::to_string(minimum) + " and " + std::to_string(maximum));
        }
      };
  require_range("num_images", options.num_images, 1, 256);
  require_range(
      "returned_neighbor_count", options.returned_neighbor_count, 1, 64);
  if (options.returned_neighbor_count > options.num_images) {
    Fail("--returned_neighbor_count cannot exceed --num_images");
  }
  require_range("minimum_frame_separation",
                options.minimum_frame_separation,
                0,
                1'000'000);
  require_range("num_visual_words", options.num_visual_words, 2, 8192);
  require_range(
      "max_features_per_image", options.max_features_per_image, 2, 8192);
  require_range("max_training_descriptors",
                options.max_training_descriptors,
                512,
                262'144);
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

struct OptionalInputs {
  std::optional<FileIdentity> query_images;
  std::optional<FileIdentity> excluded_pairs;
};

FileIdentity ValidateRegularInput(const std::filesystem::path& path,
                                  const char* label) {
  if (!path.is_absolute()) {
    Fail(std::string(label) + " must be an absolute path");
  }
  struct stat status{};
  if (::lstat(path.c_str(), &status) != 0) {
    Fail(ErrnoMessage(std::string("could not inspect ") + label, path));
  }
  if (!S_ISREG(status.st_mode)) {
    Fail(std::string(label) + " is not a regular file: " + path.string());
  }
  if (status.st_size < 0) {
    Fail(std::string(label) + " has an invalid size: " + path.string());
  }
  return {status.st_dev, status.st_ino, static_cast<uint64_t>(status.st_size)};
}

std::optional<FileIdentity> ValidateOutputPath(
    const std::filesystem::path& output) {
  if (!output.is_absolute()) {
    Fail("output pair list path must be absolute");
  }
  const std::filesystem::path parent = output.parent_path();
  if (parent.empty() || output.filename().empty() || output.filename() == "." ||
      output.filename() == "..") {
    Fail("output pair list path is invalid: " + output.string());
  }
  struct stat parent_status{};
  if (::lstat(parent.c_str(), &parent_status) != 0) {
    Fail(ErrnoMessage("could not inspect output pair list directory", parent));
  }
  if (!S_ISDIR(parent_status.st_mode)) {
    Fail("output pair list directory is not a directory: " + parent.string());
  }

  struct stat output_status{};
  if (::lstat(output.c_str(), &output_status) == 0) {
    if (!S_ISREG(output_status.st_mode)) {
      Fail("output pair list is not a regular file: " + output.string());
    }
    return FileIdentity{output_status.st_dev,
                        output_status.st_ino,
                        static_cast<uint64_t>(output_status.st_size)};
  }
  if (errno != ENOENT) {
    Fail(ErrnoMessage("could not inspect output pair list", output));
  }
  return std::nullopt;
}

bool SameFile(const FileIdentity& first, const FileIdentity& second) {
  return first.device == second.device && first.inode == second.inode;
}

void RejectPendingSidecars(const std::filesystem::path& database_path) {
  for (const char* suffix : {"-wal", "-journal"}) {
    const std::filesystem::path sidecar(database_path.string() + suffix);
    struct stat status{};
    if (::lstat(sidecar.c_str(), &status) == 0) {
      if (!S_ISREG(status.st_mode) || status.st_size > 0) {
        Fail("retrieval database has a pending SQLite " +
             std::string(suffix + 1) + " sidecar");
      }
    } else if (errno != ENOENT) {
      Fail(ErrnoMessage("could not inspect retrieval database sidecar",
                        sidecar));
    }
  }
}

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
  explicit SQLiteDatabase(const std::filesystem::path& path) {
    const std::string uri =
        "file://" + EncodeSQLiteURIPath(path.string()) + "?mode=ro&immutable=1";
    const int result = sqlite3_open_v2(
        uri.c_str(),
        &database_,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX,
        nullptr);
    if (result != SQLITE_OK) {
      const std::string detail = database_ == nullptr
                                     ? sqlite3_errstr(result)
                                     : sqlite3_errmsg(database_);
      if (database_ != nullptr) {
        sqlite3_close(database_);
        database_ = nullptr;
      }
      Fail("could not open retrieval database read-only: " + path.string() +
           ": " + detail);
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

  SQLiteDatabase(const SQLiteDatabase&) = delete;
  SQLiteDatabase& operator=(const SQLiteDatabase&) = delete;

  ~SQLiteDatabase() {
    if (database_ != nullptr) {
      sqlite3_close(database_);
    }
  }

  sqlite3* get() const { return database_; }

  void Execute(const char* sql) {
    char* error = nullptr;
    const int result = sqlite3_exec(database_, sql, nullptr, nullptr, &error);
    if (result != SQLITE_OK) {
      const std::string detail =
          error == nullptr ? sqlite3_errmsg(database_) : std::string(error);
      sqlite3_free(error);
      Fail("SQLite command failed: " + detail);
    }
  }

 private:
  sqlite3* database_ = nullptr;
};

class SQLiteStatement {
 public:
  SQLiteStatement(sqlite3* database, const std::string& sql)
      : database_(database) {
    const int result = sqlite3_prepare_v2(database_,
                                          sql.c_str(),
                                          static_cast<int>(sql.size()),
                                          &statement_,
                                          nullptr);
    if (result != SQLITE_OK) {
      Fail("could not prepare retrieval database query: " +
           std::string(sqlite3_errmsg(database_)));
    }
  }

  SQLiteStatement(const SQLiteStatement&) = delete;
  SQLiteStatement& operator=(const SQLiteStatement&) = delete;

  ~SQLiteStatement() {
    if (statement_ != nullptr) {
      sqlite3_finalize(statement_);
    }
  }

  sqlite3_stmt* get() const { return statement_; }

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
  sqlite3* database_;
  sqlite3_stmt* statement_ = nullptr;
};

std::unordered_set<std::string> TableColumns(sqlite3* database,
                                             const char* table) {
  SQLiteStatement statement(database,
                            "PRAGMA table_info(" + std::string(table) + ")");
  std::unordered_set<std::string> columns;
  while (statement.Step()) {
    if (sqlite3_column_type(statement.get(), 1) != SQLITE_TEXT) {
      Fail("retrieval database has an invalid " + std::string(table) +
           " table");
    }
    const auto* text = sqlite3_column_text(statement.get(), 1);
    const int bytes = sqlite3_column_bytes(statement.get(), 1);
    if (text == nullptr || bytes <= 0) {
      Fail("retrieval database has an invalid " + std::string(table) +
           " table");
    }
    columns.emplace(reinterpret_cast<const char*>(text), bytes);
  }
  return columns;
}

bool ValidateSchema(sqlite3* database) {
  const std::array<std::pair<const char*, std::array<const char*, 2>>, 1>
      image_schema = {{{"images", {"image_id", "name"}}}};
  for (const auto& [table, required] : image_schema) {
    const auto columns = TableColumns(database, table);
    for (const char* column : required) {
      if (columns.find(column) == columns.end()) {
        Fail("retrieval database has an invalid " + std::string(table) +
             " table");
      }
    }
  }
  bool descriptor_has_type = false;
  for (const char* table : {"keypoints", "descriptors"}) {
    const auto columns = TableColumns(database, table);
    for (const char* column : {"image_id", "rows", "cols", "data"}) {
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

uint64_t CheckedMatrixBytes(int64_t rows,
                            int64_t columns,
                            uint64_t element_size,
                            const char* table,
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

RawMatrix ReadMatrix(sqlite3* database,
                     const char* table,
                     int image_id,
                     const MatrixMetadata& metadata) {
  if (!metadata.present) {
    return {};
  }
  SQLiteStatement statement(
      database,
      "SELECT data FROM " + std::string(table) + " WHERE image_id = ?");
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
    const void* blob_data = sqlite3_column_blob(statement.get(), 0);
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

void AddMemoryProduct(uint64_t* estimate, uint64_t count, uint64_t bytes) {
  *estimate = CheckedMemoryAdd(*estimate, CheckedMemoryMultiply(count, bytes));
}

struct ImageFeatures {
  int image_id;
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

struct ImageTableMetadata {
  uint64_t count = 0;
  uint64_t total_name_bytes = 0;
  uint64_t minimum_name_bytes = 0;
  uint64_t maximum_name_bytes = 0;
};

ImageTableMetadata ReadImageTableMetadata(sqlite3* database) {
  SQLiteStatement statement(
      database,
      "SELECT COUNT(*), "
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

void ValidateOptionalInputSizes(const ImageTableMetadata& images,
                                const OptionalInputs& inputs) {
  if (inputs.query_images.has_value()) {
    const uint64_t maximum_query_bytes = CheckedMemoryMultiply(
        kMaximumQueryListLines, kMaximumQueryLineBytes + 1);
    if (inputs.query_images->bytes > maximum_query_bytes) {
      Fail("query image list exceeds the supported size bound");
    }
  }
  if (inputs.excluded_pairs.has_value()) {
    const uint64_t maximum_exclusion_bytes =
        CheckedMemoryMultiply(MaximumExclusionListLines(images.count),
                              kMaximumExcludedPairLineBytes + 1);
    if (inputs.excluded_pairs->bytes > maximum_exclusion_bytes) {
      Fail("excluded pair list exceeds the supported size bound");
    }
  }
}

uint64_t EstimateInputMemory(const ImageTableMetadata& images,
                             const OptionalInputs& inputs) {
  uint64_t estimate = kFixedRetrievalOverheadBytes;
  AddMemoryProduct(&estimate, images.total_name_bytes, 4);
  AddMemoryProduct(&estimate, images.count, kPerImageStateBytes);
  if (inputs.query_images.has_value()) {
    estimate = CheckedMemoryAdd(estimate, inputs.query_images->bytes);
    AddMemoryProduct(&estimate, images.count, kInputIdentityStateBytes);
  }
  if (inputs.excluded_pairs.has_value()) {
    estimate = CheckedMemoryAdd(estimate, inputs.excluded_pairs->bytes);
    const uint64_t minimum_pair_line_bytes = CheckedMemoryAdd(
        CheckedMemoryMultiply(images.minimum_name_bytes, 2), 1);
    const uint64_t possible_pairs = std::min<uint64_t>(
        MaximumUndirectedPairs(images.count),
        CheckedMemoryAdd(inputs.excluded_pairs->bytes / minimum_pair_line_bytes,
                         1));
    AddMemoryProduct(&estimate, possible_pairs, kPairStateBytes);
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

std::vector<ImageRecord> ReadImages(sqlite3* database,
                                    const ImageTableMetadata& metadata) {
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
    const auto* name_data = sqlite3_column_text(statement.get(), 1);
    const int name_size = sqlite3_column_bytes(statement.get(), 1);
    if (name_data == nullptr || name_size <= 0 ||
        static_cast<uint64_t>(name_size) > kMaximumImageNameBytes) {
      Fail("retrieval database contains an invalid image name");
    }
    std::string name(reinterpret_cast<const char*>(name_data), name_size);
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

std::unordered_map<int, MatrixMetadata> ReadMatrixMetadata(
    sqlite3* database,
    const char* table,
    uint64_t element_size,
    bool descriptor_has_type,
    const std::unordered_set<int>& known_image_ids) {
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
        Fail(
            "retrieval keypoints must use exactly four or six columns for "
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
        Fail(
            "retrieval database contains an unsupported descriptor type for "
            "image ID " +
            std::to_string(image_id));
      }
    }
    metadata.bytes = CheckedMatrixBytes(
        metadata.rows, metadata.columns, element_size, table, image_id);

    if (sqlite3_column_type(statement.get(), 3) != SQLITE_TEXT) {
      Fail("retrieval database has an invalid " + std::string(table) +
           " blob for image ID " + std::to_string(image_id));
    }
    const auto* storage_data = sqlite3_column_text(statement.get(), 3);
    const int storage_size = sqlite3_column_bytes(statement.get(), 3);
    if (storage_data == nullptr || storage_size <= 0) {
      Fail("retrieval database has an invalid " + std::string(table) +
           " blob for image ID " + std::to_string(image_id));
    }
    const std::string storage(reinterpret_cast<const char*>(storage_data),
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

FeaturePreflight ReadFeatureMetadata(sqlite3* database,
                                     const std::vector<ImageRecord>& records,
                                     bool descriptor_has_type,
                                     int maximum_features) {
  std::unordered_set<int> known_image_ids;
  known_image_ids.reserve(records.size());
  for (const ImageRecord& record : records) {
    known_image_ids.insert(record.image_id);
  }
  const auto keypoints = ReadMatrixMetadata(
      database, "keypoints", sizeof(float), false, known_image_ids);
  const auto descriptors = ReadMatrixMetadata(database,
                                              "descriptors",
                                              sizeof(uint8_t),
                                              descriptor_has_type,
                                              known_image_ids);

  FeaturePreflight preflight;
  preflight.images.reserve(records.size());
  size_t usable_images = 0;
  for (const ImageRecord& record : records) {
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

uint64_t EstimateRetrievalMemory(const RetrieverOptions& options,
                                 const std::vector<ImageRecord>& records,
                                 const FeaturePreflight& preflight,
                                 const ImageTableMetadata& image_metadata,
                                 const OptionalInputs& inputs) {
  uint64_t estimate = EstimateInputMemory(image_metadata, inputs);
  AddMemoryProduct(
      &estimate, preflight.total_selected_rows, kFloatDescriptorBytes);
  AddMemoryProduct(
      &estimate, preflight.total_selected_rows, sizeof(FeatureKeypoint));
  // The byte-to-float conversion is per image, but counting it for every
  // selected descriptor leaves room for Eigen alignment and allocator slack.
  AddMemoryProduct(
      &estimate, preflight.total_selected_rows, kByteDescriptorBytes);
  const uint64_t training_rows = std::min<uint64_t>(
      preflight.total_selected_rows,
      static_cast<uint64_t>(options.max_training_descriptors));
  AddMemoryProduct(
      &estimate, training_rows, kFloatDescriptorBytes + sizeof(uint64_t));
  AddMemoryProduct(
      &estimate, preflight.total_selected_rows, kVisualIndexBytesPerDescriptor);
  const uint64_t visual_words = std::min<uint64_t>(
      static_cast<uint64_t>(options.num_visual_words), training_rows - 1);
  AddMemoryProduct(&estimate, visual_words, kVisualIndexBytesPerWord);
  uint64_t maximum_transient = 0;
  for (size_t index = 0; index < records.size(); ++index) {
    const ImageFeatureMetadata& metadata = preflight.images[index];
    uint64_t transient = 0;
    // SQLite may hold a blob while RawMatrix owns its copy. Keypoints are then
    // copied once more for finite-value and scale selection.
    AddMemoryProduct(&transient, metadata.keypoints.bytes, 3);
    AddMemoryProduct(&transient, metadata.descriptors.bytes, 2);
    AddMemoryProduct(&transient,
                     static_cast<uint64_t>(metadata.keypoints.rows),
                     sizeof(size_t) + sizeof(float));
    AddMemoryProduct(&transient, metadata.selected_rows, kByteDescriptorBytes);
    maximum_transient = std::max(maximum_transient, transient);
  }
  estimate = CheckedMemoryAdd(estimate, maximum_transient);

  const uint64_t maximum_pair_count = CheckedMemoryMultiply(
      records.size(), static_cast<uint64_t>(options.returned_neighbor_count));
  const uint64_t pair_text_bytes = CheckedMemoryAdd(
      CheckedMemoryMultiply(image_metadata.maximum_name_bytes, 2), 2);
  const uint64_t pair_bytes = CheckedMemoryAdd(
      CheckedMemoryMultiply(pair_text_bytes, 2), kPairStateBytes);
  AddMemoryProduct(&estimate, maximum_pair_count, pair_bytes);
  return estimate;
}

ImageFeatures ReadSelectedFeatures(sqlite3* database,
                                   const ImageRecord& image,
                                   const ImageFeatureMetadata& metadata,
                                   int maximum_features) {
  const RawMatrix raw_keypoints =
      ReadMatrix(database, "keypoints", image.image_id, metadata.keypoints);
  const RawMatrix raw_descriptors =
      ReadMatrix(database, "descriptors", image.image_id, metadata.descriptors);
  if (raw_keypoints.rows != raw_descriptors.rows) {
    Fail("mismatched retrieval features for image: " + image.name);
  }

  ImageFeatures selected;
  selected.image_id = image.image_id;
  selected.name = image.name;
  selected.descriptors.type = FeatureExtractorType::SIFT;
  if (raw_keypoints.rows == 0) {
    selected.descriptors.data.resize(0, kDescriptorColumns);
    return selected;
  }

  std::vector<float> keypoint_values(raw_keypoints.bytes.size() /
                                     sizeof(float));
  std::memcpy(keypoint_values.data(),
              raw_keypoints.bytes.data(),
              raw_keypoints.bytes.size());
  std::vector<size_t> row_indices(static_cast<size_t>(raw_keypoints.rows));
  std::iota(row_indices.begin(), row_indices.end(), 0);
  std::vector<float> scales(row_indices.size());
  for (size_t row = 0; row < row_indices.size(); ++row) {
    const float* values =
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
  std::sort(row_indices.begin(),
            row_indices.end(),
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
    const float* values =
        &keypoint_values[source * static_cast<size_t>(raw_keypoints.columns)];
    if (raw_keypoints.columns == 6) {
      selected.keypoints.emplace_back(
          values[0], values[1], values[2], values[3], values[4], values[5]);
    } else {
      selected.keypoints.emplace_back(
          values[0], values[1], values[2], values[3]);
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

FeatureDescriptorsFloat BuildTrainingDescriptors(
    const std::vector<ImageFeatures>& images,
    int maximum_training_descriptors) {
  uint64_t total = 0;
  size_t usable_images = 0;
  for (const ImageFeatures& image : images) {
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
  for (const ImageFeatures& image : images) {
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
void StreamLines(const std::filesystem::path& path,
                 const char* label,
                 uint64_t maximum_line_bytes,
                 uint64_t maximum_lines,
                 Handler&& handler) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream.is_open()) {
    Fail("could not read " + std::string(label) + ": " + path.string());
  }
  std::string line;
  line.reserve(static_cast<size_t>(maximum_line_bytes));
  uint64_t line_count = 0;
  bool pending_line = false;
  const auto emit = [&]() {
    if (line_count >= maximum_lines) {
      Fail(std::string(label) + " contains too many lines");
    }
    ++line_count;
    handler(Trim(line));
    line.clear();
    pending_line = false;
  };
  char byte = 0;
  while (stream.get(byte)) {
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
  if (!stream.eof()) {
    Fail("could not read " + std::string(label) + ": " + path.string());
  }
  if (pending_line) {
    emit();
  }
}

std::vector<int> ReadQueryIds(
    const std::filesystem::path& path,
    const std::vector<ImageFeatures>& images,
    const std::unordered_map<std::string, int>& identifiers_by_name) {
  if (path.empty()) {
    std::vector<int> identifiers;
    identifiers.reserve(images.size());
    for (const ImageFeatures& image : images) {
      identifiers.push_back(image.image_id);
    }
    return identifiers;
  }
  std::vector<int> identifiers;
  std::unordered_set<int> seen;
  StreamLines(path,
              "query image list",
              kMaximumQueryLineBytes,
              kMaximumQueryListLines,
              [&](const std::string& line) {
                if (line.empty() || line.front() == '#') {
                  return;
                }
                const auto image = identifiers_by_name.find(line);
                if (image == identifiers_by_name.end()) {
                  Fail("query image is absent from database: " + line);
                }
                if (seen.insert(image->second).second) {
                  identifiers.push_back(image->second);
                }
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
  std::set<ImagePair> pairs;
  std::unordered_map<int, size_t> degree_by_id;
};

ExcludedPairs ReadExcludedPairs(
    const std::filesystem::path& path,
    const std::unordered_map<std::string, int>& identifiers_by_name,
    uint64_t maximum_lines) {
  ExcludedPairs excluded;
  if (path.empty()) {
    return excluded;
  }
  StreamLines(
      path,
      "excluded pair list",
      kMaximumExcludedPairLineBytes,
      maximum_lines,
      [&](const std::string& line) {
        if (line.empty() || line.front() == '#') {
          return;
        }
        std::istringstream fields(line);
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
        const ImagePair pair = UndirectedPair(first->second, second->second);
        if (excluded.pairs.insert(pair).second) {
          ++excluded.degree_by_id[pair.first];
          ++excluded.degree_by_id[pair.second];
        }
      });
  return excluded;
}

size_t MaximumFilteredCount(const std::vector<int>& query_ids,
                            const ExcludedPairs& excluded_pairs,
                            const std::unordered_map<int, size_t>& order_by_id,
                            const std::vector<ImageFeatures>& images,
                            int minimum_separation) {
  size_t maximum = 0;
  for (const int query_id : query_ids) {
    size_t filtered = 1;
    if (const auto degree = excluded_pairs.degree_by_id.find(query_id);
        degree != excluded_pairs.degree_by_id.end()) {
      filtered += degree->second;
    }
    if (minimum_separation > 0) {
      const size_t order = order_by_id.at(query_id);
      const size_t first =
          order >= static_cast<size_t>(minimum_separation - 1)
              ? order - static_cast<size_t>(minimum_separation - 1)
              : 0;
      const size_t last = std::min(
          images.size(), order + static_cast<size_t>(minimum_separation));
      const size_t temporal_count = last - first;
      if (temporal_count > 0) {
        filtered += temporal_count - 1;
      }
    }
    maximum = std::max(maximum, std::min(filtered, images.size()));
  }
  return maximum;
}

void WriteAll(int descriptor, const std::string& contents) {
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

void AtomicWrite(const std::filesystem::path& output,
                 const std::vector<std::string>& lines) {
  std::string contents;
  for (const std::string& line : lines) {
    contents += line;
    contents.push_back('\n');
  }
  const std::filesystem::path parent = output.parent_path();
  std::string template_path =
      (parent / ("." + output.filename().string() + ".XXXXXX")).string();
  std::vector<char> writable_template(template_path.begin(),
                                      template_path.end());
  writable_template.push_back('\0');
  const int descriptor = ::mkstemp(writable_template.data());
  if (descriptor < 0) {
    Fail(ErrnoMessage("could not create temporary pair list", parent));
  }
  const std::filesystem::path temporary(writable_template.data());
  bool descriptor_open = true;
  int directory = -1;
  bool directory_open = false;
  bool rename_completed = false;
  try {
    WriteAll(descriptor, contents);
    if (::fsync(descriptor) != 0) {
      Fail(ErrnoMessage("could not sync temporary pair list", temporary));
    }
    const int close_result = ::close(descriptor);
    const int close_error = errno;
    descriptor_open = false;
    if (close_result != 0) {
      Fail(ErrnoMessage(
          "could not close temporary pair list", temporary, close_error));
    }
    directory = ::open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory < 0) {
      Fail(ErrnoMessage("could not open output pair list directory", parent));
    }
    directory_open = true;
    if (::rename(temporary.c_str(), output.c_str()) != 0) {
      Fail(ErrnoMessage("could not replace output pair list", output));
    }
    rename_completed = true;

    int directory_sync_error = 0;
    if (::fsync(directory) != 0) {
      directory_sync_error = errno;
    }
    const int directory_close_result = ::close(directory);
    const int directory_close_error = errno;
    directory_open = false;
    if (directory_sync_error != 0) {
      std::string message =
          ErrnoMessage("could not sync output pair list directory",
                       parent,
                       directory_sync_error);
      if (directory_close_result != 0) {
        message +=
            "; " + ErrnoMessage("could not close output pair list directory",
                                parent,
                                directory_close_error);
      }
      Fail(message);
    }
    if (directory_close_result != 0) {
      Fail(ErrnoMessage("could not close output pair list directory",
                        parent,
                        directory_close_error));
    }
  } catch (...) {
    if (descriptor_open) {
      static_cast<void>(::close(descriptor));
    }
    if (directory_open) {
      static_cast<void>(::close(directory));
    }
    if (!rename_completed) {
      static_cast<void>(::unlink(temporary.c_str()));
    }
    throw;
  }
}

std::vector<std::string> RetrievePairs(const RetrieverOptions& options,
                                       SQLiteDatabase& database,
                                       const OptionalInputs& inputs) {
  const bool descriptor_has_type = ValidateSchema(database.get());
  const ImageTableMetadata image_metadata =
      ReadImageTableMetadata(database.get());
  RequireMemoryBudget(EstimateInputMemory(image_metadata, inputs),
                      options.memory_budget_bytes);
  ValidateOptionalInputSizes(image_metadata, inputs);
  const std::vector<ImageRecord> records =
      ReadImages(database.get(), image_metadata);
  const FeaturePreflight preflight =
      ReadFeatureMetadata(database.get(),
                          records,
                          descriptor_has_type,
                          options.max_features_per_image);
  const uint64_t estimated_memory = EstimateRetrievalMemory(
      options, records, preflight, image_metadata, inputs);
  RequireMemoryBudget(estimated_memory, options.memory_budget_bytes);
  std::vector<ImageFeatures> images;
  images.reserve(records.size());
  for (size_t index = 0; index < records.size(); ++index) {
    const ImageRecord& record = records[index];
    images.push_back(ReadSelectedFeatures(database.get(),
                                          record,
                                          preflight.images[index],
                                          options.max_features_per_image));
  }
  FeatureDescriptorsFloat training =
      BuildTrainingDescriptors(images, options.max_training_descriptors);

  std::unordered_map<std::string, int> identifiers_by_name;
  std::unordered_map<int, size_t> order_by_id;
  std::unordered_map<int, const ImageFeatures*> image_by_id;
  for (size_t index = 0; index < images.size(); ++index) {
    identifiers_by_name.emplace(images[index].name, images[index].image_id);
    order_by_id.emplace(images[index].image_id, index);
    image_by_id.emplace(images[index].image_id, &images[index]);
  }
  const std::vector<int> query_ids =
      ReadQueryIds(options.query_image_list_path, images, identifiers_by_name);
  const ExcludedPairs excluded_pairs =
      ReadExcludedPairs(options.excluded_pair_list_path,
                        identifiers_by_name,
                        MaximumExclusionListLines(image_metadata.count));
  const size_t maximum_filtered =
      MaximumFilteredCount(query_ids,
                           excluded_pairs,
                           order_by_id,
                           images,
                           options.minimum_frame_separation);

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
  for (const ImageFeatures& image : images) {
    visual_index->Add(
        index_options, image.image_id, image.keypoints, image.descriptors);
  }
  visual_index->Prepare();

  retrieval::VisualIndex::QueryOptions query_options;
  query_options.max_num_images = -1;
  query_options.num_neighbors = 5;
  query_options.num_images_after_verification = 0;
  query_options.num_checks = std::min(options.num_checks, effective_words);
  query_options.num_threads = options.num_threads;

  std::set<ImagePair> emitted;
  std::vector<std::string> lines;
  const size_t retrieval_limit =
      std::min(images.size(),
               static_cast<size_t>(options.num_images) + maximum_filtered);
  for (const int query_id : query_ids) {
    const ImageFeatures& query = *image_by_id.at(query_id);
    std::vector<retrieval::ImageScore> scores;
    visual_index->Query(
        query_options, query.keypoints, query.descriptors, &scores);
    for (const retrieval::ImageScore& score : scores) {
      if (!std::isfinite(score.score) ||
          image_by_id.find(score.image_id) == image_by_id.end()) {
        Fail("vocabulary retrieval returned an invalid image score");
      }
    }
    std::sort(scores.begin(),
              scores.end(),
              [&image_by_id](const retrieval::ImageScore& first,
                             const retrieval::ImageScore& second) {
                if (first.score != second.score) {
                  return first.score > second.score;
                }
                return image_by_id.at(first.image_id)->name <
                       image_by_id.at(second.image_id)->name;
              });
    if (scores.size() > retrieval_limit) {
      scores.resize(retrieval_limit);
    }

    size_t retained = 0;
    for (const retrieval::ImageScore& score : scores) {
      const int candidate_id = score.image_id;
      if (candidate_id == query_id) {
        continue;
      }
      const auto pair = UndirectedPair(query_id, candidate_id);
      if (excluded_pairs.pairs.find(pair) != excluded_pairs.pairs.end()) {
        continue;
      }
      const size_t query_order = order_by_id.at(query_id);
      const size_t candidate_order = order_by_id.at(candidate_id);
      const size_t distance = query_order > candidate_order
                                  ? query_order - candidate_order
                                  : candidate_order - query_order;
      if (distance < static_cast<size_t>(options.minimum_frame_separation)) {
        continue;
      }
      if (emitted.insert(pair).second) {
        lines.push_back(query.name + " " + image_by_id.at(candidate_id)->name);
      }
      ++retained;
      if (retained >= static_cast<size_t>(options.returned_neighbor_count)) {
        break;
      }
    }
  }
  std::sort(lines.begin(), lines.end());
  return lines;
}

int Run(const RetrieverOptions& options) {
  ValidateBounds(options);
  const FileIdentity database_identity =
      ValidateRegularInput(options.database_path, "database path");
  const std::optional<FileIdentity> output_identity =
      ValidateOutputPath(options.output_pair_list_path);
  if (output_identity.has_value() &&
      SameFile(database_identity, output_identity.value())) {
    Fail("output pair list must not replace the retrieval database");
  }
  OptionalInputs inputs;
  if (!options.query_image_list_path.empty()) {
    inputs.query_images =
        ValidateRegularInput(options.query_image_list_path, "query image list");
  }
  if (!options.excluded_pair_list_path.empty()) {
    inputs.excluded_pairs = ValidateRegularInput(
        options.excluded_pair_list_path, "excluded pair list");
  }
  if (output_identity.has_value() && inputs.query_images.has_value() &&
      SameFile(output_identity.value(), inputs.query_images.value())) {
    Fail("output pair list must not replace the query image list");
  }
  if (output_identity.has_value() && inputs.excluded_pairs.has_value() &&
      SameFile(output_identity.value(), inputs.excluded_pairs.value())) {
    Fail("output pair list must not replace the excluded pair list");
  }
  RejectPendingSidecars(options.database_path);
  SQLiteDatabase database(options.database_path);
  const std::vector<std::string> pair_lines =
      RetrievePairs(options, database, inputs);
  AtomicWrite(options.output_pair_list_path, pair_lines);
  LOG(INFO) << "Retrieved image pairs: " << pair_lines.size();
  return EXIT_SUCCESS;
}

}  // namespace

int RunLocalVocabularyRetriever(int argc, char** argv) {
  RetrieverOptions values;
  OptionManager options(/*add_project_options=*/false);
  options.AddRequiredOption("database_path", &values.database_path);
  options.AddRequiredOption("output_pair_list_path",
                            &values.output_pair_list_path);
  options.AddDefaultOption("query_image_list_path",
                           &values.query_image_list_path);
  options.AddDefaultOption("excluded_pair_list_path",
                           &values.excluded_pair_list_path);
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
  } catch (const std::exception& error) {
    LOG(ERROR) << "Local vocabulary retrieval failed: " << error.what();
    return EXIT_FAILURE;
  }
}

}  // namespace colmap
