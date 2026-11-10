//! Persisted preferences for the extra camera controls.
//!
//! The frozen white-balance and power-line settings are compile-time constants
//! and are deliberately absent from this file.
//!
//! The settings live at `%LOCALAPPDATA%\CameraProject\settings.zon` so that the
//! normal and the elevated copies of the programs share one file.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// Upper bound for the settings file; it is only a few hundred bytes.
pub const max_file_bytes: usize = 16 * 1024;

/// Bumped when the meaning of a field changes incompatibly.
pub const current_version: u32 = 1;

const folder_name = "CameraProject";
const file_name = "settings.zon";

extern "kernel32" fn GetEnvironmentVariableW(
    name: [*:0]const u16,
    buffer: [*]u16,
    size: u32,
) u32;

/// One user-managed control, keyed by `controls.Spec.name`.
pub const Entry = struct {
    /// Stable key from `controls.specs`.
    name: []const u8,
    /// False: the control is left exactly as the camera or another app set it.
    manage: bool = false,
    /// True: force the driver's automatic mode; `value` is then unused.
    auto: bool = false,
    /// Manual value enforced when `manage` is true and `auto` is false.
    value: i32 = 0,
};

pub const Settings = struct {
    version: u32 = current_version,
    /// Only controls that were saved at least once appear here.
    controls: []const Entry = &.{},

    pub fn find(self: *const Settings, name: []const u8) ?*const Entry {
        for (self.controls) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn findMut(self: *Settings, name: []const u8) ?*Entry {
        for (self.controls) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// True when at least one control should be enforced.
    pub fn hasManagedControls(self: *const Settings) bool {
        for (self.controls) |entry| {
            if (entry.manage) return true;
        }
        return false;
    }
};

/// A parsed settings file and the arena that owns its strings.
pub const Loaded = struct {
    settings: Settings,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// `%LOCALAPPDATA%\CameraProject`
pub fn folderPath(allocator: Allocator) ![]u8 {
    const local_app_data = try localAppData(allocator);
    defer allocator.free(local_app_data);
    return allocator.print("{s}\\{s}", .{ local_app_data, folder_name });
}

/// `%LOCALAPPDATA%\CameraProject\settings.zon`
pub fn filePath(allocator: Allocator) ![]u8 {
    const folder = try folderPath(allocator);
    defer allocator.free(folder);
    return allocator.print("{s}\\{s}", .{ folder, file_name });
}

/// Reads the settings file, or null when it does not exist yet. Caller owns
/// the returned bytes.
pub fn readFile(io: std.Io, allocator: Allocator) !?[:0]u8 {
    const path = try filePath(allocator);
    defer allocator.free(path);

    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(max_file_bytes),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Parses settings bytes. The returned value owns `arena`.
pub fn parse(bytes: [:0]const u8, path: []const u8, gpa: Allocator) !Loaded {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const settings = std.zon.parse.fromSlice(Settings, .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .source = bytes,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.ParseZon => {
            diagnostics.log(path);
            return error.InvalidSettingsFile;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (settings.version > current_version) return error.UnsupportedSettingsVersion;
    return .{ .settings = settings, .arena = arena };
}

/// Reads and parses the settings file, or null when it does not exist yet.
pub fn load(io: std.Io, gpa: Allocator, scratch: Allocator) !?Loaded {
    const path = try filePath(scratch);
    defer scratch.free(path);

    const bytes = (try readFile(io, scratch)) orelse return null;
    defer scratch.free(bytes[0..bytes.len]);

    return try parse(bytes, path, gpa);
}

/// Writes the settings file, creating `%LOCALAPPDATA%\CameraProject` first.
pub fn save(io: std.Io, value: Settings, scratch: Allocator) !void {
    const folder = try folderPath(scratch);
    defer scratch.free(folder);
    const path = try filePath(scratch);
    defer scratch.free(path);

    try std.Io.Dir.cwd().createDirPath(io, folder);

    var buffer: [max_file_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}\n", .{std.zon.fmt(value, .{})});

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = writer.buffered(),
    });
}

fn localAppData(allocator: Allocator) ![]u8 {
    const wide_name = std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA");
    var buffer: [1024]u16 = undefined;
    const length = GetEnvironmentVariableW(wide_name, &buffer, buffer.len);
    if (length == 0 or length >= buffer.len) return error.LocalAppDataUnavailable;
    return std.unicode.utf16LeToUtf8Alloc(allocator, buffer[0..length]);
}

test "settings round-trip through zon" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const input = Settings{
        .controls = &.{
            .{ .name = "brightness", .manage = true, .value = 3 },
            .{ .name = "exposure", .manage = true, .auto = true, .value = -7 },
            .{ .name = "focus", .manage = false, .value = 12 },
        },
    };

    var buffer: [max_file_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}", .{std.zon.fmt(input, .{})});

    var sentinel_buffer: [max_file_bytes + 1]u8 = undefined;
    const text = writer.buffered();
    @memcpy(sentinel_buffer[0..text.len], text);
    sentinel_buffer[text.len] = 0;

    var loaded = try parse(sentinel_buffer[0..text.len :0], "settings.zon", std.testing.allocator);
    defer loaded.deinit();

    try std.testing.expectEqual(current_version, loaded.settings.version);
    try std.testing.expectEqual(@as(usize, 3), loaded.settings.controls.len);
    try std.testing.expect(loaded.settings.hasManagedControls());

    const brightness = loaded.settings.find("brightness").?;
    try std.testing.expect(brightness.manage);
    try std.testing.expect(!brightness.auto);
    try std.testing.expectEqual(@as(i32, 3), brightness.value);

    const exposure = loaded.settings.find("exposure").?;
    try std.testing.expect(exposure.auto);
    try std.testing.expectEqual(@as(i32, -7), exposure.value);

    const focus = loaded.settings.find("focus").?;
    try std.testing.expect(!focus.manage);
    try std.testing.expectEqual(@as(i32, 12), focus.value);
    _ = scratch;
}

test "an empty settings file means nothing is managed" {
    var loaded = try parse(".{ .version = 1, .controls = .{} }", "settings.zon", std.testing.allocator);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 0), loaded.settings.controls.len);
    try std.testing.expect(!loaded.settings.hasManagedControls());
}
