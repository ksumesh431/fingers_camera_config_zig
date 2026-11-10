//! `camera-daemon.exe`: the logon daemon, built as a window-subsystem binary.
//!
//! Task Scheduler starts this executable so no console window ever appears at
//! logon. `camera-probe daemon` remains the interactive console form for
//! debugging; both run the same `daemon.zig` controller.
//!
//! Because there is no console, every `std.debug.print` (and a panic trace)
//! is pointed at `%LOCALAPPDATA%\CameraProject\daemon.log` instead of stderr.
const std = @import("std");
const daemon = @import("daemon.zig");
const settings = @import("settings.zig");

pub fn main(init: std.process.Init) !void {
    redirectStderrToLog(init.io);
    try daemon.run(init.io, 0);
}

/// Sends this process's stderr to the daemon log, truncating it on every
/// start. Zig's debug printer resolves stderr from
/// `ProcessParameters.hStdError` when it first writes, so setting the field
/// before any print captures the whole run, including crash output.
///
/// Best effort: when the log cannot be opened the daemon still runs, it just
/// logs nowhere.
fn redirectStderrToLog(io: std.Io) void {
    const allocator = std.heap.page_allocator;

    const folder = settings.folderPath(allocator) catch return;
    defer allocator.free(folder);
    std.Io.Dir.cwd().createDirPath(io, folder) catch return;

    const path = allocator.print("{s}\\daemon.log", .{folder}) catch return;
    defer allocator.free(path);

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    std.os.windows.peb().ProcessParameters.hStdError = file.handle;
}
