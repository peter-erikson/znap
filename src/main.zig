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
const taskbar_created_name = std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated");

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

const SnapIdentity = struct {
    window: usize,
    action: settings.Action,
};

const SnapTransition = enum {
    repeat,
    window_changed,
    method_changed,
};

var message_window: c.HWND = null;
var taskbar_created_message: c.UINT = 0;
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
var smart_fill = true;
var last_snap: ?SnapIdentity = null;
var app_io: std.Io = undefined;
var app_allocator: std.mem.Allocator = undefined;
var settings_file_path: []const u8 = &.{};

const snapshot_capacity = 64;
const snapshot_count = 10;
const snapshot_window_capacity = snapshot_capacity * snapshot_count;
const snapshot_text_capacity = 4096;
const occluder_capacity = 1024;
const snapshot_edge_overlap_tolerance: i32 = 2;
const snapping_match_tolerance: i32 = 2;

const SnapshotEntry = struct {
    hwnd: c.HWND,
    placement: c.WINDOWPLACEMENT,
    application_index: u8 = 0,
};

const SnapshotText = struct {
    bytes: [snapshot_text_capacity]u8 = undefined,
    len: u16 = 0,

    fn slice(self: *const SnapshotText) []const u8 {
        return self.bytes[0..self.len];
    }

    fn setUtf8(self: *SnapshotText, value: []const u8) bool {
        if (value.len > self.bytes.len) return false;
        @memcpy(self.bytes[0..value.len], value);
        self.len = @intCast(value.len);
        return true;
    }

    fn setUtf16(self: *SnapshotText, value: [*:0]const u16) bool {
        const wide_len: c_int = @intCast(std.mem.len(value));
        if (wide_len == 0) {
            self.len = 0;
            return true;
        }
        const converted = c.WideCharToMultiByte(c.CP_UTF8, c.WC_ERR_INVALID_CHARS, value, wide_len, &self.bytes, self.bytes.len, null, null);
        if (converted <= 0) return false;
        self.len = @intCast(converted);
        return true;
    }

    fn toUtf16(self: *const SnapshotText, buffer: []u16) bool {
        if (buffer.len == 0) return false;
        if (self.len == 0) {
            buffer[0] = 0;
            return true;
        }
        const converted = c.MultiByteToWideChar(c.CP_UTF8, c.MB_ERR_INVALID_CHARS, self.bytes[0..self.len].ptr, self.len, buffer.ptr, @intCast(buffer.len - 1));
        if (converted <= 0) return false;
        buffer[@intCast(converted)] = 0;
        return true;
    }
};

const SnapshotApplication = struct {
    window_id: u64 = 0,
    window_id_persisted: bool = false,
    executable: SnapshotText = .{},
    arguments: SnapshotText = .{},
    working_directory: SnapshotText = .{},
    app_user_model_id: SnapshotText = .{},
};

const WindowSnapshot = struct {
    entries: [snapshot_capacity]SnapshotEntry = undefined,
    count: usize = 0,
    focused: c.HWND = null,
    focused_application: ?u8 = null,
    applications: [snapshot_capacity]SnapshotApplication = undefined,
    application_count: usize = 0,
    auto_start: bool = false,
    stored: bool = false,
    layout_persisted: bool = false,
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

var snapshots = [_]WindowSnapshot{.{}} ** snapshot_count;
const RuntimeWindow = struct {
    window_id: u64,
    hwnd: c.HWND,
};
var runtime_windows: [snapshot_window_capacity]RuntimeWindow = undefined;
var runtime_window_count: usize = 0;
var next_window_id: u64 = 1;

fn allocateWindowId() u64 {
    const result = next_window_id;
    next_window_id +%= 1;
    if (next_window_id == 0) next_window_id = 1;
    return result;
}

fn loadWindowId(saved: u64) u64 {
    if (saved == 0) return allocateWindowId();
    if (saved >= next_window_id) {
        next_window_id = saved +% 1;
        if (next_window_id == 0) next_window_id = 1;
    }
    return saved;
}

fn hwndFromStoredValue(saved: u64) c.HWND {
    if (saved == 0) return null;
    const address = std.math.cast(usize, saved) orelse return null;
    return @ptrFromInt(address);
}

fn loadSnapshotSettings(loaded: []const settings.Snapshot) void {
    for (loaded) |saved| {
        const snapshot_index: usize = saved.index;
        if (snapshot_index >= snapshots.len) continue;
        const snapshot = &snapshots[snapshot_index];
        snapshot.application_count = @min(saved.applications.len, snapshot_capacity);
        snapshot.auto_start = saved.auto_start;
        snapshot.stored = true;
        snapshot.count = 0;
        snapshot.focused = null;
        snapshot.focused_application = if (saved.focused_application) |index|
            if (index < snapshot.application_count) index else null
        else
            null;
        snapshot.layout_persisted = snapshot.application_count > 0;
        for (saved.applications[0..snapshot.application_count], 0..) |application, index| {
            snapshot.applications[index] = .{
                .window_id = loadWindowId(application.window_id),
                .window_id_persisted = application.window_id != 0,
            };
            _ = snapshot.applications[index].executable.setUtf8(application.executable);
            _ = snapshot.applications[index].arguments.setUtf8(application.arguments);
            _ = snapshot.applications[index].working_directory.setUtf8(application.working_directory);
            _ = snapshot.applications[index].app_user_model_id.setUtf8(application.app_user_model_id);
            if (application.placement) |placement| {
                snapshot.entries[index] = .{
                    .hwnd = hwndFromStoredValue(application.last_hwnd),
                    .placement = placementFromSettings(placement),
                    .application_index = @intCast(index),
                };
            } else {
                snapshot.layout_persisted = false;
            }
        }
        if (snapshot.layout_persisted) {
            snapshot.count = snapshot.application_count;
        } else {
            // Settings written before window placements were persisted retain
            // their launch metadata, but need one unrestricted recapture.
            snapshot.focused_application = null;
        }
    }
}

fn placementFromSettings(saved: settings.SnapshotPlacement) c.WINDOWPLACEMENT {
    return .{
        .length = @sizeOf(c.WINDOWPLACEMENT),
        .flags = saved.flags,
        .showCmd = saved.show_command,
        .ptMinPosition = .{ .x = saved.minimized_x, .y = saved.minimized_y },
        .ptMaxPosition = .{ .x = saved.maximized_x, .y = saved.maximized_y },
        .rcNormalPosition = .{
            .left = saved.normal_left,
            .top = saved.normal_top,
            .right = saved.normal_right,
            .bottom = saved.normal_bottom,
        },
    };
}

fn placementToSettings(placement: c.WINDOWPLACEMENT) settings.SnapshotPlacement {
    return .{
        .flags = placement.flags,
        .show_command = placement.showCmd,
        .minimized_x = placement.ptMinPosition.x,
        .minimized_y = placement.ptMinPosition.y,
        .maximized_x = placement.ptMaxPosition.x,
        .maximized_y = placement.ptMaxPosition.y,
        .normal_left = placement.rcNormalPosition.left,
        .normal_top = placement.rcNormalPosition.top,
        .normal_right = placement.rcNormalPosition.right,
        .normal_bottom = placement.rcNormalPosition.bottom,
    };
}

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
    smart_fill = loaded_settings.smart_fill;
    settings_file_path = loaded_settings.path;
    loadSnapshotSettings(loaded_settings.snapshots);

    const instance = c.GetModuleHandleW(null);
    taskbar_created_message = c.RegisterWindowMessageW(taskbar_created_name);
    if (taskbar_created_message == 0) return error.RegisterTaskbarCreatedMessageFailed;
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

    // Explorer runs without elevation, so its TaskbarCreated broadcast is
    // otherwise blocked by UIPI when Znap is running as administrator.
    if (c.ChangeWindowMessageFilterEx(message_window, taskbar_created_message, c.MSGFLT_ALLOW, null) == 0) {
        return error.AllowTaskbarCreatedMessageFailed;
    }

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
    if (message == taskbar_created_message) {
        restoreTrayIcon();
        return 0;
    }

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
    if (snapshot.layout_persisted) associateExistingSnapshotWindows(snapshot);
    if (snapshot.stored and snapshot.auto_start and snapshot.layout_persisted) {
        const update_mismatch = if (snapshotWindowIdsPersisted(snapshot))
            !hasSameSnapshotWindows(snapshot, capture.entries[0..capture.entry_count])
        else
            capture.entry_count != snapshot.application_count;
        if (update_mismatch) {
            c.ZnapShowSnapshotUpdateRejected(message_window, tray_id, @intCast(snapshot_index), @intCast(snapshot.count), @intCast(capture.entry_count));
            return;
        }
    }
    const preserve_launch_information = snapshot.stored and snapshot.auto_start and snapshot.layout_persisted;
    if (preserve_launch_information) alignSnapshotApplications(snapshot, capture.entries[0..capture.entry_count]);
    snapshot.count = capture.entry_count;
    @memcpy(snapshot.entries[0..capture.entry_count], capture.entries[0..capture.entry_count]);
    if (preserve_launch_information) {
        for (snapshot.entries[0..snapshot.count], 0..) |*entry, index| entry.application_index = @intCast(index);
        migrateSnapshotWindowIds(snapshot);
    } else captureSnapshotApplications(snapshot);
    snapshot.focused = null;
    snapshot.focused_application = null;
    for (snapshot.entries[0..snapshot.count]) |entry| {
        if (entry.hwnd == focused) {
            snapshot.focused = focused;
            snapshot.focused_application = entry.application_index;
            break;
        }
    }
    snapshot.stored = true;
    snapshot.layout_persisted = true;
    if (snapshot.auto_start) saveSettings() catch |err| {
        std.log.err("failed to save snapshot application information: {s}", .{@errorName(err)});
    };
    animateStoredSnapshot(snapshot);
    refreshSnapshotSettingsPanel();
}

