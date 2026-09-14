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
    store_snapshot,
    recall_snapshot,
};

const SerializedAction = enum {
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
    store_snapshot,
    recall_snapshot,

    // Retained only so older settings files can be migrated.
    always_on_top,
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
    action: SerializedAction,
    snapshot_index: ?u4 = null,
};

pub const CycleWidth = enum {
    @"1/4",
    @"1/3",
    @"1/2",
    @"2/3",
    @"3/4",
};

pub const cycle_width_count = @typeInfo(CycleWidth).@"enum".fields.len;
pub const default_cycle_widths = [_]CycleWidth{ .@"1/3", .@"1/2", .@"2/3" };
pub const default_cycle_mask: u8 = cycleWidthBit(.@"1/3") | cycleWidthBit(.@"1/2") | cycleWidthBit(.@"2/3");
pub const default_cycle_width: CycleWidth = .@"1/2";

pub const Settings = struct {
    keymaps: []const Keymap,
    edge_cycles: ?[]const CycleWidth = null,
    corner_cycles: ?[]const CycleWidth = null,
    center_cycles: ?[]const CycleWidth = null,
    default_edge_cycle_width: ?CycleWidth = null,
    default_corner_cycle_width: ?CycleWidth = null,
    default_center_cycle_width: ?CycleWidth = null,
    smart_fill: ?bool = null,
    // Deprecated aliases retained so existing settings files can be migrated.
    smart_edge_fill: ?bool = null,
    smart_corner_fill: ?bool = null,
};

pub const LoadedKeymap = struct {
    modifiers: u32,
    key: u32,
    action: Action,
    snapshot_index: u4,
};

pub const LoadedSettings = struct {
    keymaps: []LoadedKeymap,
    edge_cycles: u8,
    corner_cycles: u8,
    center_cycles: u8,
    default_edge_cycle_width: CycleWidth,
    default_corner_cycle_width: CycleWidth,
    default_center_cycle_width: CycleWidth,
    smart_fill: bool,
    path: []const u8,
};

