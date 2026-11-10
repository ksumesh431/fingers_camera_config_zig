//! Live camera preview for the settings window.
//!
//! A DirectShow capture graph streams from the same source filter the window
//! already holds for its property pages, into a Sample Grabber sink kept in
//! buffered mode. Each view copies the grabber's latest buffer into a BGRA
//! buffer that `ui.texture` draws; no window, no video renderer and no Media
//! Foundation stack are involved.
//!
//! This camera allows only one streaming graph. When OBS or Zoom is already
//! streaming, `start` fails with `error.CameraBusy` and the window reports it
//! instead of retrying in a loop.

const std = @import("std");
const directshow = @import("directshow.zig");

const GUID = std.os.windows.GUID;
pub const HRESULT = directshow.HRESULT;
const ULONG = u32;
const LONG = i32;
const DWORD = u32;

/// The preview format requested from the graph. 16:9 matches the camera's
/// native shape, and small frames keep the CPU renderer's sampling cheap.
pub const width: u32 = 1280;
pub const height: u32 = 720;
/// The buffer a caller should allocate; the graph may negotiate smaller.
pub const max_frame_bytes: usize = @as(usize, width) * height * 4;
const frame_interval_100ns: i64 = 333_333; // 30 frames per second
const BI_RGB: u32 = 0;

const CLSCTX_INPROC_SERVER: DWORD = 0x1;

const clsid_filter_graph = GUID.parse("{E436EBB3-524F-11CE-9F53-0020AF0BA770}");
const iid_graph_builder = GUID.parse("{56A868A9-0AD4-11CE-B03A-0020AF0BA770}");
const clsid_capture_graph_builder = GUID.parse("{BF87B6E1-8C27-11D0-B3F0-00AA003761C5}");
const iid_capture_graph_builder = GUID.parse("{93E5A4E0-2D50-11D2-ABFA-00A0C9C6E38D}");
const clsid_sample_grabber = GUID.parse("{C1F400A0-3F08-11D3-9F0B-006008039E37}");
const iid_sample_grabber = GUID.parse("{6B652FFF-11FE-4FCE-92AD-0266B5D7C78F}");
const iid_base_filter = GUID.parse("{56A86895-0AD4-11CE-B03A-0020AF0BA770}");
const iid_media_control = GUID.parse("{56A868B1-0AD4-11CE-B03A-0020AF0BA770}");
const pin_category_capture = GUID.parse("{FB6C4281-0353-11D1-905F-0000C0CC16BA}");
const media_type_video = GUID.parse("{73646976-0000-0010-8000-00AA00389B71}");
const media_subtype_rgb32 = GUID.parse("{E436EB7E-524F-11CE-9F53-0020AF0BA770}");
const format_video_info = GUID.parse("{05589F80-C356-11CE-BF01-00AA0055595A}");
const iid_am_stream_config = GUID.parse("{C6E13340-30AC-11D0-A18C-00A0C9118956}");

extern "ole32" fn CoCreateInstance(
    class_id: *const GUID,
    outer: ?*anyopaque,
    class_context: DWORD,
    interface_id: *const GUID,
    object: *?*anyopaque,
) HRESULT;
extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) void;

/// Windows `ERROR_NO_SYSTEM_RESOURCES`: another app is streaming the camera.
const error_no_system_resources: HRESULT = @bitCast(@as(u32, 0x800705AA));
const error_busy: HRESULT = @bitCast(@as(u32, 0x800700AA));
const error_gen_failure: HRESULT = @bitCast(@as(u32, 0x8007001F));
const vfw_e_invalid_media_type: HRESULT = @bitCast(@as(u32, 0x80040200));
const vfw_e_no_acceptable_types: HRESULT = @bitCast(@as(u32, 0x80040207));
const vfw_e_cannot_connect: HRESULT = @bitCast(@as(u32, 0x80040217));
const vfw_e_type_not_accepted: HRESULT = @bitCast(@as(u32, 0x8004022A));
/// `VFW_E_WRONG_STATE`: no sample has arrived yet.
const vfw_e_wrong_state: HRESULT = @bitCast(@as(u32, 0x80040227));
/// `VFW_E_BUFFER_OVERFLOW`: the caller's buffer is smaller than the frame.
const vfw_e_buffer_overflow: HRESULT = @bitCast(@as(u32, 0x80040213));

