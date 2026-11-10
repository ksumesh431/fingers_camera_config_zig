const std = @import("std");
const directshow = @import("directshow.zig");

const GUID = std.os.windows.GUID;
const HRESULT = directshow.HRESULT;
const ULONG = u32;
const DWORD = u32;

const CLSCTX_INPROC_SERVER: DWORD = 0x1;

const clsid_filter_graph = GUID.parse("{E436EBB3-524F-11CE-9F53-0020AF0BA770}");
const clsid_capture_graph_builder = GUID.parse("{BF87B6E1-8C27-11D0-B3F0-00AA003761C5}");
const clsid_null_renderer = GUID.parse("{C1F400A4-3F08-11D3-9F0B-006008039E37}");
const iid_graph_builder = GUID.parse("{56A868A9-0AD4-11CE-B03A-0020AF0BA770}");
const iid_capture_graph_builder = GUID.parse("{93E5A4E0-2D50-11D2-ABFA-00A0C9C6E38D}");
const iid_base_filter = GUID.parse("{56A86895-0AD4-11CE-B03A-0020AF0BA770}");
const iid_media_control = GUID.parse("{56A868B1-0AD4-11CE-B03A-0020AF0BA770}");
const pin_category_capture = GUID.parse("{FB6C4281-0353-11D1-905F-0000C0CC16BA}");
const media_type_video = GUID.parse("{73646976-0000-0010-8000-00AA00389B71}");

extern "ole32" fn CoCreateInstance(
    class_id: *const GUID,
    outer: ?*anyopaque,
    class_context: DWORD,
    interface_id: *const GUID,
    object: *?*anyopaque,
) HRESULT;
extern "kernel32" fn Sleep(milliseconds: u32) void;

pub fn run(camera: *directshow.CameraDevice, seconds: u32) !void {
    const graph: *IGraphBuilder = @ptrCast(@alignCast(try create(
        &clsid_filter_graph,
        &iid_graph_builder,
        "CoCreateInstance(FilterGraph)",
    )));
    defer _ = graph.vtable.release(graph);

    const builder: *ICaptureGraphBuilder2 = @ptrCast(@alignCast(try create(
        &clsid_capture_graph_builder,
        &iid_capture_graph_builder,
        "CoCreateInstance(CaptureGraphBuilder2)",
    )));
    defer _ = builder.vtable.release(builder);

    const null_renderer: *directshow.IBaseFilter = @ptrCast(@alignCast(try create(
        &clsid_null_renderer,
        &iid_base_filter,
        "CoCreateInstance(NullRenderer)",
    )));
    defer _ = null_renderer.vtable.release(null_renderer);

    try check(
        "ICaptureGraphBuilder2.SetFiltergraph",
        builder.vtable.set_filtergraph(builder, graph),
    );
    try check(
        "IGraphBuilder.AddFilter(FINGERS)",
        graph.vtable.add_filter(
            graph,
            camera.filter,
            std.unicode.utf8ToUtf16LeStringLiteral("FINGERS keep-alive"),
        ),
    );
    try check(
        "IGraphBuilder.AddFilter(NullRenderer)",
        graph.vtable.add_filter(
            graph,
            null_renderer,
            std.unicode.utf8ToUtf16LeStringLiteral("Null Renderer"),
        ),
    );

    var raw_media_control: ?*anyopaque = null;
    try check(
        "IGraphBuilder.QueryInterface(IMediaControl)",
        graph.vtable.query_interface(graph, &iid_media_control, &raw_media_control),
    );
    const media_control: *IMediaControl = @ptrCast(@alignCast(raw_media_control.?));
    defer _ = media_control.vtable.release(media_control);

    try check(
        "ICaptureGraphBuilder2.RenderStream(Capture)",
        builder.vtable.render_stream(
            builder,
            &pin_category_capture,
            &media_type_video,
            @ptrCast(camera.filter),
            null,
            null_renderer,
        ),
    );

    var running = false;
    errdefer {
        if (running) _ = media_control.vtable.stop(media_control);
    }

    try check("IMediaControl.Run", media_control.vtable.run(media_control));
    running = true;
    std.debug.print(
        "Keep-alive stream running for {d} second(s); no camera settings were changed.\n",
        .{seconds},
    );

    Sleep(seconds * 1000);

    try check("IMediaControl.Stop", media_control.vtable.stop(media_control));
    running = false;
    std.debug.print("Keep-alive stream stopped.\n", .{});
}

fn create(
    class_id: *const GUID,
    interface_id: *const GUID,
    operation: []const u8,
) !*anyopaque {
    var object: ?*anyopaque = null;
    const hr = CoCreateInstance(
        class_id,
        null,
        CLSCTX_INPROC_SERVER,
        interface_id,
        &object,
    );
    try check(operation, hr);
    return object orelse error.MissingComObject;
}

fn check(operation: []const u8, hr: HRESULT) !void {
    if (hr >= 0) return;
    std.debug.print(
        "{s} failed with HRESULT 0x{x:0>8}\n",
        .{ operation, @as(u32, @bitCast(hr)) },
    );
    return error.KeepAliveGraphFailed;
}

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
        find_interface: *const anyopaque,
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
