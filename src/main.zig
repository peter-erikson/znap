const std = @import("std");
const c = @import("win32");
const geometry = @import("geometry.zig");
const settings = @import("settings.zig");
const window_states = @import("window_states.zig");

// test

comptime {
    @setEvalBranchQuota(20_000);
}

const app_name = std.unicode.utf8ToUtf16LeStringLiteral("Znap");
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Znap.MessageWindow");
const documentation_url = std.unicode.utf8ToUtf16LeStringLiteral("https://github.com/peter-erikson/znap");
const startup_key = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run");
const startup_value = std.unicode.utf8ToUtf16LeStringLiteral("Znap");
const snap_settings_key = std.unicode.utf8ToUtf16LeStringLiteral("Control Panel\\Desktop");
const snap_settings_value = std.unicode.utf8ToUtf16LeStringLiteral("WindowArrangementActive");
const znap_registry_key = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Znap");
const snap_warning_shown_value = std.unicode.utf8ToUtf16LeStringLiteral("WindowsSnapWarningShown");
const single_instance_mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\Znap.SingleInstance");
const already_running_message = std.unicode.utf8ToUtf16LeStringLiteral("Znap is already running.");

const tray_message = c.WM_APP + 1;
const hotkey_message = c.WM_APP + 2;
const tray_id = 1;
const menu_documentation = 1001;
const menu_settings = 1002;
const menu_quit = 1004;

const mod_alt: u32 = 0x0001;
const mod_control: u32 = 0x0002;
const mod_shift: u32 = 0x0004;
const mod_win: u32 = 0x0008;

var message_window: c.HWND = null;
var keyboard_hook: c.HHOOK = null;
var keyboard_hook_ready: c.HANDLE = null;
var keyboard_hook_thread_id: c.DWORD = 0;
var recording_modifiers: u32 = 0;
var suppressed_keys = [_]bool{false} ** 256;
var tray_data: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
var maximize_states: window_states.Store = .{};
var hotkeys: []settings.LoadedKeymap = &.{};
var edge_cycle_mask: u8 = settings.default_cycle_mask;
var corner_cycle_mask: u8 = settings.default_cycle_mask;
var center_cycle_mask: u8 = settings.default_cycle_mask;
var default_edge_cycle_width: settings.CycleWidth = settings.default_cycle_width;
var default_corner_cycle_width: settings.CycleWidth = settings.default_cycle_width;
var default_center_cycle_width: settings.CycleWidth = settings.default_cycle_width;
var app_io: std.Io = undefined;
var app_allocator: std.mem.Allocator = undefined;
var settings_file_path: []const u8 = &.{};

const snapshot_capacity = 64;
const occluder_capacity = 1024;
const snapshot_edge_overlap_tolerance: i32 = 2;
const snapping_match_tolerance: i32 = 2;

const SnapshotEntry = struct {
    hwnd: c.HWND,
    placement: c.WINDOWPLACEMENT,
};

const WindowSnapshot = struct {
    entries: [snapshot_capacity]SnapshotEntry = undefined,
    count: usize = 0,
    focused: c.HWND = null,
    stored: bool = false,
};

const SnapshotCapture = struct {
    monitor: c.HMONITOR,
    entries: [snapshot_capacity]SnapshotEntry = undefined,
    entry_count: usize = 0,
    occluders: [occluder_capacity]c.RECT = undefined,
    occluder_count: usize = 0,
};

const AnimationWindow = struct {
    hwnd: c.HWND,
    left: i32,
    top: i32,
};

