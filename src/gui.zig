//! Camera settings window.
//!
//! The frozen white-balance and power-line settings are shown but cannot be
//! edited. Every other control on the camera is listed with a switch, and any
//! change is written to `%LOCALAPPDATA%\CameraProject\settings.zon` so the
//! elevated daemon keeps it applied after restarts.
const std = @import("std");
const nanoui = @import("nanoui");
const controls = @import("controls.zig");
const directshow = @import("directshow.zig");
const preview = @import("preview.zig");
const settings = @import("settings.zig");
const startup = @import("startup.zig");

const ui = nanoui.ui;

const target_name = "FINGERS Hi-Res 2K";
const target_usb_id = "vid_5843&pid_7884";
const white_balance_value: directshow.LONG = 4;
const powerline_refresh_delay_ms: u32 = 2000;

extern "kernel32" fn Sleep(milliseconds: u32) void;
extern "kernel32" fn SetEnvironmentVariableW(
    name: [*:0]const u16,
    value: ?[*:0]const u16,
) callconv(.winapi) i32;

const Note = enum {
    ready,
    refreshed,
    restarted,
    saved,
    applied,
    released,
    frozen_applied,
    preview_started,
    preview_stopped,
    no_camera,
    failed,
    config_failed,

    fn text(note: Note) []const u8 {
        return switch (note) {
            .ready => "Ready.",
            .refreshed => "Read the current camera state.",
            .restarted => "Camera restarted; the stream and every read-out are fresh.",
            .saved => "Preferences saved. The daemon keeps them applied.",
            .applied => "Applied the managed controls to the camera.",
            .released => "All custom controls released; the camera decides again.",
            .frozen_applied => "Reapplied white balance 4 and refreshed 50 Hz.",
            .preview_started => "Preview started. The camera allows one stream, so OBS cannot use it now.",
            .preview_stopped => "Preview stopped; the camera is free for OBS, Zoom and Windows Camera.",
            .no_camera => "FINGERS Hi-Res 2K was not found. Connect it and refresh.",
            .failed => "The camera rejected the request. See the note in the preview panel.",
            .config_failed => "The settings file could not be read or written.",
        };
    }
};

/// Why the preview could not start. Separate from `Note` because it stays in
/// the preview panel until the next attempt.
const PreviewProblem = enum {
    busy,
    format,
    failed,

    fn text(problem: PreviewProblem) []const u8 {
        return switch (problem) {
            .busy => "Another app is streaming the camera. Close OBS or Zoom, then press Restart camera.",
            .format => "The camera did not offer an RGB32 preview format.",
            .failed => "The preview could not start. Try Restart camera.",
        };
    }
};

/// Per-control window state. `value` is what gets saved; `slide` is the
/// slider's own value, snapped onto the driver grid after every change.
const ControlUi = struct {
    supported: bool = false,
    has_auto: bool = false,
    has_manual: bool = true,
    min: i32 = 0,
    max: i32 = 1,
    step: i32 = 1,
    manage: bool = false,
    auto: bool = false,
    value: i32 = 0,
    slide: f32 = 0,
    current: ?directshow.PropertyValue = null,
};

const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    loaded: bool = false,
    dirty: bool = false,
    note: Note = .ready,
    white_balance: ?directshow.PropertyValue = null,
    powerline: ?directshow.PropertyValue = null,
    startup_installed: bool = false,
    com_ready: bool = false,
    camera: ?directshow.CameraDevice = null,
    controls: [controls.specs.len]ControlUi = @splat(.{}),
    settings_path: []const u8 = "",

    /// Preview: a streaming graph on the same camera handle, frames copied
    /// into `preview_pixels` for `ui.texture`. Pixel memory is allocated once
    /// with the page allocator and lives for the process.
    camera_on: bool = false,
    preview: ?preview.Preview = null,
    preview_pixels: []u8 = &.{},
    preview_width: u32 = 0,
    preview_height: u32 = 0,
    preview_bytes: usize = 0,
    preview_frames: u64 = 0,
    preview_problem: ?PreviewProblem = null,
};

