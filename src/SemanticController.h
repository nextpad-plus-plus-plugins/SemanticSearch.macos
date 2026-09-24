// SemanticSearch.macos — semantic sentence heatmap for Nextpad++.
// Based on nextpad-plus-plus-macos PR #346 by Kristian Rickert (@krickert);
// adapted from an in-host feature to a standalone plugin.
//
// SemanticController drives the heatmap for the CURRENT document: splits it
// into sentences (NLTokenizer, UTF-8 byte spans), embeds them (Apple
// NaturalLanguage), scores every sentence against the query (Metal/MPS) and
// paints a host-allocated Scintilla indicator with per-range colors.
//
// Plugin-API adaptation notes vs the PR:
//  - All editor access goes through NppData._sendMessage (SCI_* / NPPM_*).
//  - "Attached editor" is a buffer ID (NPPM_GETCURRENTBUFFERID), re-targeted
//    on NPPN_BUFFERACTIVATED by the plugin entry.
//  - Text changes arrive as forwarded SCN_MODIFIED (insert/delete filtered by
//    the entry), debounced here exactly like the PR (600 ms).
//  - The indicator slot comes from NPPM_ALLOCATEINDICATOR (fallback 20).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SemanticStatusBlock)(NSString *status, BOOL busy);

@interface SemanticController : NSObject

/// YES on macOS 14+ (model/GPU availability is validated lazily).
+ (BOOL)isFeatureAvailable;

/// Status sink ("Indexing…", "N sentences · Metal/MPS", errors). Always
/// called on the main thread.
@property (nonatomic, copy, nullable) SemanticStatusBlock statusBlock;

/// Color sensitivity: -1 stricter, 0 standard, 1 broader. Repaints cached hits.
@property (nonatomic) NSInteger sensitivity;

/// Legend band filter, multi-select: bit i set = band i selected. 0 = show
/// all bands (default). While any band is selected, only those bands are
/// painted AND their sentences' first lines carry the host bookmark marker
/// (F2-navigable); deselecting removes the bookmarks this controller added
/// (never the user's own). Repaints cached hits.
@property (nonatomic) NSUInteger bandMask;

/// Attach to the host's CURRENT buffer and (re)build the sentence index.
/// No-op if already attached to that buffer.
- (void)attachToCurrentBuffer;

/// Clear the heatmap, drop state, forget the buffer.
- (void)detach;

/// Forwarded SCN_MODIFIED (insert/delete only): invalidate now, rebuild after
/// a debounce.
- (void)noteTextChanged;

/// Live query update. Empty clears the heatmap but keeps the index warm.
- (void)updateQuery:(NSString *)query;

/// Remove all heatmap coloring (and our bookmarks) from the current view.
- (void)clearHeatmap;

/// NPPN_FILECLOSED: forget bookkeeping for a dead buffer id.
- (void)noteFileClosed:(intptr_t)bufferID;

@end

NS_ASSUME_NONNULL_END