const ParsedSettings = struct {
    keymaps: []LoadedKeymap,
    edge_cycles: u8,
    corner_cycles: u8,
    center_cycles: u8,
    default_edge_cycle_width: CycleWidth,
    default_corner_cycle_width: CycleWidth,
    default_center_cycle_width: CycleWidth,
    smart_fill: bool,
    migrated: bool,
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
        error.FileNotFound => createDefaultFile(io, allocator, settings_dir, settings_path) catch |create_err| {
            std.log.warn("could not create settings file ({s}); using defaults", .{@errorName(create_err)});
            return .{
                .keymaps = try loadDefaultKeymaps(allocator),
                .edge_cycles = default_cycle_mask,
                .corner_cycles = default_cycle_mask,
                .center_cycles = default_cycle_mask,
                .default_edge_cycle_width = default_cycle_width,
                .default_corner_cycle_width = default_cycle_width,
                .default_center_cycle_width = default_cycle_width,
                .smart_fill = true,
                .path = settings_path,
            };
        },
        else => {
            std.log.warn("could not read settings file ({s}); using defaults", .{@errorName(err)});
            return .{
                .keymaps = try loadDefaultKeymaps(allocator),
                .edge_cycles = default_cycle_mask,
                .corner_cycles = default_cycle_mask,
                .center_cycles = default_cycle_mask,
                .default_edge_cycle_width = default_cycle_width,
                .default_corner_cycle_width = default_cycle_width,
                .default_center_cycle_width = default_cycle_width,
                .smart_fill = true,
                .path = settings_path,
            };
        },
    };
    defer allocator.free(contents);

    const parsed = parseSettings(allocator, contents) catch |err| {
        std.log.warn("could not parse settings file ({s}); using defaults", .{@errorName(err)});
        return .{
            .keymaps = try loadDefaultKeymaps(allocator),
            .edge_cycles = default_cycle_mask,
            .corner_cycles = default_cycle_mask,
            .center_cycles = default_cycle_mask,
            .default_edge_cycle_width = default_cycle_width,
            .default_corner_cycle_width = default_cycle_width,
            .default_center_cycle_width = default_cycle_width,
            .smart_fill = true,
            .path = settings_path,
        };
    };
    if (parsed.migrated) {
        save(io, allocator, settings_path, parsed.keymaps, parsed.edge_cycles, parsed.corner_cycles, parsed.center_cycles, parsed.default_edge_cycle_width, parsed.default_corner_cycle_width, parsed.default_center_cycle_width, parsed.smart_fill) catch |err| {
            std.log.warn("could not save migrated settings file: {s}", .{@errorName(err)});
        };
    }
    return .{
        .keymaps = parsed.keymaps,
        .edge_cycles = parsed.edge_cycles,
        .corner_cycles = parsed.corner_cycles,
        .center_cycles = parsed.center_cycles,
        .default_edge_cycle_width = parsed.default_edge_cycle_width,
        .default_corner_cycle_width = parsed.default_corner_cycle_width,
        .default_center_cycle_width = parsed.default_center_cycle_width,
        .smart_fill = parsed.smart_fill,
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
        Settings{
            .keymaps = &default_keymaps,
            .edge_cycles = &default_cycle_widths,
            .corner_cycles = &default_cycle_widths,
            .center_cycles = &default_cycle_widths,
            .default_edge_cycle_width = default_cycle_width,
            .default_corner_cycle_width = default_cycle_width,
            .default_center_cycle_width = default_cycle_width,
            .smart_fill = true,
        },
        .{ .whitespace = .indent_2, .emit_null_optional_fields = false },
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

fn runtimeAction(action: SerializedAction) ?Action {
    return switch (action) {
        .edge_left => .edge_left,
        .edge_right => .edge_right,
        .edge_top => .edge_top,
        .edge_bottom => .edge_bottom,
        .corner_top_left => .corner_top_left,
        .corner_top_right => .corner_top_right,
        .corner_bottom_left => .corner_bottom_left,
        .corner_bottom_right => .corner_bottom_right,
        .maximize => .maximize,
        .center => .center,
        .store_snapshot => .store_snapshot,
        .recall_snapshot => .recall_snapshot,
        .always_on_top => null,
    };
}

fn serializedAction(action: Action) SerializedAction {
    return switch (action) {
        .edge_left => .edge_left,
        .edge_right => .edge_right,
        .edge_top => .edge_top,
        .edge_bottom => .edge_bottom,
        .corner_top_left => .corner_top_left,
        .corner_top_right => .corner_top_right,
        .corner_bottom_left => .corner_bottom_left,
        .corner_bottom_right => .corner_bottom_right,
        .maximize => .maximize,
        .center => .center,
        .store_snapshot => .store_snapshot,
        .recall_snapshot => .recall_snapshot,
    };
}

fn parseSettings(allocator: std.mem.Allocator, contents: []const u8) !ParsedSettings {
    const parsed = try std.json.parseFromSlice(Settings, allocator, contents, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value.keymaps.len > 256) return error.TooManyKeymaps;

    var active_count: usize = 0;
    for (parsed.value.keymaps) |keymap| {
        if (runtimeAction(keymap.action) != null) active_count += 1;
    }
    const loaded = try allocator.alloc(LoadedKeymap, active_count);
    errdefer allocator.free(loaded);
    var loaded_index: usize = 0;
    for (parsed.value.keymaps) |keymap| {
        const action = runtimeAction(keymap.action) orelse continue;
        const is_snapshot = action == .store_snapshot or action == .recall_snapshot;
        if (is_snapshot and keymap.snapshot_index == null) return error.MissingSnapshotIndex;
        if (!is_snapshot and keymap.snapshot_index != null) return error.UnexpectedSnapshotIndex;

        var modifiers: u32 = 0;
        for (keymap.modifiers) |modifier| modifiers |= switch (modifier) {
            .alt => mod_alt,
            .control => mod_control,
            .shift => mod_shift,
            .win => mod_win,
        };
        loaded[loaded_index] = .{
            .modifiers = modifiers,
            .key = try keyCode(keymap.key),
            .action = action,
            .snapshot_index = keymap.snapshot_index orelse 0,
        };
        loaded_index += 1;
    }
    const edge_cycles = try cycleMask(parsed.value.edge_cycles orelse &default_cycle_widths);
    const corner_cycles = try cycleMask(parsed.value.corner_cycles orelse &default_cycle_widths);
    const center_cycles = try cycleMask(parsed.value.center_cycles orelse &default_cycle_widths);
    const default_edge_cycle_width = normalizedDefaultWidth(edge_cycles, parsed.value.default_edge_cycle_width);
    const default_corner_cycle_width = normalizedDefaultWidth(corner_cycles, parsed.value.default_corner_cycle_width);
    const default_center_cycle_width = normalizedDefaultWidth(center_cycles, parsed.value.default_center_cycle_width);
    const smart_fill = parsed.value.smart_fill orelse
        ((parsed.value.smart_edge_fill orelse true) and (parsed.value.smart_corner_fill orelse true));
    return .{
        .keymaps = loaded,
        .edge_cycles = edge_cycles,
        .corner_cycles = corner_cycles,
        .center_cycles = center_cycles,
        .default_edge_cycle_width = default_edge_cycle_width,
        .default_corner_cycle_width = default_corner_cycle_width,
        .default_center_cycle_width = default_center_cycle_width,
        .smart_fill = smart_fill,
        .migrated = active_count != parsed.value.keymaps.len or
            parsed.value.edge_cycles == null or
            parsed.value.corner_cycles == null or
            parsed.value.center_cycles == null or
            !defaultWidthIsValid(edge_cycles, parsed.value.default_edge_cycle_width) or
            !defaultWidthIsValid(corner_cycles, parsed.value.default_corner_cycle_width) or
            !defaultWidthIsValid(center_cycles, parsed.value.default_center_cycle_width) or
            parsed.value.smart_fill == null or
            parsed.value.smart_edge_fill != null or
            parsed.value.smart_corner_fill != null,
    };
}

pub fn parse(allocator: std.mem.Allocator, contents: []const u8) ![]LoadedKeymap {
    return (try parseSettings(allocator, contents)).keymaps;
}

fn loadDefaultKeymaps(allocator: std.mem.Allocator) ![]LoadedKeymap {
    const contents = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(
        Settings{
            .keymaps = &default_keymaps,
            .edge_cycles = &default_cycle_widths,
            .corner_cycles = &default_cycle_widths,
            .center_cycles = &default_cycle_widths,
            .default_edge_cycle_width = default_cycle_width,
            .default_corner_cycle_width = default_cycle_width,
            .default_center_cycle_width = default_cycle_width,
            .smart_fill = true,
        },
        .{ .emit_null_optional_fields = false },
    )});
    defer allocator.free(contents);
    return parse(allocator, contents);
}