pub fn main(init: std.process.Init) !void {
    // NanoUI's Windows Direct3D 11 presenter draws `ui.texture` as a plain
    // box; its CPU canvas samples the app's BGRA pixels, which is what the
    // live preview needs. Set before the first window creates its surface.
    _ = SetEnvironmentVariableW(
        std.unicode.utf8ToUtf16LeStringLiteral("NANOUI_NO_D3D"),
        std.unicode.utf8ToUtf16LeStringLiteral("1"),
    );

    const app = try nanoui.App.create(init, .{ .name = "Camera Settings" });
    defer app.destroy();

    var state: State = .{
        .io = init.io,
        .allocator = init.arena.allocator(),
    };
    _ = try app.newWindow(.{
        .title = "Camera Settings",
        .width = 1020,
        .height = 940,
        .content = .{ .view = ui.View.init(&state, view) },
    });
    try app.run();
}

fn view(s: *State, c: *ui.Context) void {
    if (!s.loaded) {
        s.loaded = true;
        load(s);
    }

    const th = c.theme;
    const page = ui.div(c).column().sizeFull().p(24).gap(12);
    defer page.end();

    ui.heading(c, "FINGERS Hi-Res 2K");
    ui.label(c, "White balance and 50 Hz stay locked; everything else is yours to tune.");

    {
        const top = ui.div(c).row().wFull().gap(12);
        defer top.end();
        previewPanel(s, c);
        frozenPanel(s, c);
    }

    {
        const header = ui.div(c).row().wFull().itemsCenter().gap(10);
        defer header.end();
        ui.text(c, "Custom controls", .{ .size = 15, .weight = .semibold });
        ui.spacer(c);
        ui.textf(c, .{ .size = 12, .color = th.muted, .tabular = true }, "{d} available", .{
            supportedCount(s),
        });
    }

    {
        ui.scroll(c, .{ .width = .fill, .grow = 1, .gap = 8, .padding = .all(6) });
        defer ui.end(c);

        controlsGroup(s, c, .image, "Image");
        ui.divider(c);
        controlsGroup(s, c, .camera, "Camera");
    }

    {
        const buttons = ui.div(c).row().wFull().itemsCenter().gap(10);
        defer buttons.end();
        if (ui.button(c, "Apply managed controls", .{ .size = 13 }).clicked) applyManaged(s);
        if (ui.button(c, "Release all", .{ .size = 13 }).clicked) releaseAll(s);
        if (ui.button(c, "Refresh values", .{ .size = 13 }).clicked) refreshValues(s);
        ui.spacer(c);
        if (ui.button(c, "Save preferences", .{
            .variant = .primary,
            .size = 13,
        }).clicked) saveSettings(s);
    }

    ui.divider(c);
    ui.text(c, Note.text(s.note), .{ .size = 13, .color = th.muted, .wrap = true });
    ui.textf(c, .{ .size = 11, .color = th.muted, .wrap = true }, "Saved to {s}", .{
        s.settings_path,
    });

    // Sliders write on every frame they move; the file is written once the
    // pointer is released.
    if (s.dirty and !c.input.down) saveSettings(s);
}

