const std = @import("std");
const c = @import("win32");
const geometry = @import("geometry.zig");

comptime {
    @setEvalBranchQuota(20_000);
}

const app_name = std.unicode.utf8ToUtf16LeStringLiteral("Znap");
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Znap.MessageWindow");
const documentation_url = std.unicode.utf8ToUtf16LeStringLiteral("https://github.com/peter-erikson/znap");
const startup_key = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run");
const startup_value = std.unicode.utf8ToUtf16LeStringLiteral("Znap");
const single_instance_mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\Znap.SingleInstance");
const already_running_message = std.unicode.utf8ToUtf16LeStringLiteral("Znap is already running.");

const tray_message = c.WM_APP + 1;
const tray_id = 1;
const menu_documentation = 1001;
const menu_startup = 1002;
const menu_quit = 1003;

const HotkeyAction = enum {
    edge_left,
    edge_right,
    edge_top,
    edge_bottom,
    corner_top_left,
    corner_top_right,
    corner_bottom_left,
    corner_bottom_right,
    maximize,
    center,
    always_on_top,
};

const Hotkey = struct {
    id: i32,
    modifiers: u32,
    key: u32,
    action: HotkeyAction,
    description: [*:0]const u16,
};

const mod_alt: u32 = 0x0001;
const mod_control: u32 = 0x0002;
const mod_shift: u32 = 0x0004;
const mod_win: u32 = 0x0008;
const mod_norepeat: u32 = 0x4000;

