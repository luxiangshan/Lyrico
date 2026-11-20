// See LyricoTagCore.hpp. Logic follows lyrico-audiotag/src/main/cpp/taglib.cpp + utils.h.
#include "LyricoTagCore.hpp"

#include <tfilestream.h>
#include <tiostream.h>
#include <tfile.h>
#include <tpropertymap.h>
#include <tvariant.h>
#include <tstringlist.h>
#include <tbytevector.h>
#include <audioproperties.h>
#include <tag.h>

#include <mpegfile.h>
#include <vorbisfile.h>
#include <flacfile.h>
#include <opusfile.h>
#include <mp4file.h>
#include <wavfile.h>
#include <apefile.h>
#include <asffile.h>
#include <aifffile.h>
#include <wavpackfile.h>
#include <dsffile.h>
#include <speexfile.h>
#include <oggflacfile.h>

#include <algorithm>
#include <cstring>
#include <exception>
#include <memory>

namespace lyrico {
namespace {

template<typename FileType>
TagLib::File *createSupportedFile(TagLib::IOStream *stream, bool readAudioProperties,
                                  TagLib::AudioProperties::ReadStyle style) {
    stream->seek(0);
    if (!FileType::isSupported(stream)) {
        return nullptr;
    }
    stream->seek(0);
    return new FileType(stream, readAudioProperties, style);
}

// Same detection order as Android (APE before MPEG), followed by a few extra formats iOS users
// commonly have (WMA/ASF, AIFF, WavPack, DSF, Speex, Ogg FLAC).
TagLib::File *createFileFromContent(TagLib::IOStream *stream, bool readAudioProperties,
                                    TagLib::AudioProperties::ReadStyle style) {
    TagLib::File *file = nullptr;
    file = createSupportedFile<TagLib::APE::File>(stream, readAudioProperties, style);
    if (!file) file = createSupportedFile<TagLib::MPEG::File>(stream, readAudioProperties, style);
    if (!file) file = createSupportedFile<TagLib::Ogg::Vorbis::File>(stream, readAudioProperties, style);
    if (!file) file = createSupportedFile<TagLib::FLAC::File>(stream, readAudioProperties, style);
    if (!file) file = createSupportedFile<TagLib::Ogg::Opus::File>(stream, readAudioProperties, style);
    if (!file) file = createSupportedFile<TagLib::MP4::File>(stream, readAudioProperties, style);
    if (!file) file = createSupportedFile<TagLib::RIFF::WAV::File>(stream, readAudioProperties, style);
    if (!file) file = createSupportedFile<TagLib::ASF::File>(stream, readAudioProperties, style);
    if (!file) file = createSupportedFile<TagLib::RIFF::AIFF::File>(stream, readAudioProperties, style);
    if (!file) file = createSupportedFile<TagLib::WavPack::File>(stream, readAudioProperties, style);
    if (!file) file = createSupportedFile<TagLib::DSF::File>(stream, readAudioProperties, style);
    if (!file) file = createSupportedFile<TagLib::Ogg::Speex::File>(stream, readAudioProperties, style);
    if (!file) file = createSupportedFile<TagLib::Ogg::FLAC::File>(stream, readAudioProperties, style);
    if (!file) return nullptr;

    if (file->isValid()) return file;
    bool hasTags = (file->tag() && !file->tag()->isEmpty()) || !file->properties().isEmpty();
    if (hasTags) return file;
    delete file;
    return nullptr;
}

TagLib::AudioProperties::ReadStyle toStyle(int readStyle) {
    switch (readStyle) {
        case 0: return TagLib::AudioProperties::Fast;
        case 2: return TagLib::AudioProperties::Accurate;
        default: return TagLib::AudioProperties::Average;
    }
}

std::string toUtf8(const TagLib::String &s) {
    return s.to8Bit(true);
}

TagLib::String fromUtf8(const std::string &s) {
    return TagLib::String(s, TagLib::String::UTF8);
}

void fillProperties(TagLib::File *file, CorePropertyList &out) {
    out.clear();
    const TagLib::PropertyMap map = file->properties();
    for (const auto &entry : map) {
        std::vector<std::string> values;
        for (const auto &v : entry.second) values.push_back(toUtf8(v));
        out.emplace_back(toUtf8(entry.first), std::move(values));
    }
}

void fillPictures(TagLib::File *file, std::vector<CorePicture> &out) {
    out.clear();
    const auto list = file->complexProperties("PICTURE");
    for (const auto &picture : list) {
        const TagLib::ByteVector data = picture["data"].toByteVector();
        if (data.isEmpty()) continue;
        CorePicture p;
        p.data.assign(data.data(), data.size());
        p.description = toUtf8(picture["description"].toString());
        p.pictureType = toUtf8(picture["pictureType"].toString());
        p.mimeType = toUtf8(picture["mimeType"].toString());
        out.push_back(std::move(p));
    }
}

bool supportsTypedPictures(TagLib::File *file) {
    return dynamic_cast<TagLib::MP4::File *>(file) == nullptr;
}

void setError(std::string *error, const std::string &message) {
    if (error) *error = message;
}

/// Read-only IOStream backed by a CoreReader callback (random access).
class ReaderStream : public TagLib::IOStream {
public:
    explicit ReaderStream(const CoreReader &reader) : reader_(reader) {}

