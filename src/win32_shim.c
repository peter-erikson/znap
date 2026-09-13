#define COBJMACROS
#define SECURITY_WIN32
#ifndef UNICODE
#define UNICODE
#endif
#include "win32.h"
#include <initguid.h>
#include <taskschd.h>
#include <secext.h>
#include <oleauto.h>
#include <commctrl.h>
#include <uxtheme.h>

#define ZNAP_TASK_NAME L"Znap"
#define ZNAP_TASK_DESCRIPTION L"Starts Znap when the current user signs in."
#define ZNAP_LEGACY_STARTUP_KEY L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run"
#define ZNAP_LEGACY_STARTUP_VALUE L"Znap"

typedef struct ZnapTaskScheduler {
    BOOL uninitialize_com;
    ITaskService *service;
    ITaskFolder *root;
} ZnapTaskScheduler;

static void ZnapCloseTaskScheduler(ZnapTaskScheduler *scheduler) {
    if (scheduler->root != NULL) ITaskFolder_Release(scheduler->root);
    if (scheduler->service != NULL) ITaskService_Release(scheduler->service);
    if (scheduler->uninitialize_com) CoUninitialize();
}

static HRESULT ZnapOpenTaskScheduler(ZnapTaskScheduler *scheduler) {
    ZeroMemory(scheduler, sizeof(*scheduler));
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (SUCCEEDED(hr)) scheduler->uninitialize_com = TRUE;
    else if (hr != RPC_E_CHANGED_MODE) return hr;

    hr = CoCreateInstance(&CLSID_TaskScheduler, NULL, CLSCTX_INPROC_SERVER,
        &IID_ITaskService, (void **)&scheduler->service);
    if (FAILED(hr)) return hr;

    VARIANT empty;
    VariantInit(&empty);
    hr = ITaskService_Connect(scheduler->service, empty, empty, empty, empty);
    if (FAILED(hr)) return hr;

    BSTR root_path = SysAllocString(L"\\");
    if (root_path == NULL) return E_OUTOFMEMORY;
    hr = ITaskService_GetFolder(scheduler->service, root_path, &scheduler->root);
    SysFreeString(root_path);
    return hr;
}

static BSTR ZnapCurrentUserName(void) {
    WCHAR user_name[512];
    ULONG length = ARRAYSIZE(user_name);
    if (!GetUserNameExW(NameSamCompatible, user_name, &length)) return NULL;
    return SysAllocString(user_name);
}

BOOL ZnapStartupTaskEnabled(void) {
    ZnapTaskScheduler scheduler;
    HRESULT hr = ZnapOpenTaskScheduler(&scheduler);
    if (FAILED(hr)) {
        ZnapCloseTaskScheduler(&scheduler);
        return FALSE;
    }

    BSTR task_name = SysAllocString(ZNAP_TASK_NAME);
    IRegisteredTask *task = NULL;
    VARIANT_BOOL enabled = VARIANT_FALSE;
    if (task_name != NULL) hr = ITaskFolder_GetTask(scheduler.root, task_name, &task);
    else hr = E_OUTOFMEMORY;
    if (SUCCEEDED(hr)) hr = IRegisteredTask_get_Enabled(task, &enabled);
    if (task != NULL) IRegisteredTask_Release(task);
    SysFreeString(task_name);
    ZnapCloseTaskScheduler(&scheduler);
    return SUCCEEDED(hr) && enabled == VARIANT_TRUE;
}

static HRESULT ZnapDeleteStartupTask(ITaskFolder *root) {
    BSTR task_name = SysAllocString(ZNAP_TASK_NAME);
    if (task_name == NULL) return E_OUTOFMEMORY;
    HRESULT hr = ITaskFolder_DeleteTask(root, task_name, 0);
    SysFreeString(task_name);
    if (hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) return S_OK;
    return hr;
}

static HRESULT ZnapCreateStartupTask(ITaskService *service, ITaskFolder *root) {
    HRESULT hr;
    ITaskDefinition *definition = NULL;
    IRegistrationInfo *registration = NULL;
    IPrincipal *principal = NULL;
    ITaskSettings *settings = NULL;
    ITriggerCollection *triggers = NULL;
    ITrigger *trigger = NULL;
    ILogonTrigger *logon_trigger = NULL;
    IActionCollection *actions = NULL;
    IAction *action = NULL;
    IExecAction *exec_action = NULL;
    IRegisteredTask *registered_task = NULL;
    BSTR user_name = NULL;
    BSTR text = NULL;
    BSTR executable = NULL;
    BSTR task_name = NULL;

    hr = ITaskService_NewTask(service, 0, &definition);
    if (FAILED(hr)) goto cleanup;

    hr = ITaskDefinition_get_RegistrationInfo(definition, &registration);
    if (FAILED(hr)) goto cleanup;
    text = SysAllocString(ZNAP_TASK_DESCRIPTION);
    if (text == NULL) { hr = E_OUTOFMEMORY; goto cleanup; }
    hr = IRegistrationInfo_put_Description(registration, text);
    SysFreeString(text);
    text = NULL;
    if (FAILED(hr)) goto cleanup;

    user_name = ZnapCurrentUserName();
    if (user_name == NULL) { hr = HRESULT_FROM_WIN32(GetLastError()); goto cleanup; }
    hr = ITaskDefinition_get_Principal(definition, &principal);
    if (FAILED(hr)) goto cleanup;
    hr = IPrincipal_put_UserId(principal, user_name);
    if (FAILED(hr)) goto cleanup;
    hr = IPrincipal_put_LogonType(principal, TASK_LOGON_INTERACTIVE_TOKEN);
    if (FAILED(hr)) goto cleanup;
    hr = IPrincipal_put_RunLevel(principal, TASK_RUNLEVEL_HIGHEST);
    if (FAILED(hr)) goto cleanup;

    hr = ITaskDefinition_get_Settings(definition, &settings);
    if (FAILED(hr)) goto cleanup;
    hr = ITaskSettings_put_StartWhenAvailable(settings, VARIANT_TRUE);
    if (FAILED(hr)) goto cleanup;
    hr = ITaskSettings_put_DisallowStartIfOnBatteries(settings, VARIANT_FALSE);
    if (FAILED(hr)) goto cleanup;
    hr = ITaskSettings_put_StopIfGoingOnBatteries(settings, VARIANT_FALSE);
    if (FAILED(hr)) goto cleanup;
    text = SysAllocString(L"PT0S");
    if (text == NULL) { hr = E_OUTOFMEMORY; goto cleanup; }
    hr = ITaskSettings_put_ExecutionTimeLimit(settings, text);
    SysFreeString(text);
    text = NULL;
    if (FAILED(hr)) goto cleanup;

    hr = ITaskDefinition_get_Triggers(definition, &triggers);
    if (FAILED(hr)) goto cleanup;
    hr = ITriggerCollection_Create(triggers, TASK_TRIGGER_LOGON, &trigger);
    if (FAILED(hr)) goto cleanup;
    hr = ITrigger_QueryInterface(trigger, &IID_ILogonTrigger, (void **)&logon_trigger);
    if (FAILED(hr)) goto cleanup;
    hr = ILogonTrigger_put_UserId(logon_trigger, user_name);
    if (FAILED(hr)) goto cleanup;
    hr = ILogonTrigger_put_Enabled(logon_trigger, VARIANT_TRUE);
    if (FAILED(hr)) goto cleanup;
    text = SysAllocString(L"PT10S");
    if (text == NULL) { hr = E_OUTOFMEMORY; goto cleanup; }
    hr = ILogonTrigger_put_Delay(logon_trigger, text);
    SysFreeString(text);
    text = NULL;
    if (FAILED(hr)) goto cleanup;

    hr = ITaskDefinition_get_Actions(definition, &actions);
    if (FAILED(hr)) goto cleanup;
    hr = IActionCollection_Create(actions, TASK_ACTION_EXEC, &action);
    if (FAILED(hr)) goto cleanup;
    hr = IAction_QueryInterface(action, &IID_IExecAction, (void **)&exec_action);
    if (FAILED(hr)) goto cleanup;

    WCHAR executable_path[32768];
    DWORD executable_length = GetModuleFileNameW(NULL, executable_path, ARRAYSIZE(executable_path));
    if (executable_length == 0 || executable_length == ARRAYSIZE(executable_path)) {
        hr = HRESULT_FROM_WIN32(GetLastError());
        goto cleanup;
    }
    executable = SysAllocString(executable_path);
    if (executable == NULL) { hr = E_OUTOFMEMORY; goto cleanup; }
    hr = IExecAction_put_Path(exec_action, executable);
    if (FAILED(hr)) goto cleanup;

    task_name = SysAllocString(ZNAP_TASK_NAME);
    if (task_name == NULL) { hr = E_OUTOFMEMORY; goto cleanup; }
    VARIANT user;
    VARIANT password;
    VARIANT security_descriptor;
    VariantInit(&user);
    VariantInit(&password);
    VariantInit(&security_descriptor);
    V_VT(&user) = VT_BSTR;
    V_BSTR(&user) = user_name;
    hr = ITaskFolder_RegisterTaskDefinition(root, task_name, definition, TASK_CREATE_OR_UPDATE,
        user, password, TASK_LOGON_INTERACTIVE_TOKEN, security_descriptor, &registered_task);

cleanup:
    if (registered_task != NULL) IRegisteredTask_Release(registered_task);
    SysFreeString(task_name);
    SysFreeString(executable);
    SysFreeString(text);
    if (exec_action != NULL) IExecAction_Release(exec_action);
    if (action != NULL) IAction_Release(action);
    if (actions != NULL) IActionCollection_Release(actions);
    if (logon_trigger != NULL) ILogonTrigger_Release(logon_trigger);
    if (trigger != NULL) ITrigger_Release(trigger);
    if (triggers != NULL) ITriggerCollection_Release(triggers);
    if (settings != NULL) ITaskSettings_Release(settings);
    if (principal != NULL) IPrincipal_Release(principal);
    SysFreeString(user_name);
    if (registration != NULL) IRegistrationInfo_Release(registration);
    if (definition != NULL) ITaskDefinition_Release(definition);
    return hr;
}