fn previewPanel(s: *State, c: *ui.Context) void {
    const th = c.theme;
    const panel = ui.div(c).column().w(508).p(14).gap(8).rounded(12).bg(th.surface);
    defer panel.end();

    {
        const title = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer title.end();
        ui.text(c, "Camera preview", .{ .size = 14, .weight = .semibold });
        ui.spacer(c);
        ui.badge(c, if (s.preview != null) "live" else "off", if (s.preview != null) th.success else th.muted);
    }

    drawPreview(s, c);

    {
        const row = ui.div(c).row().wFull().itemsCenter().gap(10);
        defer row.end();
        var on = s.camera_on;
        if (ui.toggle(c, "Camera on", &on)) {
            s.camera_on = on;
            if (on) startPreview(s) else stopPreview(s, true);
        }
        ui.spacer(c);
        if (ui.button(c, "Restart camera", .{ .size = 13 }).clicked) restartCamera(s);
    }

    if (s.preview_problem) |problem| {
        ui.text(c, problem.text(), .{ .size = 12, .color = th.muted, .wrap = true });
    } else if (s.preview != null) {
        if (s.preview_bytes > 0) {
            ui.textf(
                c,
                .{ .size = 12, .color = th.muted, .tabular = true },
                "{d}x{d} at 30 fps - {d} frames received",
                .{ s.preview_width, s.preview_height, s.preview_frames },
            );
        } else {
            ui.text(c, "Starting the stream...", .{ .size = 12, .color = th.muted });
        }
    } else {
        ui.text(c, "Preview off. The camera stays free for OBS, Zoom and Windows Camera.", .{
            .size = 12,
            .color = th.muted,
            .wrap = true,
        });
    }
}

fn drawPreview(s: *State, c: *ui.Context) void {
    const box = ui.div(c).wFull().h(270).rounded(10).bg(ui.Color.hex(0x0B0D10));
    defer box.end();

    if (s.preview == null) {
        const message = ui.div(c).row().sizeFull().itemsCenter().justifyCenter();
        defer message.end();
        ui.text(c, "The stream is off.", .{ .size = 13, .color = c.theme.muted });
        return;
    }

    // A video needs a frame as often as it changes, not on every refresh.
    c.frameIn(1.0 / 30.0);

    if (s.preview) |*active| {
        if (active.copyLatest(s.preview_pixels)) |frame| {
            s.preview_width = frame.width;
            s.preview_height = frame.height;
            s.preview_bytes = frame.bytes;
            s.preview_frames = frame.seq;
        }
    }

    if (s.preview_bytes == 0) {
        const message = ui.div(c).row().sizeFull().itemsCenter().justifyCenter();
        defer message.end();
        ui.text(c, "Waiting for the first frame...", .{ .size = 13, .color = c.theme.muted });
        return;
    }

    ui.texture(c, .{ .width = .fill, .height = .fill, .radius = 10 }, .{
        .width = s.preview_width,
        .height = s.preview_height,
        .bgra = s.preview_pixels[0..s.preview_bytes],
    }, .{ 0, 0, 1, 1 }, 1);
}

fn frozenPanel(s: *State, c: *ui.Context) void {
    const th = c.theme;
    const panel = ui.div(c).column().grow().p(14).gap(6).rounded(12).bg(th.surface);
    defer panel.end();

    {
        const title = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer title.end();
        ui.text(c, "Protected settings", .{ .size = 14, .weight = .semibold });
        ui.spacer(c);
        ui.badge(c, "locked", th.success);
    }

    whiteBalanceLine(s, c);
    powerlineLine(s, c);
    startupLine(s, c);

    {
        const row = ui.div(c).row().wFull().itemsCenter().gap(10);
        defer row.end();
        if (ui.button(c, "Reapply frozen fix", .{ .size = 13 }).clicked) applyFrozen(s);
        ui.text(c, "White balance 4 and a 60 -> 50 Hz refresh; never editable.", .{
            .size = 12,
            .color = th.muted,
        });
    }
}

fn controlsGroup(
    s: *State,
    c: *ui.Context,
    group: controls.Group,
    title: []const u8,
) void {
    var any = false;
    for (s.controls, controls.specs) |state, spec| {
        if (spec.group == group and state.supported) any = true;
    }

    ui.text(c, title, .{ .size = 14, .weight = .semibold });
    if (!any) {
        ui.text(c, "This camera does not expose these controls.", .{
            .size = 12,
            .color = c.theme.muted,
        });
        return;
    }

    for (s.controls, controls.specs, 0..) |state, spec, index| {
        if (spec.group != group or !state.supported) continue;
        drawControl(s, c, index);
    }
}

