#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <shellapi.h>
#include <dwmapi.h>

DPI_AWARENESS_CONTEXT ZnapPerMonitorV2(void);
void ZnapSwitchToThisWindow(HWND hwnd);
HWND ZnapHwndTopmost(void);
HWND ZnapHwndNotopmost(void);
HKEY ZnapHkeyCurrentUser(void);
BOOL ZnapMarkWindowsKeyUsed(void);
void ZnapShowSnapWarning(HINSTANCE instance);
BOOL ZnapStartupTaskEnabled(void);
BOOL ZnapSetStartupTask(BOOL enabled);
BOOL ZnapSetStartupTaskElevated(BOOL enabled);

typedef struct ZnapKeymapRow {
    UINT index;
    UINT action;
    UINT snapshot_index;
    UINT modifiers;
    UINT key;
} ZnapKeymapRow;

void ZnapShowSettingsDialog(HINSTANCE instance, HWND owner, const ZnapKeymapRow *rows, UINT row_count, UINT general_count, BOOL show_snap_warning, BOOL startup_enabled, BOOL admin_startup_enabled, UINT edge_cycles, UINT corner_cycles, UINT center_cycles, UINT default_edge_cycle_width, UINT default_corner_cycle_width, UINT default_center_cycle_width);
BOOL ZnapSettingsRecording(void);
void ZnapRecordKeymap(UINT modifiers, UINT key);

/* Implemented in Zig and called by the native settings window. */
BOOL ZnapUpdateKeymap(UINT index, UINT modifiers, UINT key);
BOOL ZnapSetStartupOption(UINT option, BOOL enabled);
BOOL ZnapUpdateCycleWidth(UINT group, UINT width, BOOL enabled);
BOOL ZnapUpdateDefaultCycleWidth(UINT group, UINT width);
