// SemanticSearch.macos — see SemanticPanel.h.
#import "SemanticPanel.h"
#include "NppPluginInterfaceMac.h"
#include "SemanticHeatmapColors.h"
#include <algorithm>

extern NppData gNppData;

static const NSTimeInterval kQueryDebounceSec = 0.30;

// Sensitivity persists in the plugin Config dir (good-citizen storage; the
// PR used the app's NSUserDefaults domain).
static NSString *configPlistPath(void) {
    char buf[1024] = {0};
    gNppData._sendMessage(gNppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR, 0, (intptr_t)buf);
    NSString *dir = [NSString stringWithUTF8String:buf];
    return dir.length ? [dir stringByAppendingPathComponent:@"SemanticSearch.plist"] : nil;
}

// ── Legend swatch: a clickable color square with a selection ring ───────────
@interface SemSwatchButton : NSButton
@property (nonatomic) BOOL selectedBand;
@end
@implementation SemSwatchButton
- (void)setSelectedBand:(BOOL)sel {
    _selectedBand = sel;
    self.layer.borderWidth = sel ? 2.0 : 0.0;
}
- (void)updateLayer {
    [super updateLayer];
    // Resolve the ring color for the current appearance (dark mode safe).
    self.layer.borderColor = NSColor.labelColor.CGColor;
}
@end

@implementation SemanticPanel {
    NSTextField *_titleLabel;
    NSTextField *_queryField;
    NSTextField *_statusLabel;
    NSProgressIndicator *_spinner;
    NSPopUpButton *_sensitivityPopup;
    NSStackView *_legendStack;
    NSMutableArray<SemSwatchButton *> *_swatches;
    NSUInteger _bandMask;               // bit i = band i selected; 0 = all
    NSTimer *_debounceTimer;
}

+ (NSInteger)savedSensitivity {
    NSString *path = configPlistPath();
    if (!path) return 0;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    NSInteger v = [d[@"sensitivity"] integerValue];
    return std::clamp(v, (NSInteger)-1, (NSInteger)1);
}

+ (void)saveSensitivity:(NSInteger)v {
    NSString *path = configPlistPath();
    if (!path) return;
    [@{ @"sensitivity": @(v) } writeToFile:path atomically:YES];
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _titleLabel = [NSTextField labelWithString:@"Semantic:"];
    _titleLabel.font = [NSFont systemFontOfSize:12];
    _titleLabel.textColor = [NSColor secondaryLabelColor];

    _queryField = [NSTextField textFieldWithString:@""];
    _queryField.placeholderString = @"Describe what you're looking for…";
    _queryField.delegate = self;
    [[_queryField cell] setScrollable:YES];
    [_queryField setAccessibilityLabel:@"Semantic search query"];

    _sensitivityPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _sensitivityPopup.controlSize = NSControlSizeSmall;
    _sensitivityPopup.target = self;
    _sensitivityPopup.action = @selector(sensitivityChanged:);
    [_sensitivityPopup addItemsWithTitles:@[@"Strict", @"Standard", @"Broad"]];
    [_sensitivityPopup selectItemAtIndex:[SemanticPanel savedSensitivity] + 1];
    _sensitivityPopup.toolTip =
        @"Heatmap sensitivity: Broad colors weaker matches green; Strict "
        @"requires stronger matches. Scores are unchanged.";

    // Legend: six clickable swatches (least → most similar), multi-select.
    // Selected bands are the only ones painted, and their lines get
    // bookmarks (F2-navigable). No selection = show all, no bookmarks.
    // 16pt squares — 50% larger than the original 11pt glyph legend.
    _bandMask = 0;
    _swatches = [NSMutableArray array];
    _legendStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    _legendStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _legendStack.spacing = 4;
    for (int i = 0; i < 6; i++) {
        uint32_t bgr = SemanticHeatmap::colorBGR(SemanticHeatmap::kLegendScores[i]);
        NSColor *c = [NSColor colorWithRed:(bgr & 255) / 255.0
                                     green:((bgr >> 8) & 255) / 255.0
                                      blue:((bgr >> 16) & 255) / 255.0 alpha:1];
        SemSwatchButton *b = [[SemSwatchButton alloc] initWithFrame:NSZeroRect];
        b.title = @"";
        b.bordered = NO;
        b.wantsLayer = YES;
        b.layer.backgroundColor = c.CGColor;
        b.layer.cornerRadius = 3.5;
        b.tag = i;
        b.target = self;
        b.action = @selector(swatchClicked:);
        b.toolTip = @"Show only the selected similarity bands and bookmark "
                    @"their lines (click again to deselect; multiple bands "
                    @"can be selected)";
        [b setAccessibilityLabel:
            [NSString stringWithFormat:@"Similarity band %d of 6", i + 1]];
        [b.widthAnchor constraintEqualToConstant:16].active = YES;
        [b.heightAnchor constraintEqualToConstant:16].active = YES;
        [_swatches addObject:b];
        [_legendStack addArrangedSubview:b];
    }

    _spinner = [[NSProgressIndicator alloc] init];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;

    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.font = [NSFont systemFontOfSize:11];
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_statusLabel setContentCompressionResistancePriority:250
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    // The bottom row must fill the panel width; the STATUS label absorbs the
    // slack (invisible — its text is left-aligned and truncates), so the
    // sensitivity popup stays exactly as wide as its longest item.
    [_statusLabel setContentHuggingPriority:100
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_sensitivityPopup setContentHuggingPriority:NSLayoutPriorityDefaultHigh
        forOrientation:NSLayoutConstraintOrientationHorizontal];

    for (NSView *v in @[_titleLabel, _queryField, _sensitivityPopup,
                        _legendStack, _spinner, _statusLabel]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:v];
    }

    NSDictionary *views = @{ @"lbl": _titleLabel, @"field": _queryField,
                             @"sens": _sensitivityPopup, @"legend": _legendStack,
                             @"spin": _spinner, @"status": _statusLabel };
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint
        constraintsWithVisualFormat:@"H:|-(10)-[lbl]-(6)-[field(>=140)]-(10)-|"
                           options:NSLayoutFormatAlignAllCenterY metrics:nil views:views]];
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint
        constraintsWithVisualFormat:@"H:|-(10)-[sens]-(8)-[legend]-(8)-[spin(16)]-(6)-[status(>=0)]-(10)-|"
                           options:NSLayoutFormatAlignAllCenterY metrics:nil views:views]];
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
        [_sensitivityPopup.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:14],
    ]];
    return self;
}