fn drawControl(s: *State, c: *ui.Context, index: usize) void {
    const spec = controls.specs[index];
    const state = &s.controls[index];
    const th = c.theme;

    ui.key(c, spec.name);

    {
        const row = ui.div(c).row().wFull().itemsCenter().gap(10);
        defer row.end();

        if (ui.toggle(c, spec.label, &state.manage)) {
            s.dirty = true;
            if (state.manage) applyControl(s, index);
        }

        ui.spacer(c);

        if (state.current) |current| {
            ui.textf(c, .{ .size = 12, .color = th.muted, .tabular = true }, "now {d} ({s})", .{
                current.value,
                if (current.flags & directshow.video_proc_amp_flag_auto != 0) "auto" else "manual",
            });
        } else {
            ui.text(c, "unavailable", .{ .size = 12, .color = th.muted });
        }
    }

    if (!state.manage) return;

    const row = ui.div(c).row().wFull().itemsCenter().gap(12);
    defer row.end();

    {
        const indent = ui.div(c).w(18);
        defer indent.end();
    }

    if (state.has_auto and state.has_manual) {
        var options = [_][]const u8{ "Automatic", "Manual" };
        var selected: usize = if (state.auto) 0 else 1;
        if (ui.segmented(c, &options, &selected)) {
            state.auto = selected == 0;
            s.dirty = true;
            applyControl(s, index);
        }
    } else if (state.has_auto) {
        ui.text(c, "Automatic only", .{ .size = 12, .color = th.muted });
    }

    ui.spacer(c);

    if (!state.has_manual or state.auto) return;

    if (spec.kind == .boolean) {
        var on = state.value != 0;
        if (ui.toggle(c, "On", &on)) {
            state.value = if (on) 1 else 0;
            state.slide = @floatFromInt(state.value);
            s.dirty = true;
            applyControl(s, index);
        }
        return;
    }

    if (ui.slider(c, &state.slide, .{
        .min = @floatFromInt(state.min),
        .max = @floatFromInt(state.max),
        .width = .{ .px = 240 },
        .label = spec.label,
    })) {
        state.value = controls.snapToRange(state.min, state.max, state.step, state.slide);
        state.slide = @floatFromInt(state.value);
        s.dirty = true;
        applyControl(s, index);
    }
    ui.textf(c, .{ .size = 13, .tabular = true }, "{d}", .{state.value});
}

fn whiteBalanceLine(s: *State, c: *ui.Context) void {
    if (s.white_balance) |white_balance| {
        ui.textf(c, .{ .size = 14, .tabular = true }, "White balance: {s} (value {d}, flags 0x{x})", .{
            if (isManual(white_balance.flags)) "manual" else "automatic",
            white_balance.value,
            @as(u32, @bitCast(white_balance.flags)),
        });
    } else {
        ui.text(c, "White balance: unavailable", .{ .size = 14 });
    }
}

fn powerlineLine(s: *State, c: *ui.Context) void {
    if (s.powerline) |powerline| {
        ui.textf(c, .{ .size = 14, .tabular = true }, "Power line frequency: {s} (value {d})", .{
            powerlineName(powerline.value),
            powerline.value,
        });
    } else {
        ui.text(c, "Power line frequency: unavailable", .{ .size = 14 });
    }
}

fn startupLine(s: *State, c: *ui.Context) void {
    ui.textf(c, .{ .size = 14 }, "Starts with Windows: {s}", .{
        if (s.startup_installed) "yes" else "no",
    });
}

