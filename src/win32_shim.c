#ifndef UNICODE
#define UNICODE
#endif
#include "win32.h"

DPI_AWARENESS_CONTEXT RectangleWinPerMonitorV2(void) {
    return DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2;
}

HWND RectangleWinHwndTopmost(void) {
    return HWND_TOPMOST;
}

HWND RectangleWinHwndNotopmost(void) {
    return HWND_NOTOPMOST;
}

HKEY RectangleWinHkeyCurrentUser(void) {
    return HKEY_CURRENT_USER;
}