var snapshots = [_]WindowSnapshot{.{}} ** 10;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--install-startup-task")) {
        std.process.exit(if (c.ZnapSetStartupTask(c.TRUE) != 0) 0 else 1);
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--remove-startup-task")) {
        std.process.exit(if (c.ZnapSetStartupTask(c.FALSE) != 0) 0 else 1);
    }

    const single_instance_mutex = c.CreateMutexW(null, c.TRUE, single_instance_mutex_name);
    if (single_instance_mutex == null) return error.CreateSingleInstanceMutexFailed;
    defer _ = c.CloseHandle(single_instance_mutex);

    if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) {
        _ = c.MessageBoxW(null, already_running_message, app_name, c.MB_OK | c.MB_ICONINFORMATION);
        return;
    }

    _ = c.SetProcessDpiAwarenessContext(c.ZnapPerMonitorV2());

    app_io = init.io;
    app_allocator = init.gpa;
    const loaded_settings = settings.load(app_io, init.arena.allocator(), init.environ_map) catch |err| {
        std.log.err("failed to load settings: {s}", .{@errorName(err)});
        return err;
    };
    hotkeys = loaded_settings.keymaps;
    edge_cycle_mask = loaded_settings.edge_cycles;
    corner_cycle_mask = loaded_settings.corner_cycles;
    center_cycle_mask = loaded_settings.center_cycles;
    default_edge_cycle_width = loaded_settings.default_edge_cycle_width;
    default_corner_cycle_width = loaded_settings.default_corner_cycle_width;
    default_center_cycle_width = loaded_settings.default_center_cycle_width;
    settings_file_path = loaded_settings.path;

    const instance = c.GetModuleHandleW(null);
    if (windowsSnapEnabled() and !snapWarningShown()) {
        c.ZnapShowSnapWarning(instance);
        markSnapWarningShown();
    }

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

    keyboard_hook_ready = c.CreateEventW(null, c.FALSE, c.FALSE, null);
    if (keyboard_hook_ready == null) return error.CreateKeyboardHookEventFailed;
    defer _ = c.CloseHandle(keyboard_hook_ready);

    const keyboard_hook_thread = try std.Thread.spawn(.{}, keyboardHookThread, .{instance});
    _ = c.WaitForSingleObject(keyboard_hook_ready, c.INFINITE);
    if (keyboard_hook == null) {
        keyboard_hook_thread.join();
        return error.InstallKeyboardHookFailed;
    }
    defer {
        _ = c.PostThreadMessageW(keyboard_hook_thread_id, c.WM_QUIT, 0, 0);
        keyboard_hook_thread.join();
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

fn windowsSnapEnabled() bool {
    var key: c.HKEY = null;
    if (c.RegOpenKeyExW(c.ZnapHkeyCurrentUser(), snap_settings_key, 0, c.KEY_QUERY_VALUE, &key) != c.ERROR_SUCCESS) return false;
    defer _ = c.RegCloseKey(key);

    var value_type: c.DWORD = 0;
    var value: [2]u16 = .{ 0, 0 };
    var byte_count: c.DWORD = @sizeOf(@TypeOf(value));
    const result = c.RegQueryValueExW(key, snap_settings_value, null, &value_type, @ptrCast(&value), &byte_count);
    if (result == c.ERROR_FILE_NOT_FOUND) return true;
    if (result != c.ERROR_SUCCESS) return false;
    return value_type == c.REG_SZ and byte_count >= @sizeOf(u16) and value[0] == '1';
}

fn snapWarningShown() bool {
    var key: c.HKEY = null;
    if (c.RegOpenKeyExW(c.ZnapHkeyCurrentUser(), znap_registry_key, 0, c.KEY_QUERY_VALUE, &key) != c.ERROR_SUCCESS) return false;
    defer _ = c.RegCloseKey(key);

    var value_type: c.DWORD = 0;
    var value: c.DWORD = 0;
    var byte_count: c.DWORD = @sizeOf(c.DWORD);
    return c.RegQueryValueExW(key, snap_warning_shown_value, null, &value_type, @ptrCast(&value), &byte_count) == c.ERROR_SUCCESS and
        value_type == c.REG_DWORD and byte_count == @sizeOf(c.DWORD) and value != 0;
}

fn markSnapWarningShown() void {
    var key: c.HKEY = null;
    if (c.RegCreateKeyExW(
        c.ZnapHkeyCurrentUser(),
        znap_registry_key,
        0,
        null,
        0,
        c.KEY_SET_VALUE,
        null,
        &key,
        null,
    ) != c.ERROR_SUCCESS) return;
    defer _ = c.RegCloseKey(key);

    const value: c.DWORD = 1;
    _ = c.RegSetValueExW(
        key,
        snap_warning_shown_value,
        0,
        c.REG_DWORD,
        @ptrCast(&value),
        @sizeOf(c.DWORD),
    );
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    switch (message) {
        hotkey_message => handleHotkey(@intCast(wparam)),
        tray_message => handleTrayMessage(hwnd, lparam),
        c.WM_DESTROY => c.PostQuitMessage(0),
        else => return c.DefWindowProcW(hwnd, message, wparam, lparam),
    }
    return 0;
}

fn keyboardHookThread(instance: c.HINSTANCE) void {
    keyboard_hook_thread_id = c.GetCurrentThreadId();

    // A thread message queue must exist before the main thread can stop this
    // hook with PostThreadMessageW.
    var message: c.MSG = undefined;
    _ = c.PeekMessageW(&message, null, 0, 0, c.PM_NOREMOVE);

    keyboard_hook = c.SetWindowsHookExW(c.WH_KEYBOARD_LL, keyboardProc, instance, 0);
    _ = c.SetEvent(keyboard_hook_ready);
    if (keyboard_hook == null) return;
    defer _ = c.UnhookWindowsHookEx(keyboard_hook);

    while (c.GetMessageW(&message, null, 0, 0) > 0) {}
}

fn keyboardProc(code: c_int, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    if (code == c.HC_ACTION) {
        const event: *const c.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const is_key_down = wparam == c.WM_KEYDOWN or wparam == c.WM_SYSKEYDOWN;
        const is_key_up = wparam == c.WM_KEYUP or wparam == c.WM_SYSKEYUP;

        if (c.ZnapSettingsRecording() != 0) {
            if (modifierForKey(event.vkCode)) |modifier| {
                if (is_key_down) recording_modifiers |= modifier;
                if (is_key_up) recording_modifiers &= ~modifier;
            } else if (is_key_down and event.vkCode == c.VK_BACK) {
                c.ZnapRecordKeymap(0, 0);
            } else if (is_key_down and recording_modifiers != 0) {
                c.ZnapRecordKeymap(recording_modifiers, event.vkCode);
            }
            return 1;
        }
        recording_modifiers = 0;

        if (event.vkCode < suppressed_keys.len) {
            const key_index: usize = @intCast(event.vkCode);

            if (is_key_up and suppressed_keys[key_index]) {
                suppressed_keys[key_index] = false;
                return 1;
            }

            if (is_key_down) {
                for (hotkeys, 0..) |hotkey, hotkey_index| {
                    if (event.vkCode != hotkey.key or currentModifiers() != hotkey.modifiers) continue;
                    if (!suppressed_keys[key_index]) {
                        suppressed_keys[key_index] = true;
                        if (hotkey.modifiers == mod_win) _ = c.ZnapMarkWindowsKeyUsed();
                        _ = c.PostMessageW(message_window, hotkey_message, hotkey_index, 0);
                    }
                    return 1;
                }
            }
        }
    }
    return c.CallNextHookEx(keyboard_hook, code, wparam, lparam);
}

fn modifierForKey(key: u32) ?u32 {
    return switch (key) {
        c.VK_MENU, c.VK_LMENU, c.VK_RMENU => mod_alt,
        c.VK_CONTROL, c.VK_LCONTROL, c.VK_RCONTROL => mod_control,
        c.VK_SHIFT, c.VK_LSHIFT, c.VK_RSHIFT => mod_shift,
        c.VK_LWIN, c.VK_RWIN => mod_win,
        else => null,
    };
}

fn currentModifiers() u32 {
    var modifiers: u32 = 0;
    if (c.GetAsyncKeyState(c.VK_CONTROL) < 0) modifiers |= mod_control;
    if (c.GetAsyncKeyState(c.VK_MENU) < 0) modifiers |= mod_alt;
    if (c.GetAsyncKeyState(c.VK_SHIFT) < 0) modifiers |= mod_shift;
    if (c.GetAsyncKeyState(c.VK_LWIN) < 0 or c.GetAsyncKeyState(c.VK_RWIN) < 0) modifiers |= mod_win;
    return modifiers;
}

fn handleHotkey(id: i32) void {
    if (id < 0 or id >= hotkeys.len) return;
    const hotkey = hotkeys[@intCast(id)];
    switch (hotkey.action) {
        .edge_left => cycleEdge(0),
        .edge_right => cycleEdge(1),
        .edge_top => cycleEdge(2),
        .edge_bottom => cycleEdge(3),
        .corner_top_left => cycleCorner(0),
        .corner_top_right => cycleCorner(1),
        .corner_bottom_left => cycleCorner(2),
        .corner_bottom_right => cycleCorner(3),
        .maximize => toggleMaximize(c.GetForegroundWindow()),
        .center => cycleCenter(),
        .store_snapshot => storeSnapshot(hotkey.snapshot_index),
        .recall_snapshot => recallSnapshot(hotkey.snapshot_index),
    }
}

fn storeSnapshot(snapshot_index: usize) void {
    const focused = c.GetForegroundWindow();
    if (focused == null) return;
    const monitor = c.MonitorFromWindow(focused, c.MONITOR_DEFAULTTONEAREST);
    if (monitor == null) return;

    var capture: SnapshotCapture = .{ .monitor = monitor };
    _ = c.EnumWindows(captureSnapshotWindow, @bitCast(@intFromPtr(&capture)));

    const snapshot = &snapshots[snapshot_index];
    snapshot.count = capture.entry_count;
    @memcpy(snapshot.entries[0..capture.entry_count], capture.entries[0..capture.entry_count]);
    snapshot.focused = null;
    for (snapshot.entries[0..snapshot.count]) |entry| {
        if (entry.hwnd == focused) {
            snapshot.focused = focused;
            break;
        }
    }
    snapshot.stored = true;
    animateStoredSnapshot(snapshot);
}

fn animateStoredSnapshot(snapshot: *const WindowSnapshot) void {
    var windows: [snapshot_capacity]AnimationWindow = undefined;
    var window_count: usize = 0;
    for (snapshot.entries[0..snapshot.count]) |entry| {
        if (c.IsWindow(entry.hwnd) == 0 or !isZonableWindow(entry.hwnd)) continue;
        var bounds: c.RECT = undefined;
        if (c.GetWindowRect(entry.hwnd, &bounds) == 0) continue;
        windows[window_count] = .{ .hwnd = entry.hwnd, .left = bounds.left, .top = bounds.top };
        window_count += 1;
    }
    if (window_count == 0) return;

    const offsets = [_]i32{ 3, 6, 9, 12, 9, 6, 3, 0 };
    const move_flags = c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE;
    for (offsets) |offset| {
        for (windows[0..window_count]) |window| {
            if (c.IsWindow(window.hwnd) == 0) continue;
            _ = c.SetWindowPos(window.hwnd, null, window.left, window.top + offset, 0, 0, move_flags);
        }
        if (offset != 0) c.Sleep(14);
    }
}

fn captureSnapshotWindow(hwnd: c.HWND, lparam: c.LPARAM) callconv(.c) c.BOOL {
    const capture: *SnapshotCapture = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (!isOccludingWindow(hwnd)) return c.TRUE;

    var bounds: c.RECT = undefined;
    if (!getVisibleWindowBounds(hwnd, &bounds)) return c.TRUE;

    const ex_style: u32 = @bitCast(c.GetWindowLongW(hwnd, c.GWL_EXSTYLE));
    // Always-on-top windows are outside snapshot semantics: do not save them,
    // and do not treat them as covering ordinary windows underneath them.
    if ((ex_style & c.WS_EX_TOPMOST) != 0) return c.TRUE;

    const on_current_monitor = c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST) == capture.monitor;
    if (on_current_monitor and
        isZonableWindow(hwnd) and
        !isCovered(bounds, capture.occluders[0..capture.occluder_count]) and
        capture.entry_count < capture.entries.len)
    {
        var placement: c.WINDOWPLACEMENT = std.mem.zeroes(c.WINDOWPLACEMENT);
        placement.length = @sizeOf(c.WINDOWPLACEMENT);
        if (c.GetWindowPlacement(hwnd, &placement) != 0) {
            capture.entries[capture.entry_count] = .{ .hwnd = hwnd, .placement = placement };
            capture.entry_count += 1;
        }
    }

    // EnumWindows visits ordinary windows from highest to lowest Z order, so
    // each one can cover later ordinary windows.
    if (capture.occluder_count == capture.occluders.len) return c.FALSE;
    capture.occluders[capture.occluder_count] = bounds;
    capture.occluder_count += 1;
    return c.TRUE;
}

