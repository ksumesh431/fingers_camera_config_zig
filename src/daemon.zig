const std = @import("std");
const directshow = @import("directshow.zig");
const etw = @import("etw.zig");
const winutil = @import("winutil.zig");

const target_name = "FINGERS Hi-Res 2K";
const target_usb_id = "vid_5843&pid_7884";
const white_balance_value: directshow.LONG = 4;
const powerline_target: directshow.LONG = directshow.powerline_50hz;
const white_balance_poll_ms: u32 = 250;
const powerline_refresh_delay_ms: u32 = 2000;
const retry_delay_ms: u32 = 5000;
const infinite: u32 = 0xFFFFFFFF;

const HANDLE = *anyopaque;

extern "kernel32" fn CreateEventW(
    attributes: ?*anyopaque,
    manual_reset: i32,
    initial_state: i32,
    name: ?[*:0]const u16,
) ?HANDLE;
extern "kernel32" fn SetEvent(handle: HANDLE) i32;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: u32) u32;
extern "kernel32" fn CreateThread(
    attributes: ?*anyopaque,
    stack_size: usize,
    start_address: *const fn (?*anyopaque) callconv(.winapi) u32,
    parameter: ?*anyopaque,
    creation_flags: u32,
    thread_id: ?*u32,
) ?HANDLE;
extern "kernel32" fn Sleep(milliseconds: u32) void;
extern "kernel32" fn CloseHandle(handle: HANDLE) i32;
extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (u32) callconv(.winapi) i32,
    add: i32,
) i32;

const WorkerContext = struct {
    shutdown_event: HANDLE,
};

var shutdown_event: ?HANDLE = null;

pub fn run(duration_seconds: u32) !void {
    if (!winutil.isElevated()) {
        winutil.printRequiresElevation("daemon");
        return error.RequiresElevation;
    }

    const stop_event = CreateEventW(null, 1, 0, null) orelse return error.CreateShutdownEventFailed;
    shutdown_event = stop_event;
    defer {
        shutdown_event = null;
        _ = CloseHandle(stop_event);
    }

    if (SetConsoleCtrlHandler(consoleControlHandler, 1) == 0) {
        return error.ConsoleHandlerRegistrationFailed;
    }
    defer _ = SetConsoleCtrlHandler(consoleControlHandler, 0);

    var white_balance_context: WorkerContext = .{ .shutdown_event = stop_event };
    var powerline_context: WorkerContext = .{ .shutdown_event = stop_event };

    const white_balance_thread = CreateThread(
        null,
        0,
        whiteBalanceWorker,
        &white_balance_context,
        0,
        null,
    ) orelse return error.CreateWhiteBalanceThreadFailed;
    defer _ = CloseHandle(white_balance_thread);

    const powerline_thread = CreateThread(
        null,
        0,
        powerlineWorker,
        &powerline_context,
        0,
        null,
    ) orelse {
        _ = SetEvent(stop_event);
        _ = WaitForSingleObject(white_balance_thread, infinite);
        return error.CreatePowerlineThreadFailed;
    };
    defer _ = CloseHandle(powerline_thread);

    std.debug.print(
        "Camera controller daemon started (elevated).\n",
        .{},
    );
    std.debug.print(
        "  white balance: manual value {d}, poll {d} ms\n  power line: {s}, ETW-triggered refresh\n",
        .{ white_balance_value, white_balance_poll_ms, powerlineName(powerline_target) },
    );
    std.debug.print("Press Ctrl+C to stop.\n", .{});

    const wait_ms = if (duration_seconds == 0) infinite else duration_seconds * 1000;
    _ = WaitForSingleObject(stop_event, wait_ms);
    _ = SetEvent(stop_event);

    _ = WaitForSingleObject(white_balance_thread, infinite);
    _ = WaitForSingleObject(powerline_thread, infinite);
    std.debug.print("Camera controller daemon stopped.\n", .{});
}

fn whiteBalanceWorker(raw_context: ?*anyopaque) callconv(.winapi) u32 {
    const context: *WorkerContext = @ptrCast(@alignCast(raw_context orelse return 1));
    const allocator = std.heap.page_allocator;
    std.debug.print("[white-balance] worker started.\n", .{});

    while (!isStopped(context.shutdown_event)) {
        var apartment = directshow.ComApartment.init() catch |err| {
            std.debug.print("[white-balance] COM init failed: {s}; retrying.\n", .{@errorName(err)});
            waitForRetry(context.shutdown_event);
            continue;
        };

        var camera = openTargetCamera(allocator) catch |err| {
            std.debug.print("[white-balance] camera open failed: {s}; retrying.\n", .{@errorName(err)});
            apartment.deinit();
            waitForRetry(context.shutdown_event);
            continue;
        };

        runWhiteBalanceLoop(&camera, context.shutdown_event) catch |err| {
            std.debug.print("[white-balance] loop failed: {s}; retrying.\n", .{@errorName(err)});
            camera.deinit(allocator);
            apartment.deinit();
            waitForRetry(context.shutdown_event);
            continue;
        };

        camera.deinit(allocator);
        apartment.deinit();
    }

    std.debug.print("[white-balance] worker stopped.\n", .{});
    return 0;
}

