// SemanticSearch.macos — see SemanticController.h.
// Pipeline logic derives from PR #346 (Kristian Rickert); the generation/
// debounce/caching design is his, re-plumbed onto the plugin API.
#import "SemanticController.h"
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import "SemanticProtocols.h"
#import "AppleNLEmbeddingProvider.h"
#import "MetalSimilarityEngine.h"
#import "SpillableVectorIndex.h"
#include "SemanticHeatmapColors.h"
#import <NaturalLanguage/NaturalLanguage.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <map>
#include <memory>
#include <set>
#include <vector>

// Provided by PluginEntry.mm.
extern NppData gNppData;

static intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return gNppData._sendMessage(gNppData._nppHandle, msg, w, l);
}
static NppHandle curScintilla(void) {
    int which = 0;
    npp(NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return which == 0 ? gNppData._scintillaMainHandle
                      : gNppData._scintillaSecondHandle;
}
static intptr_t sci(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return gNppData._sendMessage(curScintilla(), msg, w, l);
}

// Fallback slot if NPPM_ALLOCATEINDICATOR is unavailable: 20 is the first id
// past the host's plugin-indicator range (9..19) and unused by the host.
static const int kFallbackIndicator = 20;

static const long       kMaxDocBytes  = 2 * 1024 * 1024;
static const NSUInteger kMaxSentences = 4096;
static const int64_t    kRebuildDebounceNs = (int64_t)(0.6 * NSEC_PER_SEC);

struct SemSentenceSpan {
    long byteStart;
    long byteLength;
};

@implementation SemanticController {
    // Pipeline components (confined to _workQueue after creation).
    id<SemanticEmbeddingProvider> _provider;
    id<SemanticVectorIndex>       _index;
    id<SemanticSimilarityEngine>  _engine;

    dispatch_queue_t _workQueue;
    NSCache<NSString *, NSData *> *_embedCache;

    // Main-thread state.
    intptr_t  _bufferID;         // 0 = detached
    int       _indicator;        // Scintilla indicator slot (allocated once)
    BOOL      _indicatorConfigured;
    std::vector<SemSentenceSpan> _spans;
    int64_t   _firstSentenceID;
    int64_t   _nextSentenceID;
    BOOL      _indexReady;
    NSString *_query;
    NSInteger _sensitivity;
    NSUInteger _bandMask;    // bit i = band i selected; 0 = all bands
    int        _bookmarkID;  // host bookmark marker (NPPM_GETBOOKMARKID)
    // Lines WE bookmarked, per buffer — so deselecting a band (or clearing)
    // removes exactly what we added and never the user's own bookmarks.
    std::map<intptr_t, std::set<long>> _ourBookmarks;
    std::vector<SemanticHit> _lastHits;
    NSString *_indexStatus;
    NSString *_providerLanguage;

    std::atomic<uint64_t> _buildGeneration;
    std::atomic<uint64_t> _queryGeneration;
    uint64_t _pendingRebuildToken;
}

+ (BOOL)isFeatureAvailable {
    if (@available(macOS 14.0, *)) return YES;
    return NO;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _buildGeneration.store(0);
    _queryGeneration.store(0);
    _workQueue = dispatch_queue_create("org.nextpadplusplus.plugin.semantic-search",
                                       DISPATCH_QUEUE_SERIAL);
    _embedCache = [[NSCache alloc] init];
    _embedCache.countLimit = 3 * kMaxSentences;
    _query = @"";
    _bufferID = 0;
    _indicator = 0;
    _bandMask = 0;
    _bookmarkID = -1;
    return self;
}

- (int)bookmarkID {
    if (_bookmarkID >= 0) return _bookmarkID;
    // The host's NPPM_GETBOOKMARKID answers 24 (the Windows NPP number), but
    // the macOS host's own bookmark marker is 20 (kBookmarkMarker) — a marker
    // added at 24 is invisible (not in margin 1's mask) and F2 ignores it.
    // The margin mask tells the truth, so trust what the bookmark margin
    // actually displays; fall back to the API answer on other hosts.
    // (Margin 1 also masks the hide-lines arrows, 18/19 — both below 20.)
    unsigned marginMask = (unsigned)sci(SCI_GETMARGINMASKN, 1);
    if (marginMask & (1u << 20))      _bookmarkID = 20;
    else if (marginMask & (1u << 24)) _bookmarkID = 24;
    else {
        intptr_t id_ = npp(NPPM_GETBOOKMARKID);
        _bookmarkID = (id_ > 0 && id_ < 32) ? (int)id_ : 20;
    }
    return _bookmarkID;
}

- (int)indicatorSlot {
    if (_indicator > 0) return _indicator;
    int start = 0;
    if (npp(NPPM_ALLOCATEINDICATOR, 1, (intptr_t)&start) && start > 0)
        _indicator = start;
    else
        _indicator = kFallbackIndicator;
    return _indicator;
}

- (NSInteger)sensitivity { return _sensitivity; }

- (void)setSensitivity:(NSInteger)sensitivity {
    _sensitivity = std::clamp(sensitivity, (NSInteger)-1, (NSInteger)1);
    [self paintHits:_lastHits];
}

- (NSUInteger)bandMask { return _bandMask; }

- (void)setBandMask:(NSUInteger)bandMask {
    _bandMask = bandMask & 0x3F;
    [self paintHits:_lastHits];
}

#pragma mark - Attach / detach

- (void)attachToCurrentBuffer {
    intptr_t buf = npp(NPPM_GETCURRENTBUFFERID);
    if (buf != 0 && buf == _bufferID) return;
    _buildGeneration++;
    _queryGeneration++;
    _pendingRebuildToken++;
    [self clearHeatmap];

    _bufferID = buf;
    _indexReady = NO;
    if (_bufferID == 0) return;

    [self configureIndicator];
    [self rebuildIndex];
}

- (void)detach {
    [self clearHeatmap];
    _bufferID = 0;
    _indexReady = NO;
    _buildGeneration++;
    _queryGeneration++;
    _pendingRebuildToken++;
}

- (void)configureIndicator {
    const int ind = [self indicatorSlot];
    sci(SCI_INDICSETSTYLE, ind, INDIC_FULLBOX);
    sci(SCI_INDICSETFLAGS, ind, SC_INDICFLAG_VALUEFORE);
    sci(SCI_INDICSETALPHA, ind, 100);
    sci(SCI_INDICSETOUTLINEALPHA, ind, 0);
    sci(SCI_INDICSETUNDER, ind, 1);
    _indicatorConfigured = YES;
}

#pragma mark - Edits → debounced rebuild

- (void)noteTextChanged {
    if (_bufferID == 0) return;
    _indexReady = NO;
    _buildGeneration++;
    [self clearHeatmap];
    uint64_t token = ++_pendingRebuildToken;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kRebuildDebounceNs),
                   dispatch_get_main_queue(), ^{
        __typeof(self) self_ = weakSelf;
        if (!self_ || token != self_->_pendingRebuildToken) return;
        [self_ rebuildIndex];
    });
}

