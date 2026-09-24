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

@implementation SemanticPanel {
    NSTextField *_titleLabel;
    NSTextField *_queryField;
    NSTextField *_legendLabel;
    NSTextField *_statusLabel;
    NSProgressIndicator *_spinner;
    NSPopUpButton *_sensitivityPopup;
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

    _legendLabel = [NSTextField labelWithAttributedString:[self legendString]];
    _legendLabel.font = [NSFont systemFontOfSize:11];
    _legendLabel.toolTip = @"Red: less similar. Grey: intermediate. "
                           @"Green: more similar.";

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
                        _legendLabel, _spinner, _statusLabel]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:v];
    }

    NSDictionary *views = @{ @"lbl": _titleLabel, @"field": _queryField,
                             @"sens": _sensitivityPopup, @"legend": _legendLabel,
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

- (NSAttributedString *)legendString {
    static const double scores[] = {0.35, 0.60, 0.75, 0.84, 0.90, 0.93};
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
    for (int i = 0; i < 6; i++) {
        uint32_t bgr = SemanticHeatmap::colorBGR(scores[i]);
        NSColor *c = [NSColor colorWithRed:(bgr & 255) / 255.0
                                     green:((bgr >> 8) & 255) / 255.0
                                      blue:((bgr >> 16) & 255) / 255.0 alpha:1];
        [s appendAttributedString:
            [[NSAttributedString alloc] initWithString:@"■"
                attributes:@{ NSForegroundColorAttributeName: c,
                              NSFontAttributeName: [NSFont systemFontOfSize:11] }]];
    }
    return s;
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