/// One frame as the grabber holds it.
pub const Frame = struct {
    width: u32,
    height: u32,
    bytes: usize,
    seq: u64,
};

pub const Preview = struct {
    graph: *IGraphBuilder,
    builder: *ICaptureGraphBuilder2,
    control: *IMediaControl,
    grabber: *ISampleGrabber,
    grabber_filter: *directshow.IBaseFilter,
    frame_width: u32,
    frame_height: u32,
    stride: usize,
    /// RGB32 rows come bottom-up when `biHeight` is positive.
    flip: bool,
    seq: u64 = 0,

    /// Builds and starts the graph on the current COM apartment. `camera`
    /// must stay open for as long as the preview runs: the graph holds a
    /// reference to its filter, and the property pages need the same object.
    pub fn start(camera: *directshow.CameraDevice) !Preview {
        const graph: *IGraphBuilder = @ptrCast(@alignCast(try create(
            &clsid_filter_graph,
            &iid_graph_builder,
        )));
        errdefer _ = graph.vtable.release(graph);

        const builder: *ICaptureGraphBuilder2 = @ptrCast(@alignCast(try create(
            &clsid_capture_graph_builder,
            &iid_capture_graph_builder,
        )));
        errdefer _ = builder.vtable.release(builder);

        const grabber_filter: *directshow.IBaseFilter = @ptrCast(@alignCast(try create(
            &clsid_sample_grabber,
            &iid_base_filter,
        )));
        errdefer _ = grabber_filter.vtable.release(grabber_filter);

        var raw_grabber: ?*anyopaque = null;
        try check(grabber_filter.vtable.query_interface(
            grabber_filter,
            &iid_sample_grabber,
            &raw_grabber,
        ));
        const grabber: *ISampleGrabber = @ptrCast(@alignCast(raw_grabber.?));
        errdefer _ = grabber.vtable.release(grabber);

        try check(builder.vtable.set_filtergraph(builder, graph));
        try check(graph.vtable.add_filter(
            graph,
            camera.filter,
            std.unicode.utf8ToUtf16LeStringLiteral("FINGERS preview"),
        ));
        try check(graph.vtable.add_filter(
            graph,
            grabber_filter,
            std.unicode.utf8ToUtf16LeStringLiteral("Sample Grabber"),
        ));

        // The camera's native format is 2560 x 1440; ask its capture pin for
        // the largest format that still fits 1280 x 720 before connecting, so
        // the graph and the CPU preview stay cheap.
        const chosen = chooseFormat(builder, camera.filter);

        var header: VIDEOINFOHEADER = .{
            .rcSource = .{ .left = 0, .top = 0, .right = width, .bottom = height },
            .rcTarget = .{ .left = 0, .top = 0, .right = width, .bottom = height },
            .dwBitRate = 0,
            .dwBitErrorRate = 0,
            .AvgTimePerFrame = frame_interval_100ns,
            .bmiHeader = .{
                .biSize = @sizeOf(BITMAPINFOHEADER),
                .biWidth = width,
                .biHeight = height,
                .biPlanes = 1,
                .biBitCount = 32,
                .biCompression = BI_RGB,
                .biSizeImage = @intCast(max_frame_bytes),
                .biXPelsPerMeter = 0,
                .biYPelsPerMeter = 0,
                .biClrUsed = 0,
                .biClrImportant = 0,
            },
        };
        if (chosen) |format| header = format.header;
        const requested_width: u32 = @intCast(@abs(header.bmiHeader.biWidth));
        const requested_height: u32 = @intCast(@abs(header.bmiHeader.biHeight));

        var requested: AM_MEDIA_TYPE = .{
            .majortype = media_type_video,
            .subtype = media_subtype_rgb32,
            .bFixedSizeSamples = 1,
            .bTemporalCompression = 0,
            .lSampleSize = @intCast(@as(usize, requested_width) * requested_height * 4),
            .formattype = format_video_info,
            .pUnk = null,
            .cbFormat = @sizeOf(VIDEOINFOHEADER),
            .pbFormat = @ptrCast(&header),
        };
        try check(grabber.vtable.set_media_type(grabber, &requested));

        try check(builder.vtable.render_stream(
            builder,
            &pin_category_capture,
            &media_type_video,
            @ptrCast(camera.filter),
            null,
            grabber_filter,
        ));

        var connected: AM_MEDIA_TYPE = std.mem.zeroes(AM_MEDIA_TYPE);
        try check(grabber.vtable.get_connected_media_type(grabber, &connected));
        defer if (connected.pbFormat) |format| CoTaskMemFree(format);
        const sink_frame = try readFrameInfo(&connected);

        // Buffered mode: the grabber acts as the renderer, copying each
        // sample so the view can read it without a callback thread.
        try check(grabber.vtable.set_buffer_samples(grabber, 1));
        try check(grabber.vtable.set_one_shot(grabber, 0));

        var raw_control: ?*anyopaque = null;
        try check(graph.vtable.query_interface(graph, &iid_media_control, &raw_control));
        const control: *IMediaControl = @ptrCast(@alignCast(raw_control.?));
        errdefer _ = control.vtable.release(control);

        try check(control.vtable.run(control));

        return .{
            .graph = graph,
            .builder = builder,
            .control = control,
            .grabber = grabber,
            .grabber_filter = grabber_filter,
            .frame_width = sink_frame.frame_width,
            .frame_height = sink_frame.frame_height,
            .stride = sink_frame.stride,
            .flip = sink_frame.flip,
        };
    }

    /// Stops the stream and releases every COM object. Safe to call once.
    pub fn stop(self: *Preview) void {
        _ = self.control.vtable.stop(self.control);
        _ = self.grabber.vtable.release(self.grabber);
        _ = self.grabber_filter.vtable.release(self.grabber_filter);
        _ = self.control.vtable.release(self.control);
        _ = self.builder.vtable.release(self.builder);
        _ = self.graph.vtable.release(self.graph);
        self.* = undefined;
    }

    /// The bytes one frame needs, as the graph negotiated them.
    pub fn bufferBytes(self: *const Preview) usize {
        return self.stride * self.frame_height;
    }

    /// Copies the grabber's newest frame into `destination`. Returns null
    /// until the first sample arrives, or when the buffer is too small.
    pub fn copyLatest(self: *Preview, destination: []u8) ?Frame {
        const needed = self.stride * self.frame_height;
        if (destination.len < needed) return null;

        var size: LONG = @intCast(needed);
        const hr = self.grabber.vtable.get_current_buffer(
            self.grabber,
            &size,
            @ptrCast(destination.ptr),
        );
        if (hr < 0) return null;

        const bytes: usize = @intCast(size);
        if (bytes == 0 or bytes > destination.len) return null;

        const pixels = destination[0..bytes];
        if (self.flip) flipRows(pixels, self.stride, self.frame_height);

        // RGB32 leaves the fourth byte undefined; NanoUI premultiplies by
        // alpha, so every pixel must be fully opaque.
        var index: usize = 3;
        while (index < bytes) : (index += 4) pixels[index] = 255;

        self.seq +%= 1;
        return .{
            .width = self.frame_width,
            .height = self.frame_height,
            .bytes = bytes,
            .seq = self.seq,
        };
    }
};