fn alignSnapshotApplications(snapshot: *WindowSnapshot, captured: []const SnapshotEntry) void {
    var application_windows: [snapshot_capacity]c.HWND = [_]c.HWND{null} ** snapshot_capacity;
    for (snapshot.entries[0..snapshot.count]) |entry| application_windows[entry.application_index] = entry.hwnd;
    for (captured, 0..) |captured_entry, target_index| {
        var source_index = target_index;
        while (source_index < snapshot.application_count and application_windows[source_index] != captured_entry.hwnd) : (source_index += 1) {}
        if (source_index == snapshot.application_count or source_index == target_index) continue;
        std.mem.swap(SnapshotApplication, &snapshot.applications[target_index], &snapshot.applications[source_index]);
        std.mem.swap(c.HWND, &application_windows[target_index], &application_windows[source_index]);
    }
}

fn hasSameSnapshotWindows(snapshot: *const WindowSnapshot, captured: []const SnapshotEntry) bool {
    if (snapshot.count != captured.len) return false;
    for (snapshot.entries[0..snapshot.count]) |saved| {
        var found = false;
        for (captured) |candidate| {
            if (candidate.hwnd == saved.hwnd) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn snapshotWindowIdsPersisted(snapshot: *const WindowSnapshot) bool {
    for (snapshot.applications[0..snapshot.application_count]) |application| {
        if (!application.window_id_persisted) return false;
    }
    return true;
}

fn migrateSnapshotWindowIds(snapshot: *WindowSnapshot) void {
    for (snapshot.entries[0..snapshot.count]) |entry| {
        const application = &snapshot.applications[entry.application_index];
        if (application.window_id_persisted) {
            rememberRuntimeWindow(application.window_id, entry.hwnd);
            continue;
        }
        application.window_id = runtimeWindowIdForHwnd(entry.hwnd) orelse allocateWindowId();
        application.window_id_persisted = true;
        rememberRuntimeWindow(application.window_id, entry.hwnd);
    }
}

fn captureSnapshotApplications(snapshot: *WindowSnapshot) void {
    snapshot.application_count = snapshot.count;
    for (snapshot.entries[0..snapshot.count], 0..) |*entry, index| {
        const window_id = runtimeWindowIdForHwnd(entry.hwnd) orelse allocateWindowId();
        snapshot.applications[index] = .{ .window_id = window_id, .window_id_persisted = true };
        var executable: [4096]u16 = [_]u16{0} ** 4096;
        var app_user_model_id: [512]u16 = [_]u16{0} ** 512;
        if (c.ZnapGetWindowApplicationInfo(entry.hwnd, &executable, executable.len, &app_user_model_id, app_user_model_id.len) != 0) {
            _ = snapshot.applications[index].executable.setUtf16(@ptrCast(&executable));
            _ = snapshot.applications[index].app_user_model_id.setUtf16(@ptrCast(&app_user_model_id));
        }
        entry.application_index = @intCast(index);
        rememberRuntimeWindow(window_id, entry.hwnd);
    }
}

fn applicationWindowIsUsable(application: *const SnapshotApplication, hwnd: c.HWND) bool {
    if (!isZonableWindow(hwnd)) return false;
    var executable: [4096]u16 = [_]u16{0} ** 4096;
    var app_user_model_id: [4096]u16 = [_]u16{0} ** 4096;
    if (!application.executable.toUtf16(&executable) or !application.app_user_model_id.toUtf16(&app_user_model_id)) return false;
    return c.ZnapWindowMatchesApplication(hwnd, &executable, &app_user_model_id) != 0;
}

fn snapshotEntryWindowIsUsable(snapshot: *const WindowSnapshot, entry: *const SnapshotEntry) bool {
    const application_index: usize = entry.application_index;
    return application_index < snapshot.application_count and
        applicationWindowIsUsable(&snapshot.applications[application_index], entry.hwnd);
}

fn appendClaimedWindow(claimed: []c.HWND, claimed_count: *usize, hwnd: c.HWND) void {
    if (hwnd == null) return;
    for (claimed[0..claimed_count.*]) |existing| {
        if (existing == hwnd) return;
    }
    if (claimed_count.* == claimed.len) return;
    claimed[claimed_count.*] = hwnd;
    claimed_count.* += 1;
}

fn windowIdMatchesRuntimeWindow(window_id: u64, hwnd: c.HWND) bool {
    for (&snapshots) |*snapshot| {
        for (snapshot.applications[0..snapshot.application_count]) |*application| {
            if (application.window_id == window_id and applicationWindowIsUsable(application, hwnd)) return true;
        }
    }
    return false;
}

fn runtimeWindowIdForHwnd(hwnd: c.HWND) ?u64 {
    for (runtime_windows[0..runtime_window_count]) |*runtime| {
        if (runtime.hwnd != hwnd or hwnd == null) continue;
        if (windowIdMatchesRuntimeWindow(runtime.window_id, hwnd)) return runtime.window_id;
        runtime.hwnd = null;
    }
    return null;
}

fn rememberRuntimeWindow(window_id: u64, hwnd: c.HWND) void {
    if (window_id == 0 or hwnd == null) return;
    var target_index: ?usize = null;
    for (runtime_windows[0..runtime_window_count], 0..) |*runtime, index| {
        if (runtime.window_id == window_id) target_index = index;
        if (runtime.hwnd == hwnd and runtime.window_id != window_id) runtime.hwnd = null;
    }
    if (target_index) |index| {
        runtime_windows[index].hwnd = hwnd;
    } else if (runtime_window_count < runtime_windows.len) {
        runtime_windows[runtime_window_count] = .{ .window_id = window_id, .hwnd = hwnd };
        runtime_window_count += 1;
    }
}

fn runtimeWindowForApplication(application: *const SnapshotApplication) c.HWND {
    for (runtime_windows[0..runtime_window_count]) |*runtime| {
        if (runtime.window_id != application.window_id) continue;
        if (applicationWindowIsUsable(application, runtime.hwnd)) return runtime.hwnd;
        runtime.hwnd = null;
        return null;
    }
    return null;
}

fn runtimeHwndForWindowId(window_id: u64) c.HWND {
    for (runtime_windows[0..runtime_window_count]) |*runtime| {
        if (runtime.window_id != window_id) continue;
        if (isZonableWindow(runtime.hwnd)) return runtime.hwnd;
        runtime.hwnd = null;
        return null;
    }
    return null;
}

fn excludeOtherRuntimeWindows(window_id: u64, excluded: []c.HWND, excluded_count: *usize) void {
    for (runtime_windows[0..runtime_window_count]) |*runtime| {
        if (runtime.window_id == window_id or runtime.hwnd == null) continue;
        if (!windowIdMatchesRuntimeWindow(runtime.window_id, runtime.hwnd)) {
            runtime.hwnd = null;
            continue;
        }
        appendClaimedWindow(excluded, excluded_count, runtime.hwnd);
    }
}

fn bindApplicationWindow(snapshot: *WindowSnapshot, application_index: usize, hwnd: c.HWND) void {
    const application = &snapshot.applications[application_index];
    rememberRuntimeWindow(application.window_id, hwnd);
    assignApplicationWindow(snapshot, application_index, hwnd);
}

fn seedRuntimeWindowsFromSnapshots() void {
    for (&snapshots) |*stored_snapshot| {
        if (!stored_snapshot.stored) continue;
        for (stored_snapshot.entries[0..stored_snapshot.count]) |entry| {
            if (!snapshotEntryWindowIsUsable(stored_snapshot, &entry)) continue;
            rememberRuntimeWindow(stored_snapshot.applications[entry.application_index].window_id, entry.hwnd);
        }
    }
}

fn associateExistingSnapshotWindows(snapshot: *WindowSnapshot) void {
    seedRuntimeWindowsFromSnapshots();

    for (snapshot.applications[0..snapshot.application_count], 0..) |*application, application_index| {
        if (runtimeWindowForApplication(application)) |hwnd| {
            assignApplicationWindow(snapshot, application_index, hwnd);
        }
    }
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
    const started_windows = snapshot.auto_start and startMissingSnapshotApplications(snapshot_index, snapshot);
    const previous_focus = c.GetForegroundWindow();

    if (started_windows) c.Sleep(350);
    applySnapshotPlacements(snapshot);
    if (started_windows) {
        // Some applications apply their own startup geometry shortly after
        // showing the window. Reapply once after that initialization pass.
        c.Sleep(250);
        applySnapshotPlacements(snapshot);
    }

    restoreSnapshotOrderAndFocus(snapshot, previous_focus);
}

fn applySnapshotPlacements(snapshot: *WindowSnapshot) void {
    for (snapshot.entries[0..snapshot.count]) |entry| {
        if (c.IsWindow(entry.hwnd) == 0 or !isZonableWindow(entry.hwnd)) continue;
        var placement = entry.placement;
        placement.length = @sizeOf(c.WINDOWPLACEMENT);
        _ = c.SetWindowPlacement(entry.hwnd, &placement);
        maximize_states.remove(@intFromPtr(entry.hwnd.?));
    }
}

fn restoreSnapshotOrderAndFocus(snapshot: *WindowSnapshot, previous_focus: c.HWND) void {
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

fn startMissingSnapshotApplications(snapshot_index: usize, snapshot: *WindowSnapshot) bool {
    var pending = [_]bool{false} ** snapshot_capacity;
    var failed = [_]bool{false} ** snapshot_capacity;
    var pending_count: usize = 0;
    var runtime_mapping_changed = false;
    seedRuntimeWindowsFromSnapshots();
    for (snapshot.applications[0..snapshot.application_count], 0..) |*application, application_index| {
        if (runtimeWindowForApplication(application)) |hwnd| {
            assignApplicationWindow(snapshot, application_index, hwnd);
            continue;
        }

        var executable: [4096]u16 = [_]u16{0} ** 4096;
        var arguments: [4096]u16 = [_]u16{0} ** 4096;
        var working_directory: [4096]u16 = [_]u16{0} ** 4096;
        var app_user_model_id: [4096]u16 = [_]u16{0} ** 4096;
        if (!application.executable.toUtf16(&executable) or
            !application.arguments.toUtf16(&arguments) or
            !application.working_directory.toUtf16(&working_directory) or
            !application.app_user_model_id.toUtf16(&app_user_model_id)) {
            failed[application_index] = true;
            continue;
        }

        if (c.ZnapStartApplication(&executable, &arguments, &working_directory, &app_user_model_id, if (isWindowsTerminal(application)) c.TRUE else c.FALSE) != 0) {
            pending[application_index] = true;
            pending_count += 1;
        } else {
            failed[application_index] = true;
        }
    }

    var matched_started_window = false;
    var attempt: u7 = 0;
    while (pending_count > 0 and attempt < 100) : (attempt += 1) {
        if (attempt != 0) c.Sleep(50);
        for (snapshot.applications[0..snapshot.application_count], 0..) |*application, application_index| {
            if (!pending[application_index]) continue;
            var executable: [4096]u16 = [_]u16{0} ** 4096;
            var app_user_model_id: [4096]u16 = [_]u16{0} ** 4096;
            if (!application.executable.toUtf16(&executable) or !application.app_user_model_id.toUtf16(&app_user_model_id)) {
                pending[application_index] = false;
                pending_count -= 1;
                failed[application_index] = true;
                continue;
            }
            var excluded: [snapshot_window_capacity]c.HWND = [_]c.HWND{null} ** snapshot_window_capacity;
            var excluded_count: usize = 0;
            excludeOtherRuntimeWindows(application.window_id, &excluded, &excluded_count);
            const hwnd = c.ZnapFindApplicationWindow(&executable, &app_user_model_id, &excluded, @intCast(excluded_count));
            if (hwnd == null) continue;
            bindApplicationWindow(snapshot, application_index, hwnd);
            runtime_mapping_changed = true;
            pending[application_index] = false;
            pending_count -= 1;
            matched_started_window = true;
        }
    }

    var failed_count: usize = 0;
    var first_failed: usize = 0;
    for (failed, pending, 0..) |launch_failed, window_pending, application_index| {
        if (!launch_failed and !window_pending) continue;
        if (failed_count == 0) first_failed = application_index;
        failed_count += 1;
    }
    if (failed_count != 0) {
        c.ZnapShowSnapshotRecallFailed(
            message_window,
            tray_id,
            @intCast(snapshot_index),
            @intCast(first_failed),
            @intCast(failed_count),
        );
    }
    if (runtime_mapping_changed) saveSettings() catch |err| {
        std.log.err("failed to save snapshot window mappings: {s}", .{@errorName(err)});
    };
    return matched_started_window;
}

fn isWindowsTerminal(application: *const SnapshotApplication) bool {
    const executable_name = std.fs.path.basename(application.executable.slice());
    return std.ascii.eqlIgnoreCase(executable_name, "WindowsTerminal.exe") or
        std.ascii.eqlIgnoreCase(executable_name, "wt.exe") or
        asciiContainsIgnoreCase(application.app_user_model_id.slice(), "WindowsTerminal");
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn assignApplicationWindow(snapshot: *WindowSnapshot, application_index: usize, hwnd: c.HWND) void {
    for (snapshot.entries[0..snapshot.count]) |*entry| {
        if (entry.application_index != application_index) continue;
        entry.hwnd = hwnd;
        if (snapshot.focused_application) |focused_index| {
            if (@as(usize, focused_index) == application_index) snapshot.focused = hwnd;
        }
        return;
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

const edge_snap_actions = [4]settings.Action{ .edge_left, .edge_right, .edge_top, .edge_bottom };

const corner_cycles = [4][settings.cycle_width_count]geometry.Placement{
    .{ .top_left_one_quarter, .top_left_one_third, .top_left_half, .top_left_two_thirds, .top_left_three_quarters },
    .{ .top_right_one_quarter, .top_right_one_third, .top_right_half, .top_right_two_thirds, .top_right_three_quarters },
    .{ .bottom_left_one_quarter, .bottom_left_one_third, .bottom_left_half, .bottom_left_two_thirds, .bottom_left_three_quarters },
    .{ .bottom_right_one_quarter, .bottom_right_one_third, .bottom_right_half, .bottom_right_two_thirds, .bottom_right_three_quarters },
};

const corner_snap_actions = [4]settings.Action{ .corner_top_left, .corner_top_right, .corner_bottom_left, .corner_bottom_right };

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

const SmartFillCandidate = struct {
    placements: *const [settings.cycle_width_count]geometry.Placement,
    mask: u8,
    complement: enum { matching_width, half, centered_sides },
};

const SmartFillRequest = struct {
    target: *const [settings.cycle_width_count]geometry.Placement,
    target_mask: u8,
    candidates: [4]SmartFillCandidate,
};

const SmartFillCapture = struct {
    ignored: c.HWND,
    monitor: c.HMONITOR,
    display: geometry.Rect,
    request: SmartFillRequest,
    occluders: [occluder_capacity]c.RECT = undefined,
    occluder_count: usize = 0,
    placement: ?geometry.Placement = null,
};

const complementary_widths = [settings.cycle_width_count]usize{ 4, 3, 2, 1, 0 };

fn complementarySmartPlacement(candidate: geometry.Rect, display: geometry.Rect, request: SmartFillRequest) ?geometry.Placement {
    for (request.candidates) |candidate_set| {
        for (0..settings.cycle_width_count) |width| {
            const bit = @as(u8, 1) << @intCast(width);
            if (candidate_set.mask & bit == 0) continue;
            if (!geometry.approximatelyEqual(candidate, geometry.place(candidate_set.placements[width], display, candidate), snapping_match_tolerance)) continue;
            const complement: usize = switch (candidate_set.complement) {
                .matching_width => complementary_widths[width],
                .half => 2,
                .centered_sides => switch (width) {
                    1 => 1,
                    2 => 0,
                    else => continue,
                },
            };
            if (request.target_mask & (@as(u8, 1) << @intCast(complement)) != 0) {
                return request.target[complement];
            }
        }
    }
    return null;
}

fn overlapsSmartFillTargetBand(candidate: geometry.Rect, placement: geometry.Placement, display: geometry.Rect) bool {
    const target = geometry.place(placement, display, candidate);
    if (target.width() == display.width()) {
        return @min(candidate.right, target.right) - @max(candidate.left, target.left) > snapping_match_tolerance;
    }
    return @min(candidate.bottom, target.bottom) - @max(candidate.top, target.top) > snapping_match_tolerance;
}

fn smartFillExtent(placement: geometry.Placement, display: geometry.Rect) i32 {
    const target = geometry.place(placement, display, undefined);
    return if (target.width() == display.width()) target.height() else target.width();
}

fn narrowerSmartPlacement(current: ?geometry.Placement, candidate: geometry.Placement, display: geometry.Rect) geometry.Placement {
    const previous = current orelse return candidate;
    return if (smartFillExtent(candidate, display) < smartFillExtent(previous, display)) candidate else previous;
}

fn smartEdgeRequest(index: usize) SmartFillRequest {
    const opposite_edge = ([4]usize{ 1, 0, 3, 2 })[index];
    const corner_directions = switch (index) {
        0 => [2]usize{ 1, 3 },
        1 => [2]usize{ 0, 2 },
        2 => [2]usize{ 2, 3 },
        3 => [2]usize{ 0, 1 },
        else => unreachable,
    };
    return .{
        .target = &edge_cycles[index],
        .target_mask = edge_cycle_mask,
        .candidates = .{
            .{ .placements = &edge_cycles[opposite_edge], .mask = edge_cycle_mask, .complement = .matching_width },
            .{ .placements = &corner_cycles[corner_directions[0]], .mask = corner_cycle_mask, .complement = if (index < 2) .matching_width else .half },
            .{ .placements = &corner_cycles[corner_directions[1]], .mask = corner_cycle_mask, .complement = if (index < 2) .matching_width else .half },
            .{ .placements = &center_cycles, .mask = if (index < 2) center_cycle_mask else 0, .complement = .centered_sides },
        },
    };
}

fn smartCornerRequest(index: usize) SmartFillRequest {
    const opposite_edge: usize = if (index == 0 or index == 2) 1 else 0;
    const opposite_corners = switch (index) {
        0 => [2]usize{ 1, 3 },
        1 => [2]usize{ 0, 2 },
        2 => [2]usize{ 3, 1 },
        3 => [2]usize{ 2, 0 },
        else => unreachable,
    };
    return .{
        .target = &corner_cycles[index],
        .target_mask = corner_cycle_mask,
        .candidates = .{
            .{ .placements = &corner_cycles[opposite_corners[0]], .mask = corner_cycle_mask, .complement = .matching_width },
            .{ .placements = &edge_cycles[opposite_edge], .mask = edge_cycle_mask, .complement = .matching_width },
            .{ .placements = &corner_cycles[opposite_corners[1]], .mask = corner_cycle_mask, .complement = .matching_width },
            .{ .placements = &center_cycles, .mask = center_cycle_mask, .complement = .centered_sides },
        },
    };
}

fn captureSmartFillWindow(hwnd: c.HWND, lparam: c.LPARAM) callconv(.c) c.BOOL {
    const capture: *SmartFillCapture = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (hwnd == capture.ignored or !isOccludingWindow(hwnd)) return c.TRUE;

    var bounds: c.RECT = undefined;
    if (!getVisibleWindowBounds(hwnd, &bounds)) return c.TRUE;
    if (c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST) == capture.monitor and
        isZonableWindow(hwnd) and
        !isCovered(bounds, capture.occluders[0..capture.occluder_count]))
    {
        if (complementarySmartPlacement(fromWinRect(bounds), capture.display, capture.request)) |placement| {
            if (overlapsSmartFillTargetBand(fromWinRect(bounds), placement, capture.display)) {
                capture.placement = narrowerSmartPlacement(capture.placement, placement, capture.display);
            }
        }
    }

    if (capture.occluder_count == capture.occluders.len) return c.FALSE;
    capture.occluders[capture.occluder_count] = bounds;
    capture.occluder_count += 1;
    return c.TRUE;
}

fn smartFillPlacement(hwnd: c.HWND, monitor: c.HMONITOR, display: geometry.Rect, request: SmartFillRequest) ?geometry.Placement {
    var capture: SmartFillCapture = .{
        .ignored = hwnd,
        .monitor = monitor,
        .display = display,
        .request = request,
    };
    _ = c.EnumWindows(captureSmartFillWindow, @bitCast(@intFromPtr(&capture)));
    return capture.placement;
}

test "configured cycle starts at the selected default width" {
    var configured: [settings.cycle_width_count]geometry.Placement = undefined;
    const cycle = configuredCycle(&edge_cycles[0], settings.default_cycle_mask, .@"1/2", &configured);
    try std.testing.expectEqualSlices(geometry.Placement, &.{ .left_half, .left_two_thirds, .left_one_third }, cycle);
}

test "smart fill chooses an enabled complementary width" {
    const display: geometry.Rect = .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 };
    const request: SmartFillRequest = .{
        .target = &edge_cycles[0],
        .target_mask = settings.default_cycle_mask,
        .candidates = .{
            .{ .placements = &edge_cycles[1], .mask = settings.default_cycle_mask, .complement = .matching_width },
            .{ .placements = &corner_cycles[1], .mask = settings.default_cycle_mask, .complement = .matching_width },
            .{ .placements = &corner_cycles[3], .mask = settings.default_cycle_mask, .complement = .matching_width },
            .{ .placements = &center_cycles, .mask = settings.default_cycle_mask, .complement = .centered_sides },
        },
    };
    try std.testing.expectEqual(geometry.Placement.left_one_third, complementarySmartPlacement(
        geometry.place(.right_two_thirds, display, undefined),
        display,
        request,
    ));
    try std.testing.expectEqual(@as(?geometry.Placement, null), complementarySmartPlacement(
        geometry.place(.right_three_quarters, display, undefined),
        display,
        request,
    ));
    try std.testing.expectEqual(geometry.Placement.left_two_thirds, complementarySmartPlacement(
        geometry.place(.top_right_one_third, display, undefined),
        display,
        request,
    ));
}

test "smart fill uses the side space around a centered window" {
    const display: geometry.Rect = .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 };
    const disabled: SmartFillCandidate = .{ .placements = &edge_cycles[0], .mask = 0, .complement = .matching_width };
    const center_candidate: SmartFillCandidate = .{ .placements = &center_cycles, .mask = settings.default_cycle_mask, .complement = .centered_sides };
    const edge_request: SmartFillRequest = .{
        .target = &edge_cycles[0],
        .target_mask = 0x1f,
        .candidates = .{ center_candidate, disabled, disabled, disabled },
    };
    const corner_request: SmartFillRequest = .{
        .target = &corner_cycles[0],
        .target_mask = 0x1f,
        .candidates = .{ center_candidate, disabled, disabled, disabled },
    };
    const centered_half = geometry.place(.center_half, display, undefined);

    try std.testing.expectEqual(geometry.Placement.left_one_quarter, complementarySmartPlacement(centered_half, display, edge_request));
    try std.testing.expectEqual(geometry.Placement.top_left_one_quarter, complementarySmartPlacement(centered_half, display, corner_request));
}

test "smart fill uses the narrowest free extent from multiple windows" {
    const display: geometry.Rect = .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 };
    const disabled: SmartFillCandidate = .{ .placements = &edge_cycles[0], .mask = 0, .complement = .matching_width };
    const request: SmartFillRequest = .{
        .target = &edge_cycles[0],
        .target_mask = 0x1f,
        .candidates = .{
            .{ .placements = &edge_cycles[1], .mask = 0x1f, .complement = .matching_width },
            .{ .placements = &center_cycles, .mask = 0x1f, .complement = .centered_sides },
            disabled,
            disabled,
        },
    };
    const right_quarter_fill = complementarySmartPlacement(geometry.place(.right_one_quarter, display, undefined), display, request).?;
    const centered_half_fill = complementarySmartPlacement(geometry.place(.center_half, display, undefined), display, request).?;

    try std.testing.expectEqual(geometry.Placement.left_three_quarters, right_quarter_fill);
    try std.testing.expectEqual(geometry.Placement.left_one_quarter, centered_half_fill);
    try std.testing.expectEqual(geometry.Placement.left_one_quarter, narrowerSmartPlacement(right_quarter_fill, centered_half_fill, display));
}

test "corner smart fill only uses windows in the destination row" {
    const display: geometry.Rect = .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 };
    const request = smartCornerRequest(2);
    const same_row = geometry.place(.bottom_right_one_third, display, undefined);
    const other_row = geometry.place(.top_right_one_third, display, undefined);
    const placement = complementarySmartPlacement(same_row, display, request).?;

    try std.testing.expectEqual(geometry.Placement.bottom_left_two_thirds, placement);
    try std.testing.expect(overlapsSmartFillTargetBand(same_row, placement, display));
    try std.testing.expect(!overlapsSmartFillTargetBand(other_row, placement, display));
}

test "a fresh window snap tries smart fill before continuing its existing cycle" {
    const display: geometry.Rect = .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 };
    const cycle = [_]geometry.Placement{ .left_half, .left_two_thirds, .left_one_third };
    const current = geometry.place(.left_one_third, display, undefined);

    try std.testing.expectEqual(
        .left_two_thirds,
        nextSnapPlacement(&cycle, current, display, .left_two_thirds, .window_changed),
    );
    try std.testing.expectEqual(
        .left_half,
        nextSnapPlacement(&cycle, current, display, .left_two_thirds, .repeat),
    );
    try std.testing.expectEqual(
        .left_one_third,
        nextSnapPlacement(&cycle, geometry.place(.right_one_third, display, undefined), display, .left_one_third, .window_changed),
    );
    try std.testing.expectEqual(
        .left_half,
        nextSnapPlacement(&cycle, current, display, .left_one_third, .window_changed),
    );
}

test "switching corners applies smart fill even when the width is unchanged" {
    const display: geometry.Rect = .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 };
    const cycle = [_]geometry.Placement{ .top_left_half, .top_left_two_thirds, .top_left_one_third };
    const current = geometry.place(.bottom_left_one_third, display, undefined);

    try std.testing.expectEqual(
        .top_left_one_third,
        nextSnapPlacement(&cycle, current, display, .top_left_one_third, .method_changed),
    );

    const bottom_right_cycle = [_]geometry.Placement{ .bottom_right_half, .bottom_right_two_thirds, .bottom_right_one_third };
    try std.testing.expectEqual(
        .bottom_right_two_thirds,
        nextSnapPlacement(&bottom_right_cycle, geometry.place(.top_right_two_thirds, display, undefined), display, .bottom_right_two_thirds, .window_changed),
    );
}

