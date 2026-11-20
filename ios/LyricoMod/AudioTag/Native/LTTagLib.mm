#import "LTTagLib.h"
#include "LyricoTagCore.hpp"
#include <taglib.h>
#include <string>
#include <vector>

static NSString *const LTErrorDomain = @"LyricoTagLib";

@implementation LTPicture
- (instancetype)initWithData:(NSData *)data pictureDescription:(NSString *)pictureDescription pictureType:(NSString *)pictureType mimeType:(NSString *)mimeType {
    if ((self = [super init])) {
        _data = [data copy];
        _pictureDescription = [pictureDescription copy];
        _pictureType = [pictureType copy];
        _mimeType = [mimeType copy];
    }
    return self;
}
@end

@implementation LTAudioProperties
@end

@implementation LTMetadata
@end

static NSString *LTString(const std::string &s) {
    NSString *r = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return r ?: @"";
}

static std::string LTStd(NSString *s) {
    if (!s) return std::string();
    const char *c = [s UTF8String];
    return c ? std::string(c) : std::string();
}

static void LTSetError(NSError **error, const std::string &message) {
    if (error) {
        *error = [NSError errorWithDomain:LTErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: LTString(message.empty() ? std::string("TagLib error") : message)}];
    }
}

static NSArray<LTPicture *> *LTPictures(const std::vector<lyrico::CorePicture> &pictures) {
    NSMutableArray<LTPicture *> *out = [NSMutableArray arrayWithCapacity:pictures.size()];
    for (const auto &p : pictures) {
        NSData *data = [NSData dataWithBytes:p.data.data() length:p.data.size()];
        [out addObject:[[LTPicture alloc] initWithData:data
                                    pictureDescription:LTString(p.description)
                                           pictureType:LTString(p.pictureType)
                                              mimeType:LTString(p.mimeType)]];
    }
    return out;
}

static LTMetadata *LTMakeMetadata(const lyrico::CoreMetadata &md) {
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *map = [NSMutableDictionary dictionaryWithCapacity:md.properties.size()];
    for (const auto &entry : md.properties) {
        NSMutableArray<NSString *> *values = [NSMutableArray arrayWithCapacity:entry.second.size()];
        for (const auto &v : entry.second) [values addObject:LTString(v)];
        map[LTString(entry.first)] = values;
    }
    LTMetadata *m = [LTMetadata new];
    m.propertyMap = map;
    m.pictures = LTPictures(md.pictures);
    m.supportsTypedPictures = md.supportsTypedPictures;
    return m;
}

static LTAudioProperties *LTMakeProps(const lyrico::CoreAudioProperties &p) {
    LTAudioProperties *r = [LTAudioProperties new];
    r.length = p.length;
    r.bitrate = p.bitrate;
    r.sampleRate = p.sampleRate;
    r.channels = p.channels;
    return r;
}

static lyrico::CoreReader LTMakeReader(id<LTRandomAccessReader> reader) {
    lyrico::CoreReader r;
    r.length = [reader totalLength];
    r.readAt = [reader](int64_t offset, int64_t size, char *out) -> int64_t {
        @autoreleasepool {
            NSData *d = [reader readAtOffset:offset length:(NSInteger)size];
            if (!d) return -1;
            const int64_t n = MIN((int64_t)d.length, size);
            if (n > 0) memcpy(out, d.bytes, (size_t)n);
            return n;
        }
    };
    return r;
}

@implementation LTTagLib

+ (LTAudioProperties *)audioPropertiesAtPath:(NSString *)path readStyle:(NSInteger)readStyle error:(NSError **)error {
    lyrico::CoreAudioProperties p;
    std::string err;
    if (!lyrico::readAudioProperties(path.fileSystemRepresentation, (int)readStyle, p, &err)) {
        LTSetError(error, err);
        return nil;
    }
    return LTMakeProps(p);
}

+ (LTMetadata *)metadataAtPath:(NSString *)path readPictures:(BOOL)readPictures error:(NSError **)error {
    lyrico::CoreMetadata md;
    std::string err;
    if (!lyrico::readMetadata(path.fileSystemRepresentation, readPictures, md, &err)) {
        LTSetError(error, err);
        return nil;
    }
    return LTMakeMetadata(md);
}

+ (NSArray<NSString *> *)propertyValuesAtPath:(NSString *)path propertyName:(NSString *)propertyName {
    std::vector<std::string> values;
    if (!lyrico::readPropertyValues(path.fileSystemRepresentation, LTStd(propertyName), values, nullptr)) return nil;
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto &v : values) [out addObject:LTString(v)];
    return out;
}

+ (NSArray<LTPicture *> *)picturesAtPath:(NSString *)path {
    std::vector<lyrico::CorePicture> pictures;
    lyrico::readPictures(path.fileSystemRepresentation, pictures, nullptr);
    return LTPictures(pictures);
}

+ (BOOL)savePropertyMap:(NSDictionary<NSString *, NSArray<NSString *> *> *)propertyMap atPath:(NSString *)path error:(NSError **)error {
    lyrico::CorePropertyList updates;
    for (NSString *key in propertyMap) {
        std::vector<std::string> values;
        for (NSString *v in propertyMap[key]) values.push_back(LTStd(v));
        updates.emplace_back(LTStd(key), std::move(values));
    }
    std::string err;
    if (!lyrico::savePropertyMap(path.fileSystemRepresentation, updates, &err)) {
        LTSetError(error, err);
        return NO;
    }
    return YES;
}

+ (BOOL)savePictures:(NSArray<LTPicture *> *)pictures atPath:(NSString *)path error:(NSError **)error {
    std::vector<lyrico::CorePicture> list;
    for (LTPicture *p in pictures) {
        lyrico::CorePicture c;
        c.data.assign((const char *)p.data.bytes, p.data.length);
        c.description = LTStd(p.pictureDescription);
        c.pictureType = LTStd(p.pictureType);
        c.mimeType = LTStd(p.mimeType);
        list.push_back(std::move(c));
    }
    std::string err;
    if (!lyrico::savePictures(path.fileSystemRepresentation, list, &err)) {
        LTSetError(error, err);
        return NO;
    }
    return YES;
}

+ (LTAudioProperties *)audioPropertiesWithReader:(id<LTRandomAccessReader>)reader readStyle:(NSInteger)readStyle error:(NSError **)error {
    lyrico::CoreReader r = LTMakeReader(reader);
    lyrico::CoreAudioProperties p;
    std::string err;
    if (!lyrico::readAudioProperties(r, (int)readStyle, p, &err)) {
        LTSetError(error, err);
        return nil;
    }
    return LTMakeProps(p);
}

+ (LTMetadata *)metadataWithReader:(id<LTRandomAccessReader>)reader readPictures:(BOOL)readPictures error:(NSError **)error {
    lyrico::CoreReader r = LTMakeReader(reader);
    lyrico::CoreMetadata md;
    std::string err;
    if (!lyrico::readMetadata(r, readPictures, md, &err)) {
        LTSetError(error, err);
        return nil;
    }
    return LTMakeMetadata(md);
}

+ (NSArray<LTPicture *> *)picturesWithReader:(id<LTRandomAccessReader>)reader {
    lyrico::CoreReader r = LTMakeReader(reader);
    std::vector<lyrico::CorePicture> pictures;
    lyrico::readPictures(r, pictures, nullptr);
    return LTPictures(pictures);
}

+ (NSString *)tagLibVersion {
    return [NSString stringWithFormat:@"%d.%d.%d", TAGLIB_MAJOR_VERSION, TAGLIB_MINOR_VERSION, TAGLIB_PATCH_VERSION];
}

@end
