const std = @import("std");
const directshow = @import("directshow.zig");
const keepalive = @import("keepalive.zig");
const etw = @import("etw.zig");
const daemon = @import("daemon.zig");
const startup = @import("startup.zig");

const target_name = "FINGERS Hi-Res 2K";
const target_usb_id = "vid_5843&pid_7884";
const watch_interval_ms: u32 = 250;
const powerline_refresh_delay_ms: u32 = 2000;

extern "kernel32" fn Sleep(milliseconds: u32) void;

const WatchOptions = struct {
    value: directshow.LONG,
    seconds: u32,
    powerline: ?directshow.LONG,
};

const EtwWatchOptions = struct {
    seconds: u32,
    target: directshow.LONG,
};

const Action = union(enum) {
    probe,
    set_manual: directshow.LONG,
    set_auto,
    set_powerline: directshow.LONG,
    refresh_powerline: directshow.LONG,
    set_exposure: directshow.LONG,
    set_exposure_auto,
    keepalive: u32,
    etw_watch: EtwWatchOptions,
    daemon: u32,
    install_startup,
    uninstall_startup,
    startup_status,
    watch: WatchOptions,
    help,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const action = parseAction(args) catch |err| {
        printUsage();
        return err;
    };

    switch (action) {
        .help => {
            printUsage();
            return;
        },
        .daemon => |duration_seconds| return daemon.run(duration_seconds),
        .install_startup => return startup.install(init.io, allocator),
        .uninstall_startup => return startup.uninstall(init.io),
        .startup_status => return startup.showStatus(init.io),
        else => {},
    }

    var apartment = try directshow.ComApartment.init();
    defer apartment.deinit();

    var camera = try findTargetCamera(allocator);
    defer camera.deinit(allocator);

    switch (action) {
        .probe => try probe(&camera),
        .set_manual => |value| try setManual(&camera, value),
        .set_auto => try setAuto(&camera),
        .set_powerline => |value| try setPowerline(&camera, value),
        .refresh_powerline => |value| try refreshPowerline(&camera, value),
        .set_exposure => |value| try setExposure(&camera, value),
        .set_exposure_auto => try setExposureAuto(&camera),
        .keepalive => |seconds| try keepalive.run(&camera, seconds),
        .etw_watch => |options| try etw.run(
            &camera,
            options.seconds,
            options.target,
            refreshPowerline,
        ),
        .daemon => unreachable,
        .install_startup, .uninstall_startup, .startup_status => unreachable,
        .watch => |options| try watch(&camera, options),
        .help => unreachable,
    }
}

fn findTargetCamera(allocator: std.mem.Allocator) !directshow.CameraDevice {
    std.debug.print("Enumerating DirectShow video devices...\n", .{});

    var devices = try directshow.DeviceEnumerator.init();
    defer devices.deinit();

    var selected: ?directshow.CameraDevice = null;
    errdefer if (selected) |*camera| camera.deinit(allocator);

    var device_count: usize = 0;
    while (try devices.next(allocator)) |next_device| {
        var device = next_device;
        device_count += 1;

        std.debug.print(
            "Device {d}: {s}\n  Path: {s}\n  IAMVideoProcAmp: {s} (HRESULT 0x{x:0>8})\n",
            .{
                device_count,
                device.friendly_name,
                device.device_path,
                if (device.proc_amp != null) "available" else "unavailable",
                @as(u32, @bitCast(device.proc_amp_query_hr)),
            },
        );

        if (isTargetCamera(device.friendly_name, device.device_path)) {
            if (selected != null) {
                device.deinit(allocator);
                return error.MultipleTargetCamerasFound;
            }
            selected = device;
        } else {
            device.deinit(allocator);
        }
    }

    if (device_count == 0) return error.NoVideoInputDevicesFound;
    if (selected) |camera| return camera;
    return error.TargetCameraNotFound;
}