pub fn save(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    keymaps: []const LoadedKeymap,
    edge_cycles: u8,
    corner_cycles: u8,
    center_cycles: u8,
    default_edge_cycle_width: CycleWidth,
    default_corner_cycle_width: CycleWidth,
    default_center_cycle_width: CycleWidth,
    smart_fill: bool,
) !void {
    if (edge_cycles == 0 or corner_cycles == 0 or center_cycles == 0) return error.EmptyCycleWidths;
    if (!defaultWidthIsValid(edge_cycles, default_edge_cycle_width) or
        !defaultWidthIsValid(corner_cycles, default_corner_cycle_width) or
        !defaultWidthIsValid(center_cycles, default_center_cycle_width)) return error.DisabledDefaultCycleWidth;
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
            .action = serializedAction(keymap.action),
            .snapshot_index = if (keymap.action == .store_snapshot or keymap.action == .recall_snapshot)
                keymap.snapshot_index
            else
                null,
        };
    }

    var edge_cycle_storage: [cycle_width_count]CycleWidth = undefined;
    var corner_cycle_storage: [cycle_width_count]CycleWidth = undefined;
    var center_cycle_storage: [cycle_width_count]CycleWidth = undefined;
    const contents = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(
        Settings{
            .keymaps = serialized,
            .edge_cycles = cycleWidthsFromMask(edge_cycles, &edge_cycle_storage),
            .corner_cycles = cycleWidthsFromMask(corner_cycles, &corner_cycle_storage),
            .center_cycles = cycleWidthsFromMask(center_cycles, &center_cycle_storage),
            .default_edge_cycle_width = default_edge_cycle_width,
            .default_corner_cycle_width = default_corner_cycle_width,
            .default_center_cycle_width = default_center_cycle_width,
            .smart_fill = smart_fill,
        },
        .{ .whitespace = .indent_2, .emit_null_optional_fields = false },
    )});
    defer allocator.free(contents);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, contents);
    try atomic.replace(io);
}

pub fn cycleWidthBit(width: CycleWidth) u8 {
    return @as(u8, 1) << @intFromEnum(width);
}

fn cycleMask(widths: []const CycleWidth) !u8 {
    if (widths.len == 0) return error.EmptyCycleWidths;
    var mask: u8 = 0;
    for (widths) |width| {
        const bit = cycleWidthBit(width);
        if (mask & bit != 0) return error.DuplicateCycleWidth;
        mask |= bit;
    }
    return mask;
}

fn defaultWidthIsValid(mask: u8, width: ?CycleWidth) bool {
    const configured = width orelse return false;
    return mask & cycleWidthBit(configured) != 0;
}

fn normalizedDefaultWidth(mask: u8, width: ?CycleWidth) CycleWidth {
    const candidate = width orelse default_cycle_width;
    if (mask & cycleWidthBit(candidate) != 0) return candidate;
    inline for (@typeInfo(CycleWidth).@"enum".fields) |field| {
        const fallback: CycleWidth = @enumFromInt(field.value);
        if (mask & cycleWidthBit(fallback) != 0) return fallback;
    }
    unreachable;
}