#pragma mark - Index rebuild

- (void)rebuildIndex {
    if (_bufferID == 0) return;

    uint64_t gen = ++_buildGeneration;
    _indexReady = NO;
    [self clearHeatmap];
    long docLen = (long)sci(SCI_GETLENGTH);
    if (docLen > kMaxDocBytes) {
        [self reportStatus:@"Document too large for semantic search" busy:NO];
        return;
    }

    // Snapshot the bytes NOW (main thread) — the pointer dies on the next edit.
    const char *chars = (const char *)sci(SCI_GETCHARACTERPOINTER);
    NSData *docBytes = chars ? [NSData dataWithBytes:chars length:(NSUInteger)docLen]
                             : [NSData data];

    int64_t firstID = _nextSentenceID;
    [self reportStatus:@"Indexing…" busy:YES];

    __weak __typeof(self) weakSelf = self;
    dispatch_async(_workQueue, ^{
        __typeof(self) self_ = weakSelf;
        if (!self_ || gen != self_->_buildGeneration) return;

        NSString *text = [[NSString alloc] initWithData:docBytes
                                               encoding:NSUTF8StringEncoding];
        NSMutableArray<NSString *> *sentences = [NSMutableArray array];
        auto spans = std::make_shared<std::vector<SemSentenceSpan>>();

        if (text.length) {
            // NLTokenizer ranges are UTF-16; convert gaps + sentences to UTF-8
            // byte lengths so spans line up with Scintilla positions.
            NLTokenizer *tok = [[NLTokenizer alloc] initWithUnit:NLTokenUnitSentence];
            tok.string = text;
            __block NSUInteger lastU16 = 0;
            __block long lastByte = 0;
            [tok enumerateTokensInRange:NSMakeRange(0, text.length)
                             usingBlock:^(NSRange r, NLTokenizerAttributes attrs, BOOL *stop) {
                NSString *gap = [text substringWithRange:
                                    NSMakeRange(lastU16, r.location - lastU16)];
                NSString *sentence = [text substringWithRange:r];
                long byteStart = lastByte +
                    (long)[gap lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                long byteLen =
                    (long)[sentence lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                lastU16  = NSMaxRange(r);
                lastByte = byteStart + byteLen;

                NSString *trimmed = [sentence stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (trimmed.length == 0) return;

                [sentences addObject:sentence];
                spans->push_back(SemSentenceSpan{ byteStart, byteLen });
                if (sentences.count > kMaxSentences) *stop = YES;
            }];
        }

        if (!text || sentences.count > kMaxSentences) {
            [self_ reportBuildError:!text ? @"Document is not valid UTF-8"
                : @"Document has too many sentences for semantic search" generation:gen];
            return;
        }
        NSString *pipelineError = sentences.count ? [self_ ensurePipelineForSample:text] : nil;
        if (pipelineError) {
            [self_ reportBuildError:pipelineError generation:gen];
            return;
        }

        NSUInteger dim = self_->_provider.dimension;
        [self_->_index resetWithDimension:dim];
        std::vector<float> scratch(dim);
        int64_t sid = firstID;
        NSUInteger embedded = 0;
        for (NSString *s in sentences) {
            if (gen != self_->_buildGeneration) return;
            NSData *cached = [self_->_embedCache objectForKey:s];
            if (cached.length == dim * sizeof(float)) {
                memcpy(scratch.data(), cached.bytes, cached.length);
            } else if ([self_->_provider embedString:s into:scratch.data()]) {
                [self_->_embedCache setObject:[NSData dataWithBytes:scratch.data()
                                                             length:dim * sizeof(float)]
                                       forKey:s];
            } else {
                sid++;                 // keep ids aligned; leave unpaintable
                continue;
            }
            if (![self_->_index addVector:scratch.data() sentenceID:sid++]) {
                [self_ reportBuildError:@"Could not store sentence embeddings" generation:gen];
                return;
            }
            embedded++;
        }

        // Surface WHICH embedding backend ran: "contextual" is Apple's
        // transformer model (OS-downloaded asset), "sentence" the built-in
        // static model used until that asset arrives.
        NSString *backend = @"";
        if ([(NSObject *)self_->_provider respondsToSelector:@selector(backendName)]) {
            NSString *bn = ((AppleNLEmbeddingProvider *)self_->_provider).backendName;
            if (bn.length) backend = [bn stringByAppendingString:@" model · "];
        }
        NSString *status = sentences.count
            ? [NSString stringWithFormat:@"%lu of %lu sentences indexed · %@%@",
                (unsigned long)embedded, (unsigned long)sentences.count,
                backend, self_->_engine.engineName]
            : @"No sentences to search";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self_->_buildGeneration) return;
            self_->_spans = *spans;
            self_->_firstSentenceID = firstID;
            self_->_nextSentenceID  = firstID + (int64_t)spans->size();
            self_->_indexReady = YES;
            self_->_indexStatus = status;
            [self_ reportStatus:status busy:NO];
            if (self_->_query.length) [self_ runQuery];
        });
    });
}