    TagLib::FileName name() const override { return reader_.name.c_str(); }

    TagLib::ByteVector readBlock(size_t length) override {
        if (length == 0 || position_ >= reader_.length) return TagLib::ByteVector();
        const int64_t available = reader_.length - position_;
        const int64_t want = std::min<int64_t>(static_cast<int64_t>(length), available);
        TagLib::ByteVector buffer(static_cast<unsigned int>(want), 0);
        int64_t total = 0;
        while (total < want) {
            const int64_t got = reader_.readAt(position_ + total, want - total, buffer.data() + total);
            if (got <= 0) break;
            total += got;
        }
        buffer.resize(static_cast<unsigned int>(std::max<int64_t>(total, 0)));
        position_ += total;
        return buffer;
    }

    void writeBlock(const TagLib::ByteVector &) override {}
    void insert(const TagLib::ByteVector &, TagLib::offset_t, size_t) override {}
    void removeBlock(TagLib::offset_t, size_t) override {}
    bool readOnly() const override { return true; }
    bool isOpen() const override { return true; }

    void seek(TagLib::offset_t offset, Position p) override {
        int64_t base = 0;
        if (p == Current) base = position_;
        else if (p == End) base = reader_.length;
        int64_t target = base + static_cast<int64_t>(offset);
        if (target < 0) target = 0;
        position_ = target;
    }

