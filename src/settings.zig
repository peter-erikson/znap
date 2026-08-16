const std = @import("std");

pub const Action = enum {
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
    store_snapshot,
    recall_snapshot,
};

pub const Modifier = enum {
    alt,
    control,
    shift,
    win,
};

pub const Keymap = struct {
    modifiers: []const Modifier,
    key: []const u8,
    action: Action,
    snapshot_index: ?u4 = null,
};

pub const Settings = struct {
    keymaps: []const Keymap,
};

pub const LoadedKeymap = struct {
    modifiers: u32,
    key: u32,
    action: Action,
    snapshot_index: u4,
};

pub const LoadedSettings = struct {
    keymaps: []LoadedKeymap,
    path: []const u8,
};

const mod_alt: u32 = 0x0001;
const mod_control: u32 = 0x0002;
const mod_shift: u32 = 0x0004;
const mod_win: u32 = 0x0008;

const win = &.{Modifier.win};
const win_alt = &.{ Modifier.win, Modifier.alt };

pub const default_keymaps = [_]Keymap{
    .{ .modifiers = win, .key = "left", .action = .edge_left },
    .{ .modifiers = win, .key = "right", .action = .edge_right },
    .{ .modifiers = win, .key = "up", .action = .edge_top },
    .{ .modifiers = win, .key = "down", .action = .edge_bottom },
    .{ .modifiers = win, .key = "insert", .action = .corner_top_left },
    .{ .modifiers = win, .key = "delete", .action = .corner_bottom_left },
    .{ .modifiers = win, .key = "page_up", .action = .corner_top_right },
    .{ .modifiers = win, .key = "page_down", .action = .corner_bottom_right },
    .{ .modifiers = win, .key = "enter", .action = .maximize },
    .{ .modifiers = win, .key = "backslash", .action = .center },
    .{ .modifiers = win_alt, .key = "a", .action = .always_on_top },
    .{ .modifiers = win_alt, .key = "1", .action = .store_snapshot, .snapshot_index = 0 },
    .{ .modifiers = win, .key = "1", .action = .recall_snapshot, .snapshot_index = 0 },
    .{ .modifiers = win_alt, .key = "2", .action = .store_snapshot, .snapshot_index = 1 },
    .{ .modifiers = win, .key = "2", .action = .recall_snapshot, .snapshot_index = 1 },
    .{ .modifiers = win_alt, .key = "3", .action = .store_snapshot, .snapshot_index = 2 },
    .{ .modifiers = win, .key = "3", .action = .recall_snapshot, .snapshot_index = 2 },
    .{ .modifiers = win_alt, .key = "4", .action = .store_snapshot, .snapshot_index = 3 },
    .{ .modifiers = win, .key = "4", .action = .recall_snapshot, .snapshot_index = 3 },
    .{ .modifiers = win_alt, .key = "5", .action = .store_snapshot, .snapshot_index = 4 },
    .{ .modifiers = win, .key = "5", .action = .recall_snapshot, .snapshot_index = 4 },
    .{ .modifiers = win_alt, .key = "6", .action = .store_snapshot, .snapshot_index = 5 },
    .{ .modifiers = win, .key = "6", .action = .recall_snapshot, .snapshot_index = 5 },
    .{ .modifiers = win_alt, .key = "7", .action = .store_snapshot, .snapshot_index = 6 },
    .{ .modifiers = win, .key = "7", .action = .recall_snapshot, .snapshot_index = 6 },
    .{ .modifiers = win_alt, .key = "8", .action = .store_snapshot, .snapshot_index = 7 },
    .{ .modifiers = win, .key = "8", .action = .recall_snapshot, .snapshot_index = 7 },
    .{ .modifiers = win_alt, .key = "9", .action = .store_snapshot, .snapshot_index = 8 },
    .{ .modifiers = win, .key = "9", .action = .recall_snapshot, .snapshot_index = 8 },
    .{ .modifiers = win_alt, .key = "0", .action = .store_snapshot, .snapshot_index = 9 },
    .{ .modifiers = win, .key = "0", .action = .recall_snapshot, .snapshot_index = 9 },
};

pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !LoadedSettings {
    const user_home = environ.get("USERPROFILE") orelse return error.UserHomeDirectoryNotFound;
    const settings_dir = try std.fs.path.join(allocator, &.{ user_home, ".config", "znap" });
    defer allocator.free(settings_dir);
    const settings_path = try std.fs.path.join(allocator, &.{ settings_dir, "settings.json" });
    errdefer allocator.free(settings_path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try createDefaultFile(io, allocator, settings_dir, settings_path),
        else => return err,
    };
    defer allocator.free(contents);
    return .{
        .keymaps = try parse(allocator, contents),
        .path = settings_path,
    };
}

fn createDefaultFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    settings_dir: []const u8,
    settings_path: []const u8,
) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(io, settings_dir);
    const contents = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(
        Settings{ .keymaps = &default_keymaps },
        .{ .whitespace = .indent_2 },
    )});
    errdefer allocator.free(contents);

    var file = std.Io.Dir.cwd().createFile(io, settings_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            allocator.free(contents);
            return std.Io.Dir.cwd().readFileAlloc(io, settings_path, allocator, .limited(1024 * 1024));
        },
        else => return err,
    };
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
    return contents;
}

pub fn parse(allocator: std.mem.Allocator, contents: []const u8) ![]LoadedKeymap {
    const parsed = try std.json.parseFromSlice(Settings, allocator, contents, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value.keymaps.len > 256) return error.TooManyKeymaps;

    const loaded = try allocator.alloc(LoadedKeymap, parsed.value.keymaps.len);
    errdefer allocator.free(loaded);
    for (parsed.value.keymaps, loaded) |keymap, *result| {
        const is_snapshot = keymap.action == .store_snapshot or keymap.action == .recall_snapshot;
        if (is_snapshot and keymap.snapshot_index == null) return error.MissingSnapshotIndex;
        if (!is_snapshot and keymap.snapshot_index != null) return error.UnexpectedSnapshotIndex;

        var modifiers: u32 = 0;
        for (keymap.modifiers) |modifier| modifiers |= switch (modifier) {
            .alt => mod_alt,
            .control => mod_control,
            .shift => mod_shift,
            .win => mod_win,
        };
        result.* = .{
            .modifiers = modifiers,
            .key = try keyCode(keymap.key),
            .action = keymap.action,
            .snapshot_index = keymap.snapshot_index orelse 0,
        };
    }
    return loaded;
}

pub fn save(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    keymaps: []const LoadedKeymap,
) !void {
    const serialized = try allocator.alloc(Keymap, keymaps.len);
    defer allocator.free(serialized);
    const modifier_storage = try allocator.alloc([4]Modifier, keymaps.len);
    defer allocator.free(modifier_storage);
    const key_storage = try allocator.alloc([16]u8, keymaps.len);
    defer allocator.free(key_storage);

    for (keymaps, serialized, modifier_storage, key_storage) |keymap, *output, *modifiers, *key_buffer| {
        var modifier_count: usize = 0;
        inline for (.{
            .{ mod_win, Modifier.win },
            .{ mod_control, Modifier.control },
            .{ mod_alt, Modifier.alt },
            .{ mod_shift, Modifier.shift },
        }) |entry| {
            if (keymap.modifiers & entry[0] != 0) {
                modifiers[modifier_count] = entry[1];
                modifier_count += 1;
            }
        }
        output.* = .{
            .modifiers = modifiers[0..modifier_count],
            .key = keyName(keymap.key, key_buffer),
            .action = keymap.action,
            .snapshot_index = if (keymap.action == .store_snapshot or keymap.action == .recall_snapshot)
                keymap.snapshot_index
            else
                null,
        };
    }

    const contents = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(
        Settings{ .keymaps = serialized },
        .{ .whitespace = .indent_2 },
    )});
    defer allocator.free(contents);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, contents);
    try atomic.replace(io);
}

pub fn updateKeymap(keymaps: []LoadedKeymap, index: usize, modifiers: u32, key: u32) void {
    for (keymaps, 0..) |*keymap, other_index| {
        if (key != 0 and other_index != index and keymap.key == key and keymap.modifiers == modifiers) {
            keymap.modifiers = 0;
            keymap.key = 0;
        }
    }
    keymaps[index].modifiers = modifiers;
    keymaps[index].key = key;
}