test "disabled smart fill cycles only an existing requested placement" {
    const display: geometry.Rect = .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 };
    const cycle = [_]geometry.Placement{ .top_left_half, .top_left_two_thirds, .top_left_one_third };

    try std.testing.expectEqual(
        .top_left_half,
        nextPlacementWithoutSmartFill(&cycle, geometry.place(.bottom_left_two_thirds, display, undefined), display),
    );
    try std.testing.expectEqual(
        .top_left_one_third,
        nextPlacementWithoutSmartFill(&cycle, geometry.place(.top_left_two_thirds, display, undefined), display),
    );

    const center_cycle = [_]geometry.Placement{ .center_half, .center_two_thirds, .center_one_third };
    try std.testing.expectEqual(
        .center_half,
        nextPlacementWithoutSmartFill(&center_cycle, geometry.place(.left_half, display, undefined), display),
    );
    try std.testing.expectEqual(
        .center_two_thirds,
        nextPlacementWithoutSmartFill(&center_cycle, geometry.place(.center_half, display, undefined), display),
    );
}

test "switching snap methods starts a fresh snap for the same window" {
    const left: SnapIdentity = .{ .window = 1, .action = .edge_left };

    try std.testing.expectEqual(SnapTransition.repeat, snapTransition(left, left));
    try std.testing.expectEqual(SnapTransition.method_changed, snapTransition(left, .{ .window = 1, .action = .edge_right }));
    try std.testing.expectEqual(SnapTransition.method_changed, snapTransition(.{ .window = 1, .action = .corner_top_left }, .{ .window = 1, .action = .corner_bottom_left }));
    try std.testing.expectEqual(SnapTransition.window_changed, snapTransition(left, .{ .window = 2, .action = .edge_left }));
}