fn recallSnapshot(snapshot_index: usize) void {
    const snapshot = &snapshots[snapshot_index];
    if (!snapshot.stored) return;
    const previous_focus = c.GetForegroundWindow();

    for (snapshot.entries[0..snapshot.count]) |entry| {
        if (c.IsWindow(entry.hwnd) == 0 or !isZonableWindow(entry.hwnd)) continue;
        var placement = entry.placement;
        placement.length = @sizeOf(c.WINDOWPLACEMENT);
        _ = c.SetWindowPlacement(entry.hwnd, &placement);
        maximize_states.remove(@intFromPtr(entry.hwnd.?));
    }

    // Entries were captured from front to back. Raise them in reverse so the
    // whole snapshot ends above other normal windows in its captured order.
    // Toggling through the topmost band forces Windows to promote windows owned
    // by other processes; HWND_NOTOPMOST immediately restores ordinary status.
    const raise_flags = c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE;
    var index = snapshot.count;
    while (index > 0) {
        index -= 1;
        const hwnd = snapshot.entries[index].hwnd;
        if (c.IsWindow(hwnd) == 0 or !isZonableWindow(hwnd)) continue;
        if (c.SetWindowPos(hwnd, c.ZnapHwndTopmost(), 0, 0, 0, 0, raise_flags) != 0) {
            _ = c.SetWindowPos(hwnd, c.ZnapHwndNotopmost(), 0, 0, 0, 0, raise_flags);
        }
    }

    // Windows does not expose its Alt+Tab MRU list. Perform actual task-switch
    // activations from back to front so Explorer observes each transition in
    // snapshot order. Leave the desired final focus until last.
    const final_focus = if (snapshot.focused != null) snapshot.focused else previous_focus;
    index = snapshot.count;
    while (index > 0) {
        index -= 1;
        const hwnd = snapshot.entries[index].hwnd;
        if (hwnd == final_focus or c.IsWindow(hwnd) == 0 or !isZonableWindow(hwnd)) continue;
        activateForTaskSwitch(hwnd);
    }

    if (final_focus != null and c.IsWindow(final_focus) != 0 and isZonableWindow(final_focus)) {
        if (c.IsIconic(final_focus) != 0) _ = c.ShowWindow(final_focus, c.SW_RESTORE);
        activateForTaskSwitch(final_focus);
    }
}

