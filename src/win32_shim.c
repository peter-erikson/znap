#ifndef UNICODE
#define UNICODE
#endif
#include "win32.h"

DPI_AWARENESS_CONTEXT ZnapPerMonitorV2(void) {
    return DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2;
}

void ZnapSwitchToThisWindow(HWND hwnd) {
    SwitchToThisWindow(hwnd, TRUE);
}

HWND ZnapHwndTopmost(void) {
    return HWND_TOPMOST;
}

HWND ZnapHwndNotopmost(void) {
    return HWND_NOTOPMOST;
}

HKEY ZnapHkeyCurrentUser(void) {
    return HKEY_CURRENT_USER;
}

BOOL ZnapMarkWindowsKeyUsed(void) {
    INPUT inputs[2] = {0};
    inputs[0].type = INPUT_KEYBOARD;
    inputs[0].ki.wVk = VK_CONTROL;
    inputs[1] = inputs[0];
    inputs[1].ki.dwFlags = KEYEVENTF_KEYUP;
    return SendInput(2, inputs, sizeof(INPUT)) == 2;
}

static void ZnapCenterDialog(HWND dialog) {
    RECT dialog_rect;
    MONITORINFO monitor_info = {0};
    monitor_info.cbSize = sizeof(monitor_info);

    HMONITOR monitor = MonitorFromWindow(dialog, MONITOR_DEFAULTTOPRIMARY);
    if (!GetWindowRect(dialog, &dialog_rect) || !GetMonitorInfoW(monitor, &monitor_info)) return;

    const int width = dialog_rect.right - dialog_rect.left;
    const int height = dialog_rect.bottom - dialog_rect.top;
    const int x = monitor_info.rcWork.left + (monitor_info.rcWork.right - monitor_info.rcWork.left - width) / 2;
    const int y = monitor_info.rcWork.top + (monitor_info.rcWork.bottom - monitor_info.rcWork.top - height) / 2;
    SetWindowPos(dialog, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

static INT_PTR CALLBACK ZnapSnapWarningProc(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam) {
    (void)lparam;
    if (message == WM_INITDIALOG) {
        HICON icon = LoadIconW(GetModuleHandleW(NULL), MAKEINTRESOURCEW(1));
        if (icon != NULL) {
            SendMessageW(dialog, WM_SETICON, ICON_SMALL, (LPARAM)icon);
            SendMessageW(dialog, WM_SETICON, ICON_BIG, (LPARAM)icon);
        }
        ZnapCenterDialog(dialog);
        return TRUE;
    }
    if (message != WM_COMMAND) return FALSE;

    switch (LOWORD(wparam)) {
        case 2001:
            ShellExecuteW(NULL, L"open", L"ms-settings:multitasking", NULL, NULL, SW_SHOWNORMAL);
            EndDialog(dialog, 2001);
            return TRUE;
        case IDCANCEL:
            EndDialog(dialog, IDCANCEL);
            return TRUE;
        default:
            return FALSE;
    }
}

void ZnapShowSnapWarning(HINSTANCE instance) {
    DialogBoxParamW(instance, MAKEINTRESOURCEW(101), NULL, ZnapSnapWarningProc, 0);
}

#define ZNAP_SETTINGS_CLASS L"Znap.SettingsWindow"
#define ZNAP_OPEN_WINDOWS_SETTINGS 3001
#define ZNAP_CLOSE_SETTINGS 3002
#define ZNAP_KEYMAP_CONTROL_BASE 4000
#define ZNAP_MAX_KEYMAPS 256
#define ZNAP_CAPTURE_KEYMAP (WM_APP + 20)
#define ZNAP_TOOLTIP_TIMER 1
#define ZNAP_SETTINGS_WIDTH 1010
#define ZNAP_SETTINGS_HEIGHT 720

typedef struct ZnapSettingsRowState {
    HWND edit;
    HWND warning;
    UINT index;
    UINT modifiers;
    UINT key;
} ZnapSettingsRowState;

static HWND znap_settings_window = NULL;
static ZnapSettingsRowState znap_settings_rows[ZNAP_MAX_KEYMAPS];
static UINT znap_settings_row_count = 0;
static LONG znap_recording_row = -1;
static HFONT znap_settings_font = NULL;
static HFONT znap_warning_font = NULL;
static HWND znap_settings_tooltip = NULL;
static LONG znap_active_tooltip_row = -1;
static LONG znap_hover_tooltip_row = -1;
static DWORD znap_tooltip_hover_started = 0;
static WCHAR znap_collision_tooltip[] = L"The keyboard shortcut is overriding a global system shortcut, this can have unforeseen consequences.";

static void ZnapDeactivateCollisionTooltip(UINT row) {
    if (znap_settings_tooltip == NULL) return;
    if (InterlockedCompareExchange(&znap_active_tooltip_row, -1, (LONG)row) == (LONG)row) {
        ShowWindow(znap_settings_tooltip, SW_HIDE);
    }
}

static void ZnapShowCollisionTooltip(UINT row, POINT cursor) {
    if (znap_settings_tooltip == NULL || row >= znap_settings_row_count) return;
    const int width = 500;
    const int height = 48;
    int x = cursor.x + 12;
    int y = cursor.y + 20;
    MONITORINFO monitor_info = {0};
    monitor_info.cbSize = sizeof(monitor_info);
    HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
    if (GetMonitorInfoW(monitor, &monitor_info)) {
        if (x + width > monitor_info.rcWork.right) x = monitor_info.rcWork.right - width;
        if (y + height > monitor_info.rcWork.bottom) y = cursor.y - height - 8;
    }
    SetWindowPos(znap_settings_tooltip, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InterlockedExchange(&znap_active_tooltip_row, (LONG)row);
}

static void ZnapPollCollisionTooltip(void) {
    POINT cursor;
    if (!GetCursorPos(&cursor)) return;
    LONG hovered_row = -1;
    for (UINT row = 0; row < znap_settings_row_count; row++) {
        HWND warning = znap_settings_rows[row].warning;
        RECT bounds;
        if (warning != NULL && IsWindowVisible(warning) && GetWindowRect(warning, &bounds) && PtInRect(&bounds, cursor)) {
            hovered_row = (LONG)row;
            break;
        }
    }

    if (hovered_row != znap_hover_tooltip_row) {
        const LONG active = InterlockedExchange(&znap_active_tooltip_row, -1);
        if (active >= 0 && znap_settings_tooltip != NULL) ShowWindow(znap_settings_tooltip, SW_HIDE);
        znap_hover_tooltip_row = hovered_row;
        znap_tooltip_hover_started = GetTickCount();
        return;
    }
    if (hovered_row >= 0 && GetTickCount() - znap_tooltip_hover_started >= 300) {
        ZnapShowCollisionTooltip((UINT)hovered_row, cursor);
    }
}

static BOOL ZnapIsExtendedKey(UINT key) {
    switch (key) {
        case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN:
        case VK_PRIOR: case VK_NEXT: case VK_HOME: case VK_END:
        case VK_INSERT: case VK_DELETE: case VK_DIVIDE: case VK_NUMLOCK:
            return TRUE;
        default:
            return FALSE;
    }
}

static void ZnapAppendText(WCHAR *buffer, size_t capacity, const WCHAR *text) {
    size_t used = lstrlenW(buffer);
    if (used >= capacity - 1) return;
    lstrcpynW(buffer + used, text, (int)(capacity - used));
}

static void ZnapFormatKeymap(UINT modifiers, UINT key, WCHAR *buffer, size_t capacity) {
    buffer[0] = L'\0';
    if (modifiers & MOD_WIN) ZnapAppendText(buffer, capacity, L"Win + ");
    if (modifiers & MOD_CONTROL) ZnapAppendText(buffer, capacity, L"Ctrl + ");
    if (modifiers & MOD_ALT) ZnapAppendText(buffer, capacity, L"Alt + ");
    if (modifiers & MOD_SHIFT) ZnapAppendText(buffer, capacity, L"Shift + ");

    WCHAR key_name[64] = {0};
    if ((key >= L'0' && key <= L'9') || (key >= L'A' && key <= L'Z')) {
        key_name[0] = (WCHAR)key;
        key_name[1] = L'\0';
    } else {
        LONG scan_code = (LONG)(MapVirtualKeyW(key, MAPVK_VK_TO_VSC) << 16);
        if (ZnapIsExtendedKey(key)) scan_code |= 1 << 24;
        if (GetKeyNameTextW(scan_code, key_name, ARRAYSIZE(key_name)) == 0) {
            wsprintfW(key_name, L"VK %02X", key);
        }
    }
    ZnapAppendText(buffer, capacity, key_name);
}

static BOOL ZnapKeymapCollides(HWND window, UINT row, UINT modifiers, UINT key) {
    const int hotkey_id = 0x6000 + (int)row;
    if (!RegisterHotKey(window, hotkey_id, modifiers | MOD_NOREPEAT, key)) return TRUE;
    UnregisterHotKey(window, hotkey_id);
    return FALSE;
}

static void ZnapRefreshSettingsRow(UINT row) {
    if (row >= znap_settings_row_count) return;
    ZnapSettingsRowState *state = &znap_settings_rows[row];
    WCHAR text[128];
    ZnapFormatKeymap(state->modifiers, state->key, text, ARRAYSIZE(text));
    SetWindowTextW(state->edit, text);
    const BOOL collides = ZnapKeymapCollides(znap_settings_window, row, state->modifiers, state->key);
    if (!collides) ZnapDeactivateCollisionTooltip(row);
    ShowWindow(state->warning, collides ? SW_SHOW : SW_HIDE);
}

static const WCHAR *ZnapActionLabel(UINT action) {
    switch (action) {
        case 0: return L"Snap/cycle left edge:";
        case 1: return L"Snap/cycle right edge:";
        case 2: return L"Snap/cycle top edge:";
        case 3: return L"Snap/cycle bottom edge:";
        case 4: return L"Snap/cycle top-left corner:";
        case 5: return L"Snap/cycle top-right corner:";
        case 6: return L"Snap/cycle bottom-left corner:";
        case 7: return L"Snap/cycle bottom-right corner:";
        case 8: return L"Maximize/restore:";
        case 9: return L"Cycle center window:";
        case 10: return L"Always on top:";
        default: return L"Keymap:";
    }
}

static HWND ZnapCreateSettingsControl(DWORD ex_style, const WCHAR *class_name, const WCHAR *text, DWORD style, int x, int y, int width, int height, HWND parent, UINT id) {
    HWND control = CreateWindowExW(ex_style, class_name, text, WS_CHILD | WS_VISIBLE | style, x, y, width, height, parent, (HMENU)(UINT_PTR)id, GetModuleHandleW(NULL), NULL);
    if (control != NULL && znap_settings_font != NULL) SendMessageW(control, WM_SETFONT, (WPARAM)znap_settings_font, TRUE);
    return control;
}

static LRESULT CALLBACK ZnapSettingsProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
        case WM_COMMAND: {
            const UINT id = LOWORD(wparam);
            const UINT notification = HIWORD(wparam);
            if (id == ZNAP_OPEN_WINDOWS_SETTINGS && notification == BN_CLICKED) {
                ShellExecuteW(window, L"open", L"ms-settings:multitasking", NULL, NULL, SW_SHOWNORMAL);
                return 0;
            }
            if (id == ZNAP_CLOSE_SETTINGS && notification == BN_CLICKED) {
                DestroyWindow(window);
                return 0;
            }
            if (id >= ZNAP_KEYMAP_CONTROL_BASE && id < ZNAP_KEYMAP_CONTROL_BASE + znap_settings_row_count) {
                const LONG row = (LONG)(id - ZNAP_KEYMAP_CONTROL_BASE);
                if (notification == EN_SETFOCUS) {
                    InterlockedExchange(&znap_recording_row, row);
                    SendMessageW(znap_settings_rows[row].edit, EM_SETSEL, 0, -1);
                } else if (notification == EN_KILLFOCUS) {
                    InterlockedCompareExchange(&znap_recording_row, -1, row);
                }
                return 0;
            }
            break;
        }
        case WM_CTLCOLORSTATIC: {
            HWND control = (HWND)lparam;
            if (control == znap_settings_tooltip) {
                SetTextColor((HDC)wparam, GetSysColor(COLOR_INFOTEXT));
                SetBkColor((HDC)wparam, GetSysColor(COLOR_INFOBK));
                return (LRESULT)GetSysColorBrush(COLOR_INFOBK);
            }
            for (UINT row = 0; row < znap_settings_row_count; row++) {
                if (znap_settings_rows[row].warning == control) {
                    SetTextColor((HDC)wparam, RGB(215, 160, 0));
                    SetBkMode((HDC)wparam, TRANSPARENT);
                    return (LRESULT)GetStockObject(NULL_BRUSH);
                }
                if (znap_settings_rows[row].edit == control) {
                    SetTextColor((HDC)wparam, RGB(0, 0, 0));
                    SetBkColor((HDC)wparam, RGB(255, 255, 255));
                    return (LRESULT)GetStockObject(WHITE_BRUSH);
                }
            }
            break;
        }
        case WM_CTLCOLOREDIT:
            SetTextColor((HDC)wparam, RGB(0, 0, 0));
            SetBkColor((HDC)wparam, RGB(255, 255, 255));
            return (LRESULT)GetStockObject(WHITE_BRUSH);
        case WM_TIMER:
            if (wparam == ZNAP_TOOLTIP_TIMER) ZnapPollCollisionTooltip();
            return 0;
        case WM_GETMINMAXINFO: {
            MINMAXINFO *limits = (MINMAXINFO *)lparam;
            limits->ptMinTrackSize.x = ZNAP_SETTINGS_WIDTH;
            limits->ptMinTrackSize.y = ZNAP_SETTINGS_HEIGHT;
            limits->ptMaxTrackSize.x = ZNAP_SETTINGS_WIDTH;
            limits->ptMaxTrackSize.y = ZNAP_SETTINGS_HEIGHT;
            return 0;
        }
        case ZNAP_CAPTURE_KEYMAP: {
            const LONG row = InterlockedCompareExchange(&znap_recording_row, -1, -1);
            if (row < 0 || (UINT)row >= znap_settings_row_count) return 0;
            ZnapSettingsRowState *state = &znap_settings_rows[row];
            if (!ZnapUpdateKeymap(state->index, (UINT)wparam, (UINT)lparam)) {
                MessageBoxW(window, L"The keymap could not be saved. The previous keymap is still active.", L"Znap Settings", MB_OK | MB_ICONERROR);
                return 0;
            }
            state->modifiers = (UINT)wparam;
            state->key = (UINT)lparam;
            ZnapRefreshSettingsRow((UINT)row);
            InterlockedExchange(&znap_recording_row, -1);
            SetFocus(znap_settings_window);
            return 0;
        }
        case WM_CLOSE:
            DestroyWindow(window);
            return 0;
        case WM_DESTROY:
            InterlockedExchange(&znap_recording_row, -1);
            InterlockedExchange(&znap_active_tooltip_row, -1);
            znap_hover_tooltip_row = -1;
            KillTimer(window, ZNAP_TOOLTIP_TIMER);
            if (znap_warning_font != NULL) {
                DeleteObject(znap_warning_font);
                znap_warning_font = NULL;
            }
            znap_settings_window = NULL;
            znap_settings_tooltip = NULL;
            znap_settings_row_count = 0;
            return 0;
        default:
            break;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

static void ZnapEnsureSettingsClass(HINSTANCE instance) {
    WNDCLASSEXW window_class = {0};
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = ZnapSettingsProc;
    window_class.hInstance = instance;
    window_class.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(1));
    window_class.hIconSm = window_class.hIcon;
    window_class.hCursor = LoadCursorW(NULL, IDC_ARROW);
    window_class.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    window_class.lpszClassName = ZNAP_SETTINGS_CLASS;
    RegisterClassExW(&window_class);
}

void ZnapShowSettingsDialog(HINSTANCE instance, HWND owner, const ZnapKeymapRow *rows, UINT row_count, UINT general_count, BOOL show_snap_warning) {
    if (znap_settings_window != NULL) {
        ShowWindow(znap_settings_window, SW_RESTORE);
        SetForegroundWindow(znap_settings_window);
        return;
    }
    if (row_count > ZNAP_MAX_KEYMAPS) row_count = ZNAP_MAX_KEYMAPS;
    ZnapEnsureSettingsClass(instance);
    znap_settings_font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    znap_warning_font = CreateFontW(-20, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI Symbol");
    znap_settings_window = CreateWindowExW(WS_EX_DLGMODALFRAME, ZNAP_SETTINGS_CLASS, L"Settings", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, ZNAP_SETTINGS_WIDTH, ZNAP_SETTINGS_HEIGHT, owner, NULL, instance, NULL);
    if (znap_settings_window == NULL) return;
    znap_settings_row_count = row_count;
    znap_settings_tooltip = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"STATIC", znap_collision_tooltip,
        WS_POPUP | WS_BORDER | SS_LEFT, 0, 0, 500, 48, znap_settings_window, NULL, instance, NULL);
    if (znap_settings_tooltip != NULL) {
        SendMessageW(znap_settings_tooltip, WM_SETFONT, (WPARAM)znap_settings_font, TRUE);
    }

    ZnapCreateSettingsControl(0, L"STATIC", L"General", SS_LEFT, 20, 16, 440, 22, znap_settings_window, 0);
    ZnapCreateSettingsControl(0, L"STATIC", L"Snapshots", SS_LEFT, 520, 16, 440, 22, znap_settings_window, 0);

    UINT general_row = 0;
    UINT snapshot_row = 0;
    for (UINT row = 0; row < row_count; row++) {
        const BOOL general = row < general_count;
        const int x = general ? 20 : 520;
        const int y = general ? 46 + (int)general_row++ * 28 : 46 + (int)snapshot_row++ * 28;
        const int label_width = general ? 190 : 165;
        const int control_height = 23;
        WCHAR snapshot_label[64];
        const WCHAR *label = ZnapActionLabel(rows[row].action);
        if (!general) {
            wsprintfW(snapshot_label, rows[row].action == 11 ? L"Store snapshot %u:" : L"Recall snapshot %u:", rows[row].snapshot_index + 1);
            label = snapshot_label;
        }
        ZnapCreateSettingsControl(0, L"STATIC", label, SS_RIGHT, x, y + 4, label_width, 22, znap_settings_window, 0);
        znap_settings_rows[row].edit = ZnapCreateSettingsControl(WS_EX_CLIENTEDGE, L"EDIT", L"", ES_READONLY | ES_AUTOHSCROLL | WS_TABSTOP, x + label_width + 10, y, 220, control_height, znap_settings_window, ZNAP_KEYMAP_CONTROL_BASE + row);
        znap_settings_rows[row].warning = ZnapCreateSettingsControl(0, L"STATIC", L"\x26A0", SS_CENTER | SS_CENTERIMAGE | SS_NOTIFY, x + label_width + 235, y - 2, 32, 27, znap_settings_window, 0);
        if (znap_settings_rows[row].warning != NULL && znap_warning_font != NULL) {
            SendMessageW(znap_settings_rows[row].warning, WM_SETFONT, (WPARAM)znap_warning_font, TRUE);
        }
        znap_settings_rows[row].index = rows[row].index;
        znap_settings_rows[row].modifiers = rows[row].modifiers;
        znap_settings_rows[row].key = rows[row].key;
        ZnapRefreshSettingsRow(row);
    }

    ZnapCreateSettingsControl(0, L"STATIC", L"", SS_ETCHEDHORZ, 24, 615, 950, 2, znap_settings_window, 0);
    if (show_snap_warning) {
        ZnapCreateSettingsControl(0, L"STATIC", L"Znap is can have compatibility issues with Windows default window snapping functionality. It is recommended to disable window snapping from Windows settings.", SS_LEFT, 28, 632, 620, 35, znap_settings_window, 0);
        ZnapCreateSettingsControl(0, L"BUTTON", L"Open Windows Settings", BS_PUSHBUTTON | WS_TABSTOP, 665, 627, 150, 32, znap_settings_window, ZNAP_OPEN_WINDOWS_SETTINGS);
    }
    ZnapCreateSettingsControl(0, L"BUTTON", L"Close", BS_DEFPUSHBUTTON | WS_TABSTOP, 830, 627, 140, 32, znap_settings_window, ZNAP_CLOSE_SETTINGS);

    ZnapCenterDialog(znap_settings_window);
    ShowWindow(znap_settings_window, SW_SHOW);
    UpdateWindow(znap_settings_window);
    SetTimer(znap_settings_window, ZNAP_TOOLTIP_TIMER, 50, NULL);
}

BOOL ZnapSettingsRecording(void) {
    return InterlockedCompareExchange(&znap_recording_row, -1, -1) >= 0;
}

void ZnapRecordKeymap(UINT modifiers, UINT key) {
    if (znap_settings_window != NULL) PostMessageW(znap_settings_window, ZNAP_CAPTURE_KEYMAP, modifiers, key);
}