/// A capture-pin format chosen from the driver's capability list.
const ChosenFormat = struct {
    header: VIDEOINFOHEADER,
    subtype: GUID,
};

/// Asks the source's capture pin for its capabilities and sets the largest
/// format no bigger than 1280 x 720. Returns null when the pin has no
/// stream-configuration interface, in which case the graph default is used.
fn chooseFormat(
    builder: *ICaptureGraphBuilder2,
    filter: *directshow.IBaseFilter,
) ?ChosenFormat {
    var raw_config: ?*anyopaque = null;
    const query = builder.vtable.find_interface(
        builder,
        &pin_category_capture,
        &media_type_video,
        filter,
        &iid_am_stream_config,
        &raw_config,
    );
    if (query < 0) return null;
    const config: *IAMStreamConfig = @ptrCast(@alignCast(raw_config orelse return null));
    defer _ = config.vtable.release(config);

    var count: LONG = 0;
    var caps_size: LONG = 0;
    if (config.vtable.get_number_of_capabilities(config, &count, &caps_size) < 0) return null;
    if (count <= 0) return null;

    var caps: [256]u8 = undefined;
    var best: ?ChosenFormat = null;
    var best_area: i64 = 0;

    var index: LONG = 0;
    while (index < count) : (index += 1) {
        var raw: ?*AM_MEDIA_TYPE = null;
        if (config.vtable.get_stream_caps(config, index, &raw, &caps) < 0) continue;
        const candidate = raw orelse continue;
        defer if (candidate.pbFormat) |format| CoTaskMemFree(format);
        defer CoTaskMemFree(candidate);

        if (!std.mem.eql(u8, std.mem.asBytes(&candidate.majortype), std.mem.asBytes(&media_type_video))) continue;
        if (!std.mem.eql(u8, std.mem.asBytes(&candidate.formattype), std.mem.asBytes(&format_video_info))) continue;
        if (candidate.cbFormat < @sizeOf(VIDEOINFOHEADER)) continue;
        const format = candidate.pbFormat orelse continue;

        const header: *const VIDEOINFOHEADER = @ptrCast(@alignCast(format));
        const frame_width: u32 = @intCast(@abs(header.bmiHeader.biWidth));
        const frame_height: u32 = @intCast(@abs(header.bmiHeader.biHeight));
        if (frame_width < 426 or frame_height < 240) continue;
        if (frame_width > width or frame_height > height) continue;

        const area: i64 = @as(i64, frame_width) * @as(i64, frame_height);
        if (area <= best_area) continue;
        best_area = area;
        best = .{ .header = header.*, .subtype = candidate.subtype };
    }

    var chosen = best orelse return null;
    const media_type: AM_MEDIA_TYPE = .{
        .majortype = media_type_video,
        .subtype = chosen.subtype,
        .bFixedSizeSamples = 1,
        .bTemporalCompression = 0,
        .lSampleSize = 0,
        .formattype = format_video_info,
        .pUnk = null,
        .cbFormat = @sizeOf(VIDEOINFOHEADER),
        .pbFormat = @ptrCast(&chosen.header),
    };
    if (config.vtable.set_format(config, &media_type) < 0) return null;
    return chosen;
}

