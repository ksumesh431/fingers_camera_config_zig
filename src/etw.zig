const std = @import("std");
const directshow = @import("directshow.zig");

const GUID = std.os.windows.GUID;
const TRACEHANDLE = u64;
const ULONG = u32;
const DWORD = u32;

const ERROR_SUCCESS: ULONG = 0;
const ERROR_ALREADY_EXISTS: ULONG = 183;
const INVALID_TRACE_HANDLE: TRACEHANDLE = std.math.maxInt(TRACEHANDLE);
const WNODE_FLAG_TRACED_GUID: ULONG = 0x00020000;
const EVENT_TRACE_REAL_TIME_MODE: ULONG = 0x00000100;
const PROCESS_TRACE_MODE_REAL_TIME: ULONG = 0x00000100;
const PROCESS_TRACE_MODE_EVENT_RECORD: ULONG = 0x10000000;
const EVENT_CONTROL_CODE_ENABLE_PROVIDER: ULONG = 1;
const UVC_KEYWORDS: u64 = 0xC000000000000000;
const UVC_VERBOSE_LEVEL: u8 = 5;
const FILL_USER_BUFFER_START: u16 = 208;
const IDLE_TRIGGER_MS: u64 = 500;
const REFRESH_COOLDOWN_MS: u64 = 5000;

const provider_usb_video = GUID.parse("{DA1D1DBD-3186-4FA2-BC2D-075EFD9E43E2}");
const session_name = std.unicode.utf8ToUtf16LeStringLiteral("CameraProjectUvc");

extern "advapi32" fn StartTraceW(
    session_handle: *TRACEHANDLE,
    instance_name: [*:0]const u16,
    properties: *EventTraceProperties,
) ULONG;
extern "advapi32" fn StopTraceW(
    session_handle: TRACEHANDLE,
    instance_name: [*:0]const u16,
    properties: *EventTraceProperties,
) ULONG;
extern "advapi32" fn EnableTraceEx2(
    trace_handle: TRACEHANDLE,
    provider_id: *const GUID,
    control_code: ULONG,
    level: u8,
    match_any_keyword: u64,
    match_all_keyword: u64,
    timeout: ULONG,
    enable_parameters: ?*anyopaque,
) ULONG;
extern "advapi32" fn OpenTraceW(logfile: *EventTraceLogfileW) TRACEHANDLE;
extern "advapi32" fn ProcessTrace(
    handle_array: *TRACEHANDLE,
    handle_count: ULONG,
    start_time: ?*anyopaque,
    end_time: ?*anyopaque,
) ULONG;
extern "advapi32" fn CloseTrace(trace_handle: TRACEHANDLE) ULONG;
extern "kernel32" fn GetTickCount64() u64;
extern "kernel32" fn QueryPerformanceFrequency(frequency: *i64) i32;
extern "kernel32" fn Sleep(milliseconds: u32) void;
extern "kernel32" fn CreateThread(
    attributes: ?*anyopaque,
    stack_size: usize,
    start_address: *const fn (?*anyopaque) callconv(.winapi) u32,
    parameter: ?*anyopaque,
    creation_flags: DWORD,
    thread_id: ?*DWORD,
) ?*anyopaque;
extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, milliseconds: DWORD) DWORD;
extern "kernel32" fn WaitForMultipleObjects(
    count: DWORD,
    handles: *const [2]?*anyopaque,
    wait_all: i32,
    milliseconds: DWORD,
) DWORD;
extern "kernel32" fn CreateEventW(
    attributes: ?*anyopaque,
    manual_reset: i32,
    initial_state: i32,
    name: ?[*:0]const u16,
) ?*anyopaque;
extern "kernel32" fn SetEvent(handle: *anyopaque) i32;
extern "kernel32" fn CloseHandle(handle: *anyopaque) i32;

const RefreshFn = *const fn (*directshow.CameraDevice, directshow.LONG) anyerror!void;

const Context = struct {
    camera: *directshow.CameraDevice,
    target: directshow.LONG,
    refresh: RefreshFn,
    performance_frequency: u64,
    last_frame_timestamp: i64 = 0,
    suppress_until_ms: u64 = 0,
    refresh_count: u32 = 0,
    refresh_failed: bool = false,
};

const ObserverContext = struct {
    trace_handle: TRACEHANDLE,
    shutdown_event: ?*anyopaque,
    abort_event: *anyopaque,
    timeout_ms: ?u32,
};

pub fn run(
    camera: *directshow.CameraDevice,
    seconds: u32,
    target: directshow.LONG,
    refresh: RefreshFn,
) !void {
    return runCore(camera, target, refresh, null, seconds * 1000);
}

pub fn runUntilStopped(
    camera: *directshow.CameraDevice,
    target: directshow.LONG,
    refresh: RefreshFn,
    shutdown_event: *anyopaque,
) !void {
    return runCore(camera, target, refresh, shutdown_event, null);
}