fn probe(camera: *directshow.CameraDevice) !void {
    std.debug.print("\nSelected target: {s} (read-only probe)\n", .{camera.friendly_name});
    if (camera.proc_amp == null) return error.VideoProcAmpUnavailable;

    _ = try printRange(camera);
    const current = try camera.whiteBalance();
    printCurrent("White balance current", current);

    const powerline_range = try camera.powerlineFrequencyRange();
    std.debug.print(
        "Power line frequency range: min={d} max={d} step={d} default={d}\n  capabilities=0x{x} (auto={} manual={})\n",
        .{
            powerline_range.min,
            powerline_range.max,
            powerline_range.step,
            powerline_range.default,
            @as(u32, @bitCast(powerline_range.capabilities)),
            supportsAuto(powerline_range.capabilities),
            supportsManual(powerline_range.capabilities),
        },
    );
    const powerline = try camera.powerlineFrequency();
    printPowerline("Power line frequency current", powerline);

    if (camera.camera_control != null) {
        const exposure_range = try camera.cameraControlRange(directshow.camera_control_exposure);
        std.debug.print(
            "Exposure range: min={d} max={d} step={d} default={d}\n  capabilities=0x{x} (auto={} manual={})\n",
            .{
                exposure_range.min,
                exposure_range.max,
                exposure_range.step,
                exposure_range.default,
                @as(u32, @bitCast(exposure_range.capabilities)),
                supportsAuto(exposure_range.capabilities),
                supportsManual(exposure_range.capabilities),
            },
        );
        const exposure = try camera.cameraControlValue(directshow.camera_control_exposure);
        printCurrent("Exposure current", exposure);
    } else {
        std.debug.print(
            "Exposure: IAMCameraControl unavailable (HRESULT 0x{x:0>8})\n",
            .{@as(u32, @bitCast(camera.camera_control_query_hr))},
        );
    }

    std.debug.print("No camera settings were changed.\n", .{});
}

fn printRange(camera: *directshow.CameraDevice) !directshow.PropertyRange {
    const range = try camera.whiteBalanceRange();
    std.debug.print(
        "White balance range: min={d} max={d} step={d} default={d}\n  capabilities=0x{x} (auto={} manual={})\n",
        .{
            range.min,
            range.max,
            range.step,
            range.default,
            @as(u32, @bitCast(range.capabilities)),
            supportsAuto(range.capabilities),
            supportsManual(range.capabilities),
        },
    );
    return range;
}

fn printCurrent(label: []const u8, current: directshow.PropertyValue) void {
    std.debug.print(
        "{s}: value={d} flags=0x{x} mode={s}\n",
        .{
            label,
            current.value,
            @as(u32, @bitCast(current.flags)),
            modeName(current.flags),
        },
    );
}

fn printPowerline(label: []const u8, current: directshow.PropertyValue) void {
    std.debug.print(
        "{s}: value={d} ({s}) flags=0x{x}\n",
        .{
            label,
            current.value,
            powerlineName(current.value),
            @as(u32, @bitCast(current.flags)),
        },
    );
}

fn powerlineName(value: directshow.LONG) []const u8 {
    return switch (value) {
        directshow.powerline_disabled => "disabled",
        directshow.powerline_50hz => "50 Hz",
        directshow.powerline_60hz => "60 Hz",
        directshow.powerline_auto => "auto",
        else => "unknown",
    };
}

fn setManual(camera: *directshow.CameraDevice, value: directshow.LONG) !void {
    const range = try printRange(camera);
    validateManualValue(range, value) catch |err| {
        if (err == error.InvalidWhiteBalanceValue) {
            std.debug.print(
                "Invalid value {d}; expected {d}..{d} in steps of {d}.\n",
                .{ value, range.min, range.max, range.step },
            );
        }
        return err;
    };

    try camera.setWhiteBalance(value, directshow.video_proc_amp_flag_manual);
    const current = try camera.whiteBalance();
    printCurrent("Applied white balance", current);

    if (!isManual(current.flags) or current.value != value) {
        return error.WhiteBalanceVerificationFailed;
    }
}

fn setAuto(camera: *directshow.CameraDevice) !void {
    const before = try camera.whiteBalance();
    try camera.setWhiteBalance(before.value, directshow.video_proc_amp_flag_auto);
    const current = try camera.whiteBalance();
    printCurrent("Restored automatic white balance", current);

    if (!supportsAuto(current.flags) or supportsManual(current.flags)) {
        return error.WhiteBalanceVerificationFailed;
    }
}