fn cycleEdge(index: usize) void {
    const hwnd = c.GetForegroundWindow();
    if (hwnd == null) return;
    const snap: SnapIdentity = .{ .window = @intFromPtr(hwnd.?), .action = edge_snap_actions[index] };
    var configured: [settings.cycle_width_count]geometry.Placement = undefined;
    const smart_request: ?SmartFillRequest = if (smart_fill) smartEdgeRequest(index) else null;
    const placement = nextWindowCyclePlacement(hwnd, configuredCycle(&edge_cycles[index], edge_cycle_mask, default_edge_cycle_width, &configured), smart_request, snapTransition(last_snap, snap));
    if (resizeWindow(hwnd, placement)) last_snap = snap;
}

fn cycleCorner(index: usize) void {
    const hwnd = c.GetForegroundWindow();
    if (hwnd == null) return;
    const snap: SnapIdentity = .{ .window = @intFromPtr(hwnd.?), .action = corner_snap_actions[index] };
    var configured: [settings.cycle_width_count]geometry.Placement = undefined;
    const smart_request: ?SmartFillRequest = if (smart_fill) smartCornerRequest(index) else null;
    const placement = nextWindowCyclePlacement(hwnd, configuredCycle(&corner_cycles[index], corner_cycle_mask, default_corner_cycle_width, &configured), smart_request, snapTransition(last_snap, snap));
    if (resizeWindow(hwnd, placement)) last_snap = snap;
}

