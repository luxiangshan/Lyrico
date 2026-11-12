// Objective-C facade over LyricoTagCore (TagLib 2.x). Exposed to Swift through the bridging header.
// Mirrors com.lonx.audiotag.TagLib (Kotlin/JNI): file descriptors are replaced by file paths, plus
// reader-based variants for random-access sources (remote partial reads).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LTPicture : NSObject
@property (nonatomic, copy) NSData *data;
@property (nonatomic, copy) NSString *pictureDescription;
/// ID3v2 style picture type name, e.g. "Front Cover".
@property (nonatomic, copy) NSString *pictureType;
@property (nonatomic, copy) NSString *mimeType;
- (instancetype)initWithData:(NSData *)data
          pictureDescription:(NSString *)pictureDescription
                 pictureType:(NSString *)pictureType
                    mimeType:(NSString *)mimeType;
@end

@interface LTAudioProperties : NSObject
/// Length in milliseconds.
@property (nonatomic) NSInteger length;
/// kbps
@property (nonatomic) NSInteger bitrate;
@property (nonatomic) NSInteger sampleRate;
@property (nonatomic) NSInteger channels;
@end

@interface LTMetadata : NSObject
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *propertyMap;
@property (nonatomic, copy) NSArray<LTPicture *> *pictures;
@property (nonatomic) BOOL supportsTypedPictures;
@end

/// Random-access byte source used for read-only parsing without a local file.
@protocol LTRandomAccessReader <NSObject>
- (int64_t)totalLength;
/// Returns up to `length` bytes at `offset` (shorter at EOF), or nil on error.
- (nullable NSData *)readAtOffset:(int64_t)offset length:(NSInteger)length;
@end

@interface LTTagLib : NSObject

/// readStyle: 0 Fast, 1 Average, 2 Accurate.
+ (nullable LTAudioProperties *)audioPropertiesAtPath:(NSString *)path readStyle:(NSInteger)readStyle error:(NSError **)error;
+ (nullable LTMetadata *)metadataAtPath:(NSString *)path readPictures:(BOOL)readPictures error:(NSError **)error;
+ (nullable NSArray<NSString *> *)propertyValuesAtPath:(NSString *)path propertyName:(NSString *)propertyName;
+ (NSArray<LTPicture *> *)picturesAtPath:(NSString *)path;
/// Each entry replaces that key; an empty array (or [""]) removes the key. Other keys are kept.
+ (BOOL)savePropertyMap:(NSDictionary<NSString *, NSArray<NSString *> *> *)propertyMap atPath:(NSString *)path error:(NSError **)error;
/// Replaces all embedded pictures; an empty array removes every picture.
+ (BOOL)savePictures:(NSArray<LTPicture *> *)pictures atPath:(NSString *)path error:(NSError **)error;

+ (nullable LTAudioProperties *)audioPropertiesWithReader:(id<LTRandomAccessReader>)reader readStyle:(NSInteger)readStyle error:(NSError **)error;
+ (nullable LTMetadata *)metadataWithReader:(id<LTRandomAccessReader>)reader readPictures:(BOOL)readPictures error:(NSError **)error;
+ (NSArray<LTPicture *> *)picturesWithReader:(id<LTRandomAccessReader>)reader;

/// TagLib version string, e.g. "2.1.1".
+ (NSString *)tagLibVersion;

@end

NS_ASSUME_NONNULL_END
