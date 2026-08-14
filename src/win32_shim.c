#ifndef UNICODE
#define UNICODE
#endif
#include "win32.h"

DPI_AWARENESS_CONTEXT ZnapPerMonitorV2(void) {
    return DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2;
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