fn snapTransition(previous: ?SnapIdentity, current: SnapIdentity) SnapTransition {
    const last = previous orelse return .window_changed;
    if (last.window != current.window) return .window_changed;
    if (last.action != current.action) return .method_changed;
    return .repeat;
}

fn nextWindowCyclePlacement(hwnd: c.HWND, cycle: []const geometry.Placement, smart_request: ?SmartFillRequest, transition: SnapTransition) geometry.Placement {
    const monitor = c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST);
    if (monitor == null) return cycle[0];

    var monitor_info: c.MONITORINFO = std.mem.zeroes(c.MONITORINFO);
    monitor_info.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(monitor, &monitor_info) == 0) return cycle[0];

    var bounds: c.RECT = undefined;
    if (!getVisibleWindowBounds(hwnd, &bounds)) return cycle[0];
    const current = fromWinRect(bounds);
    const display = fromWinRect(monitor_info.rcWork);
    const request = smart_request orelse return nextPlacementWithoutSmartFill(cycle, current, display);
    const smart_placement = if (transition != .repeat)
        smartFillPlacement(hwnd, monitor, display, request)
    else
        null;
    return nextSnapPlacement(cycle, current, display, smart_placement, transition);
}

fn nextSnapPlacement(cycle: []const geometry.Placement, current: geometry.Rect, display: geometry.Rect, smart_placement: ?geometry.Placement, transition: SnapTransition) geometry.Placement {
    if (transition != .repeat) {
        if (smart_placement) |placement| {
            if (transition == .method_changed) return placement;
            const smart_bounds = geometry.place(placement, display, current);
            if (geometry.approximatelyEqual(current, smart_bounds, snapping_match_tolerance)) {
                return geometry.nextCyclePlacement(cycle, smart_bounds, display, snapping_match_tolerance);
            }
            return placement;
        }
        return cycle[0];
    }
    return geometry.nextCyclePlacement(cycle, current, display, snapping_match_tolerance);
}

