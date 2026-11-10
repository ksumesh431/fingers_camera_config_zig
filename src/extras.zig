//! Third daemon worker: keeps the user's extra camera controls applied.
//!
//! This worker is independent from the frozen white-balance poll and from the
//! ETW power-line refresh. It only ever touches the properties listed in
//! `controls.specs`, which excludes the frozen white balance and power line.
const std = @import("std");
const controls = @import("controls.zig");
const directshow = @import("directshow.zig");
const settings = @import("settings.zig");

const Allocator = std.mem.Allocator;

/// How often the settings file and the camera state are checked.
pub const poll_ms: u32 = 1000;
const retry_delay_ms: u32 = 5000;

const HANDLE = *anyopaque;

const target_name = "FINGERS Hi-Res 2K";
const target_usb_id = "vid_5843&pid_7884";

extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: u32) u32;

pub const Context = struct {
    shutdown_event: HANDLE,
    io: std.Io,
};

/// The last successfully parsed settings file and the bytes it came from.
const ConfigCache = struct {
    loaded: ?settings.Loaded = null,
    bytes: ?[]u8 = null,

    fn deinit(self: *ConfigCache, allocator: Allocator) void {
        if (self.loaded) |*loaded| loaded.deinit();
        if (self.bytes) |bytes| allocator.free(bytes);
        self.* = undefined;
    }

    /// Re-reads the file and re-parses it only when its bytes changed.
    fn refresh(self: *ConfigCache, io: std.Io, allocator: Allocator) void {
        const path = settings.filePath(allocator) catch return;
        defer allocator.free(path);

        const bytes = settings.readFile(io, allocator) catch |err| {
            std.debug.print(
                "[extras] settings read failed: {s}; keeping the previous values.\n",
                .{@errorName(err)},
            );
            return;
        } orelse {
            if (self.loaded != null) {
                std.debug.print(
                    "[extras] settings file removed; extra controls are no longer enforced.\n",
                    .{},
                );
                if (self.loaded) |*loaded| loaded.deinit();
                self.loaded = null;
                if (self.bytes) |previous| allocator.free(previous);
                self.bytes = null;
            }
            return;
        };

        if (self.bytes) |previous| {
            if (std.mem.eql(u8, previous, bytes)) {
                allocator.free(bytes[0..bytes.len]);
                return;
            }
            allocator.free(previous);
            self.bytes = null;
        }

        const loaded = settings.parse(bytes, path, allocator) catch |err| {
            std.debug.print(
                "[extras] settings parse failed: {s}; keeping the previous values.\n",
                .{@errorName(err)},
            );
            allocator.free(bytes[0..bytes.len]);
            return;
        };

        if (self.loaded) |*previous| previous.deinit();
        self.loaded = loaded;
        self.bytes = bytes[0..bytes.len];
        std.debug.print(
            "[extras] settings loaded: {d} control(s), {s}.\n",
            .{
                loaded.settings.controls.len,
                if (loaded.settings.hasManagedControls()) "enforcing" else "nothing managed",
            },
        );
    }

    fn current(self: *const ConfigCache) ?settings.Settings {
        if (self.loaded) |loaded| return loaded.settings;
        return null;
    }
};

pub fn workerMain(raw_context: ?*anyopaque) callconv(.winapi) u32 {
    const context: *Context = @ptrCast(@alignCast(raw_context orelse return 1));
    const allocator = std.heap.page_allocator;

    var cache: ConfigCache = .{};
    defer cache.deinit(allocator);

    var apartment: ?directshow.ComApartment = null;
    var camera: ?directshow.CameraDevice = null;
    defer {
        if (camera) |*open_camera| open_camera.deinit(allocator);
        if (apartment) |*open_apartment| open_apartment.deinit();
    }

    std.debug.print("[extras] worker started.\n", .{});

    while (!isStopped(context.shutdown_event)) {
        cache.refresh(context.io, allocator);

        const config = cache.current() orelse {
            waitFor(context.shutdown_event, poll_ms);
            continue;
        };
        if (!config.hasManagedControls()) {
            waitFor(context.shutdown_event, poll_ms);
            continue;
        }

        if (camera == null) {
            apartment = directshow.ComApartment.init() catch |err| {
                std.debug.print(
                    "[extras] COM init failed: {s}; retrying.\n",
                    .{@errorName(err)},
                );
                waitFor(context.shutdown_event, retry_delay_ms);
                continue;
            };

            camera = openTargetCamera(allocator) catch |err| {
                std.debug.print(
                    "[extras] camera open failed: {s}; retrying.\n",
                    .{@errorName(err)},
                );
                if (apartment) |*open_apartment| open_apartment.deinit();
                apartment = null;
                waitFor(context.shutdown_event, retry_delay_ms);
                continue;
            };
        }

        if (camera) |*open_camera| {
            const stats = controls.applySettings(open_camera, config, true);
            if (stats.failed > 0) {
                std.debug.print(
                    "[extras] {d} control(s) failed; reopening the camera.\n",
                    .{stats.failed},
                );
                open_camera.deinit(allocator);
                camera = null;
                if (apartment) |*open_apartment| open_apartment.deinit();
                apartment = null;
                waitFor(context.shutdown_event, retry_delay_ms);
                continue;
            }
        }

        waitFor(context.shutdown_event, poll_ms);
    }

    std.debug.print("[extras] worker stopped.\n", .{});
    return 0;
}

fn openTargetCamera(allocator: Allocator) !directshow.CameraDevice {
    var devices = try directshow.DeviceEnumerator.init();
    defer devices.deinit();

    while (try devices.next(allocator)) |next_device| {
        var device = next_device;
        if (std.mem.eql(u8, device.friendly_name, target_name) and
            std.ascii.findIgnoreCase(device.device_path, target_usb_id) != null)
        {
            return device;
        }
        device.deinit(allocator);
    }
    return error.TargetCameraNotFound;
}

fn isStopped(stop_event: HANDLE) bool {
    return WaitForSingleObject(stop_event, 0) == 0;
}

fn waitFor(stop_event: HANDLE, milliseconds: u32) void {
    _ = WaitForSingleObject(stop_event, milliseconds);
}
