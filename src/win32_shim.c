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