// Create provider / engine / index on first use (work queue). Returns nil on
// success or a user-facing error. Fail-loud: no CPU fallback.
- (nullable NSString *)ensurePipelineForSample:(nullable NSString *)sampleText {
    NSString *lang = sampleText.length
        ? [NLLanguageRecognizer dominantLanguageForString:sampleText] : nil;
    lang = lang ?: NLLanguageEnglish;
    if (![_providerLanguage isEqualToString:lang]) {
        _provider = nil;
        [_embedCache removeAllObjects];
        _providerLanguage = [lang copy];
    }
    if (_provider && _provider.isAvailable && _engine) return nil;
    if (@available(macOS 14.0, *)) {
        if (!_engine) {
            _engine = [MetalSimilarityEngine engineIfAvailable];
            if (!_engine)
                return @"Metal GPU unavailable — semantic search disabled";
        }
        if (!_provider || !_provider.isAvailable) {
            _provider = [[AppleNLEmbeddingProvider alloc] initWithLanguageHint:lang];
            if (!_provider.isAvailable) {
                _provider = nil;
                return @"Embedding model unavailable on this Mac";
            }
        }
        if (!_index) _index = [[SpillableVectorIndex alloc] initWithSimilarityEngine:_engine];
        return nil;
    }
    return @"Requires macOS 14 or later";
}