static void ZnapDeleteLegacyStartupValue(void) {
    HKEY key = NULL;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, ZNAP_LEGACY_STARTUP_KEY, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) return;
    RegDeleteValueW(key, ZNAP_LEGACY_STARTUP_VALUE);
    RegCloseKey(key);
}

BOOL ZnapSetStartupTask(BOOL enabled) {
    ZnapTaskScheduler scheduler;
    HRESULT hr = ZnapOpenTaskScheduler(&scheduler);
    if (SUCCEEDED(hr)) {
        hr = enabled ? ZnapCreateStartupTask(scheduler.service, scheduler.root)
                     : ZnapDeleteStartupTask(scheduler.root);
    }
    if (SUCCEEDED(hr)) ZnapDeleteLegacyStartupValue();
    ZnapCloseTaskScheduler(&scheduler);
    return SUCCEEDED(hr);
}

BOOL ZnapSetStartupTaskElevated(BOOL enabled) {
    WCHAR executable[32768];
    DWORD length = GetModuleFileNameW(NULL, executable, ARRAYSIZE(executable));
    if (length == 0 || length == ARRAYSIZE(executable)) return FALSE;

    SHELLEXECUTEINFOW launch = {0};
    launch.cbSize = sizeof(launch);
    launch.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    launch.lpVerb = L"runas";
    launch.lpFile = executable;
    launch.lpParameters = enabled ? L"--install-startup-task" : L"--remove-startup-task";
    launch.nShow = SW_HIDE;
    if (!ShellExecuteExW(&launch) || launch.hProcess == NULL) return FALSE;

    DWORD wait_result = WaitForSingleObject(launch.hProcess, INFINITE);
    DWORD exit_code = 1;
    BOOL got_exit_code = GetExitCodeProcess(launch.hProcess, &exit_code);
    CloseHandle(launch.hProcess);
    return wait_result == WAIT_OBJECT_0 && got_exit_code && exit_code == 0;
}

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

static BOOL ZnapHighContrastEnabled(void) {
    HIGHCONTRASTW high_contrast = {0};
    high_contrast.cbSize = sizeof(high_contrast);
    return SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(high_contrast), &high_contrast, 0) &&
        (high_contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;
}

static BOOL ZnapDarkModeEnabled(void) {
    if (ZnapHighContrastEnabled()) return FALSE;
    HKEY key = NULL;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) return FALSE;
    DWORD use_light_theme = 1;
    DWORD type = 0;
    DWORD size = sizeof(use_light_theme);
    const LONG result = RegQueryValueExW(key, L"AppsUseLightTheme", NULL, &type,
        (BYTE *)&use_light_theme, &size);
    RegCloseKey(key);
    return result == ERROR_SUCCESS && type == REG_DWORD && use_light_theme == 0;
}