fn activateForTaskSwitch(hwnd: c.HWND) void {
    c.ZnapSwitchToThisWindow(hwnd);

    // Foreground changes cross process input queues. Wait briefly until the
    // requested window is active, then leave Explorer a frame to record it.
    var attempt: u3 = 0;
    while (attempt < 6 and c.GetForegroundWindow() != hwnd) : (attempt += 1) c.Sleep(5);
    if (c.GetForegroundWindow() != hwnd) _ = c.SetForegroundWindow(hwnd);
    c.Sleep(16);
}

fn isOccludingWindow(hwnd: c.HWND) bool {
    if (hwnd == null or c.IsWindowVisible(hwnd) == 0 or c.IsIconic(hwnd) != 0) return false;
    if (hwnd == c.GetDesktopWindow() or hwnd == c.GetShellWindow()) return false;

    var cloaked: c.DWORD = 0;
    if (c.DwmGetWindowAttribute(hwnd, c.DWMWA_CLOAKED, &cloaked, @sizeOf(c.DWORD)) == 0 and cloaked != 0) return false;
    return true;
}

fn getVisibleWindowBounds(hwnd: c.HWND, bounds: *c.RECT) bool {
    if (c.DwmGetWindowAttribute(hwnd, c.DWMWA_EXTENDED_FRAME_BOUNDS, bounds, @sizeOf(c.RECT)) != 0 and
        c.GetWindowRect(hwnd, bounds) == 0) return false;
    return bounds.right > bounds.left and bounds.bottom > bounds.top;
}