fn keyName(key: u32, buffer: *[16]u8) []const u8 {
    if (key == 0) return "none";
    if (key <= std.math.maxInt(u8)) {
        const byte: u8 = @intCast(key);
        if (std.ascii.isDigit(byte) or std.ascii.isUpper(byte)) {
            buffer[0] = std.ascii.toLower(byte);
            return buffer[0..1];
        }
    }
    const names = .{
        .{ 0x25, "left" },
        .{ 0x26, "up" },
        .{ 0x27, "right" },
        .{ 0x28, "down" },
        .{ 0x21, "page_up" },
        .{ 0x22, "page_down" },
        .{ 0x0D, "enter" },
        .{ 0x2D, "insert" },
        .{ 0x2E, "delete" },
        .{ 0xDC, "backslash" },
    };
    inline for (names) |entry| {
        if (key == entry[0]) return entry[1];
    }
    return std.fmt.bufPrint(buffer, "vk_{X:0>2}", .{key}) catch unreachable;
}

fn keyCode(name: []const u8) !u32 {
    if (std.ascii.eqlIgnoreCase(name, "none")) return 0;
    if (name.len == 1) {
        const key = std.ascii.toUpper(name[0]);
        if (std.ascii.isAlphanumeric(key)) return key;
    }
    const names = .{
        .{ "left", 0x25 },
        .{ "up", 0x26 },
        .{ "right", 0x27 },
        .{ "down", 0x28 },
        .{ "page_up", 0x21 },
        .{ "page_down", 0x22 },
        .{ "enter", 0x0D },
        .{ "insert", 0x2D },
        .{ "delete", 0x2E },
        .{ "backslash", 0xDC },
    };
    inline for (names) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
    }
    if (name.len > 3 and std.ascii.eqlIgnoreCase(name[0..3], "vk_")) {
        return std.fmt.parseInt(u32, name[3..], 16) catch return error.UnknownKey;
    }
    return error.UnknownKey;
}

test "parses keymaps" {
    const contents =
        \\{"keymaps":[
        \\  {"modifiers":["win","shift"],"key":"left","action":"edge_left"},
        \\  {"modifiers":["win"],"key":"1","action":"recall_snapshot","snapshot_index":0}
        \\]}
    ;
    const keymaps = try parse(std.testing.allocator, contents);
    defer std.testing.allocator.free(keymaps);
    try std.testing.expectEqual(@as(usize, 2), keymaps.len);
    try std.testing.expectEqual(@as(u32, mod_win | mod_shift), keymaps[0].modifiers);
    try std.testing.expectEqual(@as(u32, 0x25), keymaps[0].key);
    try std.testing.expectEqual(Action.recall_snapshot, keymaps[1].action);
}

test "default keymaps round trip through JSON" {
    const contents = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{std.json.fmt(
        Settings{ .keymaps = &default_keymaps },
        .{ .whitespace = .indent_2 },
    )});
    defer std.testing.allocator.free(contents);
    const keymaps = try parse(std.testing.allocator, contents);
    defer std.testing.allocator.free(keymaps);
    try std.testing.expectEqual(default_keymaps.len, keymaps.len);
}

test "snapshot keymaps require an index" {
    const contents =
        \\{"keymaps":[{"modifiers":["win"],"key":"1","action":"recall_snapshot"}]}
    ;
    try std.testing.expectError(error.MissingSnapshotIndex, parse(std.testing.allocator, contents));
}

test "arbitrary virtual keys round trip through key names" {
    var buffer: [16]u8 = undefined;
    const name = keyName(0x70, &buffer);
    try std.testing.expectEqualStrings("vk_70", name);
    try std.testing.expectEqual(@as(u32, 0x70), try keyCode(name));
}

test "updating a keymap clears duplicate shortcuts" {
    var keymaps = [_]LoadedKeymap{
        .{ .modifiers = mod_win, .key = 'A', .action = .edge_left, .snapshot_index = 0 },
        .{ .modifiers = mod_alt, .key = 'B', .action = .edge_right, .snapshot_index = 0 },
        .{ .modifiers = mod_win, .key = 'A', .action = .edge_top, .snapshot_index = 0 },
    };
    updateKeymap(&keymaps, 1, mod_win, 'A');
    try std.testing.expectEqual(@as(u32, 0), keymaps[0].key);
    try std.testing.expectEqual(@as(u32, 0), keymaps[2].key);
    try std.testing.expectEqual(@as(u32, mod_win), keymaps[1].modifiers);
    try std.testing.expectEqual(@as(u32, 'A'), keymaps[1].key);
}
