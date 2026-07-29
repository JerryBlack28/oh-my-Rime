//
//  SemanticGrammar.cc
//  Squirrel
//
//  The grammar database format and query encoding are compatible with
//  librime-octagram. The file is mapped read-only so a large language model
//  does not become a similarly large resident-memory allocation.
//  Encoding and database-query behavior are derived from librime-octagram,
//  licensed under GPL-3.0.
//

#include "SemanticGrammar.h"

#include <darts.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>

namespace {

constexpr int kMaximumEncodedCharacters = 8;
constexpr int kMaximumResults = 8;
constexpr double kValueScale = 10000.0;
constexpr double kMissingScore = -100.0;

struct GrammarMetadata {
  char format[32];
  uint32_t checksum;
  uint32_t double_array_size;
  int32_t double_array_offset;
};

static_assert(offsetof(GrammarMetadata, double_array_offset) == 40,
              "Unexpected grammar metadata layout");

class MappedGrammar {
 public:
  ~MappedGrammar() {
    if (mapping_ != MAP_FAILED) {
      munmap(mapping_, mapping_size_);
    }
    if (file_descriptor_ >= 0) {
      close(file_descriptor_);
    }
  }

  bool Load(const char* path) {
    file_descriptor_ = open(path, O_RDONLY);
    if (file_descriptor_ < 0) {
      return false;
    }

    struct stat file_status {};
    if (fstat(file_descriptor_, &file_status) != 0 ||
        file_status.st_size < static_cast<off_t>(sizeof(GrammarMetadata))) {
      return false;
    }
    mapping_size_ = static_cast<size_t>(file_status.st_size);
    mapping_ = mmap(nullptr, mapping_size_, PROT_READ, MAP_PRIVATE,
                    file_descriptor_, 0);
    if (mapping_ == MAP_FAILED) {
      return false;
    }

    const auto* metadata =
        static_cast<const GrammarMetadata*>(mapping_);
    constexpr char kFormatPrefix[] = "Rime::Grammar/";
    if (std::memcmp(metadata->format, kFormatPrefix,
                    sizeof(kFormatPrefix) - 1) != 0 ||
        metadata->double_array_size == 0 ||
        metadata->double_array_offset <= 0) {
      return false;
    }

    const auto* offset_address =
        reinterpret_cast<const char*>(&metadata->double_array_offset);
    const auto* array_address =
        offset_address + metadata->double_array_offset;
    const auto* mapping_begin = static_cast<const char*>(mapping_);
    const auto* mapping_end = mapping_begin + mapping_size_;
    const size_t array_bytes =
        size_t(metadata->double_array_size) * trie_.unit_size();
    if (array_address < mapping_begin || array_address > mapping_end ||
        array_bytes > size_t(mapping_end - array_address)) {
      return false;
    }

    trie_.set_array(array_address, metadata->double_array_size);
    return true;
  }

  double Score(const std::string& context,
               const std::string& candidate) const {
    if (context.empty() || candidate.empty()) {
      return kMissingScore;
    }

    const char* context_begin =
        LastCharacters(context, kMaximumEncodedCharacters - 1);
    const char* context_end = context.c_str() + context.size();
    const char* candidate_begin = candidate.c_str();
    const char* candidate_end =
        FirstCharacters(candidate, kMaximumEncodedCharacters - 1);
    const std::string context_query = Encode(context_begin, context_end);
    const std::string candidate_query =
        Encode(candidate_begin, candidate_end);

    double result = kMissingScore;
    for (const char* cursor = context_query.c_str();
         cursor < context_query.c_str() + context_query.size();
         cursor = NextEncodedCharacter(cursor)) {
      Darts::DoubleArray::result_pair_type matches[kMaximumResults];
      size_t node_position = 0;
      size_t key_position = 0;
      trie_.traverse(cursor, node_position, key_position);
      if (key_position != std::strlen(cursor)) {
        continue;
      }
      const int count = trie_.commonPrefixSearch(
          candidate_query.c_str(), matches, kMaximumResults, 0,
          node_position);
      for (int index = 0; index < count; ++index) {
        if (matches[index].value >= 0) {
          result = std::max(
              result, double(matches[index].value) / kValueScale);
        }
      }
    }
    return result;
  }