static void ZnapApplyWindowChrome(HWND window) {
    const BOOL dark = ZnapDarkModeEnabled();
    const DWORD round_corners = 2; /* DWMWCP_ROUND */
    DwmSetWindowAttribute(window, (enum DWMWINDOWATTRIBUTE)20, &dark, sizeof(dark));
    DwmSetWindowAttribute(window, (enum DWMWINDOWATTRIBUTE)33, &round_corners, sizeof(round_corners));
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
        ZnapApplyWindowChrome(dialog);
        ZnapCenterDialog(dialog);
        return TRUE;
    }
    if (message == WM_THEMECHANGED || message == WM_SETTINGCHANGE) {
        ZnapApplyWindowChrome(dialog);
        RedrawWindow(dialog, NULL, NULL, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_ERASE);
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
#define ZNAP_SETTINGS_PAGE_CLASS L"Znap.SettingsPage"
#define ZNAP_OPEN_WINDOWS_SETTINGS 3001
#define ZNAP_SETTINGS_NAVIGATION 3002
#define ZNAP_STARTUP_NORMAL 3003
#define ZNAP_STARTUP_ADMIN 3004
#define ZNAP_CYCLE_WIDTH_BASE 3100
#define ZNAP_CYCLE_GROUP_COUNT 3
#define ZNAP_CYCLE_WIDTH_COUNT 5
#define ZNAP_KEYMAP_CONTROL_BASE 4000
#define ZNAP_ACTION_STORE_SNAPSHOT 10
#define ZNAP_MAX_KEYMAPS 256
#define ZNAP_CAPTURE_KEYMAP (WM_APP + 20)
#define ZNAP_TOOLTIP_TIMER 1
#define ZNAP_SETTINGS_WIDTH 980
#define ZNAP_SETTINGS_HEIGHT 700
#define ZNAP_SETTINGS_FONT_POINTS 11
#define ZNAP_INFO_TEXT_FONT_POINTS 10
#define ZNAP_SECTION_FONT_POINTS 13
#define ZNAP_SECTION_CONTENT_PADDING 6
#define ZNAP_NAVIGATION_WIDTH 210
#define ZNAP_NAVIGATION_ITEM_HEIGHT 44
#define ZNAP_KEYMAP_CONTROL_HEIGHT 27
#define ZNAP_INFO_ICON_SIZE 20
#define ZNAP_TOOLTIP_HORIZONTAL_PADDING 8
#define ZNAP_TOOLTIP_TOP_PADDING 5
#define ZNAP_TOOLTIP_BOTTOM_PADDING 5
#define ZNAP_TOOLTIP_HEIGHT 58
#define ZNAP_CHECKBOX_SIZE 20
#define ZNAP_CHECKBOX_HEIGHT 30
#define ZNAP_MAX_SECTION_HEADERS 8

typedef struct ZnapSettingsRowState {
    HWND edit;
    HWND warning;
    UINT index;
    UINT modifiers;
    UINT key;
} ZnapSettingsRowState;

static HWND znap_settings_window = NULL;
static HWND znap_settings_navigation = NULL;
static HWND znap_general_page = NULL;
static HWND znap_keybinds_page = NULL;
static HWND znap_startup_normal = NULL;
static HWND znap_startup_admin = NULL;
static HWND znap_startup_info = NULL;
static HWND znap_cycle_widths[ZNAP_CYCLE_GROUP_COUNT][ZNAP_CYCLE_WIDTH_COUNT] = {{NULL}};
static int znap_general_content_height = 0;
static int znap_keybinds_content_height = 0;
static ZnapSettingsRowState znap_settings_rows[ZNAP_MAX_KEYMAPS];
static UINT znap_settings_row_count = 0;
static LONG znap_recording_row = -1;
static HFONT znap_settings_font = NULL;
static HFONT znap_info_text_font = NULL;
static HFONT znap_section_font = NULL;
static HFONT znap_navigation_font = NULL;
static HWND znap_section_headers[ZNAP_MAX_SECTION_HEADERS];
static UINT znap_section_header_count = 0;
static HWND znap_settings_tooltip = NULL;
static LONG znap_active_tooltip_row = -1;
static LONG znap_hover_tooltip_row = -1;
static DWORD znap_tooltip_hover_started = 0;
static UINT znap_settings_dpi = 96;
static BOOL znap_settings_dark = FALSE;
static BOOL znap_settings_high_contrast = FALSE;
static COLORREF znap_settings_background_color = RGB(243, 243, 243);
static COLORREF znap_navigation_background_color = RGB(235, 235, 235);
static COLORREF znap_settings_surface_color = RGB(255, 255, 255);
static COLORREF znap_settings_text_color = RGB(24, 24, 24);
static COLORREF znap_settings_tooltip_color = RGB(255, 255, 225);
static HBRUSH znap_settings_background_brush = NULL;
static HBRUSH znap_navigation_background_brush = NULL;
static HBRUSH znap_settings_surface_brush = NULL;
static HBRUSH znap_settings_tooltip_brush = NULL;
static WCHAR znap_collision_tooltip[] = L"The keyboard shortcut is overriding a global system shortcut, this usually works fine but can have unforeseen consequences.";

static int ZnapScale(int value) {
    return MulDiv(value, (int)znap_settings_dpi, 96);
}

static void ZnapDeleteSettingsBrushes(void) {
    if (znap_settings_background_brush != NULL) DeleteObject(znap_settings_background_brush);
    if (znap_navigation_background_brush != NULL) DeleteObject(znap_navigation_background_brush);
    if (znap_settings_surface_brush != NULL) DeleteObject(znap_settings_surface_brush);
    if (znap_settings_tooltip_brush != NULL) DeleteObject(znap_settings_tooltip_brush);
    znap_settings_background_brush = NULL;
    znap_navigation_background_brush = NULL;
    znap_settings_surface_brush = NULL;
    znap_settings_tooltip_brush = NULL;
}

static BOOL CALLBACK ZnapApplyThemeToChild(HWND control, LPARAM unused) {
    (void)unused;
    WCHAR class_name[32] = {0};
    GetClassNameW(control, class_name, ARRAYSIZE(class_name));
    if (lstrcmpiW(class_name, L"Button") == 0 ||
        lstrcmpiW(class_name, L"Edit") == 0 ||
        lstrcmpiW(class_name, L"ListBox") == 0 ||
        lstrcmpiW(class_name, ZNAP_SETTINGS_PAGE_CLASS) == 0) {
        if (znap_settings_high_contrast) SetWindowTheme(control, NULL, NULL);
        else SetWindowTheme(control, znap_settings_dark ? L"DarkMode_Explorer" : L"Explorer", NULL);
    }
    RedrawWindow(control, NULL, NULL,
        RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_UPDATENOW);
    return TRUE;
}

static void ZnapRefreshSettingsTheme(HWND window) {
    ZnapDeleteSettingsBrushes();
    znap_settings_high_contrast = ZnapHighContrastEnabled();
    znap_settings_dark = !znap_settings_high_contrast && ZnapDarkModeEnabled();
    if (znap_settings_high_contrast) {
        znap_settings_background_color = GetSysColor(COLOR_BTNFACE);
        znap_navigation_background_color = GetSysColor(COLOR_BTNFACE);
        znap_settings_surface_color = GetSysColor(COLOR_WINDOW);
        znap_settings_text_color = GetSysColor(COLOR_WINDOWTEXT);
        znap_settings_tooltip_color = GetSysColor(COLOR_INFOBK);
    } else if (znap_settings_dark) {
        znap_settings_background_color = RGB(32, 32, 32);
        znap_navigation_background_color = RGB(27, 27, 27);
        znap_settings_surface_color = RGB(45, 45, 45);
        znap_settings_text_color = RGB(243, 243, 243);
        znap_settings_tooltip_color = RGB(48, 48, 48);
    } else {
        znap_settings_background_color = RGB(243, 243, 243);
        znap_navigation_background_color = RGB(235, 235, 235);
        znap_settings_surface_color = RGB(255, 255, 255);
        znap_settings_text_color = RGB(24, 24, 24);
        znap_settings_tooltip_color = RGB(255, 255, 225);
    }
    znap_settings_background_brush = CreateSolidBrush(znap_settings_background_color);
    znap_navigation_background_brush = CreateSolidBrush(znap_navigation_background_color);
    znap_settings_surface_brush = CreateSolidBrush(znap_settings_surface_color);
    znap_settings_tooltip_brush = CreateSolidBrush(znap_settings_tooltip_color);
    ZnapApplyWindowChrome(window);
    EnumChildWindows(window, ZnapApplyThemeToChild, 0);
    if (znap_settings_tooltip != NULL) {
        RedrawWindow(znap_settings_tooltip, NULL, NULL,
            RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_UPDATENOW);
    }
    RedrawWindow(window, NULL, NULL,
        RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_ERASE | RDW_FRAME | RDW_UPDATENOW);
}

static BOOL CALLBACK ZnapSetMessageFontOnChild(HWND control, LPARAM font) {
    SendMessageW(control, WM_SETFONT, (WPARAM)font, TRUE);
    return TRUE;
}

static void ZnapRefreshSettingsFonts(HWND window) {
    NONCLIENTMETRICSW metrics = {0};
    metrics.cbSize = sizeof(metrics);
    if (!SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0, znap_settings_dpi)) {
        if (!SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0)) return;
        const UINT system_dpi = GetDpiForSystem();
        if (system_dpi != 0 && system_dpi != znap_settings_dpi) {
            metrics.lfMessageFont.lfHeight = MulDiv(metrics.lfMessageFont.lfHeight, (int)znap_settings_dpi, (int)system_dpi);
            metrics.lfMessageFont.lfWidth = MulDiv(metrics.lfMessageFont.lfWidth, (int)znap_settings_dpi, (int)system_dpi);
        }
    }
    LOGFONTW message_font_info = metrics.lfMessageFont;
    message_font_info.lfHeight = -MulDiv(ZNAP_SETTINGS_FONT_POINTS, (int)znap_settings_dpi, 72);
    HFONT message_font = CreateFontIndirectW(&message_font_info);
    LOGFONTW info_text_font_info = metrics.lfMessageFont;
    info_text_font_info.lfHeight = -MulDiv(ZNAP_INFO_TEXT_FONT_POINTS, (int)znap_settings_dpi, 72);
    HFONT info_text_font = CreateFontIndirectW(&info_text_font_info);
    LOGFONTW section_font_info = metrics.lfMessageFont;
    section_font_info.lfHeight = -MulDiv(ZNAP_SECTION_FONT_POINTS, (int)znap_settings_dpi, 72);
    section_font_info.lfWeight = FW_BOLD;
    HFONT section_font = CreateFontIndirectW(&section_font_info);
    LOGFONTW navigation_font_info = metrics.lfMessageFont;
    navigation_font_info.lfHeight = MulDiv(navigation_font_info.lfHeight, 4, 3);
    HFONT navigation_font = CreateFontIndirectW(&navigation_font_info);
    if (message_font != NULL) {
        EnumChildWindows(window, ZnapSetMessageFontOnChild, (LPARAM)message_font);
        if (znap_settings_tooltip != NULL) {
            SendMessageW(znap_settings_tooltip, WM_SETFONT, (WPARAM)message_font, TRUE);
        }
        if (znap_settings_font != NULL) DeleteObject(znap_settings_font);
        znap_settings_font = message_font;
    }
    if (info_text_font != NULL) {
        if (znap_startup_info != NULL) {
            SendMessageW(znap_startup_info, WM_SETFONT, (WPARAM)info_text_font, TRUE);
        }
        if (znap_info_text_font != NULL) DeleteObject(znap_info_text_font);
        znap_info_text_font = info_text_font;
    }
    if (section_font != NULL) {
        for (UINT index = 0; index < znap_section_header_count; index++) {
            SendMessageW(znap_section_headers[index], WM_SETFONT, (WPARAM)section_font, TRUE);
        }
        if (znap_section_font != NULL) DeleteObject(znap_section_font);
        znap_section_font = section_font;
    }
    if (navigation_font != NULL) {
        if (znap_settings_navigation != NULL) {
            SendMessageW(znap_settings_navigation, WM_SETFONT, (WPARAM)navigation_font, TRUE);
            SendMessageW(znap_settings_navigation, LB_SETITEMHEIGHT, 0, ZnapScale(ZNAP_NAVIGATION_ITEM_HEIGHT));
        }
        if (znap_navigation_font != NULL) DeleteObject(znap_navigation_font);
        znap_navigation_font = navigation_font;
    }
}

