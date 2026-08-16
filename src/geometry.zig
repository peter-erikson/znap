const std = @import("std");

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
};

pub fn overlapsBeyondTolerance(a: Rect, b: Rect, tolerance: i32) bool {
    const overlap_width = @min(a.right, b.right) - @max(a.left, b.left);
    const overlap_height = @min(a.bottom, b.bottom) - @max(a.top, b.top);
    return overlap_width > tolerance and overlap_height > tolerance;
}

pub fn approximatelyEqual(a: Rect, b: Rect, tolerance: i32) bool {
    return coordinateWithinTolerance(a.left, b.left, tolerance) and
        coordinateWithinTolerance(a.top, b.top, tolerance) and
        coordinateWithinTolerance(a.right, b.right, tolerance) and
        coordinateWithinTolerance(a.bottom, b.bottom, tolerance);
}

fn coordinateWithinTolerance(a: i32, b: i32, tolerance: i32) bool {
    return @abs(@as(i64, a) - @as(i64, b)) <= tolerance;
}

pub const Placement = enum {
    left_half,
    left_two_thirds,
    left_one_third,
    right_half,
    right_two_thirds,
    right_one_third,
    top_half,
    top_two_thirds,
    top_one_third,
    bottom_half,
    bottom_two_thirds,
    bottom_one_third,
    top_left_half,
    top_left_two_thirds,
    top_left_one_third,
    top_right_half,
    top_right_two_thirds,
    top_right_one_third,
    bottom_left_half,
    bottom_left_two_thirds,
    bottom_left_one_third,
    bottom_right_half,
    bottom_right_two_thirds,
    bottom_right_one_third,
    center_half,
    center_two_thirds,
    center_one_third,
};

fn left(d: Rect, numerator: i32, denominator: i32) Rect {
    return .{ .left = d.left, .top = d.top, .right = d.left + @divTrunc(d.width() * numerator, denominator), .bottom = d.bottom };
}

fn right(d: Rect, numerator: i32, denominator: i32) Rect {
    const width = @divTrunc(d.width() * numerator, denominator);
    return .{ .left = d.right - width, .top = d.top, .right = d.right, .bottom = d.bottom };
}

fn top(d: Rect, numerator: i32, denominator: i32) Rect {
    return .{ .left = d.left, .top = d.top, .right = d.right, .bottom = d.top + @divTrunc(d.height() * numerator, denominator) };
}

fn bottom(d: Rect, numerator: i32, denominator: i32) Rect {
    const height = @divTrunc(d.height() * numerator, denominator);
    return .{ .left = d.left, .top = d.bottom - height, .right = d.right, .bottom = d.bottom };
}

fn merge(horizontal: Rect, vertical: Rect) Rect {
    return .{ .left = horizontal.left, .top = vertical.top, .right = horizontal.right, .bottom = vertical.bottom };
}

fn centerFullHeight(d: Rect, numerator: i32, denominator: i32) Rect {
    const width = @divTrunc(d.width() * numerator, denominator);
    const left_edge = d.left + @divTrunc(d.width() - width, 2);
    return .{ .left = left_edge, .top = d.top, .right = left_edge + width, .bottom = d.bottom };
}

pub fn place(placement: Placement, display: Rect, _: Rect) Rect {
    return switch (placement) {
        .left_half => left(display, 1, 2),
        .left_two_thirds => left(display, 2, 3),
        .left_one_third => left(display, 1, 3),
        .right_half => right(display, 1, 2),
        .right_two_thirds => right(display, 2, 3),
        .right_one_third => right(display, 1, 3),
        .top_half => top(display, 1, 2),
        .top_two_thirds => top(display, 2, 3),
        .top_one_third => top(display, 1, 3),
        .bottom_half => bottom(display, 1, 2),
        .bottom_two_thirds => bottom(display, 2, 3),
        .bottom_one_third => bottom(display, 1, 3),
        .top_left_half => merge(left(display, 1, 2), top(display, 1, 2)),
        .top_left_two_thirds => merge(left(display, 2, 3), top(display, 1, 2)),
        .top_left_one_third => merge(left(display, 1, 3), top(display, 1, 2)),
        .top_right_half => merge(right(display, 1, 2), top(display, 1, 2)),
        .top_right_two_thirds => merge(right(display, 2, 3), top(display, 1, 2)),
        .top_right_one_third => merge(right(display, 1, 3), top(display, 1, 2)),
        .bottom_left_half => merge(left(display, 1, 2), bottom(display, 1, 2)),
        .bottom_left_two_thirds => merge(left(display, 2, 3), bottom(display, 1, 2)),
        .bottom_left_one_third => merge(left(display, 1, 3), bottom(display, 1, 2)),
        .bottom_right_half => merge(right(display, 1, 2), bottom(display, 1, 2)),
        .bottom_right_two_thirds => merge(right(display, 2, 3), bottom(display, 1, 2)),
        .bottom_right_one_third => merge(right(display, 1, 3), bottom(display, 1, 2)),
        .center_half => centerFullHeight(display, 1, 2),
        .center_two_thirds => centerFullHeight(display, 2, 3),
        .center_one_third => centerFullHeight(display, 1, 3),
    };
}