fn isCovered(bounds: c.RECT, occluders: []const c.RECT) bool {
    for (occluders) |occluder| {
        if (geometry.overlapsBeyondTolerance(fromWinRect(bounds), fromWinRect(occluder), snapshot_edge_overlap_tolerance)) return true;
    }
    return false;
}

const edge_cycles = [4][settings.cycle_width_count]geometry.Placement{
    .{ .left_one_quarter, .left_one_third, .left_half, .left_two_thirds, .left_three_quarters },
    .{ .right_one_quarter, .right_one_third, .right_half, .right_two_thirds, .right_three_quarters },
    .{ .top_one_quarter, .top_one_third, .top_half, .top_two_thirds, .top_three_quarters },
    .{ .bottom_one_quarter, .bottom_one_third, .bottom_half, .bottom_two_thirds, .bottom_three_quarters },
};

const corner_cycles = [4][settings.cycle_width_count]geometry.Placement{
    .{ .top_left_one_quarter, .top_left_one_third, .top_left_half, .top_left_two_thirds, .top_left_three_quarters },
    .{ .top_right_one_quarter, .top_right_one_third, .top_right_half, .top_right_two_thirds, .top_right_three_quarters },
    .{ .bottom_left_one_quarter, .bottom_left_one_third, .bottom_left_half, .bottom_left_two_thirds, .bottom_left_three_quarters },
    .{ .bottom_right_one_quarter, .bottom_right_one_third, .bottom_right_half, .bottom_right_two_thirds, .bottom_right_three_quarters },
};

const center_cycles = [settings.cycle_width_count]geometry.Placement{
    .center_one_quarter,
    .center_one_third,
    .center_half,
    .center_two_thirds,
    .center_three_quarters,
};

