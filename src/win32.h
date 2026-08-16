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