fn nextPlacementWithoutSmartFill(cycle: []const geometry.Placement, current: geometry.Rect, display: geometry.Rect) geometry.Placement {
    return geometry.nextCyclePlacement(cycle, current, display, snapping_match_tolerance);
}

fn cycleCenter() void {
    const hwnd = c.GetForegroundWindow();
    if (hwnd == null) return;
    const snap: SnapIdentity = .{ .window = @intFromPtr(hwnd.?), .action = .center };
    var configured: [settings.cycle_width_count]geometry.Placement = undefined;
    const placement = nextWindowCyclePlacement(hwnd, configuredCycle(&center_cycles, center_cycle_mask, default_center_cycle_width, &configured), null, snapTransition(last_snap, snap));
    if (resizeWindow(hwnd, placement)) last_snap = snap;
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
    setTrayIconVersion();
}

fn restoreTrayIcon() void {
    if (c.Shell_NotifyIconW(c.NIM_ADD, &tray_data) != 0) setTrayIconVersion();
}

fn setTrayIconVersion() void {
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

    var snapshot_application_counts: [10]c.UINT = [_]c.UINT{0} ** 10;
    var stored_snapshot_mask: c.UINT = 0;
    var auto_start_snapshot_mask: c.UINT = 0;
    for (&snapshots, 0..) |*snapshot, index| {
        if (snapshot.stored) associateExistingSnapshotWindows(snapshot);
        snapshot_application_counts[index] = @intCast(snapshot.application_count);
        if (snapshot.stored) stored_snapshot_mask |= @as(c.UINT, 1) << @intCast(index);
        if (snapshot.auto_start) auto_start_snapshot_mask |= @as(c.UINT, 1) << @intCast(index);
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
        if (smart_fill) c.TRUE else c.FALSE,
        &snapshot_application_counts,
        stored_snapshot_mask,
        auto_start_snapshot_mask,
    );
}