const hotkeys = hotkeys: {
    @setEvalBranchQuota(20_000);
    break :hotkeys [_]Hotkey{
        .{ .id = 1, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = c.VK_LEFT, .action = .edge_left, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + Left") },
        .{ .id = 2, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = c.VK_RIGHT, .action = .edge_right, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + Right") },
        .{ .id = 3, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = c.VK_UP, .action = .edge_top, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + Up") },
        .{ .id = 4, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = c.VK_DOWN, .action = .edge_bottom, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + Down") },
        .{ .id = 5, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = c.VK_INSERT, .action = .corner_top_left, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + Insert") },
        .{ .id = 6, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = c.VK_DELETE, .action = .corner_bottom_left, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + Delete") },
        .{ .id = 7, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = c.VK_PRIOR, .action = .corner_top_right, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + Page Up") },
        .{ .id = 8, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = c.VK_NEXT, .action = .corner_bottom_right, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + Page Down") },
        .{ .id = 50, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = 'F', .action = .maximize, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + F") },
        .{ .id = 51, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = c.VK_RETURN, .action = .maximize, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + Enter") },
        .{ .id = 60, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = c.VK_OEM_5, .action = .center, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + \\") },
        .{ .id = 61, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = 'C', .action = .center, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + C") },
        .{ .id = 70, .modifiers = mod_control | mod_alt | mod_win | mod_norepeat, .key = 'A', .action = .always_on_top, .description = std.unicode.utf8ToUtf16LeStringLiteral("Win + Ctrl + Alt + A") },
    };
};

var message_window: c.HWND = null;
var tray_data: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
var last_resized: c.HWND = null;
var edge_turns = [_]u2{0} ** 4;
var corner_turns = [_]u2{0} ** 4;
var center_turn: u2 = 0;

pub fn main() !void {
    const single_instance_mutex = c.CreateMutexW(null, c.TRUE, single_instance_mutex_name);
    if (single_instance_mutex == null) return error.CreateSingleInstanceMutexFailed;
    defer _ = c.CloseHandle(single_instance_mutex);

    if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) {
        _ = c.MessageBoxW(null, already_running_message, app_name, c.MB_OK | c.MB_ICONINFORMATION);
        return;
    }

    _ = c.SetProcessDpiAwarenessContext(c.ZnapPerMonitorV2());

    const instance = c.GetModuleHandleW(null);
    var window_class: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    window_class.cbSize = @sizeOf(c.WNDCLASSEXW);
    window_class.lpfnWndProc = windowProc;
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name;
    if (c.RegisterClassExW(&window_class) == 0) return error.RegisterWindowClassFailed;

    message_window = c.CreateWindowExW(0, class_name, app_name, 0, 0, 0, 0, 0, null, null, instance, null);
    if (message_window == null) return error.CreateMessageWindowFailed;

    addTrayIcon(instance) catch |err| {
        std.log.err("failed to add notification-area icon: {s}", .{@errorName(err)});
        return err;
    };
    defer _ = c.Shell_NotifyIconW(c.NIM_DELETE, &tray_data);

    registerHotkeys();
    defer {
        for (hotkeys) |hotkey| _ = c.UnregisterHotKey(message_window, hotkey.id);
    }

    var message: c.MSG = undefined;
    while (true) {
        const result = c.GetMessageW(&message, null, 0, 0);
        if (result == -1) return error.GetMessageFailed;
        if (result == 0) break;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    switch (message) {
        c.WM_HOTKEY => handleHotkey(@intCast(wparam)),
        tray_message => handleTrayMessage(hwnd, lparam),
        c.WM_DESTROY => c.PostQuitMessage(0),
        else => return c.DefWindowProcW(hwnd, message, wparam, lparam),
    }
    return 0;
}

fn registerHotkeys() void {
    var failed: [hotkeys.len]Hotkey = undefined;
    var failed_count: usize = 0;
    for (hotkeys) |hotkey| {
        if (c.RegisterHotKey(message_window, hotkey.id, hotkey.modifiers, hotkey.key) == 0) {
            failed[failed_count] = hotkey;
            failed_count += 1;
        }
    }
    if (failed_count == 0) return;

    var text: [2048]u16 = [_]u16{0} ** 2048;
    const heading = std.unicode.utf8ToUtf16LeStringLiteral("These hotkeys are already in use and could not be registered:\r\n\r\n");
    var used: usize = 0;
    appendUtf16(&text, &used, heading);
    for (failed[0..failed_count]) |hotkey| {
        appendUtf16(&text, &used, std.unicode.utf8ToUtf16LeStringLiteral("  - "));
        appendUtf16(&text, &used, std.mem.span(hotkey.description));
        appendUtf16(&text, &used, std.unicode.utf8ToUtf16LeStringLiteral("\r\n"));
    }
    _ = c.MessageBoxW(message_window, &text, app_name, c.MB_OK | c.MB_ICONWARNING);
}

fn appendUtf16(buffer: []u16, used: *usize, value: []const u16) void {
    const amount = @min(value.len, buffer.len - used.* - 1);
    @memcpy(buffer[used.*..][0..amount], value[0..amount]);
    used.* += amount;
    buffer[used.*] = 0;
}

fn handleHotkey(id: i32) void {
    for (hotkeys) |hotkey| {
        if (hotkey.id != id) continue;
        switch (hotkey.action) {
            .edge_left => cycleEdge(0),
            .edge_right => cycleEdge(1),
            .edge_top => cycleEdge(2),
            .edge_bottom => cycleEdge(3),
            .corner_top_left => cycleCorner(0),
            .corner_top_right => cycleCorner(1),
            .corner_bottom_left => cycleCorner(2),
            .corner_bottom_right => cycleCorner(3),
            .maximize => {
                resetCycles();
                const hwnd = c.GetForegroundWindow();
                if (isZonableWindow(hwnd)) _ = c.ShowWindow(hwnd, c.SW_MAXIMIZE);
            },
            .center => cycleCenter(),
            .always_on_top => toggleAlwaysOnTop(c.GetForegroundWindow()),
        }
        return;
    }
}

const edge_cycles = [4][3]geometry.Placement{
    .{ .left_half, .left_two_thirds, .left_one_third },
    .{ .right_half, .right_two_thirds, .right_one_third },
    .{ .top_half, .top_two_thirds, .top_one_third },
    .{ .bottom_half, .bottom_two_thirds, .bottom_one_third },
};

const corner_cycles = [4][3]geometry.Placement{
    .{ .top_left_half, .top_left_two_thirds, .top_left_one_third },
    .{ .top_right_half, .top_right_two_thirds, .top_right_one_third },
    .{ .bottom_left_half, .bottom_left_two_thirds, .bottom_left_one_third },
    .{ .bottom_right_half, .bottom_right_two_thirds, .bottom_right_one_third },
};

const center_cycles = [3]geometry.Placement{ .center_half, .center_two_thirds, .center_one_third };

fn cycleEdge(index: usize) void {
    const hwnd = c.GetForegroundWindow();
    if (hwnd == null) return;
    if (hwnd != last_resized) edge_turns = [_]u2{0} ** 4;
    if (resizeWindow(hwnd, edge_cycles[index][edge_turns[index]])) {
        edge_turns[index] = @intCast((edge_turns[index] + 1) % 3);
        center_turn = 0;
        for (&edge_turns, 0..) |*turn, i| {
            if (i != index) turn.* = 0;
        }
    }
}

fn cycleCorner(index: usize) void {
    const hwnd = c.GetForegroundWindow();
    if (hwnd == null) return;
    if (hwnd != last_resized) corner_turns = [_]u2{0} ** 4;
    if (resizeWindow(hwnd, corner_cycles[index][corner_turns[index]])) {
        corner_turns[index] = @intCast((corner_turns[index] + 1) % 3);
        center_turn = 0;
        for (&corner_turns, 0..) |*turn, i| {
            if (i != index) turn.* = 0;
        }
    }
}

fn cycleCenter() void {
    const hwnd = c.GetForegroundWindow();
    if (hwnd == null) return;
    if (hwnd != last_resized) center_turn = 0;
    if (resizeWindow(hwnd, center_cycles[center_turn])) {
        center_turn = @intCast((center_turn + 1) % 3);
        edge_turns = [_]u2{0} ** 4;
        corner_turns = [_]u2{0} ** 4;
    }
}

fn resetCycles() void {
    last_resized = null;
    edge_turns = [_]u2{0} ** 4;
    corner_turns = [_]u2{0} ** 4;
    center_turn = 0;
}

fn resizeWindow(hwnd: c.HWND, placement: geometry.Placement) bool {
    if (!isZonableWindow(hwnd)) return false;

    var window_rect: c.RECT = undefined;
    if (c.GetWindowRect(hwnd, &window_rect) == 0) return false;
    const monitor = c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST);
    if (monitor == null) return false;
    var monitor_info: c.MONITORINFO = std.mem.zeroes(c.MONITORINFO);
    monitor_info.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(monitor, &monitor_info) == 0) return false;

    var frame = window_rect;
    _ = c.DwmGetWindowAttribute(hwnd, c.DWMWA_EXTENDED_FRAME_BOUNDS, &frame, @sizeOf(c.RECT));
    const current = fromWinRect(frame);
    const display = fromWinRect(monitor_info.rcWork);
    var target = geometry.place(placement, display, current);

    // Compensate for the invisible resize borders excluded by DWM frame bounds.
    target.left -= frame.left - window_rect.left;
    target.top -= frame.top - window_rect.top;
    target.right += window_rect.right - frame.right;
    target.bottom += window_rect.bottom - frame.bottom;

    _ = c.ShowWindow(hwnd, c.SW_RESTORE);
    const ok = c.SetWindowPos(hwnd, null, target.left, target.top, target.width(), target.height(), c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0;
    if (ok) last_resized = hwnd;
    return ok;
}

fn fromWinRect(rect: c.RECT) geometry.Rect {
    return .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.bottom };
}

fn toggleAlwaysOnTop(hwnd: c.HWND) void {
    if (!isZonableWindow(hwnd)) return;
    const style: u32 = @bitCast(c.GetWindowLongW(hwnd, c.GWL_EXSTYLE));
    const insert_after: c.HWND = if ((style & c.WS_EX_TOPMOST) != 0) c.ZnapHwndNotopmost() else c.ZnapHwndTopmost();
    _ = c.SetWindowPos(hwnd, insert_after, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
}

fn isZonableWindow(hwnd: c.HWND) bool {
    if (hwnd == null or c.GetAncestor(hwnd, c.GA_ROOT) != hwnd or c.IsWindowVisible(hwnd) == 0) return false;
    if (hwnd == c.GetDesktopWindow() or hwnd == c.GetShellWindow()) return false;

    const style: u32 = @bitCast(c.GetWindowLongW(hwnd, c.GWL_STYLE));
    const ex_style: u32 = @bitCast(c.GetWindowLongW(hwnd, c.GWL_EXSTYLE));
    if ((style & c.WS_CHILD) != 0 or (style & c.WS_DISABLED) != 0) return false;
    if ((ex_style & c.WS_EX_TOOLWINDOW) != 0 or (ex_style & c.WS_EX_NOACTIVATE) != 0) return false;
    if ((style & c.WS_POPUP) != 0 and (style & c.WS_THICKFRAME) != 0 and (style & (c.WS_MINIMIZEBOX | c.WS_MAXIMIZEBOX)) == 0) return false;

    const owner = c.GetWindow(hwnd, c.GW_OWNER);
    if (owner != null and c.IsWindowVisible(owner) != 0) {
        var owner_rect: c.RECT = undefined;
        if (c.GetWindowRect(owner, &owner_rect) == 0 or (owner_rect.right - owner_rect.left != 0 and owner_rect.bottom - owner_rect.top != 0)) return false;
    }

    var class_buffer: [256]u16 = [_]u16{0} ** 256;
    const length = c.GetClassNameW(hwnd, &class_buffer, class_buffer.len);
    if (length == 0) return false;
    const name = class_buffer[0..@intCast(length)];
    for (system_class_names) |system_name| if (utf16EqlIgnoreCase(name, system_name)) return false;
    return true;
}

const system_class_names = [_][]const u16{
    std.unicode.utf8ToUtf16LeStringLiteral("SysListView32"),
    std.unicode.utf8ToUtf16LeStringLiteral("WorkerW"),
    std.unicode.utf8ToUtf16LeStringLiteral("Shell_TrayWnd"),
    std.unicode.utf8ToUtf16LeStringLiteral("Shell_SecondaryTrayWnd"),
    std.unicode.utf8ToUtf16LeStringLiteral("Progman"),
};

fn utf16EqlIgnoreCase(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |left_char, right_char| {
        const left = if (left_char >= 'A' and left_char <= 'Z') left_char + ('a' - 'A') else left_char;
        const right = if (right_char >= 'A' and right_char <= 'Z') right_char + ('a' - 'A') else right_char;
        if (left != right) return false;
    }
    return true;
}

fn addTrayIcon(instance: c.HINSTANCE) !void {
    tray_data = std.mem.zeroes(c.NOTIFYICONDATAW);
    tray_data.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    tray_data.hWnd = message_window;
    tray_data.uID = tray_id;
    tray_data.uFlags = c.NIF_MESSAGE | c.NIF_ICON | c.NIF_TIP;
    tray_data.uCallbackMessage = tray_message;
    tray_data.hIcon = c.LoadIconW(instance, @ptrFromInt(2));
    const tooltip = app_name[0..app_name.len];
    @memcpy(tray_data.szTip[0..tooltip.len], tooltip);
    if (c.Shell_NotifyIconW(c.NIM_ADD, &tray_data) == 0) return error.AddTrayIconFailed;
    tray_data.unnamed_0.uVersion = c.NOTIFYICON_VERSION_4;
    _ = c.Shell_NotifyIconW(c.NIM_SETVERSION, &tray_data);
}

fn handleTrayMessage(hwnd: c.HWND, lparam: c.LPARAM) void {
    // NOTIFYICON_VERSION_4 packs the event into LOWORD(lParam) and the icon id
    // into HIWORD(lParam).
    const event: u16 = @truncate(@as(usize, @bitCast(lparam)));
    if (event != c.WM_RBUTTONUP and event != c.WM_CONTEXTMENU and event != c.WM_LBUTTONUP) return;
    showTrayMenu(hwnd);
}

fn showTrayMenu(hwnd: c.HWND) void {
    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);
    _ = c.AppendMenuW(menu, c.MF_STRING, menu_documentation, std.unicode.utf8ToUtf16LeStringLiteral("Documentation"));
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    const startup_flags: c.UINT = if (autoRunEnabled()) 0x00000008 else 0;
    _ = c.AppendMenuW(menu, startup_flags, menu_startup, std.unicode.utf8ToUtf16LeStringLiteral("Run on startup"));
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    _ = c.AppendMenuW(menu, c.MF_STRING, menu_quit, std.unicode.utf8ToUtf16LeStringLiteral("Quit"));

    var point: c.POINT = undefined;
    if (c.GetCursorPos(&point) == 0) return;
    _ = c.SetForegroundWindow(hwnd);
    const command = c.TrackPopupMenu(menu, c.TPM_RETURNCMD | c.TPM_NONOTIFY | c.TPM_RIGHTBUTTON, point.x, point.y, 0, hwnd, null);
    switch (command) {
        menu_documentation => _ = c.ShellExecuteW(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("open"), documentation_url, null, null, c.SW_SHOWNORMAL),
        menu_startup => if (autoRunEnabled()) disableAutoRun() else enableAutoRun(),
        menu_quit => _ = c.DestroyWindow(hwnd),
        else => {},
    }
}

fn autoRunEnabled() bool {
    var key: c.HKEY = null;
    const current_user: c.HKEY = c.ZnapHkeyCurrentUser();
    if (c.RegOpenKeyExW(current_user, startup_key, 0, c.KEY_QUERY_VALUE, &key) != c.ERROR_SUCCESS) return false;
    defer _ = c.RegCloseKey(key);
    var value_type: c.DWORD = 0;
    var bytes: c.DWORD = 0;
    return c.RegQueryValueExW(key, startup_value, null, &value_type, null, &bytes) == c.ERROR_SUCCESS and value_type == c.REG_SZ and bytes > @sizeOf(u16);
}

fn enableAutoRun() void {
    var key: c.HKEY = null;
    const current_user: c.HKEY = c.ZnapHkeyCurrentUser();
    if (c.RegOpenKeyExW(current_user, startup_key, 0, c.KEY_SET_VALUE, &key) != c.ERROR_SUCCESS) return;
    defer _ = c.RegCloseKey(key);

    var executable: [32768]u16 = [_]u16{0} ** 32768;
    const length = c.GetModuleFileNameW(null, &executable, executable.len - 3);
    if (length == 0) return;
    var command: [32768]u16 = [_]u16{0} ** 32768;
    command[0] = '"';
    @memcpy(command[1 .. length + 1], executable[0..length]);
    command[length + 1] = '"';
    command[length + 2] = 0;
    const byte_length: c.DWORD = @intCast((length + 3) * @sizeOf(u16));
    _ = c.RegSetValueExW(key, startup_value, 0, c.REG_SZ, @ptrCast(&command), byte_length);
}

fn disableAutoRun() void {
    var key: c.HKEY = null;
    const current_user: c.HKEY = c.ZnapHkeyCurrentUser();
    if (c.RegOpenKeyExW(current_user, startup_key, 0, c.KEY_SET_VALUE, &key) != c.ERROR_SUCCESS) return;
    defer _ = c.RegCloseKey(key);
    _ = c.RegDeleteValueW(key, startup_value);
}
