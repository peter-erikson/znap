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

typedef struct ZnapKeymapRow {
    UINT index;
    UINT action;
    UINT snapshot_index;
    UINT modifiers;
    UINT key;
} ZnapKeymapRow;

void ZnapShowSettingsDialog(HINSTANCE instance, HWND owner, const ZnapKeymapRow *rows, UINT row_count, UINT general_count, BOOL show_snap_warning);
BOOL ZnapSettingsRecording(void);
void ZnapRecordKeymap(UINT modifiers, UINT key);

/* Implemented in Zig and called by the native settings window. */
BOOL ZnapUpdateKeymap(UINT index, UINT modifiers, UINT key);