fn runCore(
    camera: *directshow.CameraDevice,
    target: directshow.LONG,
    refresh: RefreshFn,
    shutdown_event: ?*anyopaque,
    timeout_ms: ?u32,
) !void {
    var property_storage: [256]u64 = std.mem.zeroes([256]u64);
    const property_bytes = std.mem.sliceAsBytes(&property_storage);
    const properties: *EventTraceProperties = @ptrCast(property_bytes.ptr);
    properties.wnode.buffer_size = @sizeOf(EventTraceProperties) +
        @as(u32, @intCast((session_name.len + 1) * @sizeOf(u16)));
    properties.wnode.flags = WNODE_FLAG_TRACED_GUID;
    properties.log_file_mode = EVENT_TRACE_REAL_TIME_MODE;
    properties.flush_timer = 1;
    properties.logger_name_offset = @sizeOf(EventTraceProperties);

    const name_bytes = std.mem.sliceAsBytes(session_name);
    @memcpy(
        property_bytes[properties.logger_name_offset..][0..name_bytes.len],
        name_bytes,
    );

    var session_handle: TRACEHANDLE = 0;
    var status = StartTraceW(&session_handle, session_name, properties);
    if (status == ERROR_ALREADY_EXISTS) {
        _ = StopTraceW(0, session_name, properties);
        status = StartTraceW(&session_handle, session_name, properties);
    }
    if (status != ERROR_SUCCESS) return win32Error("StartTraceW", status);

    var session_active = true;
    defer {
        if (session_active) _ = StopTraceW(session_handle, session_name, properties);
    }

    status = EnableTraceEx2(
        session_handle,
        &provider_usb_video,
        EVENT_CONTROL_CODE_ENABLE_PROVIDER,
        UVC_VERBOSE_LEVEL,
        UVC_KEYWORDS,
        0,
        0,
        null,
    );
    if (status != ERROR_SUCCESS) return win32Error("EnableTraceEx2(Microsoft-Windows-USBVideo)", status);

    var performance_frequency: i64 = 0;
    if (QueryPerformanceFrequency(&performance_frequency) == 0 or performance_frequency <= 0) {
        return error.PerformanceFrequencyUnavailable;
    }

    var context: Context = .{
        .camera = camera,
        .target = target,
        .refresh = refresh,
        .performance_frequency = @intCast(performance_frequency),
    };

    var logfile: EventTraceLogfileW = std.mem.zeroes(EventTraceLogfileW);
    logfile.logger_name = session_name;
    logfile.process_trace_mode = PROCESS_TRACE_MODE_REAL_TIME |
        PROCESS_TRACE_MODE_EVENT_RECORD;
    logfile.event_record_callback = onEvent;
    logfile.context = &context;

    var trace_handle = OpenTraceW(&logfile);
    if (trace_handle == INVALID_TRACE_HANDLE) return error.OpenTraceFailed;
    defer _ = CloseTrace(trace_handle);

    const abort_event = CreateEventW(null, 1, 0, null) orelse return error.CreateAbortEventFailed;
    defer _ = CloseHandle(abort_event);

    var observer_context: ObserverContext = .{
        .trace_handle = trace_handle,
        .shutdown_event = shutdown_event,
        .abort_event = abort_event,
        .timeout_ms = timeout_ms,
    };
    const observer_thread = CreateThread(
        null,
        0,
        observeStopCondition,
        &observer_context,
        0,
        null,
    ) orelse return error.CreateStopThreadFailed;
    defer _ = CloseHandle(observer_thread);

    std.debug.print(
        "ETW real-time watcher started; idle threshold {d} ms, cooldown {d} ms.\n",
        .{ IDLE_TRIGGER_MS, REFRESH_COOLDOWN_MS },
    );

    status = ProcessTrace(&trace_handle, 1, null, null);
    if (status != ERROR_SUCCESS) {
        _ = SetEvent(abort_event);
        _ = CloseTrace(trace_handle);
    }
    _ = WaitForSingleObject(observer_thread, 0xFFFFFFFF);

    if (status != ERROR_SUCCESS) return win32Error("ProcessTrace", status);
    if (context.refresh_failed) return error.PowerlineRefreshFailed;

    session_active = false;
    _ = StopTraceW(session_handle, session_name, properties);
    std.debug.print(
        "ETW watcher stopped; power line refreshed {d} time(s).\n",
        .{context.refresh_count},
    );
}