 private:
  static uint32_t DecodeUTF8(const char*& cursor) {
    const auto first = static_cast<unsigned char>(*cursor++);
    if (first < 0x80) {
      return first;
    }
    int continuation_count = 0;
    uint32_t value = 0;
    if ((first & 0xE0) == 0xC0) {
      continuation_count = 1;
      value = first & 0x1F;
    } else if ((first & 0xF0) == 0xE0) {
      continuation_count = 2;
      value = first & 0x0F;
    } else {
      continuation_count = 3;
      value = first & 0x07;
    }
    for (int index = 0; index < continuation_count; ++index) {
      value = (value << 6) |
              (static_cast<unsigned char>(*cursor++) & 0x3F);
    }
    return value;
  }

  static const char* PreviousUTF8(const char* begin,
                                  const char* cursor) {
    if (cursor == begin) {
      return cursor;
    }
    --cursor;
    while (cursor > begin &&
           (static_cast<unsigned char>(*cursor) & 0xC0) == 0x80) {
      --cursor;
    }
    return cursor;
  }

  static const char* NextUTF8(const char* cursor) {
    const auto first = static_cast<unsigned char>(*cursor);
    if (first < 0x80) {
      return cursor + 1;
    }
    if ((first & 0xE0) == 0xC0) {
      return cursor + 2;
    }
    if ((first & 0xF0) == 0xE0) {
      return cursor + 3;
    }
    return cursor + 4;
  }

  static const char* LastCharacters(const std::string& text,
                                    int maximum) {
    const char* begin = text.c_str();
    const char* cursor = begin + text.size();
    for (int count = 0; cursor != begin && count < maximum; ++count) {
      cursor = PreviousUTF8(begin, cursor);
    }
    return cursor;
  }

  static const char* FirstCharacters(const std::string& text,
                                     int maximum) {
    const char* cursor = text.c_str();
    const char* end = cursor + text.size();
    for (int count = 0; cursor != end && count < maximum; ++count) {
      cursor = std::min(NextUTF8(cursor), end);
    }
    return cursor;
  }

  static std::string Encode(const char* begin, const char* end) {
    char output[kMaximumEncodedCharacters * 4];
    char* write = output;
    for (const char* cursor = begin; cursor < end;) {
      uint32_t value = DecodeUTF8(cursor);
      if (value < 0x80) {
        *write++ = value == 0 ? char(0xE0) : char(value);
      } else if (value >= 0x4000 && value < 0xA000) {
        if ((value & 0xFF) == 0) {
          *write++ = char(0xE1);
          *write++ = char((value >> 8) + 0x40);
        } else {
          *write++ = char((value >> 8) + 0x40);
          *write++ = char(value & 0xFF);
        }
      } else {
        int bits = 32;
        while (bits > 0 && (value & 0xFE000000) == 0) {
          bits -= 7;
          value <<= 7;
        }
        int bytes = (bits + 6) / 7;
        *write++ = char(0xE0 | bytes);
        while (bytes > 0) {
          --bytes;
          *write++ = char(((value >> 25) & 0x7F) | 0x80);
          value <<= 7;
        }
      }
    }
    return std::string(output, write);
  }

  static const char* NextEncodedCharacter(const char* cursor) {
    return cursor +
        ((static_cast<unsigned char>(*cursor) & 0x80) == 0
             ? 1
             : (static_cast<unsigned char>(*cursor) & 0xF0) == 0xE0
                 ? (*cursor & 0x0F) + 1
                 : 2);
  }

  int file_descriptor_ = -1;
  void* mapping_ = MAP_FAILED;
  size_t mapping_size_ = 0;
  Darts::DoubleArray trie_;
};

std::mutex grammar_mutex;
std::unique_ptr<MappedGrammar> grammar;

}  // namespace

bool SquirrelGrammarLoad(const char* model_path) {
  if (!model_path) {
    return false;
  }
  auto candidate = std::make_unique<MappedGrammar>();
  if (!candidate->Load(model_path)) {
    return false;
  }
  std::lock_guard<std::mutex> lock(grammar_mutex);
  grammar = std::move(candidate);
  return true;
}

void SquirrelGrammarUnload(void) {
  std::lock_guard<std::mutex> lock(grammar_mutex);
  grammar.reset();
}

double SquirrelGrammarScore(const char* context,
                            const char* candidate) {
  if (!context || !candidate) {
    return NAN;
  }
  std::lock_guard<std::mutex> lock(grammar_mutex);
  if (!grammar) {
    return NAN;
  }
  const double score = grammar->Score(context, candidate);
  return score <= kMissingScore ? NAN : score;
}