fn flipRows(pixels: []u8, stride: usize, rows: u32) void {
    var top: usize = 0;
    var bottom: u32 = rows - 1;
    while (top < bottom) : ({
        top += 1;
        bottom -= 1;
    }) {
        const a = top * stride;
        const b = @as(usize, bottom) * stride;
        var index: usize = 0;
        while (index < stride) : (index += 4) {
            const saved = pixels[a + index ..][0..4].*;
            pixels[a + index ..][0..4].* = pixels[b + index ..][0..4].*;
            pixels[b + index ..][0..4].* = saved;
        }
    }
}

/// The shape of the frames the graph negotiated.
const SinkFrame = struct {
    frame_width: u32,
    frame_height: u32,
    stride: usize,
    flip: bool,
};

fn readFrameInfo(media_type: *const AM_MEDIA_TYPE) !SinkFrame {
    if (!std.mem.eql(u8, std.mem.asBytes(&media_type.majortype), std.mem.asBytes(&media_type_video)) or
        !std.mem.eql(u8, std.mem.asBytes(&media_type.subtype), std.mem.asBytes(&media_subtype_rgb32)) or
        !std.mem.eql(u8, std.mem.asBytes(&media_type.formattype), std.mem.asBytes(&format_video_info)))
    {
        return error.FormatNotSupported;
    }
    if (media_type.cbFormat < @sizeOf(VIDEOINFOHEADER)) return error.FormatNotSupported;

    const format = media_type.pbFormat orelse return error.FormatNotSupported;
    const header: *const VIDEOINFOHEADER = @ptrCast(@alignCast(format));
    const bitmap = header.bmiHeader;
    if (bitmap.biBitCount != 32 or bitmap.biCompression != BI_RGB) return error.FormatNotSupported;

    const frame_width: u32 = @intCast(@abs(bitmap.biWidth));
    const frame_height: u32 = @intCast(@abs(bitmap.biHeight));
    if (frame_width == 0 or frame_height == 0) return error.FormatNotSupported;
    if (frame_width > 4096 or frame_height > 4096) return error.FormatNotSupported;

    return .{
        .frame_width = frame_width,
        .frame_height = frame_height,
        .stride = @as(usize, frame_width) * 4,
        .flip = bitmap.biHeight > 0,
    };
}

fn create(class_id: *const GUID, interface_id: *const GUID) !*anyopaque {
    var object: ?*anyopaque = null;
    const hr = CoCreateInstance(class_id, null, CLSCTX_INPROC_SERVER, interface_id, &object);
    try check(hr);
    return object orelse error.MissingComObject;
}