typedef struct ZnapDpiScaleContext {
    UINT old_dpi;
    UINT new_dpi;
} ZnapDpiScaleContext;

static BOOL CALLBACK ZnapScaleChildForDpi(HWND control, LPARAM lparam) {
    ZnapDpiScaleContext *context = (ZnapDpiScaleContext *)lparam;
    RECT bounds;
    if (!GetWindowRect(control, &bounds)) return TRUE;
    MapWindowPoints(HWND_DESKTOP, GetParent(control), (POINT *)&bounds, 2);
    const int left = MulDiv(bounds.left, (int)context->new_dpi, (int)context->old_dpi);
    const int top = MulDiv(bounds.top, (int)context->new_dpi, (int)context->old_dpi);
    const int width = MulDiv(bounds.right - bounds.left, (int)context->new_dpi, (int)context->old_dpi);
    const int height = MulDiv(bounds.bottom - bounds.top, (int)context->new_dpi, (int)context->old_dpi);
    SetWindowPos(control, NULL, left, top, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
    return TRUE;
}

static void ZnapDeactivateCollisionTooltip(UINT row) {
    if (znap_settings_tooltip == NULL) return;
    if (InterlockedCompareExchange(&znap_active_tooltip_row, -1, (LONG)row) == (LONG)row) {
        ShowWindow(znap_settings_tooltip, SW_HIDE);
    }
}

static void ZnapShowCollisionTooltip(UINT row, POINT cursor) {
    if (znap_settings_tooltip == NULL || row >= znap_settings_row_count) return;
    const int width = ZnapScale(500);
    const int height = ZnapScale(ZNAP_TOOLTIP_HEIGHT);
    int x = cursor.x + ZnapScale(12);
    int y = cursor.y + ZnapScale(20);
    MONITORINFO monitor_info = {0};
    monitor_info.cbSize = sizeof(monitor_info);
    HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
    if (GetMonitorInfoW(monitor, &monitor_info)) {
        if (x + width > monitor_info.rcWork.right) x = monitor_info.rcWork.right - width;
        if (y + height > monitor_info.rcWork.bottom) y = cursor.y - height - ZnapScale(8);
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
    if (key == 0) return;
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
    if (key == 0) return FALSE;
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
        default: return L"Keymap:";
    }
}

static HWND ZnapCreateSettingsControl(DWORD ex_style, const WCHAR *class_name, const WCHAR *text, DWORD style, int x, int y, int width, int height, HWND parent, UINT id) {
    HWND control = CreateWindowExW(ex_style, class_name, text, WS_CHILD | WS_VISIBLE | style,
        ZnapScale(x), ZnapScale(y), ZnapScale(width), ZnapScale(height),
        parent, (HMENU)(UINT_PTR)id, GetModuleHandleW(NULL), NULL);
    if (control != NULL && znap_settings_font != NULL) SendMessageW(control, WM_SETFONT, (WPARAM)znap_settings_font, TRUE);
    if (control != NULL) ZnapApplyThemeToChild(control, 0);
    return control;
}

static HWND ZnapCreateSettingsHeader(const WCHAR *text, int y, HWND parent) {
    HWND header = ZnapCreateSettingsControl(0, L"STATIC", text, SS_LEFT, 20, y, 650, 28, parent, 0);
    if (header != NULL && znap_section_header_count < ZNAP_MAX_SECTION_HEADERS) {
        znap_section_headers[znap_section_header_count++] = header;
        if (znap_section_font != NULL) SendMessageW(header, WM_SETFONT, (WPARAM)znap_section_font, TRUE);
    }
    return header;
}

static void ZnapDrawLargeCheckbox(HWND control, HDC dc) {
    RECT client;
    GetClientRect(control, &client);
    FillRect(dc, &client, znap_settings_background_brush != NULL
        ? znap_settings_background_brush : GetSysColorBrush(COLOR_BTNFACE));

    const BOOL enabled = IsWindowEnabled(control);
    const BOOL checked = SendMessageW(control, BM_GETCHECK, 0, 0) == BST_CHECKED;
    const int box_size = ZnapScale(ZNAP_CHECKBOX_SIZE);
    RECT box = { 0, (client.bottom - box_size) / 2, box_size, (client.bottom + box_size) / 2 };
    const COLORREF border_color = !enabled ? GetSysColor(COLOR_GRAYTEXT)
        : (znap_settings_high_contrast ? GetSysColor(COLOR_WINDOWTEXT)
        : (znap_settings_dark ? RGB(145, 145, 145) : RGB(96, 96, 96)));
    const COLORREF fill_color = checked && enabled ? GetSysColor(COLOR_HIGHLIGHT)
        : (!enabled ? GetSysColor(COLOR_BTNFACE) : znap_settings_surface_color);
    HPEN border_pen = CreatePen(PS_SOLID, max(1, ZnapScale(1)), border_color);
    HBRUSH fill_brush = CreateSolidBrush(fill_color);
    HPEN previous_pen = SelectObject(dc, border_pen);
    HBRUSH previous_brush = SelectObject(dc, fill_brush);
    Rectangle(dc, box.left, box.top, box.right, box.bottom);

    if (checked) {
        const COLORREF check_color = enabled ? GetSysColor(COLOR_HIGHLIGHTTEXT) : GetSysColor(COLOR_GRAYTEXT);
        HPEN check_pen = CreatePen(PS_SOLID, max(2, ZnapScale(2)), check_color);
        SelectObject(dc, check_pen);
        MoveToEx(dc, box.left + box_size * 4 / 20, box.top + box_size * 10 / 20, NULL);
        LineTo(dc, box.left + box_size * 8 / 20, box.top + box_size * 14 / 20);
        LineTo(dc, box.left + box_size * 16 / 20, box.top + box_size * 6 / 20);
        SelectObject(dc, border_pen);
        DeleteObject(check_pen);
    }
    SelectObject(dc, previous_pen);
    SelectObject(dc, previous_brush);
    DeleteObject(border_pen);
    DeleteObject(fill_brush);

    WCHAR text[256] = {0};
    GetWindowTextW(control, text, ARRAYSIZE(text));
    RECT text_bounds = client;
    text_bounds.left = box.right + ZnapScale(10);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, enabled ? znap_settings_text_color : GetSysColor(COLOR_GRAYTEXT));
    HFONT previous_font = znap_settings_font != NULL ? SelectObject(dc, znap_settings_font) : NULL;
    DrawTextW(dc, text, -1, &text_bounds, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);
    if (GetFocus() == control) {
        SIZE text_size = {0};
        GetTextExtentPoint32W(dc, text, lstrlenW(text), &text_size);
        RECT focus = {
            text_bounds.left - ZnapScale(2),
            (client.bottom - text_size.cy) / 2 - ZnapScale(1),
            text_bounds.left + text_size.cx + ZnapScale(2),
            (client.bottom + text_size.cy) / 2 + ZnapScale(1)
        };
        DrawFocusRect(dc, &focus);
    }
    if (previous_font != NULL) SelectObject(dc, previous_font);
}

static LRESULT CALLBACK ZnapLargeCheckboxProc(HWND control, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR subclass_id, DWORD_PTR reference_data) {
    (void)reference_data;
    switch (message) {
        case WM_ERASEBKGND:
            return 1;
        case WM_PAINT: {
            PAINTSTRUCT paint;
            HDC dc = BeginPaint(control, &paint);
            ZnapDrawLargeCheckbox(control, dc);
            EndPaint(control, &paint);
            return 0;
        }
        case BM_SETCHECK: {
            const LRESULT result = DefSubclassProc(control, message, wparam, lparam);
            InvalidateRect(control, NULL, TRUE);
            return result;
        }
        case WM_ENABLE:
        case WM_SETFOCUS:
        case WM_KILLFOCUS:
        case WM_THEMECHANGED: {
            const LRESULT result = DefSubclassProc(control, message, wparam, lparam);
            InvalidateRect(control, NULL, TRUE);
            return result;
        }
        case WM_NCDESTROY:
            RemoveWindowSubclass(control, ZnapLargeCheckboxProc, subclass_id);
            break;
        default:
            break;
    }
    return DefSubclassProc(control, message, wparam, lparam);
}

