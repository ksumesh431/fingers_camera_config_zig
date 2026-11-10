const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkWindowsLibraries(exe_module);

    const exe = b.addExecutable(.{
        .name = "camera-probe",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const gui = addGui(b, target, optimize);
    b.installArtifact(gui);

    const daemon_exe = addDaemon(b, target, optimize);
    b.installArtifact(daemon_exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    const run_step = b.step("run", "Run the read-only camera probe");
    run_step.dependOn(&run.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkWindowsLibraries(test_module);
    const unit_tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const fmt = b.addFmt(.{ .paths = b.pathList(&.{ "src", "build.zig" }) });
    const fmt_step = b.step("fmt", "Format Zig sources");
    fmt_step.dependOn(&fmt.step);
}

fn linkWindowsLibraries(module: *std.Build.Module) void {
    module.linkSystemLibrary("ole32", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("oleaut32", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("advapi32", .{ .use_pkg_config = .no });
}

/// The logon daemon. It is a window-subsystem binary so Task Scheduler starts
/// it without ever creating a console window; it logs to
/// `%LOCALAPPDATA%\CameraProject\daemon.log`.
fn addDaemon(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const daemon_module = b.createModule(.{
        .root_source_file = b.path("src/daemon_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkWindowsLibraries(daemon_module);

    const daemon_exe = b.addExecutable(.{
        .name = "camera-daemon",
        .root_module = daemon_module,
    });
    daemon_exe.subsystem = .windows;
    return daemon_exe;
}

/// The NanoUI settings window. It is a separate executable so the console
/// probe and daemon keep working without the GUI dependency at run time.
fn addGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const nanoui = b.dependency("nanoui", .{
        .target = target,
        .optimize = optimize,
        .webview2 = "none",
    });

    const gui_module = b.createModule(.{
        .root_source_file = b.path("src/gui.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_module.addImport("nanoui", nanoui.module("nanoui"));
    linkWindowsLibraries(gui_module);

    const gui = b.addExecutable(.{
        .name = "camera-settings",
        .root_module = gui_module,
    });
    // A window app, not a console app: launching it must not open a terminal.
    gui.subsystem = .windows;
    return gui;
}