fn check(hr: HRESULT) !void {
    if (hr >= 0) return;
    return switch (hr) {
        error_no_system_resources, error_busy, error_gen_failure => error.CameraBusy,
        vfw_e_invalid_media_type,
        vfw_e_no_acceptable_types,
        vfw_e_cannot_connect,
        vfw_e_type_not_accepted,
        => error.FormatNotSupported,
        else => error.GraphFailed,
    };
}

const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

const BITMAPINFOHEADER = extern struct {
    biSize: u32,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: u32,
    biSizeImage: u32,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: u32,
    biClrImportant: u32,
};

const VIDEOINFOHEADER = extern struct {
    rcSource: RECT,
    rcTarget: RECT,
    dwBitRate: u32,
    dwBitErrorRate: u32,
    AvgTimePerFrame: i64,
    bmiHeader: BITMAPINFOHEADER,
};

const AM_MEDIA_TYPE = extern struct {
    majortype: GUID,
    subtype: GUID,
    bFixedSizeSamples: i32,
    bTemporalCompression: i32,
    lSampleSize: u32,
    formattype: GUID,
    pUnk: ?*anyopaque,
    cbFormat: u32,
    pbFormat: ?*anyopaque,
};

const IGraphBuilder = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const fn (
            *IGraphBuilder,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        add_ref: *const anyopaque,
        release: *const fn (*IGraphBuilder) callconv(.winapi) ULONG,
        add_filter: *const fn (
            *IGraphBuilder,
            *directshow.IBaseFilter,
            [*:0]const u16,
        ) callconv(.winapi) HRESULT,
    };
};

const ICaptureGraphBuilder2 = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*ICaptureGraphBuilder2) callconv(.winapi) ULONG,
        set_filtergraph: *const fn (
            *ICaptureGraphBuilder2,
            *IGraphBuilder,
        ) callconv(.winapi) HRESULT,
        get_filtergraph: *const anyopaque,
        set_output_file_name: *const anyopaque,
        find_interface: *const fn (
            *ICaptureGraphBuilder2,
            *const GUID,
            *const GUID,
            *directshow.IBaseFilter,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        render_stream: *const fn (
            *ICaptureGraphBuilder2,
            *const GUID,
            *const GUID,
            *anyopaque,
            ?*directshow.IBaseFilter,
            ?*directshow.IBaseFilter,
        ) callconv(.winapi) HRESULT,
    };
};

const IMediaControl = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*IMediaControl) callconv(.winapi) ULONG,
        get_type_info_count: *const anyopaque,
        get_type_info: *const anyopaque,
        get_ids_of_names: *const anyopaque,
        invoke: *const anyopaque,
        run: *const fn (*IMediaControl) callconv(.winapi) HRESULT,
        pause: *const anyopaque,
        stop: *const fn (*IMediaControl) callconv(.winapi) HRESULT,
    };
};

/// `IAMStreamConfig` on the source's capture pin: the driver's format list.
const IAMStreamConfig = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*IAMStreamConfig) callconv(.winapi) ULONG,
        set_format: *const fn (
            *IAMStreamConfig,
            *const AM_MEDIA_TYPE,
        ) callconv(.winapi) HRESULT,
        get_format: *const anyopaque,
        get_number_of_capabilities: *const fn (
            *IAMStreamConfig,
            *LONG,
            *LONG,
        ) callconv(.winapi) HRESULT,
        get_stream_caps: *const fn (
            *IAMStreamConfig,
            LONG,
            *?*AM_MEDIA_TYPE,
            *[256]u8,
        ) callconv(.winapi) HRESULT,
    };
};

const ISampleGrabber = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*ISampleGrabber) callconv(.winapi) ULONG,
        set_one_shot: *const fn (*ISampleGrabber, LONG) callconv(.winapi) HRESULT,
        set_media_type: *const fn (
            *ISampleGrabber,
            *const AM_MEDIA_TYPE,
        ) callconv(.winapi) HRESULT,
        get_connected_media_type: *const fn (
            *ISampleGrabber,
            *AM_MEDIA_TYPE,
        ) callconv(.winapi) HRESULT,
        set_buffer_samples: *const fn (*ISampleGrabber, LONG) callconv(.winapi) HRESULT,
        get_current_buffer: *const fn (
            *ISampleGrabber,
            *LONG,
            ?[*]u8,
        ) callconv(.winapi) HRESULT,
        get_current_sample: *const anyopaque,
        set_callback: *const anyopaque,
    };
};