fn cycleWidthsFromMask(mask: u8, storage: *[cycle_width_count]CycleWidth) []const CycleWidth {
    var count: usize = 0;
    inline for (@typeInfo(CycleWidth).@"enum".fields) |field| {
        const width: CycleWidth = @enumFromInt(field.value);
        if (mask & cycleWidthBit(width) != 0) {
            storage[count] = width;
            count += 1;
        }
    }
    return storage[0..count];
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

test "deprecated keymaps are removed during migration" {
    const contents =
        \\{"keymaps":[
        \\  {"modifiers":["win"],"key":"left","action":"edge_left"},
        \\  {"modifiers":["win","alt"],"key":"a","action":"always_on_top"},
        \\  {"modifiers":["win"],"key":"1","action":"recall_snapshot","snapshot_index":0}
        \\]}
    ;
    const parsed = try parseSettings(std.testing.allocator, contents);
    defer std.testing.allocator.free(parsed.keymaps);
    try std.testing.expect(parsed.migrated);
    try std.testing.expectEqual(@as(usize, 2), parsed.keymaps.len);
    try std.testing.expectEqual(Action.edge_left, parsed.keymaps[0].action);
    try std.testing.expectEqual(Action.recall_snapshot, parsed.keymaps[1].action);
}

test "missing cycle widths migrate to defaults" {
    const parsed = try parseSettings(std.testing.allocator,
        \\{"keymaps":[]}
    );
    defer std.testing.allocator.free(parsed.keymaps);
    try std.testing.expect(parsed.migrated);
    try std.testing.expectEqual(default_cycle_mask, parsed.edge_cycles);
    try std.testing.expectEqual(default_cycle_mask, parsed.corner_cycles);
    try std.testing.expectEqual(default_cycle_mask, parsed.center_cycles);
    try std.testing.expectEqual(default_cycle_width, parsed.default_edge_cycle_width);
    try std.testing.expectEqual(default_cycle_width, parsed.default_corner_cycle_width);
    try std.testing.expectEqual(default_cycle_width, parsed.default_center_cycle_width);
    try std.testing.expect(parsed.smart_fill);
}

test "parses configured cycle widths" {
    const parsed = try parseSettings(std.testing.allocator,
        \\{"keymaps":[],"edge_cycles":["1/4","3/4"],"corner_cycles":["1/2"],"center_cycles":["1/3","2/3"],"default_edge_cycle_width":"3/4","default_corner_cycle_width":"1/2","default_center_cycle_width":"2/3","smart_fill":false}
    );
    defer std.testing.allocator.free(parsed.keymaps);
    try std.testing.expect(!parsed.migrated);
    try std.testing.expectEqual(cycleWidthBit(.@"1/4") | cycleWidthBit(.@"3/4"), parsed.edge_cycles);
    try std.testing.expectEqual(cycleWidthBit(.@"1/2"), parsed.corner_cycles);
    try std.testing.expectEqual(cycleWidthBit(.@"1/3") | cycleWidthBit(.@"2/3"), parsed.center_cycles);
    try std.testing.expectEqual(CycleWidth.@"3/4", parsed.default_edge_cycle_width);
    try std.testing.expectEqual(CycleWidth.@"1/2", parsed.default_corner_cycle_width);
    try std.testing.expectEqual(CycleWidth.@"2/3", parsed.default_center_cycle_width);
    try std.testing.expect(!parsed.smart_fill);
}

test "legacy smart fill settings migrate to one conservative value" {
    const parsed = try parseSettings(std.testing.allocator,
        \\{"keymaps":[],"smart_edge_fill":false,"smart_corner_fill":true}
    );
    defer std.testing.allocator.free(parsed.keymaps);
    try std.testing.expect(parsed.migrated);
    try std.testing.expect(!parsed.smart_fill);
}

test "disabled default cycle width migrates to first enabled width" {
    const parsed = try parseSettings(std.testing.allocator,
        \\{"keymaps":[],"edge_cycles":["1/3","2/3"],"corner_cycles":["1/2"],"center_cycles":["1/2"],"default_edge_cycle_width":"1/2","default_corner_cycle_width":"1/2","default_center_cycle_width":"1/2"}
    );
    defer std.testing.allocator.free(parsed.keymaps);
    try std.testing.expect(parsed.migrated);
    try std.testing.expectEqual(CycleWidth.@"1/3", parsed.default_edge_cycle_width);
}

test "rejects an empty cycle width group" {
    try std.testing.expectError(error.EmptyCycleWidths, parseSettings(std.testing.allocator,
        \\{"keymaps":[],"edge_cycles":[],"corner_cycles":["1/2"],"center_cycles":["1/2"]}
    ));
}

test "default keymaps round trip through JSON" {
    const contents = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{std.json.fmt(
        Settings{
            .keymaps = &default_keymaps,
            .edge_cycles = &default_cycle_widths,
            .corner_cycles = &default_cycle_widths,
            .center_cycles = &default_cycle_widths,
            .default_edge_cycle_width = default_cycle_width,
            .default_corner_cycle_width = default_cycle_width,
            .default_center_cycle_width = default_cycle_width,
        },
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
