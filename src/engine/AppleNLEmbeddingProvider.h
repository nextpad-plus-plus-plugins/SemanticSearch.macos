#import <Foundation/Foundation.h>
#import "SemanticProtocols.h"

NS_ASSUME_NONNULL_BEGIN

/// SemanticEmbeddingProvider backed by Apple's NaturalLanguage framework.
///
/// Two sentence models are available on macOS 14. NLContextualEmbedding
/// produces a vector per token; those are mean-pooled into one sentence
/// vector. Its assets may download on demand. NLEmbedding's sentence
/// embedding is built in and is used when contextual assets are not on
/// this Mac yet, or when the caller asks for it.
///
/// Vectors are L2-normalized. Model loading happens in init and can block.
/// Construct off the main thread.
API_AVAILABLE(macos(14.0))
@interface AppleNLEmbeddingProvider : NSObject <SemanticEmbeddingProvider>

/// languageHint is a BCP-47 NLLanguage value (for example @"en"). Nil
/// defaults to English.
///
/// modelID is @"contextual" or @"sentence". Nil prefers contextual and
/// falls back to the sentence model when the contextual assets are absent.
- (instancetype)initWithLanguageHint:(nullable NSString *)languageHint
                              modelID:(nullable NSString *)modelID;

/// Backend in use: @"contextual" or @"sentence". Nil if none loaded.
@property (nonatomic, readonly, nullable) NSString *backendName;

/// Set when modelID asked for contextual and the sentence model is running
/// because the contextual assets are not installed yet. Nil otherwise.
@property (nonatomic, readonly, nullable) NSString *fallbackNote;

/// Ids the framework can construct for this language. An id is included
/// when the model object exists, even if contextual assets still need an
/// OS download. Order is contextual, then sentence.
+ (NSArray<NSString *> *)modelIDsForLanguage:(nullable NSString *)language;

@end

NS_ASSUME_NONNULL_END
