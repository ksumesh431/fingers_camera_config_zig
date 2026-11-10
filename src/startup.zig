const std = @import("std");
const winutil = @import("winutil.zig");

/// Name of the Task Scheduler task that starts the daemon at logon.
pub const task_name = "CameraProjectCameraDaemon";

const schtasks = "schtasks.exe";

/// Registers a logon task that starts `camera-probe.exe daemon` in the current
/// user's interactive session with the highest available privileges.
pub fn install(io: std.Io, allocator: std.mem.Allocator) !void {
    if (!winutil.isElevated()) {
        winutil.printRequiresElevation("install-startup");
        return error.RequiresElevation;
    }

    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);
    // The logon task starts the window-subsystem daemon next to this binary,
    // so logon shows no console window.
    const folder = std.fs.path.dirname(exe) orelse ".";
    const daemon_exe = try std.fs.path.join(allocator, &.{ folder, "camera-daemon.exe" });
    defer allocator.free(daemon_exe);
    // A quoted path is always safe for Task Scheduler, with or without spaces.
    const action = try allocator.print("\"{s}\"", .{daemon_exe});
    defer allocator.free(action);

    std.debug.print(
        "Registering the Windows logon task \"{s}\".\n" ++
            "  program: {s}\n" ++
            "  trigger: logon of the current user\n" ++
            "  run level: highest available (elevated, no UAC prompt)\n" ++
            "  window: none (camera-daemon is a GUI-subsystem binary)\n",
        .{ task_name, action },
    );

    const term = try run(io, &.{
        schtasks, "/Create",
        "/SC",    "ONLOGON",
        "/TN",    task_name,
        "/TR",    action,
        "/RL",    "HIGHEST",
        "/F",
    });
    if (!term.success()) {
        std.debug.print(
            "\nschtasks could not create the task (exit code {d}).\n",
            .{termCode(term)},
        );
        return error.StartupTaskCreateFailed;
    }

    std.debug.print(
        "\nThe daemon now starts automatically at logon.\n" ++
            "Start it right now without logging off:\n" ++
            "  schtasks /Run /TN \"{s}\"\n" ++
            "Remove it again with:\n" ++
            "  camera-probe uninstall-startup\n",
        .{task_name},
    );
}

/// Deletes the logon task. A daemon that is already running keeps running.
pub fn uninstall(io: std.Io) !void {
    if (!winutil.isElevated()) {
        winutil.printRequiresElevation("uninstall-startup");
        return error.RequiresElevation;
    }

    const term = try run(io, &.{
        schtasks, "/Delete", "/TN", task_name, "/F",
    });
    if (!term.success()) {
        std.debug.print(
            "\nschtasks could not delete the task (exit code {d}).\n" ++
                "The task \"{s}\" may not be installed.\n",
            .{ termCode(term), task_name },
        );
        return error.StartupTaskDeleteFailed;
    }

    std.debug.print(
        "Removed the logon task \"{s}\".\n" ++
            "A daemon that is already running is not stopped by this.\n",
        .{task_name},
    );
}

pub fn showStatus(io: std.Io) !void {
    const term = try runWith(io, &.{
        schtasks, "/Query", "/TN", task_name, "/FO", "LIST",
    }, .inherit, .ignore);
    if (term.success()) return;

    std.debug.print(
        "\nThe logon task \"{s}\" is not installed.\n" ++
            "Install it from an elevated PowerShell with:\n" ++
            "  camera-probe install-startup\n",
        .{task_name},
    );
}

fn run(io: std.Io, argv: []const []const u8) !std.process.Child.Term {
    return runWith(io, argv, .inherit, .inherit);
}

/// True when the logon task exists. Quiet: nothing is printed.
pub fn isInstalled(io: std.Io) bool {
    const term = runWith(io, &.{
        schtasks, "/Query", "/TN", task_name,
    }, .ignore, .ignore) catch return false;
    return term.success();
}

fn runWith(
    io: std.Io,
    argv: []const []const u8,
    stdout: std.process.SpawnOptions.StdIo,
    stderr: std.process.SpawnOptions.StdIo,
) !std.process.Child.Term {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = stdout,
        .stderr = stderr,
    });
    return child.wait(io);
}

fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 255,
    };
}
