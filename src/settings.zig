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
    keymaps: []const LoadedKeymap,
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

pub fn parse(allocator: std.mem.Allocator, contents: []const u8) ![]const LoadedKeymap {
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

fn keyCode(name: []const u8) !u32 {
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