fn refreshSnapshotSettingsPanel() void {
    var snapshot_application_counts: [snapshot_count]c.UINT = [_]c.UINT{0} ** snapshot_count;
    var stored_snapshot_mask: c.UINT = 0;
    var auto_start_snapshot_mask: c.UINT = 0;
    for (&snapshots, 0..) |*snapshot, index| {
        snapshot_application_counts[index] = @intCast(snapshot.application_count);
        if (snapshot.stored) stored_snapshot_mask |= @as(c.UINT, 1) << @intCast(index);
        if (snapshot.auto_start) auto_start_snapshot_mask |= @as(c.UINT, 1) << @intCast(index);
    }
    c.ZnapRefreshSnapshotSettings(&snapshot_application_counts, stored_snapshot_mask, auto_start_snapshot_mask);
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
    var saved_snapshots: [10]settings.Snapshot = undefined;
    var saved_applications: [10][snapshot_capacity]settings.SnapshotApplication = undefined;
    var saved_count: usize = 0;
    for (&snapshots, 0..) |*snapshot, snapshot_index| {
        if (!snapshot.stored or !snapshot.auto_start) continue;
        for (snapshot.applications[0..snapshot.application_count], 0..) |*application, application_index| {
            const runtime_hwnd = runtimeHwndForWindowId(application.window_id);
            saved_applications[saved_count][application_index] = .{
                .window_id = if (application.window_id_persisted) application.window_id else 0,
                .last_hwnd = if (runtime_hwnd) |hwnd| @intFromPtr(hwnd) else 0,
                .executable = application.executable.slice(),
                .arguments = application.arguments.slice(),
                .working_directory = application.working_directory.slice(),
                .app_user_model_id = application.app_user_model_id.slice(),
                .placement = if (snapshot.layout_persisted)
                    if (snapshotEntryForApplication(snapshot, application_index)) |entry| placementToSettings(entry.placement) else null
                else
                    null,
            };
        }
        saved_snapshots[saved_count] = .{
            .index = @intCast(snapshot_index),
            .auto_start = true,
            .applications = saved_applications[saved_count][0..snapshot.application_count],
            .focused_application = snapshot.focused_application,
        };
        saved_count += 1;
    }
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
        smart_fill,
        saved_snapshots[0..saved_count],
    );
}