fn setPowerline(camera: *directshow.CameraDevice, value: directshow.LONG) !void {
    const range = try camera.powerlineFrequencyRange();
    if (!valueInRange(range, value)) {
        std.debug.print(
            "Invalid power line value {d}; expected {d}..{d} in steps of {d}.\n",
            .{ value, range.min, range.max, range.step },
        );
        return error.InvalidPowerlineValue;
    }

    try camera.setPowerlineFrequency(value, 0);
    const current = try camera.powerlineFrequency();
    printPowerline("Applied power line frequency", current);

    if (current.value != value) return error.PowerlineVerificationFailed;
}

fn refreshPowerline(camera: *directshow.CameraDevice, target: directshow.LONG) !void {
    const alternate = switch (target) {
        directshow.powerline_50hz => directshow.powerline_60hz,
        directshow.powerline_60hz => directshow.powerline_50hz,
        else => return error.InvalidPowerlineRefreshValue,
    };

    std.debug.print(
        "Forcing power line refresh: {s} -> {s}\n",
        .{ powerlineName(alternate), powerlineName(target) },
    );
    try setPowerline(camera, alternate);
    Sleep(powerline_refresh_delay_ms);
    try setPowerline(camera, target);
}

fn setExposure(camera: *directshow.CameraDevice, value: directshow.LONG) !void {
    const range = try camera.cameraControlRange(directshow.camera_control_exposure);
    if (!supportsManual(range.capabilities)) return error.ManualExposureNotSupported;
    if (!valueInRange(range, value)) {
        std.debug.print(
            "Invalid exposure value {d}; expected {d}..{d} in steps of {d}.\n",
            .{ value, range.min, range.max, range.step },
        );
        return error.InvalidExposureValue;
    }

    try camera.setCameraControl(
        directshow.camera_control_exposure,
        value,
        directshow.camera_control_flag_manual,
    );
    const current = try camera.cameraControlValue(directshow.camera_control_exposure);
    printCurrent("Applied exposure", current);

    if (!isManual(current.flags) or current.value != value) {
        return error.ExposureVerificationFailed;
    }
}

fn setExposureAuto(camera: *directshow.CameraDevice) !void {
    const before = try camera.cameraControlValue(directshow.camera_control_exposure);
    try camera.setCameraControl(
        directshow.camera_control_exposure,
        before.value,
        directshow.camera_control_flag_auto,
    );
    const current = try camera.cameraControlValue(directshow.camera_control_exposure);
    printCurrent("Restored automatic exposure", current);

    if (!supportsAuto(current.flags) or supportsManual(current.flags)) {
        return error.ExposureVerificationFailed;
    }
}

fn watch(camera: *directshow.CameraDevice, options: WatchOptions) !void {
    std.debug.print(
        "Starting finite watch: white_balance={d}, powerline={s}, duration={d}s, interval={d}ms.\n",
        .{
            options.value,
            if (options.powerline) |value| powerlineName(value) else "unchanged",
            options.seconds,
            watch_interval_ms,
        },
    );
    try setManual(camera, options.value);
    if (options.powerline) |value| try refreshPowerline(camera, value);

    const duration_ms = @as(u64, options.seconds) * 1000;
    var elapsed_ms: u64 = 0;
    var white_balance_reapply_count: u32 = 0;
    var powerline_reapply_count: u32 = 0;

    while (elapsed_ms < duration_ms) : (elapsed_ms += watch_interval_ms) {
        Sleep(watch_interval_ms);

        var camera_reset_detected = false;
        const observed_white_balance = try camera.whiteBalance();
        if (!isManual(observed_white_balance.flags) or
            observed_white_balance.value != options.value)
        {
            camera_reset_detected = true;
            white_balance_reapply_count += 1;
            printCurrent("White balance change detected; reapplying", observed_white_balance);
            try camera.setWhiteBalance(options.value, directshow.video_proc_amp_flag_manual);
            const verified = try camera.whiteBalance();
            printCurrent("Reapplied white balance", verified);
            if (!isManual(verified.flags) or verified.value != options.value) {
                return error.WhiteBalanceVerificationFailed;
            }
        }

        if (options.powerline) |target| {
            const observed_powerline = try camera.powerlineFrequency();
            if (camera_reset_detected or observed_powerline.value != target) {
                powerline_reapply_count += 1;
                if (observed_powerline.value == target) {
                    std.debug.print(
                        "Camera reset detected; refreshing power line even though the driver already reports {s}.\n",
                        .{powerlineName(target)},
                    );
                } else {
                    printPowerline("Power line change detected", observed_powerline);
                }
                try refreshPowerline(camera, target);
            }
        }
    }

    std.debug.print(
        "Watch complete; white balance reapplied {d} time(s), power line reapplied {d} time(s).\n",
        .{ white_balance_reapply_count, powerline_reapply_count },
    );
}