#pragma mark - Query → heatmap

- (void)updateQuery:(NSString *)query {
    _query = [query copy] ?: @"";
    _queryGeneration++;
    [self clearHeatmap];
    if (_query.length == 0) {
        if (_indexReady) [self reportStatus:_indexStatus ?: @"" busy:NO];
        return;
    }
    if (!_indexReady) return;   // rebuild completion re-runs the query
    [self runQuery];
}

- (void)runQuery {
    NSString *query = _query;
    uint64_t qGen = ++_queryGeneration;
    uint64_t bGen = _buildGeneration;
    if (_bufferID == 0 || !query.length) return;

    __weak __typeof(self) weakSelf = self;
    dispatch_async(_workQueue, ^{
        __typeof(self) self_ = weakSelf;
        if (!self_ || qGen != self_->_queryGeneration ||
            bGen != self_->_buildGeneration || !self_->_provider) return;

        NSUInteger dim = self_->_provider.dimension;
        std::vector<float> qVec(dim);
        if (![self_->_provider embedString:query into:qVec.data()]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (qGen != self_->_queryGeneration || bGen != self_->_buildGeneration) return;
                [self_ reportStatus:@"Query could not be embedded" busy:NO];
            });
            return;
        }

        NSUInteger n = self_->_index.count;
        auto hits = std::make_shared<std::vector<SemanticHit>>(n);
        NSUInteger got = n ? [self_->_index scoreAllForQuery:qVec.data()
                                                        hits:hits->data()
                                                    capacity:n] : 0;
        hits->resize(got);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (qGen != self_->_queryGeneration ||
                bGen != self_->_buildGeneration) return;
            if (got != n) {
                [self_ clearHeatmap];
                [self_ reportStatus:@"Could not score sentence embeddings" busy:NO];
                return;
            }
            self_->_lastHits = *hits;
            [self_ paintHits:*hits];
            [self_ reportStatus:self_->_indexStatus ?: @"" busy:NO];
        });
    });
}