fn snapshotEntryForApplication(snapshot: *const WindowSnapshot, application_index: usize) ?*const SnapshotEntry {
    for (snapshot.entries[0..snapshot.count]) |*entry| {
        if (entry.application_index == application_index) return entry;
    }
    return null;
}

fn applicationField(application: *SnapshotApplication, field: usize) ?*SnapshotText {
    return switch (field) {
        0 => &application.executable,
        1 => &application.arguments,
        2 => &application.working_directory,
        3 => &application.app_user_model_id,
        else => null,
    };
}

fn snapshotApplicationField(snapshot_index: usize, application_index: usize, field: usize) ?*SnapshotText {
    if (snapshot_index >= snapshots.len) return null;
    const snapshot = &snapshots[snapshot_index];
    if (!snapshot.stored or application_index >= snapshot.application_count) return null;
    return applicationField(&snapshot.applications[application_index], field);
}

pub export fn ZnapGetSnapshotApplicationText(snapshot_index: c.UINT, application_index: c.UINT, field: c.UINT, buffer: [*c]u16, capacity: c.UINT) c.BOOL {
    if (buffer == null or capacity == 0) return c.FALSE;
    const text = snapshotApplicationField(snapshot_index, application_index, field) orelse {
        buffer[0] = 0;
        return c.FALSE;
    };
    return if (text.toUtf16(buffer[0..capacity])) c.TRUE else c.FALSE;
}

pub export fn ZnapGetSnapshotApplicationHwnd(snapshot_index: c.UINT, application_index: c.UINT) c.UINT_PTR {
    if (snapshot_index >= snapshots.len) return 0;
    const snapshot = &snapshots[snapshot_index];
    if (!snapshot.stored or application_index >= snapshot.application_count) return 0;
    const hwnd = runtimeWindowForApplication(&snapshot.applications[application_index]);
    return if (hwnd) |value| @intFromPtr(value) else 0;
}

pub export fn ZnapGetSnapshotApplicationWindowId(snapshot_index: c.UINT, application_index: c.UINT) c.ULONGLONG {
    if (snapshot_index >= snapshots.len) return 0;
    const snapshot = &snapshots[snapshot_index];
    if (!snapshot.stored or application_index >= snapshot.application_count) return 0;
    return snapshot.applications[application_index].window_id;
}

pub export fn ZnapUpdateSnapshotAutoStart(snapshot_index: c.UINT, enabled: c.BOOL) c.BOOL {
    if (snapshot_index >= snapshots.len or !snapshots[snapshot_index].stored) return c.FALSE;
    const previous = snapshots[snapshot_index].auto_start;
    snapshots[snapshot_index].auto_start = enabled != 0;
    saveSettings() catch |err| {
        snapshots[snapshot_index].auto_start = previous;
        std.log.err("failed to save snapshot auto-start setting: {s}", .{@errorName(err)});
        return c.FALSE;
    };
    return c.TRUE;
}

pub export fn ZnapUpdateSnapshotApplication(snapshot_index: c.UINT, application_index: c.UINT, field: c.UINT, value: [*c]const u16) c.BOOL {
    if (value == null or snapshot_index >= snapshots.len or !snapshots[snapshot_index].auto_start) return c.FALSE;
    const source_snapshot = &snapshots[snapshot_index];
    if (application_index >= source_snapshot.application_count) return c.FALSE;
    const window_id = source_snapshot.applications[application_index].window_id;
    if (window_id == 0) return c.FALSE;

    var targets: [snapshot_count]*SnapshotText = undefined;
    var previous: [snapshot_count]SnapshotText = undefined;
    var target_count: usize = 0;
    for (&snapshots) |*snapshot| {
        if (!snapshot.stored) continue;
        for (snapshot.applications[0..snapshot.application_count]) |*application| {
            if (application.window_id != window_id) continue;
            targets[target_count] = applicationField(application, field) orelse return c.FALSE;
            previous[target_count] = targets[target_count].*;
            target_count += 1;
            break;
        }
    }
    if (target_count == 0) return c.FALSE;
    for (targets[0..target_count], 0..) |text, index| {
        if (text.setUtf16(@ptrCast(value))) continue;
        for (targets[0..index], previous[0..index]) |changed, old| changed.* = old;
        return c.FALSE;
    }
    saveSettings() catch |err| {
        for (targets[0..target_count], previous[0..target_count]) |changed, old| changed.* = old;
        std.log.err("failed to save snapshot application setting: {s}", .{@errorName(err)});
        return c.FALSE;
    };
    return c.TRUE;
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

pub export fn ZnapUpdateSmartFill(enabled: c.BOOL) c.BOOL {
    const previous = smart_fill;
    smart_fill = enabled != 0;
    saveSettings() catch |err| {
        smart_fill = previous;
        std.log.err("failed to save smart fill setting: {s}", .{@errorName(err)});
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