fn onEvent(event_record: *EventRecord) callconv(.winapi) void {
    if (event_record.event_header.event_descriptor.id != FILL_USER_BUFFER_START) return;
    const context: *Context = @ptrCast(@alignCast(event_record.user_context orelse return));

    const timestamp = event_record.event_header.time_stamp;
    const previous = context.last_frame_timestamp;
    context.last_frame_timestamp = timestamp;

    if (GetTickCount64() < context.suppress_until_ms) return;

    if (previous != 0) {
        if (timestamp <= previous) return;
        const elapsed_ticks: u64 = @intCast(timestamp - previous);
        if (elapsed_ticks * 2 < context.performance_frequency) return;
    }

    context.refresh_count += 1;
    if (previous != 0) {
        const elapsed_ticks: u64 = @intCast(timestamp - previous);
        const milliseconds = elapsed_ticks * 1000 / context.performance_frequency;
        std.debug.print(
            "Frame activity resumed after {d} ms idle; refreshing power line.\n",
            .{milliseconds},
        );
    } else {
        std.debug.print("Initial frame activity detected; refreshing power line.\n", .{});
    }

    context.suppress_until_ms = GetTickCount64() + REFRESH_COOLDOWN_MS;
    context.refresh(context.camera, context.target) catch |err| {
        context.refresh_failed = true;
        std.debug.print("Power-line refresh failed: {s}\n", .{@errorName(err)});
    };
}

fn observeStopCondition(raw_context: ?*anyopaque) callconv(.winapi) u32 {
    const context: *ObserverContext = @ptrCast(@alignCast(raw_context orelse return 1));
    if (context.shutdown_event) |shutdown_event| {
        const handles = [_]?*anyopaque{ shutdown_event, context.abort_event };
        _ = WaitForMultipleObjects(2, &handles, 0, 0xFFFFFFFF);
    } else {
        _ = WaitForSingleObject(context.abort_event, context.timeout_ms orelse 0);
    }
    _ = CloseTrace(context.trace_handle);
    return 0;
}

fn win32Error(operation: []const u8, status: ULONG) error{EtwCallFailed} {
    std.debug.print("{s} failed with Win32 error {d} (0x{x})\n", .{ operation, status, status });
    return error.EtwCallFailed;
}

const WNodeHeader = extern struct {
    buffer_size: u32,
    provider_id: u32,
    historical_context: u64,
    kernel_handle_or_timestamp: u64,
    guid: GUID,
    client_context: u32,
    flags: u32,
};

const EventTraceProperties = extern struct {
    wnode: WNodeHeader,
    buffer_size: u32,
    minimum_buffers: u32,
    maximum_buffers: u32,
    maximum_file_size: u32,
    log_file_mode: u32,
    flush_timer: u32,
    enable_flags: u32,
    age_limit: i32,
    number_of_buffers: u32,
    free_buffers: u32,
    events_lost: u32,
    buffers_written: u32,
    log_buffers_lost: u32,
    real_time_buffers_lost: u32,
    logger_thread_id: ?*anyopaque,
    log_file_name_offset: u32,
    logger_name_offset: u32,
};

const EventDescriptor = extern struct {
    id: u16,
    version: u8,
    channel: u8,
    level: u8,
    opcode: u8,
    task: u16,
    keyword: u64,
};

const EventHeader = extern struct {
    size: u16,
    header_type: u16,
    flags: u16,
    event_property: u16,
    thread_id: u32,
    process_id: u32,
    time_stamp: i64,
    provider_id: GUID,
    event_descriptor: EventDescriptor,
    processor_time: u64,
    activity_id: GUID,
};

const EventRecord = extern struct {
    event_header: EventHeader,
    buffer_context: [4]u8,
    extended_data_count: u16,
    user_data_length: u16,
    extended_data: ?*anyopaque,
    user_data: ?*anyopaque,
    user_context: ?*anyopaque,
};

const EventTraceLogfileW = extern struct {
    log_file_name: ?[*:0]u16,
    logger_name: ?[*:0]const u16,
    current_time: i64,
    buffers_read: u32,
    process_trace_mode: u32,
    current_event: [88]u8,
    logfile_header: [280]u8,
    buffer_callback: ?*anyopaque,
    buffer_size: u32,
    filled: u32,
    events_lost: u32,
    event_record_callback: ?*const fn (*EventRecord) callconv(.winapi) void,
    is_kernel_trace: u32,
    context: ?*anyopaque,
};

comptime {
    if (@sizeOf(WNodeHeader) != 48) @compileError("Unexpected WNODE_HEADER size");
    if (@sizeOf(EventTraceProperties) != 120) @compileError("Unexpected EVENT_TRACE_PROPERTIES size");
    if (@sizeOf(EventHeader) != 80) @compileError("Unexpected EVENT_HEADER size");
    if (@sizeOf(EventRecord) != 112) @compileError("Unexpected EVENT_RECORD size");
    if (@sizeOf(EventTraceLogfileW) != 448) @compileError("Unexpected EVENT_TRACE_LOGFILEW size");
    if (@offsetOf(EventTraceLogfileW, "event_record_callback") != 424) {
        @compileError("Unexpected EventRecordCallback offset");
    }
    if (@offsetOf(EventTraceLogfileW, "context") != 440) {
        @compileError("Unexpected ETW Context offset");
    }
}
