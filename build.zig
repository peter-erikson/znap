const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const console = b.option(bool, "console", "Build with a console subsystem for diagnostics") orelse false;

    const win32_headers = b.addTranslateC(.{
        .root_source_file = b.path("src/win32.h"),
        .target = target,
        // Arocc currently emits unused fortified CRT helpers for the Windows
        // SDK headers in optimized translate-c modules. These are declarations
        // only, so compiling this bindings module in Debug has no runtime cost.
        .optimize = .Debug,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "win32", .module = win32_headers.createModule() }},
    });
    root_module.addCSourceFile(.{ .file = b.path("src/win32_shim.c"), .flags = &.{} });
    root_module.addWin32ResourceFile(.{ .file = b.path("resources.rc") });
    inline for (&.{ "user32", "gdi32", "dwmapi", "shell32", "advapi32" }) |lib| {
        root_module.linkSystemLibrary(lib, .{});
    }

    const exe = b.addExecutable(.{ .name = "Znap", .root_module = root_module });
    exe.subsystem = if (console) .Console else .Windows;
    b.installArtifact(exe);

    const geometry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/geometry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_geometry_tests = b.addRunArtifact(geometry_tests);
    const window_state_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/window_states.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_window_state_tests = b.addRunArtifact(window_state_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_geometry_tests.step);
    test_step.dependOn(&run_window_state_tests.step);
}