fn configuredCycle(all: *const [settings.cycle_width_count]geometry.Placement, mask: u8, default_width: settings.CycleWidth, storage: *[settings.cycle_width_count]geometry.Placement) []const geometry.Placement {
    var count: usize = 0;
    for (0..settings.cycle_width_count) |offset| {
        const index = (@intFromEnum(default_width) + offset) % settings.cycle_width_count;
        if (mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
        storage[count] = all[index];
        count += 1;
    }
    std.debug.assert(count > 0);
    return storage[0..count];
}

test "configured cycle starts at the selected default width" {
    var configured: [settings.cycle_width_count]geometry.Placement = undefined;
    const cycle = configuredCycle(&edge_cycles[0], settings.default_cycle_mask, .@"1/2", &configured);
    try std.testing.expectEqualSlices(geometry.Placement, &.{ .left_half, .left_two_thirds, .left_one_third }, cycle);
}

fn cycleEdge(index: usize) void {
    const hwnd = c.GetForegroundWindow();
    if (hwnd == null) return;
    var configured: [settings.cycle_width_count]geometry.Placement = undefined;
    const placement = nextWindowCyclePlacement(hwnd, configuredCycle(&edge_cycles[index], edge_cycle_mask, default_edge_cycle_width, &configured));
    _ = resizeWindow(hwnd, placement);
}

fn cycleCorner(index: usize) void {
    const hwnd = c.GetForegroundWindow();
    if (hwnd == null) return;
    var configured: [settings.cycle_width_count]geometry.Placement = undefined;
    const placement = nextWindowCyclePlacement(hwnd, configuredCycle(&corner_cycles[index], corner_cycle_mask, default_corner_cycle_width, &configured));
    _ = resizeWindow(hwnd, placement);
}

fn nextWindowCyclePlacement(hwnd: c.HWND, cycle: []const geometry.Placement) geometry.Placement {
    const monitor = c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST);
    if (monitor == null) return cycle[0];

    var monitor_info: c.MONITORINFO = std.mem.zeroes(c.MONITORINFO);
    monitor_info.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(monitor, &monitor_info) == 0) return cycle[0];

    var bounds: c.RECT = undefined;
    if (!getVisibleWindowBounds(hwnd, &bounds)) return cycle[0];
    return geometry.nextCyclePlacement(cycle, fromWinRect(bounds), fromWinRect(monitor_info.rcWork), snapping_match_tolerance);
}

fn cycleCenter() void {
    const hwnd = c.GetForegroundWindow();
    if (hwnd == null) return;
    var configured: [settings.cycle_width_count]geometry.Placement = undefined;
    const placement = nextWindowCyclePlacement(hwnd, configuredCycle(&center_cycles, center_cycle_mask, default_center_cycle_width, &configured));
    _ = resizeWindow(hwnd, placement);
}

fn toggleMaximize(hwnd: c.HWND) void {
    if (!isZonableWindow(hwnd)) return;

    const key = @intFromPtr(hwnd.?);
    if (c.IsZoomed(hwnd) != 0) {
        if (maximize_states.get(key)) |bounds| {
            _ = c.ShowWindow(hwnd, c.SW_RESTORE);
            const restored = c.SetWindowPos(hwnd, null, bounds.left, bounds.top, bounds.width(), bounds.height(), c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0;
            if (restored) maximize_states.remove(key);
        } else _ = resizeWindow(hwnd, .center_half);
        return;
    }

    var bounds: c.RECT = undefined;
    if (c.GetWindowRect(hwnd, &bounds) == 0) return;
    maximize_states.remember(key, fromWinRect(bounds));
    _ = c.ShowWindow(hwnd, c.SW_MAXIMIZE);
    if (c.IsZoomed(hwnd) == 0) maximize_states.remove(key);
}

fn resizeWindow(hwnd: c.HWND, placement: geometry.Placement) bool {
    if (!isZonableWindow(hwnd)) return false;

    const monitor = c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST);
    if (monitor == null) return false;
    var monitor_info: c.MONITORINFO = std.mem.zeroes(c.MONITORINFO);
    monitor_info.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(monitor, &monitor_info) == 0) return false;

    // Maximized windows use different invisible frame margins. Restore before
    // measuring them so the compensation below matches the resized window.
    _ = c.ShowWindow(hwnd, c.SW_RESTORE);
    var window_rect: c.RECT = undefined;
    if (c.GetWindowRect(hwnd, &window_rect) == 0) return false;
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

    const ok = c.SetWindowPos(hwnd, null, target.left, target.top, target.width(), target.height(), c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0;
    if (ok) maximize_states.remove(@intFromPtr(hwnd.?));
    return ok;
}