fn validateManualValue(
    range: directshow.PropertyRange,
    value: directshow.LONG,
) !void {
    if (!supportsManual(range.capabilities)) {
        return error.ManualWhiteBalanceNotSupported;
    }
    if (range.step <= 0) return error.InvalidWhiteBalanceRange;
    if (!valueInRange(range, value)) return error.InvalidWhiteBalanceValue;
}

fn valueInRange(range: directshow.PropertyRange, value: directshow.LONG) bool {
    return range.step > 0 and
        value >= range.min and
        value <= range.max and
        @mod(value - range.min, range.step) == 0;
}

fn parseAction(args: []const [:0]const u8) !Action {
    if (args.len <= 1) return .probe;

    const command = args[1];
    if (std.mem.eql(u8, command, "probe") and args.len == 2) return .probe;
    if ((std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h")) and args.len == 2) return .help;

    if (std.mem.eql(u8, command, "set-manual") and args.len == 3) {
        return .{ .set_manual = try std.fmt.parseInt(directshow.LONG, args[2], 10) };
    }
    if (std.mem.eql(u8, command, "set-auto") and args.len == 2) return .set_auto;
    if (std.mem.eql(u8, command, "set-powerline") and args.len == 3) {
        return .{ .set_powerline = try parsePowerlineValue(args[2]) };
    }
    if (std.mem.eql(u8, command, "refresh-powerline") and args.len == 3) {
        return .{ .refresh_powerline = try parsePowerlineValue(args[2]) };
    }
    if (std.mem.eql(u8, command, "set-exposure") and args.len == 3) {
        return .{ .set_exposure = try std.fmt.parseInt(directshow.LONG, args[2], 10) };
    }
    if (std.mem.eql(u8, command, "set-exposure-auto") and args.len == 2) {
        return .set_exposure_auto;
    }
    if (std.mem.eql(u8, command, "keepalive") and args.len == 3) {
        const seconds = try std.fmt.parseInt(u32, args[2], 10);
        if (seconds == 0 or seconds > 3600) return error.InvalidKeepAliveDuration;
        return .{ .keepalive = seconds };
    }
    if (std.mem.eql(u8, command, "daemon") and args.len <= 3) {
        const seconds: u32 = if (args.len == 2)
            0
        else
            try std.fmt.parseInt(u32, args[2], 10);
        if (seconds > 86400) return error.InvalidDaemonDuration;
        return .{ .daemon = seconds };
    }
    if (std.mem.eql(u8, command, "startup-status") and args.len == 2) {
        return .startup_status;
    }
    if (std.mem.eql(u8, command, "install-startup") and args.len == 2) {
        return .install_startup;
    }
    if (std.mem.eql(u8, command, "uninstall-startup") and args.len == 2) {
        return .uninstall_startup;
    }
    if (std.mem.eql(u8, command, "etw-watch") and args.len == 4) {
        const seconds = try std.fmt.parseInt(u32, args[2], 10);
        if (seconds == 0 or seconds > 3600) return error.InvalidEtwWatchDuration;
        return .{ .etw_watch = .{
            .seconds = seconds,
            .target = try parsePowerlineValue(args[3]),
        } };
    }
    if (std.mem.eql(u8, command, "watch") and (args.len == 4 or args.len == 5)) {
        const seconds = try std.fmt.parseInt(u32, args[3], 10);
        if (seconds == 0 or seconds > 3600) return error.InvalidWatchDuration;
        return .{ .watch = .{
            .value = try std.fmt.parseInt(directshow.LONG, args[2], 10),
            .seconds = seconds,
            .powerline = if (args.len == 5) try parsePowerlineValue(args[4]) else null,
        } };
    }

    return error.InvalidCommandLine;
}

fn parsePowerlineValue(value: []const u8) !directshow.LONG {
    if (std.mem.eql(u8, value, "50")) return directshow.powerline_50hz;
    if (std.mem.eql(u8, value, "60")) return directshow.powerline_60hz;
    if (std.mem.eql(u8, value, "auto")) return directshow.powerline_auto;
    if (std.mem.eql(u8, value, "disabled") or std.mem.eql(u8, value, "off")) {
        return directshow.powerline_disabled;
    }
    return error.InvalidPowerlineValue;
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  camera-probe [probe]              Read settings without changing them
        \\  camera-probe set-manual <value>   Set and verify manual white balance
        \\  camera-probe set-auto             Restore automatic white balance
        \\  camera-probe set-powerline <hz>   Set 50, 60, auto, or disabled
        \\  camera-probe refresh-powerline <hz> Force 50/60, then restore target
        \\  camera-probe set-exposure <value> Set manual exposure (-13..0 here)
        \\  camera-probe set-exposure-auto    Restore automatic exposure
        \\  camera-probe keepalive <seconds>  Hold a null-rendered camera stream
        \\  camera-probe etw-watch <sec> <hz> Elevated stream-activity refresh
        \\  camera-probe daemon [seconds]     Persistent elevated controller
        \\  camera-probe install-startup      Elevated; start daemon at logon
        \\  camera-probe uninstall-startup    Elevated; remove the logon task
        \\  camera-probe startup-status       Show the logon task state
        \\  camera-probe watch <wb> <sec> [hz] Reapply for 1-3600 seconds
        \\  camera-probe help                 Show this help
        \\
    , .{});
}

fn isTargetCamera(friendly_name: []const u8, device_path: []const u8) bool {
    return std.mem.eql(u8, friendly_name, target_name) and
        std.ascii.findIgnoreCase(device_path, target_usb_id) != null;
}

fn supportsAuto(flags: directshow.LONG) bool {
    return flags & directshow.video_proc_amp_flag_auto != 0;
}

fn supportsManual(flags: directshow.LONG) bool {
    return flags & directshow.video_proc_amp_flag_manual != 0;
}

fn isManual(flags: directshow.LONG) bool {
    return supportsManual(flags) and !supportsAuto(flags);
}

fn modeName(flags: directshow.LONG) []const u8 {
    const auto = supportsAuto(flags);
    const manual = supportsManual(flags);
    if (auto and !manual) return "auto";
    if (manual and !auto) return "manual";
    return "unknown";
}

test {
    // Pull the other modules' tests into the test binary.
    _ = directshow;
    _ = etw;
    _ = daemon;
    _ = startup;
}

test "target camera requires both friendly name and USB identity" {
    const path = "@device:pnp:\\\\?\\usb#vid_5843&pid_7884&mi_00#example";
    try std.testing.expect(isTargetCamera("FINGERS Hi-Res 2K", path));
    try std.testing.expect(isTargetCamera("FINGERS Hi-Res 2K", "USB#VID_5843&PID_7884&MI_00"));
    try std.testing.expect(!isTargetCamera("Integrated Camera", path));
    try std.testing.expect(!isTargetCamera(
        "FINGERS Hi-Res 2K",
        "USB#VID_04F2&PID_B7B6&MI_00",
    ));
}

test "parse explicit camera actions" {
    const manual_args = [_][:0]const u8{ "camera-probe", "set-manual", "4" };
    const manual = try parseAction(&manual_args);
    switch (manual) {
        .set_manual => |value| try std.testing.expectEqual(@as(i32, 4), value),
        else => return error.ExpectedSetManualAction,
    }

    const watch_args = [_][:0]const u8{ "camera-probe", "watch", "3", "60" };
    const watch_action = try parseAction(&watch_args);
    switch (watch_action) {
        .watch => |options| {
            try std.testing.expectEqual(@as(i32, 3), options.value);
            try std.testing.expectEqual(@as(u32, 60), options.seconds);
        },
        else => return error.ExpectedWatchAction,
    }

    const invalid_args = [_][:0]const u8{ "camera-probe", "watch", "4", "0" };
    try std.testing.expectError(error.InvalidWatchDuration, parseAction(&invalid_args));

    const powerline_args = [_][:0]const u8{ "camera-probe", "set-powerline", "50" };
    const powerline_action = try parseAction(&powerline_args);
    switch (powerline_action) {
        .set_powerline => |value| try std.testing.expectEqual(
            directshow.powerline_50hz,
            value,
        ),
        else => return error.ExpectedSetPowerlineAction,
    }

    const combined_watch_args = [_][:0]const u8{ "camera-probe", "watch", "4", "120", "50" };
    const combined_watch = try parseAction(&combined_watch_args);
    switch (combined_watch) {
        .watch => |options| try std.testing.expectEqual(
            @as(?i32, directshow.powerline_50hz),
            options.powerline,
        ),
        else => return error.ExpectedCombinedWatchAction,
    }

    const invalid_powerline_args = [_][:0]const u8{ "camera-probe", "set-powerline", "mains" };
    try std.testing.expectError(
        error.InvalidPowerlineValue,
        parseAction(&invalid_powerline_args),
    );

    const exposure_args = [_][:0]const u8{ "camera-probe", "set-exposure", "-6" };
    const exposure_action = try parseAction(&exposure_args);
    switch (exposure_action) {
        .set_exposure => |value| try std.testing.expectEqual(@as(i32, -6), value),
        else => return error.ExpectedSetExposureAction,
    }

    const refresh_args = [_][:0]const u8{ "camera-probe", "refresh-powerline", "50" };
    const refresh_action = try parseAction(&refresh_args);
    switch (refresh_action) {
        .refresh_powerline => |value| try std.testing.expectEqual(
            directshow.powerline_50hz,
            value,
        ),
        else => return error.ExpectedRefreshPowerlineAction,
    }
}

test "startup commands parse without a camera argument" {
    const install_args = [_][:0]const u8{ "camera-probe", "install-startup" };
    switch (try parseAction(&install_args)) {
        .install_startup => {},
        else => return error.ExpectedInstallStartupAction,
    }

    const uninstall_args = [_][:0]const u8{ "camera-probe", "uninstall-startup" };
    switch (try parseAction(&uninstall_args)) {
        .uninstall_startup => {},
        else => return error.ExpectedUninstallStartupAction,
    }

    const status_args = [_][:0]const u8{ "camera-probe", "startup-status" };
    switch (try parseAction(&status_args)) {
        .startup_status => {},
        else => return error.ExpectedStartupStatusAction,
    }

    const daemon_forever = [_][:0]const u8{ "camera-probe", "daemon" };
    switch (try parseAction(&daemon_forever)) {
        .daemon => |seconds| try std.testing.expectEqual(@as(u32, 0), seconds),
        else => return error.ExpectedDaemonAction,
    }
}

test "power line values follow the discrete driver range" {
    const range = directshow.PropertyRange{
        .min = 0,
        .max = 2,
        .step = 1,
        .default = 1,
        .capabilities = 0,
    };
    try std.testing.expect(valueInRange(range, directshow.powerline_disabled));
    try std.testing.expect(valueInRange(range, directshow.powerline_50hz));
    try std.testing.expect(valueInRange(range, directshow.powerline_60hz));
    try std.testing.expect(!valueInRange(range, directshow.powerline_auto));
}

test "manual value must follow the reported range and step" {
    const range = directshow.PropertyRange{
        .min = 1,
        .max = 5,
        .step = 1,
        .default = 4,
        .capabilities = directshow.video_proc_amp_flag_auto |
            directshow.video_proc_amp_flag_manual,
    };
    try validateManualValue(range, 1);
    try validateManualValue(range, 5);
    try std.testing.expectError(error.InvalidWhiteBalanceValue, validateManualValue(range, 0));
    try std.testing.expectError(error.InvalidWhiteBalanceValue, validateManualValue(range, 6));
}