static HWND ZnapCreateLargeCheckbox(const WCHAR *text, int y, HWND parent, UINT id) {
    HWND checkbox = ZnapCreateSettingsControl(0, L"BUTTON", text, BS_AUTOCHECKBOX | WS_TABSTOP,
        28, y, 620, ZNAP_CHECKBOX_HEIGHT, parent, id);
    if (checkbox != NULL) SetWindowSubclass(checkbox, ZnapLargeCheckboxProc, id, 0);
    return checkbox;
}

static void ZnapDrawCollisionTooltip(HWND tooltip, HDC dc) {
    RECT client;
    GetClientRect(tooltip, &client);
    FillRect(dc, &client, znap_settings_tooltip_brush != NULL
        ? znap_settings_tooltip_brush : GetSysColorBrush(COLOR_INFOBK));

    RECT text_bounds = client;
    text_bounds.left += ZnapScale(ZNAP_TOOLTIP_HORIZONTAL_PADDING);
    text_bounds.right -= ZnapScale(ZNAP_TOOLTIP_HORIZONTAL_PADDING);
    text_bounds.top += ZnapScale(ZNAP_TOOLTIP_TOP_PADDING);
    text_bounds.bottom -= ZnapScale(ZNAP_TOOLTIP_BOTTOM_PADDING);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, znap_settings_dark ? znap_settings_text_color : GetSysColor(COLOR_INFOTEXT));
    HFONT previous_font = znap_settings_font != NULL ? SelectObject(dc, znap_settings_font) : NULL;
    DrawTextW(dc, znap_collision_tooltip, -1, &text_bounds, DT_LEFT | DT_WORDBREAK | DT_NOPREFIX);
    if (previous_font != NULL) SelectObject(dc, previous_font);
}

static LRESULT CALLBACK ZnapCollisionTooltipProc(HWND tooltip, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR subclass_id, DWORD_PTR reference_data) {
    (void)reference_data;
    switch (message) {
        case WM_ERASEBKGND:
            return 1;
        case WM_PAINT: {
            PAINTSTRUCT paint;
            HDC dc = BeginPaint(tooltip, &paint);
            ZnapDrawCollisionTooltip(tooltip, dc);
            EndPaint(tooltip, &paint);
            return 0;
        }
        case WM_THEMECHANGED:
            InvalidateRect(tooltip, NULL, TRUE);
            break;
        case WM_NCDESTROY:
            RemoveWindowSubclass(tooltip, ZnapCollisionTooltipProc, subclass_id);
            break;
        default:
            break;
    }
    return DefSubclassProc(tooltip, message, wparam, lparam);
}

static int ZnapPageContentHeight(HWND page) {
    if (page == znap_general_page) return ZnapScale(znap_general_content_height);
    if (page == znap_keybinds_page) return ZnapScale(znap_keybinds_content_height);
    return 0;
}

static void ZnapUpdatePageScrollbar(HWND page) {
    RECT client;
    GetClientRect(page, &client);
    SCROLLINFO info = { sizeof(info), SIF_POS };
    GetScrollInfo(page, SB_VERT, &info);
    info.fMask = SIF_RANGE | SIF_PAGE | SIF_POS;
    info.nMin = 0;
    info.nMax = max(0, ZnapPageContentHeight(page) - 1);
    info.nPage = (UINT)max(0, client.bottom - client.top);
    SetScrollInfo(page, SB_VERT, &info, TRUE);
}

static void ZnapScrollSettingsPage(HWND page, int requested_position) {
    SCROLLINFO info = { sizeof(info), SIF_ALL };
    if (!GetScrollInfo(page, SB_VERT, &info)) return;
    const int maximum = max(info.nMin, info.nMax - (int)info.nPage + 1);
    const int next = min(max(requested_position, info.nMin), maximum);
    if (next == info.nPos) return;
    const int delta = info.nPos - next;
    info.fMask = SIF_POS;
    info.nPos = next;
    SetScrollInfo(page, SB_VERT, &info, TRUE);
    ScrollWindowEx(page, 0, delta, NULL, NULL, NULL, NULL,
        SW_SCROLLCHILDREN | SW_INVALIDATE | SW_ERASE);
    UpdateWindow(page);
}

static void ZnapShowSettingsPage(int index) {
    const BOOL show_general = index == 0;
    ShowWindow(znap_general_page, show_general ? SW_SHOW : SW_HIDE);
    ShowWindow(znap_keybinds_page, show_general ? SW_HIDE : SW_SHOW);
    InterlockedExchange(&znap_recording_row, -1);
    if (znap_settings_tooltip != NULL) ShowWindow(znap_settings_tooltip, SW_HIDE);
}

static void ZnapDrawInfoIcon(const DRAWITEMSTRUCT *draw) {
    HBRUSH background = znap_settings_background_brush != NULL
        ? znap_settings_background_brush : GetSysColorBrush(COLOR_BTNFACE);
    FillRect(draw->hDC, &draw->rcItem, background);

    const int diameter = ZnapScale(ZNAP_INFO_ICON_SIZE);
    const int left = draw->rcItem.left + (draw->rcItem.right - draw->rcItem.left - diameter) / 2;
    const int top = draw->rcItem.top + (draw->rcItem.bottom - draw->rcItem.top - diameter) / 2;
    const COLORREF blue = znap_settings_high_contrast
        ? GetSysColor(COLOR_HIGHLIGHT) : RGB(38, 149, 232);
    const COLORREF white = znap_settings_high_contrast
        ? GetSysColor(COLOR_HIGHLIGHTTEXT) : RGB(255, 255, 255);
    HBRUSH blue_brush = CreateSolidBrush(blue);
    HBRUSH white_brush = CreateSolidBrush(white);
    if (blue_brush == NULL || white_brush == NULL) {
        if (blue_brush != NULL) DeleteObject(blue_brush);
        if (white_brush != NULL) DeleteObject(white_brush);
        return;
    }

    HGDIOBJ previous_brush = SelectObject(draw->hDC, blue_brush);
    HGDIOBJ previous_pen = SelectObject(draw->hDC, GetStockObject(NULL_PEN));
    Ellipse(draw->hDC, left, top, left + diameter, top + diameter);

    SelectObject(draw->hDC, white_brush);
    const int dot_size = max(2, ZnapScale(4));
    const int stem_width = max(2, ZnapScale(3));
    const int center_x = left + diameter / 2;
    const int dot_top = top + ZnapScale(4);
    Ellipse(draw->hDC, center_x - dot_size / 2, dot_top,
        center_x - dot_size / 2 + dot_size, dot_top + dot_size);
    RECT stem = {
        center_x - stem_width / 2,
        top + ZnapScale(10),
        center_x - stem_width / 2 + stem_width,
        top + ZnapScale(16),
    };
    FillRect(draw->hDC, &stem, white_brush);

    SelectObject(draw->hDC, previous_pen);
    SelectObject(draw->hDC, previous_brush);
    DeleteObject(white_brush);
    DeleteObject(blue_brush);
}

static LRESULT CALLBACK ZnapSettingsPageProc(HWND page, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
        case WM_ERASEBKGND: {
            RECT client;
            GetClientRect(page, &client);
            FillRect((HDC)wparam, &client, znap_settings_background_brush != NULL
                ? znap_settings_background_brush : GetSysColorBrush(COLOR_BTNFACE));
            return 1;
        }
        case WM_SIZE:
            ZnapUpdatePageScrollbar(page);
            return 0;
        case WM_VSCROLL: {
            SCROLLINFO info = { sizeof(info), SIF_ALL };
            GetScrollInfo(page, SB_VERT, &info);
            int next = info.nPos;
            switch (LOWORD(wparam)) {
                case SB_TOP: next = info.nMin; break;
                case SB_BOTTOM: next = info.nMax; break;
                case SB_LINEUP: next -= ZnapScale(28); break;
                case SB_LINEDOWN: next += ZnapScale(28); break;
                case SB_PAGEUP: next -= (int)info.nPage; break;
                case SB_PAGEDOWN: next += (int)info.nPage; break;
                case SB_THUMBTRACK: next = info.nTrackPos; break;
                default: return 0;
            }
            ZnapScrollSettingsPage(page, next);
            return 0;
        }
        case WM_MOUSEWHEEL: {
            SCROLLINFO info = { sizeof(info), SIF_POS };
            GetScrollInfo(page, SB_VERT, &info);
            const int notches = GET_WHEEL_DELTA_WPARAM(wparam) / WHEEL_DELTA;
            ZnapScrollSettingsPage(page, info.nPos - notches * ZnapScale(84));
            return 0;
        }
        case WM_COMMAND:
        case WM_DRAWITEM:
        case WM_CTLCOLORSTATIC:
        case WM_CTLCOLOREDIT:
        case WM_CTLCOLORBTN:
            return SendMessageW(znap_settings_window, message, wparam, lparam);
        default:
            return DefWindowProcW(page, message, wparam, lparam);
    }
}