fn fromWinRect(rect: c.RECT) geometry.Rect {
    return .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.bottom };
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
    std.unicode.utf8ToUtf16LeStringLiteral("Znap.SettingsWindow"),
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
    // A logon task can start before Explorer has created its notification
    // area. Give the shell time to finish starting instead of exiting.
    var attempt: u6 = 0;
    while (c.Shell_NotifyIconW(c.NIM_ADD, &tray_data) == 0) : (attempt += 1) {
        if (attempt == 29) return error.AddTrayIconFailed;
        c.Sleep(1000);
    }
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
    _ = c.AppendMenuW(menu, c.MF_STRING, menu_settings, std.unicode.utf8ToUtf16LeStringLiteral("Settings"));
    _ = c.AppendMenuW(menu, c.MF_STRING, menu_documentation, std.unicode.utf8ToUtf16LeStringLiteral("Documentation"));
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    _ = c.AppendMenuW(menu, c.MF_STRING, menu_quit, std.unicode.utf8ToUtf16LeStringLiteral("Quit"));

    var point: c.POINT = undefined;
    if (c.GetCursorPos(&point) == 0) return;
    _ = c.SetForegroundWindow(hwnd);
    const command = c.TrackPopupMenu(menu, c.TPM_RETURNCMD | c.TPM_NONOTIFY | c.TPM_RIGHTBUTTON, point.x, point.y, 0, hwnd, null);
    switch (command) {
        menu_documentation => _ = c.ShellExecuteW(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("open"), documentation_url, null, null, c.SW_SHOWNORMAL),
        menu_settings => showSettingsDialog(hwnd),
        menu_quit => _ = c.DestroyWindow(hwnd),
        else => {},
    }
}

fn showSettingsDialog(owner: c.HWND) void {
    var rows: [256]c.ZnapKeymapRow = undefined;
    var row_count: usize = 0;

    for (hotkeys, 0..) |hotkey, index| {
        if (isSnapshotAction(hotkey.action)) continue;
        rows[row_count] = makeSettingsRow(index, hotkey);
        row_count += 1;
    }
    const general_count = row_count;
    for (hotkeys, 0..) |hotkey, index| {
        if (!isSnapshotAction(hotkey.action)) continue;
        rows[row_count] = makeSettingsRow(index, hotkey);
        row_count += 1;
    }

    const instance = c.GetModuleHandleW(null);
    c.ZnapShowSettingsDialog(
        instance,
        owner,
        if (row_count == 0) null else &rows[0],
        @intCast(row_count),
        @intCast(general_count),
        if (windowsSnapEnabled()) c.TRUE else c.FALSE,
        if (autoRunEnabled()) c.TRUE else c.FALSE,
        if (c.ZnapStartupTaskEnabled() != 0) c.TRUE else c.FALSE,
        edge_cycle_mask,
        corner_cycle_mask,
        center_cycle_mask,
        @intFromEnum(default_edge_cycle_width),
        @intFromEnum(default_corner_cycle_width),
        @intFromEnum(default_center_cycle_width),
    );
}

fn makeSettingsRow(index: usize, hotkey: settings.LoadedKeymap) c.ZnapKeymapRow {
    return .{
        .index = @intCast(index),
        .action = @intFromEnum(hotkey.action),
        .snapshot_index = hotkey.snapshot_index,
        .modifiers = hotkey.modifiers,
        .key = hotkey.key,
    };
}

fn isSnapshotAction(action: settings.Action) bool {
    return action == .store_snapshot or action == .recall_snapshot;
}

pub export fn ZnapUpdateKeymap(index: c.UINT, modifiers: c.UINT, key: c.UINT) c.BOOL {
    if (index >= hotkeys.len) return c.FALSE;
    var previous: [256]settings.LoadedKeymap = undefined;
    @memcpy(previous[0..hotkeys.len], hotkeys);
    settings.updateKeymap(hotkeys, index, modifiers, key);
    saveSettings() catch |err| {
        @memcpy(hotkeys, previous[0..hotkeys.len]);
        std.log.err("failed to save settings: {s}", .{@errorName(err)});
        return c.FALSE;
    };
    return c.TRUE;
}

fn saveSettings() !void {
    try settings.save(
        app_io,
        app_allocator,
        settings_file_path,
        hotkeys,
        edge_cycle_mask,
        corner_cycle_mask,
        center_cycle_mask,
        default_edge_cycle_width,
        default_corner_cycle_width,
        default_center_cycle_width,
    );
}

