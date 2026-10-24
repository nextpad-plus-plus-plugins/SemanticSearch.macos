#import "AppleNLEmbeddingProvider.h"
#import <NaturalLanguage/NaturalLanguage.h>
#include <cmath>
#include <vector>

// L2-normalize in place. Returns NO for a zero vector.
static BOOL nppL2Normalize(float *v, NSUInteger dim) {
    double sumSq = 0;
    for (NSUInteger i = 0; i < dim; i++) sumSq += (double)v[i] * (double)v[i];
    if (!std::isfinite(sumSq) || sumSq <= 0) return NO;
    float inv = (float)(1.0 / sqrt(sumSq));
    for (NSUInteger i = 0; i < dim; i++) v[i] *= inv;
    return YES;
}

@implementation AppleNLEmbeddingProvider {
    NLContextualEmbedding *_contextual;   // preferred when the caller asks for it
    NLEmbedding           *_sentence;     // static sentence embedding
    NLLanguage             _language;
    NSUInteger             _dimension;
}

@synthesize backendName = _backendName;
@synthesize fallbackNote = _fallbackNote;

+ (NSArray<NSString *> *)modelIDsForLanguage:(NSString *)language {
    NLLanguage lang = language.length ? language : NLLanguageEnglish;
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    if (@available(macOS 14.0, *)) {
        if ([NLContextualEmbedding contextualEmbeddingWithLanguage:lang])
            [ids addObject:@"contextual"];
    }
    if ([NLEmbedding sentenceEmbeddingForLanguage:lang])
        [ids addObject:@"sentence"];
    return ids;
}

- (instancetype)initWithLanguageHint:(NSString *)languageHint
                              modelID:(NSString *)modelID {
    self = [super init];
    if (!self) return nil;

    _language = languageHint.length ? languageHint : NLLanguageEnglish;
    BOOL wantSentence = [modelID isEqualToString:@"sentence"];

    if (!wantSentence) {
        NLContextualEmbedding *ctx =
            [NLContextualEmbedding contextualEmbeddingWithLanguage:_language];
        if (ctx) {
            if (ctx.hasAvailableAssets) {
                NSError *err = nil;
                if ([ctx loadWithError:&err]) {
                    _contextual = ctx;
                    _dimension = ctx.dimension;
                    _backendName = @"contextual";
                }
            } else {
                // Ask macOS to fetch the asset for a later launch. This
                // session uses the built-in sentence model instead.
                [ctx requestEmbeddingAssetsWithCompletionHandler:
                    ^(NLContextualEmbeddingAssetsResult result, NSError *error) {}];
            }
        }
    }

    if (!_contextual) {
        NLEmbedding *sent = [NLEmbedding sentenceEmbeddingForLanguage:_language];
        if (sent) {
            _sentence = sent;
            _dimension = sent.dimension;
            _backendName = @"sentence";
            if (!wantSentence)
                _fallbackNote = @"Contextual assets are not installed yet, so the sentence model is running.";
        }
    }

    return self;
}

- (NSUInteger)dimension { return _dimension; }
- (BOOL)isAvailable     { return _dimension > 0; }

- (BOOL)embedString:(NSString *)string into:(float *)outVector {
    if (_dimension == 0 || string.length == 0) return NO;

    if (_contextual) {
        NSError *err = nil;
        NLContextualEmbeddingResult *result =
            [_contextual embeddingResultForString:string language:_language error:&err];
        if (!result) return NO;

        // Mean-pool the per-token vectors into one sentence vector.
        std::vector<double> acc(_dimension, 0.0);
        __block NSUInteger tokenCount = 0;
        NSUInteger dim = _dimension;
        double *accPtr = acc.data();
        [result enumerateTokenVectorsInRange:NSMakeRange(0, string.length)
                                  usingBlock:^(NSArray<NSNumber *> *tokenVector,
                                               NSRange tokenRange, BOOL *stop) {
            if (tokenVector.count != dim) return;
            for (NSUInteger i = 0; i < dim; i++)
                accPtr[i] += tokenVector[i].doubleValue;
            tokenCount++;
        }];
        if (tokenCount == 0) return NO;
        for (NSUInteger i = 0; i < _dimension; i++)
            outVector[i] = (float)(acc[i] / (double)tokenCount);
        return nppL2Normalize(outVector, _dimension);
    }

    if (_sentence) {
        if (![_sentence getVector:outVector forString:string]) return NO;
        return nppL2Normalize(outVector, _dimension);
    }

    return NO;
}

@end