// Main thread. Maps scores → colors, fills the indicator per sentence.
- (void)paintHits:(const std::vector<SemanticHit> &)hits {
    if (_bufferID == 0) return;
    const int ind = [self indicatorSlot];
    long docLen = (long)sci(SCI_GETLENGTH);

    sci(SCI_SETINDICATORCURRENT, ind);
    sci(SCI_INDICATORCLEARRANGE, 0, docLen);

    // First lines of the sentences that survive the band filter — these get
    // the host bookmark marker while any band is selected.
    std::set<long> wantLines;

    for (const SemanticHit &h : hits) {
        // Legend band filter (multi-select): paint only selected bands so
        // specific colors can be picked out of an otherwise fully tinted file.
        if (_bandMask &&
            !(_bandMask & (1u << SemanticHeatmap::bandForScore(h.score)))) continue;
        size_t idx = (size_t)(h.sentenceID - _firstSentenceID);
        if (idx >= _spans.size()) continue;
        const SemSentenceSpan &span = _spans[idx];
        if (span.byteStart >= docLen) continue;
        long len = std::min((long)span.byteLength, (long)(docLen - span.byteStart));

        sci(SCI_SETINDICATORVALUE,
            (uptr_t)(SemanticHeatmap::colorBGR(h.score, (int)_sensitivity) | SC_INDICVALUEBIT));
        sci(SCI_INDICATORFILLRANGE, (uptr_t)span.byteStart, len);

        if (_bandMask)
            wantLines.insert((long)sci(SCI_LINEFROMPOSITION, (uptr_t)span.byteStart));
    }

    [self syncBookmarksTo:wantLines];
}

// Reconcile OUR bookmarks on the current buffer with `want`: remove lines we
// added that are no longer wanted, add newly wanted lines — but never touch a
// bookmark the user placed (add skips lines already marked; remove only
// touches lines recorded as ours).
- (void)syncBookmarksTo:(const std::set<long> &)want {
    if (_bufferID == 0) return;
    const int bm = [self bookmarkID];
    const unsigned mask = 1u << bm;
    std::set<long> &ours = _ourBookmarks[_bufferID];

    for (auto it = ours.begin(); it != ours.end();) {
        if (want.count(*it) == 0) {
            sci(SCI_MARKERDELETE, (uptr_t)*it, bm);
            it = ours.erase(it);
        } else {
            ++it;
        }
    }
    for (long line : want) {
        if (ours.count(line)) continue;
        if ((unsigned)sci(SCI_MARKERGET, (uptr_t)line) & mask) continue; // user's
        sci(SCI_MARKERADD, (uptr_t)line, bm);
        ours.insert(line);
    }
}

- (void)clearHeatmap {
    _lastHits.clear();
    if (_bufferID == 0) return;
    // Only touch the document if it is still the one we attached to — on a
    // buffer switch the current view already shows the NEW document, and
    // line-keyed marker deletes would land in the wrong file. Stale paint
    // and marks in a background buffer self-heal when it is re-attached.
    if (npp(NPPM_GETCURRENTBUFFERID) != _bufferID) return;
    if (!_indicatorConfigured) return;   // never touched anything yet
    const int ind = [self indicatorSlot];
    sci(SCI_SETINDICATORCURRENT, ind);
    sci(SCI_INDICATORCLEARRANGE, 0, sci(SCI_GETLENGTH));
    [self syncBookmarksTo:std::set<long>()];
}

/// A buffer died — forget its bookmark record so a later buffer-id reuse
/// can never inherit stale line numbers.
- (void)noteFileClosed:(intptr_t)bufferID {
    _ourBookmarks.erase(bufferID);
}

- (void)reportBuildError:(NSString *)status generation:(uint64_t)generation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_buildGeneration) return;
        [self reportStatus:status busy:NO];
    });
}

- (void)reportStatus:(NSString *)status busy:(BOOL)busy {
    SemanticStatusBlock block = self.statusBlock;
    if (!block) return;
    if (NSThread.isMainThread) {
        block(status, busy);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ block(status, busy); });
    }
}

@end
