// SemanticSearch.macos — docked panel UI (query field, sensitivity, legend,
// status). Adapted from PR #346's SemanticSearchBar (Kristian Rickert): the
// host's PanelFrame supplies the title bar, close button and dock buttons, so
// this view is content-only.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SemanticPanelDelegate <NSObject>
/// Debounced as the user types; empty string means "clear heatmap".
- (void)semanticPanelQueryDidChange:(NSString *)query;
- (void)semanticPanelSensitivityDidChange:(NSInteger)sensitivity;
/// The host hid the panel (PanelFrame ✕ or programmatic hide).
- (void)semanticPanelDidClose;
@end

@interface SemanticPanel : NSView <NSTextFieldDelegate>

@property (nonatomic, weak, nullable) id<SemanticPanelDelegate> delegate;
@property (nonatomic, readonly) NSInteger sensitivity;   // -1 / 0 / 1
@property (nonatomic, readonly, copy) NSString *query;

/// Make the query field first responder.
- (void)activate;

/// Show pipeline status ("Indexing…", "N sentences · Metal/MPS", errors).
- (void)setStatus:(NSString *)text busy:(BOOL)busy;

/// Persisted sensitivity (plugin Config dir), loaded at creation.
+ (NSInteger)savedSensitivity;

@end

NS_ASSUME_NONNULL_END
