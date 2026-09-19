#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <shellapi.h>
#include <dwmapi.h>

#define ZNAP_SNAPSHOT_COUNT 10
#define ZNAP_SNAPSHOT_APPLICATION_CAPACITY 64

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
BOOL ZnapGetWindowApplicationInfo(HWND hwnd, WCHAR *executable, UINT executable_capacity, WCHAR *app_user_model_id, UINT app_user_model_id_capacity);
BOOL ZnapWindowMatchesApplication(HWND hwnd, const WCHAR *executable, const WCHAR *app_user_model_id);
HWND ZnapFindApplicationWindow(const WCHAR *executable, const WCHAR *app_user_model_id, const HWND *excluded, UINT excluded_count);
BOOL ZnapStartApplication(const WCHAR *executable, const WCHAR *arguments, const WCHAR *working_directory, const WCHAR *app_user_model_id, BOOL separate_terminal_window);
void ZnapShowSnapshotUpdateRejected(HWND owner, UINT icon_id, UINT snapshot_index, UINT expected_windows, UINT captured_windows);
void ZnapShowSnapshotRecallFailed(HWND owner, UINT icon_id, UINT snapshot_index, UINT application_index, UINT failed_applications);

typedef struct ZnapKeymapRow {
    UINT index;
    UINT action;
    UINT snapshot_index;
    UINT modifiers;
    UINT key;
} ZnapKeymapRow;

void ZnapShowSettingsDialog(HINSTANCE instance, HWND owner, const ZnapKeymapRow *rows, UINT row_count, UINT general_count, BOOL show_snap_warning, BOOL startup_enabled, BOOL admin_startup_enabled, UINT edge_cycles, UINT corner_cycles, UINT center_cycles, UINT default_edge_cycle_width, UINT default_corner_cycle_width, UINT default_center_cycle_width, BOOL smart_fill, const UINT *snapshot_application_counts, UINT stored_snapshot_mask, UINT auto_start_snapshot_mask);
void ZnapRefreshSnapshotSettings(const UINT *snapshot_application_counts, UINT stored_snapshot_mask, UINT auto_start_snapshot_mask);
BOOL ZnapSettingsRecording(void);
void ZnapRecordKeymap(UINT modifiers, UINT key);

/* Implemented in Zig and called by the native settings window. */
BOOL ZnapUpdateKeymap(UINT index, UINT modifiers, UINT key);
BOOL ZnapSetStartupOption(UINT option, BOOL enabled);
BOOL ZnapUpdateCycleWidth(UINT group, UINT width, BOOL enabled);
BOOL ZnapUpdateDefaultCycleWidth(UINT group, UINT width);
BOOL ZnapUpdateSmartFill(BOOL enabled);
BOOL ZnapGetSnapshotApplicationText(UINT snapshot_index, UINT application_index, UINT field, WCHAR *buffer, UINT capacity);
UINT_PTR ZnapGetSnapshotApplicationHwnd(UINT snapshot_index, UINT application_index);
ULONGLONG ZnapGetSnapshotApplicationWindowId(UINT snapshot_index, UINT application_index);
BOOL ZnapUpdateSnapshotAutoStart(UINT snapshot_index, BOOL enabled);
BOOL ZnapUpdateSnapshotApplication(UINT snapshot_index, UINT application_index, UINT field, const WCHAR *value);