pub fn nextCyclePlacement(cycle: []const Placement, current: Rect, display: Rect, tolerance: i32) Placement {
    std.debug.assert(cycle.len > 0);
    for (cycle, 0..) |placement, index| {
        if (approximatelyEqual(current, place(placement, display, current), tolerance)) {
            return cycle[(index + 1) % cycle.len];
        }
    }
    return cycle[0];
}

test "edge and corner placements preserve offset monitor coordinates" {
    const display: Rect = .{ .left = 100, .top = -900, .right = 2020, .bottom = 180 };
    try std.testing.expectEqual(Rect{ .left = 100, .top = -900, .right = 1060, .bottom = 180 }, place(.left_half, display, undefined));
    try std.testing.expectEqual(Rect{ .left = 740, .top = -900, .right = 2020, .bottom = -360 }, place(.top_right_two_thirds, display, undefined));
}

test "center placements fill height and cycle the edge widths" {
    const display: Rect = .{ .left = 100, .top = -900, .right = 2020, .bottom = 180 };
    try std.testing.expectEqual(Rect{ .left = 580, .top = -900, .right = 1540, .bottom = 180 }, place(.center_half, display, undefined));
    try std.testing.expectEqual(Rect{ .left = 420, .top = -900, .right = 1700, .bottom = 180 }, place(.center_two_thirds, display, undefined));
    try std.testing.expectEqual(Rect{ .left = 740, .top = -900, .right = 1380, .bottom = 180 }, place(.center_one_third, display, undefined));
}

test "overlap tolerance ignores thin edge and corner intersections" {
    const window: Rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 };

    try std.testing.expect(!overlapsBeyondTolerance(window, .{ .left = 98, .top = 0, .right = 150, .bottom = 100 }, 2));
    try std.testing.expect(overlapsBeyondTolerance(window, .{ .left = 97, .top = 0, .right = 150, .bottom = 100 }, 2));
    try std.testing.expect(!overlapsBeyondTolerance(window, .{ .left = 97, .top = 98, .right = 150, .bottom = 150 }, 2));
    try std.testing.expect(overlapsBeyondTolerance(window, .{ .left = 97, .top = 97, .right = 150, .bottom = 150 }, 2));
    try std.testing.expect(!overlapsBeyondTolerance(window, .{ .left = 100, .top = 0, .right = 150, .bottom = 100 }, 2));
}

test "cycle continues from matching geometry and starts at half otherwise" {
    const display: Rect = .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 };
    const cycle = [_]Placement{ .left_half, .left_two_thirds, .left_one_third };

    try std.testing.expectEqual(.left_half, nextCyclePlacement(&cycle, .{ .left = 100, .top = 100, .right = 700, .bottom = 700 }, display, 2));
    try std.testing.expectEqual(.left_two_thirds, nextCyclePlacement(&cycle, place(.left_half, display, undefined), display, 2));
    try std.testing.expectEqual(.left_one_third, nextCyclePlacement(&cycle, .{ .left = 1, .top = -1, .right = 799, .bottom = 901 }, display, 2));
    try std.testing.expectEqual(.left_half, nextCyclePlacement(&cycle, place(.left_one_third, display, undefined), display, 2));
}
