const std = @import("std");
const geometry = @import("geometry.zig");

pub const Store = struct {
    const capacity = 64;

    const Entry = struct {
        key: usize = 0,
        bounds: geometry.Rect = undefined,
        occupied: bool = false,
    };

    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    next_replacement: usize = 0,

    pub fn remember(self: *Store, key: usize, bounds: geometry.Rect) void {
        for (&self.entries) |*entry| {
            if (entry.occupied and entry.key == key) {
                entry.bounds = bounds;
                return;
            }
        }

        for (&self.entries) |*entry| {
            if (!entry.occupied) {
                entry.* = .{ .key = key, .bounds = bounds, .occupied = true };
                return;
            }
        }

        self.entries[self.next_replacement] = .{ .key = key, .bounds = bounds, .occupied = true };
        self.next_replacement = (self.next_replacement + 1) % capacity;
    }

    pub fn get(self: *const Store, key: usize) ?geometry.Rect {
        for (self.entries) |entry| {
            if (entry.occupied and entry.key == key) return entry.bounds;
        }
        return null;
    }

    pub fn remove(self: *Store, key: usize) void {
        for (&self.entries) |*entry| {
            if (entry.occupied and entry.key == key) {
                entry.occupied = false;
                return;
            }
        }
    }
};

test "store tracks and updates independent window bounds" {
    var store: Store = .{};
    const first: geometry.Rect = .{ .left = 10, .top = 20, .right = 810, .bottom = 620 };
    const updated: geometry.Rect = .{ .left = 30, .top = 40, .right = 1030, .bottom = 740 };
    const second: geometry.Rect = .{ .left = -900, .top = 0, .right = 0, .bottom = 700 };

    store.remember(11, first);
    store.remember(22, second);
    store.remember(11, updated);

    try std.testing.expectEqual(updated, store.get(11).?);
    try std.testing.expectEqual(second, store.get(22).?);
}

test "removing window bounds does not affect other windows" {
    var store: Store = .{};
    const first: geometry.Rect = .{ .left = 10, .top = 20, .right = 810, .bottom = 620 };
    const second: geometry.Rect = .{ .left = -900, .top = 0, .right = 0, .bottom = 700 };

    store.remember(11, first);
    store.remember(22, second);
    store.remove(11);

    try std.testing.expectEqual(null, store.get(11));
    try std.testing.expectEqual(second, store.get(22).?);
}
