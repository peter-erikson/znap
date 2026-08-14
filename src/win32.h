#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <shellapi.h>
#include <dwmapi.h>

DPI_AWARENESS_CONTEXT RectangleWinPerMonitorV2(void);
HWND RectangleWinHwndTopmost(void);
HWND RectangleWinHwndNotopmost(void);
HKEY RectangleWinHkeyCurrentUser(void);
