// SemanticSearch.macos: semantic sentence heatmap search for Nextpad++.
//
// Based on nextpad-plus-plus-macos PR #346 by Kristian Rickert (@krickert):
// describe what you're looking for and every sentence in the document is
// tinted red, grey, then green by semantic similarity. Apple NaturalLanguage
// embeddings + Metal/MPS scoring, entirely on-device. Requires macOS 14+
// at runtime (the plugin loads from macOS 12 and gates itself).
//
// PluginEntry.mm: plugin contract, menu, docked-panel registration (the
// Windows-named docking API with the legacy surface as fallback),
// notification routing.
#import <Cocoa/Cocoa.h>
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import "SemanticPanel.h"
#import "SemanticController.h"
#include <cstring>

// The 1.1.1 host reads this Windows docking record from NPPM_DMMREGASDCKDLG.
// The public plugin header names that message but does not define the record,
// so the layout is declared here. Field order matches the host method
// regAsDockingDlgWithData: (client, name, dialog id, mask, icon, extra text,
// floating rect, previous container, module name).
#ifndef NPPM_DMM_SETPANELINFO
#define NPPM_DMM_SETPANELINFO (NPPMSG + 505)
#endif

struct tTbData {
    void *hClient;
    const char *pszName;
    int dlgID;
    unsigned int uMask;
    void *hIconTab;
    const char *pszAddInfo;
    struct { int left, top, right, bottom; } rcFloat;
    int iPrevCont;
    const char *pszModuleName;
};

// Pointer at offset 0, command index at offset 8. The 1.1.1 host reads
// exactly those two fields from NPPM_DMM_SETPANELINFO.
struct NppPanelInfo {
    const char *pszModuleName;
    int dlgID;
};

static void cmdToggle(void);

#define PLUGIN_NAME    "Semantic Search"
#define PLUGIN_VERSION "1.0.0"
static const int NB_FUNC = 2;

NppData gNppData;                       // shared with controller/panel
static FuncItem funcItem[NB_FUNC];

static uint64_t            gPanelHandle = 0;
static SemanticPanel      *gPanel       = nil;
static SemanticController *gController  = nil;
static bool                gPanelShown  = false;
static id                  gKeyMonitor  = nil;

// Cmd+Option+F. The host menu uses Cmd+F (Find), Cmd+Shift+F (Find in
// Files) and Cmd+Ctrl+F (full screen). Cmd+Option+F is not one of those.
// ShortcutKey._key is the Windows virtual-key code; VK_F is 0x46.
// kVK_ANSI_F, the matching Mac key code, is 3.
static ShortcutKey gOpenShortcut = { false, true, false, true, 0x46 };
static const unsigned short kMacKeyF = 3;

static NSMenuItem *findHeatmapItem(NSMenu *menu) {
    if (!menu) return nil;
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.title isEqualToString:@"Semantic Heatmap Search"]) return item;
        if (item.submenu) {
            NSMenuItem *found = findHeatmapItem(item.submenu);
            if (found) return found;
        }
    }
    return nil;
}

// Nextpad++ 1.1.1 creates plugin menu items with an empty key equivalent
// and does not read FuncItem._pShKey. Put the chord on the menu item when
// we can find it, and also watch the key so the panel still opens if that
// item is rebuilt without a shortcut. The monitor consumes the event, so
// the menu action does not run a second time.
static void bindSearchShortcut(void) {
    NSMenuItem *item = findHeatmapItem(NSApp.mainMenu);
    if (item && item.keyEquivalent.length == 0) {
        item.keyEquivalent = @"f";
        item.keyEquivalentModifierMask =
            NSEventModifierFlagCommand | NSEventModifierFlagOption;
    }
    if (gKeyMonitor) return;
    gKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                        handler:^NSEvent *(NSEvent *event) {
        if (event.isARepeat) return event;
        NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        NSEventModifierFlags relevant = mods & (NSEventModifierFlagCommand |
                                                NSEventModifierFlagOption |
                                                NSEventModifierFlagControl |
                                                NSEventModifierFlagShift);
        if (event.keyCode == kMacKeyF &&
            relevant == (NSEventModifierFlagCommand | NSEventModifierFlagOption)) {
            cmdToggle();
            return nil;
        }
        return event;
    }];
}

static intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return gNppData._sendMessage(gNppData._nppHandle, msg, w, l);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Panel plumbing
// ═══════════════════════════════════════════════════════════════════════════

@interface SemanticGlue : NSObject <SemanticPanelDelegate>
@end
@implementation SemanticGlue
- (void)semanticPanelQueryDidChange:(NSString *)query {
    if (!gController) return;
    [gController attachToCurrentBuffer];   // retarget to the active tab
    [gController updateQuery:query];
}
- (void)semanticPanelSensitivityDidChange:(NSInteger)sensitivity {
    gController.sensitivity = sensitivity;
}
- (void)semanticPanelModelDidChange:(NSString *)modelID {
    gController.modelID = modelID;
}
- (void)semanticPanelBandMaskDidChange:(NSUInteger)mask {
    gController.bandMask = mask;
}
- (void)semanticPanelDidClose {
    gPanelShown = false;
    [gController detach];
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[0]._cmdID, 0);
}
@end
static SemanticGlue *gGlue = nil;

