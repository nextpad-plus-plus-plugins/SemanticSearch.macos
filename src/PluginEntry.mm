// SemanticSearch.macos — semantic sentence heatmap search for Nextpad++.
//
// Based on nextpad-plus-plus-macos PR #346 by Kristian Rickert (@krickert):
// describe what you're looking for and every sentence in the document is
// tinted red → grey → green by semantic similarity. Apple NaturalLanguage
// embeddings + Metal/MPS scoring, entirely on-device. Requires macOS 14+
// at runtime (the plugin loads from macOS 12 and gates itself).
//
// PluginEntry.mm — plugin contract: menu, docked-panel registration (the
// Windows-named docking API with the legacy surface as fallback),
// notification routing.
#import <Cocoa/Cocoa.h>
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import "SemanticPanel.h"
#import "SemanticController.h"
#include <cstring>

#define PLUGIN_NAME    "Semantic Search"
#define PLUGIN_VERSION "0.1.0"
static const int NB_FUNC = 2;

NppData gNppData;                       // shared with controller/panel
static FuncItem funcItem[NB_FUNC];

static uint64_t            gPanelHandle = 0;
static SemanticPanel      *gPanel       = nil;
static SemanticController *gController  = nil;
static bool                gPanelShown  = false;

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
    __weak SemanticPanel *weakPanel = gPanel;
    gController.statusBlock = ^(NSString *status, BOOL busy) {
        [weakPanel setStatus:status busy:busy];
    };
}

static void registerPanel(void) {
    if (gPanelHandle != 0) return;
    ensurePanel();

    // Preferred: the Windows-named registration (host 1.1.1+) — carries the
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
        // Older host: legacy registration (docks right, no restore metadata
        // unless SETPANELINFO exists — try it, ignore failure).
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
            @"Semantic sentence heatmap search — describe what you're looking "
            @"for and sentences are tinted red → grey → green by similarity.\n\n"
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
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    switch (n->nmhdr.code) {
        case NPPN_BUFFERACTIVATED:
            if (gPanelShown && gController) {
                [gController attachToCurrentBuffer];
                [gController updateQuery:gPanel.query];
            }
            break;

        case NPPN_FILECLOSED:
            // The attached buffer may be gone; retarget on next activation.
            if (gPanelShown && gController) [gController detach];
            break;

        case SCN_MODIFIED:
            if (gPanelShown && gController &&
                (n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)))
                [gController noteTextChanged];
            break;

        case NPPN_SHUTDOWN:
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
