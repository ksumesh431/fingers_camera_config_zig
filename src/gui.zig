//! Camera settings window: shows the frozen settings and reapplies them.
const std = @import("std");
const nanoui = @import("nanoui");
const directshow = @import("directshow.zig");
const startup = @import("startup.zig");

const ui = nanoui.ui;

const target_name = "FINGERS Hi-Res 2K";
const target_usb_id = "vid_5843&pid_7884";
const white_balance_value: directshow.LONG = 4;
const powerline_refresh_delay_ms: u32 = 2000;

extern "kernel32" fn Sleep(milliseconds: u32) void;

const Note = enum {
    ready,
    refreshed,
    applied,
    no_camera,
    failed,

    fn text(note: Note) []const u8 {
        return switch (note) {
            .ready => "Ready.",
            .refreshed => "Read the current camera state.",
            .applied => "Applied manual white balance 4 and refreshed 50 Hz.",
            .no_camera => "FINGERS Hi-Res 2K was not found. Connect it and refresh.",
            .failed => "The camera rejected the request. See the console output.",
        };
    }
};

const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    loaded: bool = false,
    note: Note = .ready,
    white_balance: ?directshow.PropertyValue = null,
    powerline: ?directshow.PropertyValue = null,
    startup_installed: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Camera Settings" });
    defer app.destroy();

    var state: State = .{
        .io = init.io,
        .allocator = init.arena.allocator(),
    };
    _ = try app.newWindow(.{
        .title = "Camera Settings",
        .width = 560,
        .height = 360,
        .content = .{ .view = ui.View.init(&state, view) },
    });
    try app.run();
}

fn view(s: *State, c: *ui.Context) void {
    if (!s.loaded) {
        s.loaded = true;
        refresh(s);
    }

    const th = c.theme;
    const page = ui.div(c).column().sizeFull().p(24).gap(14);
    defer page.end();

    ui.heading(c, "FINGERS Hi-Res 2K");
    ui.label(c, "Preferred settings for the external webcam.");

    {
        const panel = ui.div(c).column().wFull().p(16).gap(8).rounded(12).bg(th.surface);
        defer panel.end();
        whiteBalanceLine(s, c);
        powerlineLine(s, c);
        startupLine(s, c);
    }

    ui.spacer(c);

    {
        const buttons = ui.div(c).row().gap(10);
        defer buttons.end();
        if (ui.button(c, "Refresh", .{ .size = 14 }).clicked) refresh(s);
        if (ui.button(c, "Apply preferred settings", .{
            .variant = .primary,
            .size = 14,
        }).clicked) apply(s);
    }

    ui.divider(c);
    ui.text(c, Note.text(s.note), .{ .size = 13, .color = th.muted, .wrap = true });
    ui.text(c, "The elevated camera-probe daemon keeps both settings applied " ++
        "while you stream, including after OBS restarts the camera.", .{
        .size = 12,
        .color = th.muted,
        .wrap = true,
    });
}

fn whiteBalanceLine(s: *State, c: *ui.Context) void {
    if (s.white_balance) |white_balance| {
        ui.textf(c, .{ .size = 15, .tabular = true }, "White balance: {s} (value {d}, flags 0x{x})", .{
            if (isManual(white_balance.flags)) "manual" else "automatic",
            white_balance.value,
            @as(u32, @bitCast(white_balance.flags)),
        });
    } else {
        ui.text(c, "White balance: unavailable", .{ .size = 15 });
    }
}

fn powerlineLine(s: *State, c: *ui.Context) void {
    if (s.powerline) |powerline| {
        ui.textf(c, .{ .size = 15, .tabular = true }, "Power line frequency: {s} (value {d})", .{
            powerlineName(powerline.value),
            powerline.value,
        });
    } else {
        ui.text(c, "Power line frequency: unavailable", .{ .size = 15 });
    }
}

fn startupLine(s: *State, c: *ui.Context) void {
    ui.textf(c, .{ .size = 15 }, "Starts with Windows: {s}", .{
        if (s.startup_installed) "yes" else "no",
    });
}

fn isManual(flags: directshow.LONG) bool {
    return flags & directshow.video_proc_amp_flag_manual != 0 and
        flags & directshow.video_proc_amp_flag_auto == 0;
}

fn powerlineName(value: directshow.LONG) []const u8 {
    return switch (value) {
        directshow.powerline_disabled => "disabled",
        directshow.powerline_50hz => "50 Hz",
        directshow.powerline_60hz => "60 Hz",
        directshow.powerline_auto => "automatic",
        else => "unknown",
    };
}

fn openTargetCamera(allocator: std.mem.Allocator) !directshow.CameraDevice {
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

fn refresh(s: *State) void {
    s.startup_installed = startup.isInstalled(s.io);
    s.white_balance = null;
    s.powerline = null;

    var apartment = directshow.ComApartment.init() catch {
        s.note = .failed;
        return;
    };
    defer apartment.deinit();

    var camera = openTargetCamera(s.allocator) catch {
        s.note = .no_camera;
        return;
    };
    defer camera.deinit(s.allocator);

    s.white_balance = camera.whiteBalance() catch null;
    s.powerline = camera.powerlineFrequency() catch null;
    s.note = .refreshed;
}

fn apply(s: *State) void {
    var apartment = directshow.ComApartment.init() catch {
        s.note = .failed;
        return;
    };
    defer apartment.deinit();

    var camera = openTargetCamera(s.allocator) catch {
        s.note = .no_camera;
        return;
    };
    defer camera.deinit(s.allocator);

    camera.setWhiteBalance(
        white_balance_value,
        directshow.video_proc_amp_flag_manual,
    ) catch {
        s.note = .failed;
        return;
    };
    camera.setPowerlineFrequency(directshow.powerline_60hz, 0) catch {
        s.note = .failed;
        return;
    };
    Sleep(powerline_refresh_delay_ms);
    camera.setPowerlineFrequency(directshow.powerline_50hz, 0) catch {
        s.note = .failed;
        return;
    };

    s.white_balance = camera.whiteBalance() catch null;
    s.powerline = camera.powerlineFrequency() catch null;
    s.note = .applied;
}