static void ensurePanel(void) {
    if (gPanel) return;
    gGlue  = [SemanticGlue new];
    gPanel = [[SemanticPanel alloc] initWithFrame:NSMakeRect(0, 0, 560, 84)];
    gPanel.delegate = gGlue;

    gController = [SemanticController new];
    gController.sensitivity = gPanel.sensitivity;
    gController.modelID = gPanel.modelID;
    __weak SemanticPanel *weakPanel = gPanel;
    gController.statusBlock = ^(NSString *status, BOOL busy) {
        [weakPanel setStatus:status busy:busy];
    };
}

static void registerPanel(void) {
    if (gPanelHandle != 0) return;
    ensurePanel();

    // Preferred: the Windows-named registration (host 1.1.1+). It carries the
    // default-bottom dock hint and the session-restore metadata in one call.
    tTbData d;
    memset(&d, 0, sizeof(d));
    d.hClient       = (__bridge void *)gPanel;
    d.pszName       = "Semantic Search";
    d.dlgID         = 0;                     // FuncItem 0 reopens the panel
    d.uMask         = DWS_DF_CONT_BOTTOM;
    d.pszModuleName = "SemanticSearch";
    intptr_t h = npp(NPPM_DMMREGASDCKDLG, 0, (intptr_t)&d);

    if (h == 0) {
        // Older host: legacy registration (docks right). Restore metadata is
        // sent only when the host implements SETPANELINFO.
        h = npp(NPPM_DMM_REGISTERPANEL,
                (uintptr_t)(__bridge void *)gPanel, (intptr_t)"Semantic Search");
        if (h > 0) {
            NppPanelInfo info = { "SemanticSearch", 0 };
            npp(NPPM_DMM_SETPANELINFO, (uintptr_t)h, (intptr_t)&info);
        }
    }
    if (h > 0) gPanelHandle = (uint64_t)h;
}

static void showPanel(void) {
    if (![SemanticController isFeatureAvailable]) {
        NSAlert *a = [NSAlert new];
        a.messageText = @PLUGIN_NAME;
        a.informativeText = @"Semantic search requires macOS 14 or later.";
        [a runModal];
        return;
    }
    registerPanel();
    bindSearchShortcut();
    if (gPanelHandle == 0) return;

    npp(NPPM_DMM_SHOWPANEL, (uintptr_t)gPanelHandle, 0);
    gPanelShown = true;
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[0]._cmdID, 1);
    // Index eagerly so results are warm while the user types the query.
    [gController attachToCurrentBuffer];
    [gController updateQuery:gPanel.query];
    [gPanel activate];
}

static void cmdToggle(void) {
    if (gPanelShown && gPanelHandle != 0) {
        npp(NPPM_DMM_HIDEPANEL, (uintptr_t)gPanelHandle, 0);
        // Host hide path invokes -panelWillClose → glue handles the rest.
        return;
    }
    showPanel();
}

static void cmdAbout(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *a = [NSAlert new];
        a.messageText = @"Semantic Search v" @PLUGIN_VERSION;
        a.informativeText =
            @"Semantic sentence heatmap search. Describe what you're looking "
            @"for and sentences are tinted red, grey, then green by similarity.\n\n"
            @"Open this panel from the Plugins menu or with Cmd+Option+F.\n\n"
            @"Apple NaturalLanguage embeddings + Metal/MPS scoring, entirely "
            @"on-device. Requires macOS 14+.\n\n"
            @"Based on Nextpad++ PR #346 by Kristian Rickert.\n"
            @"License: GPL-3.0";
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    });
}

// ═══════════════════════════════════════════════════════════════════════════
//  Plugin contract
// ═══════════════════════════════════════════════════════════════════════════

extern "C" NPP_EXPORT void setInfo(NppData data) {
    gNppData = data;
    int idx = 0;
    auto addItem = [&](const char *name, PFUNCPLUGINCMD func) {
        strlcpy(funcItem[idx]._itemName, name, NPP_MENU_ITEM_SIZE);
        funcItem[idx]._pFunc = func;
        funcItem[idx]._init2Check = false;
        funcItem[idx]._pShKey = nullptr;
        idx++;
    };
    addItem("Semantic Heatmap Search", cmdToggle);   // 0 (== tTbData dlgID)
    addItem("About",                   cmdAbout);    // 1
    funcItem[0]._pShKey = &gOpenShortcut;
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    switch (n->nmhdr.code) {
        case NPPN_READY:
            bindSearchShortcut();
            break;

        case NPPN_BUFFERACTIVATED:
            if (gPanelShown && gController) {
                [gController attachToCurrentBuffer];
                [gController updateQuery:gPanel.query];
            }
            break;

        case NPPN_FILECLOSED:
            // The attached buffer may be gone; retarget on next activation.
            if (gController) [gController noteFileClosed:(intptr_t)n->nmhdr.idFrom];
            if (gPanelShown && gController) [gController detach];
            break;

        case SCN_MODIFIED:
            if (gPanelShown && gController &&
                (n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)))
                [gController noteTextChanged];
            break;

        case NPPN_SHUTDOWN:
            if (gKeyMonitor) {
                [NSEvent removeMonitor:gKeyMonitor];
                gKeyMonitor = nil;
            }
            [gController detach];
            if (gPanelHandle > 0) {
                npp(NPPM_DMM_UNREGISTERPANEL, (uintptr_t)gPanelHandle, 0);
                gPanelHandle = 0;
            }
            gPanel = nil;
            gController = nil;
            break;

        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) {
    return 1;
}