static void ZnapLayoutSettingsWindow(HWND window) {
    RECT client;
    GetClientRect(window, &client);
    const int margin = ZnapScale(16);
    const int navigation_width = ZnapScale(ZNAP_NAVIGATION_WIDTH);
    const int page_x = navigation_width + margin;
    const int page_width = max(0, client.right - page_x);
    SetWindowPos(znap_settings_navigation, NULL, 0, 0, navigation_width, client.bottom,
        SWP_NOZORDER | SWP_NOACTIVATE);
    SetWindowPos(znap_general_page, NULL, page_x, 0, page_width, client.bottom,
        SWP_NOZORDER | SWP_NOACTIVATE);
    SetWindowPos(znap_keybinds_page, NULL, page_x, 0, page_width, client.bottom,
        SWP_NOZORDER | SWP_NOACTIVATE);
}

static void ZnapSetStartupCheckboxes(BOOL normal_enabled, BOOL admin_enabled) {
    SendMessageW(znap_startup_normal, BM_SETCHECK, normal_enabled ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(znap_startup_admin, BM_SETCHECK, admin_enabled ? BST_CHECKED : BST_UNCHECKED, 0);
}

static BOOL ZnapApplyStartupCheckboxChange(UINT id, BOOL enabled, BOOL previous_normal, BOOL previous_admin) {
    if (!enabled) {
        return ZnapSetStartupOption(id == ZNAP_STARTUP_NORMAL ? 0 : 1, FALSE);
    }

    if (id == ZNAP_STARTUP_NORMAL) {
        if (previous_admin && !ZnapSetStartupOption(1, FALSE)) return FALSE;
        if (ZnapSetStartupOption(0, TRUE)) return TRUE;
        if (previous_admin) ZnapSetStartupOption(1, TRUE);
        return FALSE;
    }

    if (!ZnapSetStartupOption(1, TRUE)) return FALSE;
    if (!previous_normal || ZnapSetStartupOption(0, FALSE)) return TRUE;
    ZnapSetStartupOption(1, FALSE);
    return FALSE;
}

static LRESULT CALLBACK ZnapSettingsProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
        case WM_ERASEBKGND: {
            RECT client;
            GetClientRect(window, &client);
            HBRUSH brush = znap_settings_background_brush != NULL
                ? znap_settings_background_brush : GetSysColorBrush(COLOR_BTNFACE);
            FillRect((HDC)wparam, &client, brush);
            return 1;
        }
        case WM_MEASUREITEM: {
            MEASUREITEMSTRUCT *measure = (MEASUREITEMSTRUCT *)lparam;
            if (measure->CtlID == ZNAP_SETTINGS_NAVIGATION) {
                measure->itemHeight = (UINT)ZnapScale(ZNAP_NAVIGATION_ITEM_HEIGHT);
                return TRUE;
            }
            break;
        }
        case WM_DRAWITEM: {
            DRAWITEMSTRUCT *draw = (DRAWITEMSTRUCT *)lparam;
            for (UINT row = 0; row < znap_settings_row_count; row++) {
                if (draw->hwndItem == znap_settings_rows[row].warning) {
                    ZnapDrawInfoIcon(draw);
                    return TRUE;
                }
            }
            if (draw->CtlID != ZNAP_SETTINGS_NAVIGATION || draw->itemID == (UINT)-1) break;
            const BOOL selected = (draw->itemState & ODS_SELECTED) != 0;
            const COLORREF selected_color = znap_settings_high_contrast
                ? GetSysColor(COLOR_HIGHLIGHT) : (znap_settings_dark ? RGB(62, 54, 68) : RGB(225, 225, 225));
            HBRUSH selected_brush = selected && !znap_settings_high_contrast
                ? CreateSolidBrush(selected_color) : NULL;
            HBRUSH background = selected
                ? (znap_settings_high_contrast ? GetSysColorBrush(COLOR_HIGHLIGHT) : selected_brush)
                : (znap_navigation_background_brush != NULL ? znap_navigation_background_brush : GetSysColorBrush(COLOR_BTNFACE));
            FillRect(draw->hDC, &draw->rcItem, background);

            WCHAR text[64] = {0};
            SendMessageW(draw->hwndItem, LB_GETTEXT, draw->itemID, (LPARAM)text);
            SetBkMode(draw->hDC, TRANSPARENT);
            SetTextColor(draw->hDC, selected && znap_settings_high_contrast
                ? GetSysColor(COLOR_HIGHLIGHTTEXT) : znap_settings_text_color);
            HFONT font = znap_navigation_font != NULL ? znap_navigation_font : znap_settings_font;
            HFONT previous_font = font != NULL ? SelectObject(draw->hDC, font) : NULL;
            RECT text_bounds = draw->rcItem;
            text_bounds.left += ZnapScale(18);
            DrawTextW(draw->hDC, text, -1, &text_bounds, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);
            if (previous_font != NULL) SelectObject(draw->hDC, previous_font);
            if ((draw->itemState & ODS_FOCUS) != 0) DrawFocusRect(draw->hDC, &draw->rcItem);
            if (selected_brush != NULL) DeleteObject(selected_brush);
            return TRUE;
        }
        case WM_COMMAND: {
            const UINT id = LOWORD(wparam);
            const UINT notification = HIWORD(wparam);
            if (id == ZNAP_SETTINGS_NAVIGATION && notification == LBN_SELCHANGE) {
                const LRESULT selection = SendMessageW(znap_settings_navigation, LB_GETCURSEL, 0, 0);
                if (selection != LB_ERR) ZnapShowSettingsPage((int)selection);
                return 0;
            }
            if ((id == ZNAP_STARTUP_NORMAL || id == ZNAP_STARTUP_ADMIN) && notification == BN_CLICKED) {
                HWND checkbox = id == ZNAP_STARTUP_NORMAL ? znap_startup_normal : znap_startup_admin;
                const BOOL enabled = SendMessageW(checkbox, BM_GETCHECK, 0, 0) == BST_CHECKED;
                const BOOL current_normal = SendMessageW(znap_startup_normal, BM_GETCHECK, 0, 0) == BST_CHECKED;
                const BOOL current_admin = SendMessageW(znap_startup_admin, BM_GETCHECK, 0, 0) == BST_CHECKED;
                const BOOL previous_normal = id == ZNAP_STARTUP_NORMAL ? !enabled : current_normal;
                const BOOL previous_admin = id == ZNAP_STARTUP_ADMIN ? !enabled : current_admin;
                if (!ZnapApplyStartupCheckboxChange(id, enabled, previous_normal, previous_admin)) {
                    ZnapSetStartupCheckboxes(previous_normal, previous_admin);
                    MessageBoxW(window,
                        L"The startup settings could not be updated. The previous selection has been restored.",
                        L"Znap Settings", MB_OK | MB_ICONERROR);
                } else if (enabled) {
                    ZnapSetStartupCheckboxes(id == ZNAP_STARTUP_NORMAL, id == ZNAP_STARTUP_ADMIN);
                }
                return 0;
            }
            if (id >= ZNAP_CYCLE_WIDTH_BASE && id < ZNAP_CYCLE_WIDTH_BASE + ZNAP_CYCLE_GROUP_COUNT * ZNAP_CYCLE_WIDTH_COUNT && notification == BN_CLICKED) {
                const UINT option = id - ZNAP_CYCLE_WIDTH_BASE;
                const UINT group = option / ZNAP_CYCLE_WIDTH_COUNT;
                const UINT width = option % ZNAP_CYCLE_WIDTH_COUNT;
                HWND checkbox = znap_cycle_widths[group][width];
                const BOOL enabled = SendMessageW(checkbox, BM_GETCHECK, 0, 0) == BST_CHECKED;
                if (!enabled) {
                    UINT checked_count = 0;
                    for (UINT index = 0; index < ZNAP_CYCLE_WIDTH_COUNT; index++) {
                        if (SendMessageW(znap_cycle_widths[group][index], BM_GETCHECK, 0, 0) == BST_CHECKED) checked_count++;
                    }
                    if (checked_count == 0) {
                        SendMessageW(checkbox, BM_SETCHECK, BST_CHECKED, 0);
                        MessageBoxW(window, L"At least one width must remain enabled for each cycle.", L"Znap Settings", MB_OK | MB_ICONINFORMATION);
                        return 0;
                    }
                }
                if (!ZnapUpdateCycleWidth(group, width, enabled)) {
                    SendMessageW(checkbox, BM_SETCHECK, enabled ? BST_UNCHECKED : BST_CHECKED, 0);
                    MessageBoxW(window, L"The cycle widths could not be saved. The previous selection has been restored.", L"Znap Settings", MB_OK | MB_ICONERROR);
                }
                return 0;
            }
            if (id == ZNAP_OPEN_WINDOWS_SETTINGS && notification == BN_CLICKED) {
                ShellExecuteW(window, L"open", L"ms-settings:multitasking", NULL, NULL, SW_SHOWNORMAL);
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
                SetTextColor((HDC)wparam, znap_settings_dark ? znap_settings_text_color : GetSysColor(COLOR_INFOTEXT));
                SetBkColor((HDC)wparam, znap_settings_tooltip_color);
                return (LRESULT)(znap_settings_tooltip_brush != NULL
                    ? znap_settings_tooltip_brush : GetSysColorBrush(COLOR_INFOBK));
            }
            for (UINT row = 0; row < znap_settings_row_count; row++) {
                if (znap_settings_rows[row].edit == control) {
                    SetTextColor((HDC)wparam, znap_settings_text_color);
                    SetBkColor((HDC)wparam, znap_settings_surface_color);
                    return (LRESULT)(znap_settings_surface_brush != NULL
                        ? znap_settings_surface_brush : GetSysColorBrush(COLOR_WINDOW));
                }
            }
            SetTextColor((HDC)wparam, znap_settings_text_color);
            SetBkColor((HDC)wparam, znap_settings_background_color);
            return (LRESULT)(znap_settings_background_brush != NULL
                ? znap_settings_background_brush : GetSysColorBrush(COLOR_BTNFACE));
        }
        case WM_CTLCOLORBTN:
            SetTextColor((HDC)wparam, znap_settings_text_color);
            SetBkColor((HDC)wparam, znap_settings_background_color);
            return (LRESULT)(znap_settings_background_brush != NULL
                ? znap_settings_background_brush : GetSysColorBrush(COLOR_BTNFACE));
        case WM_CTLCOLOREDIT:
            SetTextColor((HDC)wparam, znap_settings_text_color);
            SetBkColor((HDC)wparam, znap_settings_surface_color);
            return (LRESULT)(znap_settings_surface_brush != NULL
                ? znap_settings_surface_brush : GetSysColorBrush(COLOR_WINDOW));
        case WM_CTLCOLORLISTBOX:
            SetTextColor((HDC)wparam, znap_settings_text_color);
            SetBkColor((HDC)wparam, znap_navigation_background_color);
            return (LRESULT)(znap_navigation_background_brush != NULL
                ? znap_navigation_background_brush : GetSysColorBrush(COLOR_BTNFACE));
        case WM_THEMECHANGED:
        case WM_SETTINGCHANGE:
            ZnapRefreshSettingsTheme(window);
            ZnapRefreshSettingsFonts(window);
            return 0;
        case WM_DPICHANGED: {
            const UINT new_dpi = LOWORD(wparam);
            const UINT old_dpi = znap_settings_dpi;
            RECT *suggested = (RECT *)lparam;
            ZnapScrollSettingsPage(znap_general_page, 0);
            ZnapScrollSettingsPage(znap_keybinds_page, 0);
            znap_settings_dpi = new_dpi;
            if (old_dpi != 0 && new_dpi != old_dpi) {
                ZnapDpiScaleContext context = { old_dpi, new_dpi };
                EnumChildWindows(window, ZnapScaleChildForDpi, (LPARAM)&context);
                ZnapRefreshSettingsFonts(window);
            }
            SetWindowPos(window, NULL, suggested->left, suggested->top,
                suggested->right - suggested->left, suggested->bottom - suggested->top,
                SWP_NOZORDER | SWP_NOACTIVATE);
            return 0;
        }
        case WM_SIZE:
            ZnapLayoutSettingsWindow(window);
            return 0;
        case WM_TIMER:
            if (wparam == ZNAP_TOOLTIP_TIMER) ZnapPollCollisionTooltip();
            return 0;
        case WM_GETMINMAXINFO: {
            MINMAXINFO *limits = (MINMAXINFO *)lparam;
            limits->ptMinTrackSize.x = ZnapScale(ZNAP_SETTINGS_WIDTH);
            limits->ptMinTrackSize.y = ZnapScale(520);
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
            for (UINT other_row = 0; lparam != 0 && other_row < znap_settings_row_count; other_row++) {
                ZnapSettingsRowState *other = &znap_settings_rows[other_row];
                if (other_row != (UINT)row && other->modifiers == (UINT)wparam && other->key == (UINT)lparam) {
                    other->modifiers = 0;
                    other->key = 0;
                    ZnapRefreshSettingsRow(other_row);
                }
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
            if (znap_navigation_font != NULL) {
                DeleteObject(znap_navigation_font);
                znap_navigation_font = NULL;
            }
            if (znap_section_font != NULL) {
                DeleteObject(znap_section_font);
                znap_section_font = NULL;
            }
            if (znap_info_text_font != NULL) {
                DeleteObject(znap_info_text_font);
                znap_info_text_font = NULL;
            }
            if (znap_settings_font != NULL) {
                DeleteObject(znap_settings_font);
                znap_settings_font = NULL;
            }
            ZnapDeleteSettingsBrushes();
            znap_settings_window = NULL;
            znap_settings_navigation = NULL;
            znap_general_page = NULL;
            znap_keybinds_page = NULL;
            znap_startup_normal = NULL;
            znap_startup_admin = NULL;
            znap_startup_info = NULL;
            ZeroMemory(znap_cycle_widths, sizeof(znap_cycle_widths));
            znap_section_header_count = 0;
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
    window_class.hbrBackground = NULL;
    window_class.lpszClassName = ZNAP_SETTINGS_CLASS;
    RegisterClassExW(&window_class);

    WNDCLASSEXW page_class = {0};
    page_class.cbSize = sizeof(page_class);
    page_class.lpfnWndProc = ZnapSettingsPageProc;
    page_class.hInstance = instance;
    page_class.hCursor = LoadCursorW(NULL, IDC_ARROW);
    page_class.hbrBackground = NULL;
    page_class.lpszClassName = ZNAP_SETTINGS_PAGE_CLASS;
    RegisterClassExW(&page_class);
}

void ZnapShowSettingsDialog(HINSTANCE instance, HWND owner, const ZnapKeymapRow *rows, UINT row_count, UINT general_count, BOOL show_snap_warning, BOOL startup_enabled, BOOL admin_startup_enabled, UINT edge_cycles, UINT corner_cycles, UINT center_cycles) {
    if (znap_settings_window != NULL) {
        ShowWindow(znap_settings_window, SW_RESTORE);
        SetForegroundWindow(znap_settings_window);
        return;
    }
    if (row_count > ZNAP_MAX_KEYMAPS) row_count = ZNAP_MAX_KEYMAPS;
    INITCOMMONCONTROLSEX common_controls = { sizeof(common_controls), ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&common_controls);
    znap_settings_dpi = GetDpiForSystem();
    if (znap_settings_dpi == 0) znap_settings_dpi = 96;
    ZnapEnsureSettingsClass(instance);
    znap_settings_window = CreateWindowExW(WS_EX_DLGMODALFRAME, ZNAP_SETTINGS_CLASS, L"Znap Settings", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
        CW_USEDEFAULT, CW_USEDEFAULT, ZnapScale(ZNAP_SETTINGS_WIDTH), ZnapScale(ZNAP_SETTINGS_HEIGHT), owner, NULL, instance, NULL);
    if (znap_settings_window == NULL) return;
    const UINT window_dpi = GetDpiForWindow(znap_settings_window);
    if (window_dpi != 0 && window_dpi != znap_settings_dpi) {
        znap_settings_dpi = window_dpi;
        SetWindowPos(znap_settings_window, NULL, 0, 0,
            ZnapScale(ZNAP_SETTINGS_WIDTH), ZnapScale(ZNAP_SETTINGS_HEIGHT),
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
    znap_settings_row_count = row_count;
    ZnapRefreshSettingsTheme(znap_settings_window);
    ZnapRefreshSettingsFonts(znap_settings_window);
    znap_settings_tooltip = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"STATIC", znap_collision_tooltip,
        WS_POPUP | WS_BORDER | SS_LEFT, 0, 0, ZnapScale(500), ZnapScale(ZNAP_TOOLTIP_HEIGHT), znap_settings_window, NULL, instance, NULL);
    if (znap_settings_tooltip != NULL) {
        SendMessageW(znap_settings_tooltip, WM_SETFONT, (WPARAM)znap_settings_font, TRUE);
        SetWindowSubclass(znap_settings_tooltip, ZnapCollisionTooltipProc, 1, 0);
    }

    znap_settings_navigation = ZnapCreateSettingsControl(0, L"LISTBOX", L"",
        LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | WS_TABSTOP,
        0, 0, ZNAP_NAVIGATION_WIDTH, ZNAP_SETTINGS_HEIGHT,
        znap_settings_window, ZNAP_SETTINGS_NAVIGATION);
    SendMessageW(znap_settings_navigation, WM_SETFONT, (WPARAM)znap_navigation_font, FALSE);
    SendMessageW(znap_settings_navigation, LB_SETITEMHEIGHT, 0, ZnapScale(ZNAP_NAVIGATION_ITEM_HEIGHT));
    SendMessageW(znap_settings_navigation, LB_ADDSTRING, 0, (LPARAM)L"General");
    SendMessageW(znap_settings_navigation, LB_ADDSTRING, 0, (LPARAM)L"Keybinds");
    SendMessageW(znap_settings_navigation, LB_SETCURSEL, 0, 0);

    znap_general_page = CreateWindowExW(0, ZNAP_SETTINGS_PAGE_CLASS, L"",
        WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_CLIPCHILDREN,
        242, 16, 720, 640, znap_settings_window, NULL, instance, NULL);
    znap_keybinds_page = CreateWindowExW(0, ZNAP_SETTINGS_PAGE_CLASS, L"",
        WS_CHILD | WS_VSCROLL | WS_CLIPCHILDREN,
        242, 16, 720, 640, znap_settings_window, NULL, instance, NULL);
    ZnapApplyThemeToChild(znap_general_page, 0);
    ZnapApplyThemeToChild(znap_keybinds_page, 0);

    int startup_y = 20;
    if (show_snap_warning) {
        ZnapCreateSettingsHeader(L"Windows snapping", 20, znap_general_page);
        ZnapCreateSettingsControl(0, L"STATIC", L"Znap can have compatibility issues with Windows default window snapping functionality. It is recommended to disable window snapping from Windows settings for the best user experience.", SS_LEFT, 20, 56, 650, 48, znap_general_page, 0);
        ZnapCreateSettingsControl(0, L"BUTTON", L"Open Windows Settings", BS_PUSHBUTTON | WS_TABSTOP, 20, 118, 190, 32, znap_general_page, ZNAP_OPEN_WINDOWS_SETTINGS);
        ZnapCreateSettingsControl(0, L"STATIC", L"", SS_ETCHEDHORZ, 20, 166, 650, 2, znap_general_page, 0);
        startup_y = 186;
    }

    ZnapCreateSettingsHeader(L"Startup", startup_y, znap_general_page);
    znap_startup_normal = ZnapCreateLargeCheckbox(L"Run on startup",
        startup_y + 36, znap_general_page, ZNAP_STARTUP_NORMAL);
    znap_startup_admin = ZnapCreateLargeCheckbox(L"Run on startup as administrator",
        startup_y + 70, znap_general_page, ZNAP_STARTUP_ADMIN);
    SendMessageW(znap_startup_normal, BM_SETCHECK, startup_enabled && !admin_startup_enabled ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(znap_startup_admin, BM_SETCHECK, admin_startup_enabled ? BST_CHECKED : BST_UNCHECKED, 0);
    znap_startup_info = ZnapCreateSettingsControl(0, L"STATIC",
        L"The Znap process will start up quicker on Windows startup, running as administrator. It also enables snapping application windows running under administrator priviliges.",
        SS_LEFT, 58, startup_y + 106, 600, 54, znap_general_page, 0);
    if (znap_startup_info != NULL && znap_info_text_font != NULL) {
        SendMessageW(znap_startup_info, WM_SETFONT, (WPARAM)znap_info_text_font, TRUE);
    }
    const WCHAR *cycle_titles[ZNAP_CYCLE_GROUP_COUNT] = {
        L"Edge snap/cycle widths",
        L"Corner snap/cycle widths",
        L"Center cycle widths",
    };
    const WCHAR *cycle_labels[ZNAP_CYCLE_WIDTH_COUNT] = { L"1/4", L"1/3", L"1/2", L"2/3", L"3/4" };
    const UINT cycle_masks[ZNAP_CYCLE_GROUP_COUNT] = { edge_cycles, corner_cycles, center_cycles };
    int cycle_y = startup_y + 176;
    for (UINT group = 0; group < ZNAP_CYCLE_GROUP_COUNT; group++) {
        ZnapCreateSettingsControl(0, L"STATIC", L"", SS_ETCHEDHORZ, 20, cycle_y, 650, 2, znap_general_page, 0);
        ZnapCreateSettingsHeader(cycle_titles[group], cycle_y + 20, znap_general_page);
        for (UINT width = 0; width < ZNAP_CYCLE_WIDTH_COUNT; width++) {
            const UINT id = ZNAP_CYCLE_WIDTH_BASE + group * ZNAP_CYCLE_WIDTH_COUNT + width;
            HWND checkbox = ZnapCreateLargeCheckbox(cycle_labels[width], cycle_y + 56 + (int)width * 34, znap_general_page, id);
            znap_cycle_widths[group][width] = checkbox;
            SendMessageW(checkbox, BM_SETCHECK, cycle_masks[group] & (1u << width) ? BST_CHECKED : BST_UNCHECKED, 0);
        }
        cycle_y += 238;
    }
    znap_general_content_height = cycle_y;

    int y = 20;
    ZnapCreateSettingsHeader(L"Navigation", y, znap_keybinds_page);
    y += 32 + ZNAP_SECTION_CONTENT_PADDING;

    for (UINT row = 0; row < row_count; row++) {
        if (row == general_count) {
            y += 18;
            ZnapCreateSettingsHeader(L"Snapshots", y, znap_keybinds_page);
            y += 32 + ZNAP_SECTION_CONTENT_PADDING;
        }
        const int label_width = 260;
        const int control_height = ZNAP_KEYMAP_CONTROL_HEIGHT;
        WCHAR snapshot_label[64];
        const WCHAR *label = ZnapActionLabel(rows[row].action);
        if (row >= general_count) {
            wsprintfW(snapshot_label, rows[row].action == ZNAP_ACTION_STORE_SNAPSHOT ? L"Store snapshot %u:" : L"Recall snapshot %u:", rows[row].snapshot_index + 1);
            label = snapshot_label;
        }
        ZnapCreateSettingsControl(0, L"STATIC", label, SS_RIGHT, 20, y + 4, label_width, 22, znap_keybinds_page, 0);
        znap_settings_rows[row].edit = ZnapCreateSettingsControl(WS_EX_CLIENTEDGE, L"EDIT", L"", ES_READONLY | ES_AUTOHSCROLL | WS_TABSTOP, 290, y, 250, control_height, znap_keybinds_page, ZNAP_KEYMAP_CONTROL_BASE + row);
        znap_settings_rows[row].warning = ZnapCreateSettingsControl(0, L"STATIC", L"", SS_OWNERDRAW | SS_NOTIFY, 550, y, 32, 27, znap_keybinds_page, 0);
        znap_settings_rows[row].index = rows[row].index;
        znap_settings_rows[row].modifiers = rows[row].modifiers;
        znap_settings_rows[row].key = rows[row].key;
        ZnapRefreshSettingsRow(row);
        y += 32;
    }
    znap_keybinds_content_height = y + 20;
    ZnapLayoutSettingsWindow(znap_settings_window);
    ZnapUpdatePageScrollbar(znap_general_page);
    ZnapUpdatePageScrollbar(znap_keybinds_page);
    ZnapShowSettingsPage(0);

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