    void clear() override {}
    TagLib::offset_t tell() const override { return static_cast<TagLib::offset_t>(position_); }
    TagLib::offset_t length() override { return static_cast<TagLib::offset_t>(reader_.length); }
    void truncate(TagLib::offset_t) override {}

private:
    const CoreReader &reader_;
    int64_t position_ = 0;
};

template<typename Fn>
bool withFile(TagLib::IOStream *stream, bool readProps, TagLib::AudioProperties::ReadStyle style,
              std::string *error, Fn &&fn) {
    try {
        std::unique_ptr<TagLib::File> file(createFileFromContent(stream, readProps, style));
        if (!file) {
            setError(error, "unsupported or invalid audio file");
            return false;
        }
        return fn(file.get());
    } catch (const std::exception &e) {
        setError(error, e.what());
        return false;
    } catch (...) {
        setError(error, "unknown TagLib error");
        return false;
    }
}

template<typename Fn>
bool withPath(const char *path, bool readOnly, bool readProps, TagLib::AudioProperties::ReadStyle style,
              std::string *error, Fn &&fn) {
    try {
        TagLib::FileStream stream(path, readOnly);
        if (!stream.isOpen()) {
            setError(error, readOnly ? "cannot open file" : "cannot open file for writing");
            return false;
        }
        if (!readOnly && stream.readOnly()) {
            setError(error, "file is read-only");
            return false;
        }
        return withFile(&stream, readProps, style, error, std::forward<Fn>(fn));
    } catch (const std::exception &e) {
        setError(error, e.what());
        return false;
    } catch (...) {
        setError(error, "unknown TagLib error");
        return false;
    }
}

bool audioPropsOf(TagLib::File *file, CoreAudioProperties &out) {
    out = CoreAudioProperties();
    const TagLib::AudioProperties *ap = file->audioProperties();
    if (ap) {
        out.length = ap->lengthInMilliseconds();
        out.bitrate = ap->bitrate();
        out.sampleRate = ap->sampleRate();
        out.channels = ap->channels();
    }
    return true;
}

} // namespace

bool readAudioProperties(const char *path, int readStyle, CoreAudioProperties &out, std::string *error) {
    out = CoreAudioProperties();
    return withPath(path, true, true, toStyle(readStyle), error,
                    [&](TagLib::File *file) { return audioPropsOf(file, out); });
}

bool readMetadata(const char *path, bool readPics, CoreMetadata &out, std::string *error) {
    return withPath(path, true, false, TagLib::AudioProperties::Average, error, [&](TagLib::File *file) {
        fillProperties(file, out.properties);
        if (readPics) fillPictures(file, out.pictures); else out.pictures.clear();
        out.supportsTypedPictures = supportsTypedPictures(file);
        return true;
    });
}

bool readPropertyValues(const char *path, const std::string &key, std::vector<std::string> &out, std::string *error) {
    out.clear();
    return withPath(path, true, false, TagLib::AudioProperties::Average, error, [&](TagLib::File *file) {
        const auto map = file->properties();
        auto it = map.find(fromUtf8(key));
        if (it == map.end()) return false;
        for (const auto &v : it->second) out.push_back(toUtf8(v));
        return true;
    });
}

bool readPictures(const char *path, std::vector<CorePicture> &out, std::string *error) {
    out.clear();
    return withPath(path, true, false, TagLib::AudioProperties::Average, error, [&](TagLib::File *file) {
        fillPictures(file, out);
        return true;
    });
}

bool savePropertyMap(const char *path, const CorePropertyList &updates, std::string *error) {
    return withPath(path, false, false, TagLib::AudioProperties::Average, error, [&](TagLib::File *file) {
        TagLib::PropertyMap props = file->properties();
        for (const auto &update : updates) {
            const TagLib::String key = fromUtf8(update.first);
            TagLib::StringList values;
            for (const auto &v : update.second) values.append(fromUtf8(v));
            if (values.isEmpty() || (values.size() == 1 && values.front().isEmpty())) {
                props.erase(key);
            } else {
                props.replace(key, values);
            }
        }
        file->setProperties(props);
        if (!file->save()) {
            setError(error, "TagLib save() failed");
            return false;
        }
        return true;
    });
}

bool savePictures(const char *path, const std::vector<CorePicture> &pictures, std::string *error) {
    return withPath(path, false, false, TagLib::AudioProperties::Average, error, [&](TagLib::File *file) {
        TagLib::List<TagLib::VariantMap> list;
        for (const auto &p : pictures) {
            TagLib::VariantMap m;
            m["data"] = TagLib::ByteVector(p.data.data(), static_cast<unsigned int>(p.data.size()));
            m["description"] = fromUtf8(p.description);
            m["pictureType"] = fromUtf8(p.pictureType);
            m["mimeType"] = fromUtf8(p.mimeType);
            list.append(m);
        }
        file->setComplexProperties("PICTURE", list);
        if (!file->save()) {
            setError(error, "TagLib save() failed");
            return false;
        }
        return true;
    });
}

bool readAudioProperties(const CoreReader &reader, int readStyle, CoreAudioProperties &out, std::string *error) {
    out = CoreAudioProperties();
    ReaderStream stream(reader);
    return withFile(&stream, true, toStyle(readStyle), error,
                    [&](TagLib::File *file) { return audioPropsOf(file, out); });
}

bool readMetadata(const CoreReader &reader, bool readPics, CoreMetadata &out, std::string *error) {
    ReaderStream stream(reader);
    return withFile(&stream, false, TagLib::AudioProperties::Average, error, [&](TagLib::File *file) {
        fillProperties(file, out.properties);
        if (readPics) fillPictures(file, out.pictures); else out.pictures.clear();
        out.supportsTypedPictures = supportsTypedPictures(file);
        return true;
    });
}

bool readPictures(const CoreReader &reader, std::vector<CorePicture> &out, std::string *error) {
    out.clear();
    ReaderStream stream(reader);
    return withFile(&stream, false, TagLib::AudioProperties::Average, error, [&](TagLib::File *file) {
        fillPictures(file, out);
        return true;
    });
}

} // namespace lyrico