fn powerlineWorker(raw_context: ?*anyopaque) callconv(.winapi) u32 {
    const context: *WorkerContext = @ptrCast(@alignCast(raw_context orelse return 1));
    const allocator = std.heap.page_allocator;
    std.debug.print("[power-line] worker started.\n", .{});

    while (!isStopped(context.shutdown_event)) {
        var apartment = directshow.ComApartment.init() catch |err| {
            std.debug.print("[power-line] COM init failed: {s}; retrying.\n", .{@errorName(err)});
            waitForRetry(context.shutdown_event);
            continue;
        };

        var camera = openTargetCamera(allocator) catch |err| {
            std.debug.print("[power-line] camera open failed: {s}; retrying.\n", .{@errorName(err)});
            apartment.deinit();
            waitForRetry(context.shutdown_event);
            continue;
        };

        etw.runUntilStopped(
            &camera,
            powerline_target,
            refreshCameraSettings,
            context.shutdown_event,
        ) catch |err| {
            std.debug.print("[power-line] ETW watcher failed: {s}; retrying.\n", .{@errorName(err)});
            camera.deinit(allocator);
            apartment.deinit();
            waitForRetry(context.shutdown_event);
            continue;
        };

        camera.deinit(allocator);
        apartment.deinit();
    }

    std.debug.print("[power-line] worker stopped.\n", .{});
    return 0;
}

fn runWhiteBalanceLoop(camera: *directshow.CameraDevice, stop_event: HANDLE) !void {
    const range = try camera.whiteBalanceRange();
    if (range.capabilities & directshow.video_proc_amp_flag_manual == 0) {
        return error.ManualWhiteBalanceNotSupported;
    }
    try camera.setWhiteBalance(white_balance_value, directshow.video_proc_amp_flag_manual);
    const initial = try camera.whiteBalance();
    if (!isManual(initial.flags) or initial.value != white_balance_value) {
        return error.WhiteBalanceVerificationFailed;
    }
    printWhiteBalance("White balance applied", initial);

    while (!isStopped(stop_event)) {
        Sleep(white_balance_poll_ms);
        if (isStopped(stop_event)) break;

        const observed = try camera.whiteBalance();
        if (!isManual(observed.flags) or observed.value != white_balance_value) {
            printWhiteBalance("White balance reset detected; reapplying", observed);
            try camera.setWhiteBalance(white_balance_value, directshow.video_proc_amp_flag_manual);
            const verified = try camera.whiteBalance();
            printWhiteBalance("White balance reapplied", verified);
            if (!isManual(verified.flags) or verified.value != white_balance_value) {
                return error.WhiteBalanceVerificationFailed;
            }
        }
    }
}

fn refreshCameraSettings(camera: *directshow.CameraDevice, target: directshow.LONG) !void {
    const alternate_powerline = switch (target) {
        directshow.powerline_50hz => directshow.powerline_60hz,
        directshow.powerline_60hz => directshow.powerline_50hz,
        else => return error.InvalidPowerlineRefreshValue,
    };

    std.debug.print(
        "[daemon] forcing camera setting refresh: white balance auto -> manual {d}, power line {s} -> {s}.\n",
        .{ white_balance_value, powerlineName(alternate_powerline), powerlineName(target) },
    );

    try camera.setWhiteBalance(
        white_balance_value,
        directshow.video_proc_amp_flag_auto,
    );
    try setPowerline(camera, alternate_powerline);

    Sleep(powerline_refresh_delay_ms);

    try camera.setWhiteBalance(
        white_balance_value,
        directshow.video_proc_amp_flag_manual,
    );
    const white_balance = try camera.whiteBalance();
    printWhiteBalance("White balance forced", white_balance);
    if (!isManual(white_balance.flags) or white_balance.value != white_balance_value) {
        return error.WhiteBalanceVerificationFailed;
    }

    try setPowerline(camera, target);
}

fn setPowerline(camera: *directshow.CameraDevice, value: directshow.LONG) !void {
    const range = try camera.powerlineFrequencyRange();
    if (!valueInRange(range, value)) return error.InvalidPowerlineValue;

    try camera.setPowerlineFrequency(value, 0);
    const current = try camera.powerlineFrequency();
    if (current.value != value) return error.PowerlineVerificationFailed;
    printPowerline("Applied power line frequency", current);
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

fn isStopped(stop_event: HANDLE) bool {
    return WaitForSingleObject(stop_event, 0) == 0;
}

fn waitForRetry(stop_event: HANDLE) void {
    _ = WaitForSingleObject(stop_event, retry_delay_ms);
}

fn isManual(flags: directshow.LONG) bool {
    return flags & directshow.video_proc_amp_flag_manual != 0 and
        flags & directshow.video_proc_amp_flag_auto == 0;
}

fn valueInRange(range: directshow.PropertyRange, value: directshow.LONG) bool {
    return range.step > 0 and
        value >= range.min and
        value <= range.max and
        @mod(value - range.min, range.step) == 0;
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

fn printWhiteBalance(label: []const u8, value: directshow.PropertyValue) void {
    std.debug.print(
        "[white-balance] {s}: value={d} flags=0x{x}.\n",
        .{ label, value.value, @as(u32, @bitCast(value.flags)) },
    );
}

fn printPowerline(label: []const u8, value: directshow.PropertyValue) void {
    std.debug.print(
        "[power-line] {s}: value={d} ({s}) flags=0x{x}.\n",
        .{ label, value.value, powerlineName(value.value), @as(u32, @bitCast(value.flags)) },
    );
}

fn consoleControlHandler(control_type: u32) callconv(.winapi) i32 {
    _ = control_type;
    if (shutdown_event) |stop_event| _ = SetEvent(stop_event);
    return 1;
}