- (void)dealloc {
    [_debounceTimer invalidate];
}

- (void)swatchClicked:(SemSwatchButton *)sender {
    _bandMask ^= (1u << sender.tag);    // independent toggle per swatch
    for (SemSwatchButton *b in _swatches)
        b.selectedBand = (_bandMask & (1u << b.tag)) != 0;
    [self.delegate semanticPanelBandMaskDidChange:_bandMask];
}

- (NSInteger)sensitivity { return _sensitivityPopup.indexOfSelectedItem - 1; }
- (NSString *)query      { return _queryField.stringValue; }

- (void)sensitivityChanged:(id)sender {
    [SemanticPanel saveSensitivity:self.sensitivity];
    [self.delegate semanticPanelSensitivityDidChange:self.sensitivity];
}

- (void)activate {
    [self.window makeFirstResponder:_queryField];
}

- (void)setStatus:(NSString *)text busy:(BOOL)busy {
    _statusLabel.stringValue = text ?: @"";
    _statusLabel.toolTip = _statusLabel.stringValue;
    if (busy) [_spinner startAnimation:nil];
    else      [_spinner stopAnimation:nil];
}

// Informal host contract: called by the host when the panel is hidden
// (PanelFrame ✕, tab toggle-off, programmatic hide) — flush/clear here.
- (void)panelWillClose {
    [_debounceTimer invalidate];
    _debounceTimer = nil;
    [self.delegate semanticPanelDidClose];
}

#pragma mark - Debounced live query

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object != _queryField) return;
    [_debounceTimer invalidate];
    NSString *query = _queryField.stringValue;
    if (query.length == 0) {
        [self.delegate semanticPanelQueryDidChange:@""];   // clearing = instant
        return;
    }
    __weak __typeof(self) weakSelf = self;
    _debounceTimer = [NSTimer scheduledTimerWithTimeInterval:kQueryDebounceSec
                                                     repeats:NO
                                                       block:^(NSTimer *t) {
        __typeof(self) self_ = weakSelf;
        if (!self_) return;
        [self_.delegate semanticPanelQueryDidChange:self_->_queryField.stringValue];
    }];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)tv doCommandBySelector:(SEL)cmd {
    if (control == _queryField && cmd == @selector(insertNewline:)) {
        [_debounceTimer invalidate];
        [self.delegate semanticPanelQueryDidChange:_queryField.stringValue];
        return YES;
    }
    return NO;
}

@end