fn supportedCount(s: *const State) usize {
    var count: usize = 0;
    for (s.controls) |state| {
        if (state.supported) count += 1;
    }
    return count;
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

/// One camera handle is kept open so sliders can be dragged smoothly; it is
/// dropped and reopened on every refresh.
fn ensureCamera(s: *State) ?*directshow.CameraDevice {
    if (s.camera) |*camera| return camera;

    if (!s.com_ready) {
        _ = directshow.ComApartment.init() catch return null;
        s.com_ready = true;
    }

    s.camera = openTargetCamera(s.allocator) catch return null;
    return if (s.camera) |*camera| camera else null;
}

fn dropCamera(s: *State) void {
    if (s.camera) |*camera| camera.deinit(s.allocator);
    s.camera = null;
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

fn load(s: *State) void {
    s.settings_path = settings.filePath(s.allocator) catch "settings.zon";
    s.startup_installed = startup.isInstalled(s.io);
    loadConfig(s);
    refresh(s);
    if (s.camera_on) startPreview(s);
}

/// Starts the preview graph on the camera handle the window already holds.
/// The graph streams through the same source filter, so property changes
/// keep working while frames arrive.
fn startPreview(s: *State) void {
    s.preview_problem = null;
    if (s.preview != null) return;

    const camera = ensureCamera(s) orelse {
        s.camera_on = false;
        s.preview_problem = .failed;
        s.note = .no_camera;
        return;
    };

    s.preview = preview.Preview.start(camera) catch |err| {
        s.camera_on = false;
        s.preview_problem = switch (err) {
            error.CameraBusy => .busy,
            error.FormatNotSupported => .format,
            else => .failed,
        };
        s.note = .failed;
        return;
    };

    // The graph may negotiate a smaller frame than requested; the buffer must
    // always cover the frame it reports.
    const needed = s.preview.?.bufferBytes();
    if (s.preview_pixels.len < needed) {
        if (s.preview_pixels.len > 0) std.heap.page_allocator.free(s.preview_pixels);
        s.preview_pixels = std.heap.page_allocator.alloc(u8, needed) catch {
            s.preview.?.stop();
            s.preview = null;
            s.camera_on = false;
            s.preview_problem = .failed;
            return;
        };
    }

    s.preview_width = 0;
    s.preview_height = 0;
    s.preview_bytes = 0;
    s.preview_frames = 0;
    s.note = .preview_started;

    // Starting a stream makes the camera revert white balance to automatic;
    // show that honestly instead of quietly writing the frozen setting.
    readValues(s);
}

/// Stops the stream and releases the graph. The camera handle stays open so
/// the property pages and read-outs keep working.
fn stopPreview(s: *State, update_note: bool) void {
    if (s.preview) |*active| {
        active.stop();
        s.preview = null;
    }
    s.preview_width = 0;
    s.preview_height = 0;
    s.preview_bytes = 0;
    s.preview_frames = 0;
    s.preview_problem = null;
    if (update_note) s.note = .preview_stopped;
}

/// Stops the stream, closes and reopens the camera, and starts again. This is
/// the recovery path for a stalled or busy device.
fn restartCamera(s: *State) void {
    stopPreview(s, false);
    dropCamera(s);
    refresh(s);
    if (s.camera_on) startPreview(s);
    if (s.preview_problem == null) s.note = .restarted;
}

fn refreshValues(s: *State) void {
    readValues(s);
    s.note = .refreshed;
}

fn loadConfig(s: *State) void {
    var loaded = settings.load(s.io, s.allocator, s.allocator) catch |err| {
        std.debug.print("camera-settings: could not read the settings file: {s}\n", .{@errorName(err)});
        s.note = .config_failed;
        return;
    } orelse return;
    defer loaded.deinit();

    for (&s.controls, controls.specs) |*state, spec| {
        const entry = loaded.settings.find(spec.name) orelse continue;
        state.manage = entry.manage;
        state.auto = entry.auto;
        state.value = entry.value;
        state.slide = @floatFromInt(entry.value);
    }
}

fn refresh(s: *State) void {
    s.startup_installed = startup.isInstalled(s.io);
    stopPreview(s, false);
    dropCamera(s);

    const camera = ensureCamera(s) orelse {
        s.white_balance = null;
        s.powerline = null;
        s.note = .no_camera;
        for (&s.controls) |*state| {
            state.supported = false;
            state.current = null;
        }
        return;
    };

    for (controls.specs, 0..) |spec, index| {
        const state = &s.controls[index];
        state.current = null;

        const property_range = controls.range(camera, spec) catch {
            state.supported = false;
            continue;
        };
        // Some drivers expose a placeholder control with a single value.
        if (property_range.max <= property_range.min) {
            state.supported = false;
            continue;
        }

        state.supported = true;
        state.min = property_range.min;
        state.max = property_range.max;
        state.step = if (property_range.step > 0) property_range.step else 1;
        state.has_auto = controls.supportsAuto(property_range);
        state.has_manual = controls.supportsManual(property_range);
        state.current = controls.value(camera, spec) catch null;

        if (state.current) |current| {
            if (!state.manage) {
                state.value = current.value;
                state.auto = current.flags & directshow.video_proc_amp_flag_auto != 0;
            }
        }
        if (!controls.valueInRange(property_range, state.value)) {
            state.value = controls.snapToRange(
                state.min,
                state.max,
                state.step,
                @floatFromInt(state.value),
            );
        }
        state.slide = @floatFromInt(state.value);
        if (!state.has_auto) state.auto = false;
        if (!state.has_manual) state.auto = true;
    }

    s.white_balance = camera.whiteBalance() catch null;
    s.powerline = camera.powerlineFrequency() catch null;
    s.note = .refreshed;
}

/// Updates the read-outs without reopening the camera.
fn readValues(s: *State) void {
    const camera = ensureCamera(s) orelse return;

    for (controls.specs, 0..) |spec, index| {
        const state = &s.controls[index];
        if (!state.supported) continue;
        state.current = controls.value(camera, spec) catch null;
    }

    s.white_balance = camera.whiteBalance() catch null;
    s.powerline = camera.powerlineFrequency() catch null;
}

fn applyControl(s: *State, index: usize) void {
    const spec = controls.specs[index];
    const state = &s.controls[index];
    const camera = ensureCamera(s) orelse {
        s.note = .no_camera;
        return;
    };

    const entry = settings.Entry{
        .name = spec.name,
        .manage = true,
        .auto = state.auto,
        .value = state.value,
    };
    _ = controls.applyEntry(camera, spec, entry, false) catch {
        s.note = .failed;
        return;
    };

    state.current = controls.value(camera, spec) catch null;
    s.note = .applied;
}

fn buildSettings(s: *State, buffer: *[controls.specs.len]settings.Entry) settings.Settings {
    var count: usize = 0;
    for (s.controls, controls.specs) |state, spec| {
        buffer[count] = .{
            .name = spec.name,
            .manage = state.manage,
            .auto = state.auto,
            .value = state.value,
        };
        count += 1;
    }
    return .{ .controls = buffer[0..count] };
}

fn applyManaged(s: *State) void {
    const camera = ensureCamera(s) orelse {
        s.note = .no_camera;
        return;
    };

    var buffer: [controls.specs.len]settings.Entry = undefined;
    const config = buildSettings(s, &buffer);
    const stats = controls.applySettings(camera, config, true);

    readValues(s);
    s.note = if (stats.failed > 0) .failed else .applied;
}

fn releaseAll(s: *State) void {
    for (&s.controls) |*state| {
        state.manage = false;
        if (state.current) |current| {
            state.value = current.value;
            state.slide = @floatFromInt(current.value);
        }
    }
    s.dirty = true;
    s.note = .released;
}

fn saveSettings(s: *State) void {
    var buffer: [controls.specs.len]settings.Entry = undefined;
    const config = buildSettings(s, &buffer);

    settings.save(s.io, config, s.allocator) catch |err| {
        std.debug.print("camera-settings: could not write the settings file: {s}\n", .{@errorName(err)});
        s.dirty = false;
        s.note = .config_failed;
        return;
    };

    s.dirty = false;
    s.note = .saved;
}

/// The frozen fix: manual white balance 4 and the timed 60 -> 50 Hz refresh.
/// This behavior must not change.
fn applyFrozen(s: *State) void {
    const camera = ensureCamera(s) orelse {
        s.note = .no_camera;
        return;
    };

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
    s.note = .frozen_applied;
}