fn firstEnabledCycleWidth(mask: u8) settings.CycleWidth {
    for (0..settings.cycle_width_count) |index| {
        if (mask & (@as(u8, 1) << @intCast(index)) != 0) return @enumFromInt(index);
    }
    unreachable;
}

pub export fn ZnapUpdateCycleWidth(group: c.UINT, width: c.UINT, enabled: c.BOOL) c.BOOL {
    if (group >= 3 or width >= settings.cycle_width_count) return c.FALSE;
    const mask = switch (group) {
        0 => &edge_cycle_mask,
        1 => &corner_cycle_mask,
        2 => &center_cycle_mask,
        else => unreachable,
    };
    const default_width = switch (group) {
        0 => &default_edge_cycle_width,
        1 => &default_corner_cycle_width,
        2 => &default_center_cycle_width,
        else => unreachable,
    };
    const previous = mask.*;
    const previous_default = default_width.*;
    const bit = @as(u8, 1) << @intCast(width);
    mask.* = if (enabled != 0) previous | bit else previous & ~bit;
    if (mask.* == 0) {
        mask.* = previous;
        return c.FALSE;
    }
    if (mask.* & settings.cycleWidthBit(default_width.*) == 0) default_width.* = firstEnabledCycleWidth(mask.*);
    saveSettings() catch |err| {
        mask.* = previous;
        default_width.* = previous_default;
        std.log.err("failed to save cycle widths: {s}", .{@errorName(err)});
        return c.FALSE;
    };
    return c.TRUE;
}

pub export fn ZnapUpdateDefaultCycleWidth(group: c.UINT, width: c.UINT) c.BOOL {
    if (group >= 3 or width >= settings.cycle_width_count) return c.FALSE;
    const mask = switch (group) {
        0 => edge_cycle_mask,
        1 => corner_cycle_mask,
        2 => center_cycle_mask,
        else => unreachable,
    };
    const default_width = switch (group) {
        0 => &default_edge_cycle_width,
        1 => &default_corner_cycle_width,
        2 => &default_center_cycle_width,
        else => unreachable,
    };
    const selected: settings.CycleWidth = @enumFromInt(width);
    if (mask & settings.cycleWidthBit(selected) == 0) return c.FALSE;
    const previous = default_width.*;
    default_width.* = selected;
    saveSettings() catch |err| {
        default_width.* = previous;
        std.log.err("failed to save default cycle width: {s}", .{@errorName(err)});
        return c.FALSE;
    };
    return c.TRUE;
}

fn autoRunEnabled() bool {
    var key: c.HKEY = null;
    if (c.RegOpenKeyExW(c.ZnapHkeyCurrentUser(), startup_key, 0, c.KEY_QUERY_VALUE, &key) != c.ERROR_SUCCESS) return false;
    defer _ = c.RegCloseKey(key);

    var value_type: c.DWORD = 0;
    var bytes: c.DWORD = 0;
    return c.RegQueryValueExW(key, startup_value, null, &value_type, null, &bytes) == c.ERROR_SUCCESS and
        value_type == c.REG_SZ and bytes > @sizeOf(u16);
}

fn setAutoRun(enabled: bool) bool {
    var key: c.HKEY = null;
    if (c.RegOpenKeyExW(c.ZnapHkeyCurrentUser(), startup_key, 0, c.KEY_SET_VALUE, &key) != c.ERROR_SUCCESS) return false;
    defer _ = c.RegCloseKey(key);

    if (!enabled) {
        const result = c.RegDeleteValueW(key, startup_value);
        return result == c.ERROR_SUCCESS or result == c.ERROR_FILE_NOT_FOUND;
    }

    var executable: [32768]u16 = [_]u16{0} ** 32768;
    const length = c.GetModuleFileNameW(null, &executable, executable.len - 3);
    if (length == 0) return false;
    var command: [32768]u16 = [_]u16{0} ** 32768;
    command[0] = '"';
    @memcpy(command[1 .. length + 1], executable[0..length]);
    command[length + 1] = '"';
    command[length + 2] = 0;
    const byte_length: c.DWORD = @intCast((length + 3) * @sizeOf(u16));
    return c.RegSetValueExW(key, startup_value, 0, c.REG_SZ, @ptrCast(&command), byte_length) == c.ERROR_SUCCESS;
}

pub export fn ZnapSetStartupOption(option: c.UINT, enabled: c.BOOL) c.BOOL {
    const succeeded = switch (option) {
        0 => setAutoRun(enabled != 0),
        1 => c.ZnapSetStartupTaskElevated(enabled) != 0,
        else => false,
    };
    return if (succeeded) c.TRUE else c.FALSE;
}
