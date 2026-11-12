// Pure C++ core of the iOS TagLib bridge. Mirrors lyrico-audiotag/src/main/cpp/taglib.cpp
// (JNI) but without JNI/Objective-C types, so it can be unit-tested on any platform.
#ifndef LYRICO_TAG_CORE_HPP
#define LYRICO_TAG_CORE_HPP

#include <cstdint>
#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace lyrico {

struct CorePicture {
    std::string data;          // raw image bytes
    std::string description;   // UTF-8
    std::string pictureType;   // ID3v2 style name, e.g. "Front Cover"
    std::string mimeType;      // e.g. "image/jpeg"
};

struct CoreAudioProperties {
    int length = 0;      // milliseconds
    int bitrate = 0;     // kbps
    int sampleRate = 0;  // Hz
    int channels = 0;
};

using CorePropertyList = std::vector<std::pair<std::string, std::vector<std::string>>>;

struct CoreMetadata {
    CorePropertyList properties;
    std::vector<CorePicture> pictures;
    bool supportsTypedPictures = true;
};

/// Random access source for read-only parsing (e.g. remote files read in ranges).
struct CoreReader {
    int64_t length = 0;
    /// Must fill `out` with up to `size` bytes starting at `offset`; return bytes copied (0 at EOF, -1 on error).
    std::function<int64_t(int64_t offset, int64_t size, char *out)> readAt;
    std::string name = "stream";
};

/// readStyle: 0 = Fast, 1 = Average, 2 = Accurate (same ordinal as Kotlin AudioPropertiesReadStyle).
bool readAudioProperties(const char *path, int readStyle, CoreAudioProperties &out, std::string *error = nullptr);
bool readMetadata(const char *path, bool readPictures, CoreMetadata &out, std::string *error = nullptr);
bool readPropertyValues(const char *path, const std::string &key, std::vector<std::string> &out, std::string *error = nullptr);
bool readPictures(const char *path, std::vector<CorePicture> &out, std::string *error = nullptr);
/// Same semantics as Kotlin TagLib.savePropertyMap: each entry replaces the key; an empty list
/// (or a single empty string) erases the key. Keys not mentioned are kept.
bool savePropertyMap(const char *path, const CorePropertyList &updates, std::string *error = nullptr);
/// Replaces all pictures (complex property PICTURE). Empty list removes all pictures.
bool savePictures(const char *path, const std::vector<CorePicture> &pictures, std::string *error = nullptr);

bool readAudioProperties(const CoreReader &reader, int readStyle, CoreAudioProperties &out, std::string *error = nullptr);
bool readMetadata(const CoreReader &reader, bool readPictures, CoreMetadata &out, std::string *error = nullptr);
bool readPictures(const CoreReader &reader, std::vector<CorePicture> &out, std::string *error = nullptr);

} // namespace lyrico

#endif
