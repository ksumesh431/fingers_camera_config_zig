const std = @import("std");

const Allocator = std.mem.Allocator;
const GUID = std.os.windows.GUID;

pub const HRESULT = i32;
pub const LONG = i32;
const DWORD = u32;
const ULONG = u32;

const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;
const COINIT_APARTMENTTHREADED: DWORD = 0x2;
const CLSCTX_INPROC_SERVER: DWORD = 0x1;
const VT_BSTR: u16 = 8;

const video_proc_amp_white_balance: LONG = 7;
pub const video_proc_amp_powerline_frequency: LONG = 13;
pub const video_proc_amp_flag_auto: LONG = 0x1;
pub const video_proc_amp_flag_manual: LONG = 0x2;

pub const camera_control_exposure: LONG = 4;
pub const camera_control_flag_auto: LONG = 0x1;
pub const camera_control_flag_manual: LONG = 0x2;

pub const powerline_disabled: LONG = 0;
pub const powerline_50hz: LONG = 1;
pub const powerline_60hz: LONG = 2;
pub const powerline_auto: LONG = 3;

const clsid_system_device_enum = GUID.parse("{62BE5D10-60EB-11D0-BD3B-00A0C911CE86}");
const clsid_video_input_device_category = GUID.parse("{860BB310-5D01-11D0-BD3B-00A0C911CE86}");
const iid_create_dev_enum = GUID.parse("{29840822-5B84-11D0-BD3B-00A0C911CE86}");
const iid_property_bag = GUID.parse("{55272A00-42CB-11CE-8135-00AA004BB851}");
const iid_base_filter = GUID.parse("{56A86895-0AD4-11CE-B03A-0020AF0BA770}");
const iid_video_proc_amp = GUID.parse("{C6E13360-30AC-11D0-A18C-00A0C9118956}");
const iid_camera_control = GUID.parse("{C6E13370-30AC-11D0-A18C-00A0C9118956}");

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, co_init: DWORD) HRESULT;
extern "ole32" fn CoUninitialize() void;
extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) void;
extern "ole32" fn CoCreateInstance(
    class_id: *const GUID,
    outer: ?*anyopaque,
    class_context: DWORD,
    interface_id: *const GUID,
    object: *?*anyopaque,
) HRESULT;
extern "oleaut32" fn VariantInit(value: *Variant) void;
extern "oleaut32" fn VariantClear(value: *Variant) HRESULT;
extern "oleaut32" fn SysStringLen(value: [*:0]const u16) ULONG;

pub const ComApartment = struct {
    pub fn init() !ComApartment {
        const hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
        if (failed(hr)) return comError("CoInitializeEx", hr);
        return .{};
    }

    pub fn deinit(self: *ComApartment) void {
        _ = self;
        CoUninitialize();
    }
};

pub const DeviceEnumerator = struct {
    system_enum: *ICreateDevEnum,
    video_enum: ?*IEnumMoniker,

    pub fn init() !DeviceEnumerator {
        var raw_system_enum: ?*anyopaque = null;
        var hr = CoCreateInstance(
            &clsid_system_device_enum,
            null,
            CLSCTX_INPROC_SERVER,
            &iid_create_dev_enum,
            &raw_system_enum,
        );
        if (failed(hr)) return comError("CoCreateInstance(SystemDeviceEnum)", hr);

        const system_enum: *ICreateDevEnum = @ptrCast(@alignCast(raw_system_enum.?));
        errdefer _ = system_enum.vtable.release(system_enum);

        var video_enum: ?*IEnumMoniker = null;
        hr = system_enum.vtable.create_class_enumerator(
            system_enum,
            &clsid_video_input_device_category,
            &video_enum,
            0,
        );
        if (failed(hr)) return comError("CreateClassEnumerator(VideoInputDeviceCategory)", hr);

        return .{
            .system_enum = system_enum,
            .video_enum = video_enum,
        };
    }

    pub fn deinit(self: *DeviceEnumerator) void {
        if (self.video_enum) |video_enum| _ = video_enum.vtable.release(video_enum);
        _ = self.system_enum.vtable.release(self.system_enum);
        self.* = undefined;
    }

    pub fn next(self: *DeviceEnumerator, allocator: Allocator) !?CameraDevice {
        const video_enum = self.video_enum orelse return null;

        while (true) {
            var moniker: ?*IMoniker = null;
            var fetched: ULONG = 0;
            const hr = video_enum.vtable.next(video_enum, 1, &moniker, &fetched);
            if (failed(hr)) return comError("IEnumMoniker.Next", hr);
            if (hr == S_FALSE or fetched == 0) return null;

            const device_moniker = moniker orelse return error.MissingDeviceMoniker;
            defer _ = device_moniker.vtable.release(device_moniker);
            return CameraDevice.bind(allocator, device_moniker) catch |err| {
                std.debug.print("Skipping unavailable DirectShow device: {s}\n", .{@errorName(err)});
                continue;
            };
        }
    }
};

pub const CameraDevice = struct {
    friendly_name: []u8,
    device_path: []u8,
    filter: *IBaseFilter,
    proc_amp: ?*IAMVideoProcAmp,
    proc_amp_query_hr: HRESULT,
    camera_control: ?*IAMCameraControl,
    camera_control_query_hr: HRESULT,

    fn bind(allocator: Allocator, moniker: *IMoniker) !CameraDevice {
        var raw_bag: ?*anyopaque = null;
        var hr = moniker.vtable.bind_to_storage(
            moniker,
            null,
            null,
            &iid_property_bag,
            &raw_bag,
        );
        if (failed(hr)) return comError("IMoniker.BindToStorage(IPropertyBag)", hr);

        const bag: *IPropertyBag = @ptrCast(@alignCast(raw_bag.?));
        defer _ = bag.vtable.release(bag);

        const friendly_name = (try readStringProperty(allocator, bag, "FriendlyName")) orelse
            try allocator.dupe(u8, "<unnamed>");
        errdefer allocator.free(friendly_name);
        const device_path = if (try readStringProperty(allocator, bag, "DevicePath")) |path|
            path
        else
            try readDisplayName(allocator, moniker);
        errdefer allocator.free(device_path);

        var raw_filter: ?*anyopaque = null;
        hr = moniker.vtable.bind_to_object(
            moniker,
            null,
            null,
            &iid_base_filter,
            &raw_filter,
        );
        if (failed(hr)) return comError("IMoniker.BindToObject(IBaseFilter)", hr);

        const filter: *IBaseFilter = @ptrCast(@alignCast(raw_filter.?));
        errdefer _ = filter.vtable.release(filter);

        var raw_proc_amp: ?*anyopaque = null;
        const proc_amp_query_hr = filter.vtable.query_interface(
            filter,
            &iid_video_proc_amp,
            &raw_proc_amp,
        );
        const proc_amp: ?*IAMVideoProcAmp = if (!failed(proc_amp_query_hr))
            @ptrCast(@alignCast(raw_proc_amp.?))
        else
            null;

        var raw_camera_control: ?*anyopaque = null;
        const camera_control_query_hr = filter.vtable.query_interface(
            filter,
            &iid_camera_control,
            &raw_camera_control,
        );
        const camera_control: ?*IAMCameraControl = if (!failed(camera_control_query_hr))
            @ptrCast(@alignCast(raw_camera_control.?))
        else
            null;

        return .{
            .friendly_name = friendly_name,
            .device_path = device_path,
            .filter = filter,
            .proc_amp = proc_amp,
            .proc_amp_query_hr = proc_amp_query_hr,
            .camera_control = camera_control,
            .camera_control_query_hr = camera_control_query_hr,
        };
    }

    pub fn deinit(self: *CameraDevice, allocator: Allocator) void {
        if (self.camera_control) |camera_control| {
            _ = camera_control.vtable.release(camera_control);
        }
        if (self.proc_amp) |proc_amp| _ = proc_amp.vtable.release(proc_amp);
        _ = self.filter.vtable.release(self.filter);
        allocator.free(self.friendly_name);
        allocator.free(self.device_path);
        self.* = undefined;
    }

    pub fn propertyRange(self: *CameraDevice, property_id: LONG) !PropertyRange {
        const proc_amp = self.proc_amp orelse return error.VideoProcAmpUnavailable;
        var range: PropertyRange = undefined;
        const hr = proc_amp.vtable.get_range(
            proc_amp,
            property_id,
            &range.min,
            &range.max,
            &range.step,
            &range.default,
            &range.capabilities,
        );
        if (failed(hr)) return comError("IAMVideoProcAmp.GetRange", hr);
        return range;
    }

    pub fn propertyValue(self: *CameraDevice, property_id: LONG) !PropertyValue {
        const proc_amp = self.proc_amp orelse return error.VideoProcAmpUnavailable;
        var value: PropertyValue = undefined;
        const hr = proc_amp.vtable.get(
            proc_amp,
            property_id,
            &value.value,
            &value.flags,
        );
        if (failed(hr)) return comError("IAMVideoProcAmp.Get", hr);
        return value;
    }

    pub fn setProperty(self: *CameraDevice, property_id: LONG, value: LONG, flags: LONG) !void {
        const proc_amp = self.proc_amp orelse return error.VideoProcAmpUnavailable;
        const hr = proc_amp.vtable.set(
            proc_amp,
            property_id,
            value,
            flags,
        );
        if (failed(hr)) return comError("IAMVideoProcAmp.Set", hr);
    }

    pub fn whiteBalanceRange(self: *CameraDevice) !PropertyRange {
        return self.propertyRange(video_proc_amp_white_balance);
    }

    pub fn whiteBalance(self: *CameraDevice) !PropertyValue {
        return self.propertyValue(video_proc_amp_white_balance);
    }

    pub fn setWhiteBalance(self: *CameraDevice, value: LONG, flags: LONG) !void {
        return self.setProperty(video_proc_amp_white_balance, value, flags);
    }

    pub fn powerlineFrequencyRange(self: *CameraDevice) !PropertyRange {
        return self.propertyRange(video_proc_amp_powerline_frequency);
    }

    pub fn powerlineFrequency(self: *CameraDevice) !PropertyValue {
        return self.propertyValue(video_proc_amp_powerline_frequency);
    }

    pub fn setPowerlineFrequency(self: *CameraDevice, value: LONG, flags: LONG) !void {
        return self.setProperty(video_proc_amp_powerline_frequency, value, flags);
    }

    pub fn cameraControlRange(self: *CameraDevice, property_id: LONG) !PropertyRange {
        const camera_control = self.camera_control orelse return error.CameraControlUnavailable;
        var range: PropertyRange = undefined;
        const hr = camera_control.vtable.get_range(
            camera_control,
            property_id,
            &range.min,
            &range.max,
            &range.step,
            &range.default,
            &range.capabilities,
        );
        if (failed(hr)) return comError("IAMCameraControl.GetRange", hr);
        return range;
    }

    pub fn cameraControlValue(self: *CameraDevice, property_id: LONG) !PropertyValue {
        const camera_control = self.camera_control orelse return error.CameraControlUnavailable;
        var value: PropertyValue = undefined;
        const hr = camera_control.vtable.get(
            camera_control,
            property_id,
            &value.value,
            &value.flags,
        );
        if (failed(hr)) return comError("IAMCameraControl.Get", hr);
        return value;
    }

    pub fn setCameraControl(
        self: *CameraDevice,
        property_id: LONG,
        value: LONG,
        flags: LONG,
    ) !void {
        const camera_control = self.camera_control orelse return error.CameraControlUnavailable;
        const hr = camera_control.vtable.set(
            camera_control,
            property_id,
            value,
            flags,
        );
        if (failed(hr)) return comError("IAMCameraControl.Set", hr);
    }
};

pub const PropertyRange = struct {
    min: LONG,
    max: LONG,
    step: LONG,
    default: LONG,
    capabilities: LONG,
};

pub const PropertyValue = struct {
    value: LONG,
    flags: LONG,
};

fn readStringProperty(
    allocator: Allocator,
    bag: *IPropertyBag,
    comptime property_name: []const u8,
) !?[]u8 {
    var value: Variant = .{};
    VariantInit(&value);
    defer _ = VariantClear(&value);

    const wide_name = std.unicode.utf8ToUtf16LeStringLiteral(property_name);
    const hr = bag.vtable.read(bag, wide_name, &value, null);
    if (failed(hr)) return null;
    if (value.vt != VT_BSTR or value.data == 0) {
        std.debug.print("{s}: expected VT_BSTR, got VARTYPE {d}\n", .{ property_name, value.vt });
        return error.UnexpectedPropertyType;
    }

    const string: [*:0]const u16 = @ptrFromInt(value.data);
    const length = SysStringLen(string);
    return try std.unicode.utf16LeToUtf8Alloc(allocator, string[0..length]);
}

fn readDisplayName(allocator: Allocator, moniker: *IMoniker) ![]u8 {
    var display_name: ?[*:0]u16 = null;
    const hr = moniker.vtable.get_display_name(moniker, null, null, &display_name);
    if (failed(hr)) return comError("IMoniker.GetDisplayName", hr);

    const string = display_name orelse return error.MissingDisplayName;
    defer CoTaskMemFree(@ptrCast(string));
    return std.unicode.utf16LeToUtf8Alloc(allocator, string[0..std.mem.len(string)]);
}

fn failed(hr: HRESULT) bool {
    return hr < 0;
}

fn comError(operation: []const u8, hr: HRESULT) error{ComCallFailed} {
    std.debug.print(
        "{s} failed with HRESULT 0x{x:0>8}\n",
        .{ operation, @as(u32, @bitCast(hr)) },
    );
    return error.ComCallFailed;
}

const Variant = extern struct {
    vt: u16 = 0,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    data: u64 = 0,
};

comptime {
    if (@sizeOf(Variant) != 16) @compileError("Unexpected Windows VARIANT size");
}

const ICreateDevEnum = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*ICreateDevEnum) callconv(.winapi) ULONG,
        create_class_enumerator: *const fn (
            *ICreateDevEnum,
            *const GUID,
            *?*IEnumMoniker,
            DWORD,
        ) callconv(.winapi) HRESULT,
    };
};

const IEnumMoniker = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*IEnumMoniker) callconv(.winapi) ULONG,
        next: *const fn (
            *IEnumMoniker,
            ULONG,
            *?*IMoniker,
            ?*ULONG,
        ) callconv(.winapi) HRESULT,
        skip: *const anyopaque,
        reset: *const anyopaque,
        clone: *const anyopaque,
    };
};

const IMoniker = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*IMoniker) callconv(.winapi) ULONG,
        get_class_id: *const anyopaque,
        is_dirty: *const anyopaque,
        load: *const anyopaque,
        save: *const anyopaque,
        get_size_max: *const anyopaque,
        bind_to_object: *const fn (
            *IMoniker,
            ?*anyopaque,
            ?*IMoniker,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        bind_to_storage: *const fn (
            *IMoniker,
            ?*anyopaque,
            ?*IMoniker,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        reduce: *const anyopaque,
        compose_with: *const anyopaque,
        enumerate: *const anyopaque,
        is_equal: *const anyopaque,
        hash: *const anyopaque,
        is_running: *const anyopaque,
        get_time_of_last_change: *const anyopaque,
        inverse: *const anyopaque,
        common_prefix_with: *const anyopaque,
        relative_path_to: *const anyopaque,
        get_display_name: *const fn (
            *IMoniker,
            ?*anyopaque,
            ?*IMoniker,
            *?[*:0]u16,
        ) callconv(.winapi) HRESULT,
    };
};

const IPropertyBag = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*IPropertyBag) callconv(.winapi) ULONG,
        read: *const fn (
            *IPropertyBag,
            [*:0]const u16,
            *Variant,
            ?*anyopaque,
        ) callconv(.winapi) HRESULT,
        write: *const anyopaque,
    };
};

pub const IBaseFilter = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const fn (
            *IBaseFilter,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        add_ref: *const anyopaque,
        release: *const fn (*IBaseFilter) callconv(.winapi) ULONG,
        get_class_id: *const anyopaque,
        stop: *const anyopaque,
        pause: *const anyopaque,
        run: *const anyopaque,
        get_state: *const anyopaque,
        set_sync_source: *const anyopaque,
        get_sync_source: *const anyopaque,
    };
};

const IAMVideoProcAmp = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*IAMVideoProcAmp) callconv(.winapi) ULONG,
        get_range: *const fn (
            *IAMVideoProcAmp,
            LONG,
            *LONG,
            *LONG,
            *LONG,
            *LONG,
            *LONG,
        ) callconv(.winapi) HRESULT,
        set: *const fn (
            *IAMVideoProcAmp,
            LONG,
            LONG,
            LONG,
        ) callconv(.winapi) HRESULT,
        get: *const fn (
            *IAMVideoProcAmp,
            LONG,
            *LONG,
            *LONG,
        ) callconv(.winapi) HRESULT,
    };
};

const IAMCameraControl = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*IAMCameraControl) callconv(.winapi) ULONG,
        get_range: *const fn (
            *IAMCameraControl,
            LONG,
            *LONG,
            *LONG,
            *LONG,
            *LONG,
            *LONG,
        ) callconv(.winapi) HRESULT,
        set: *const fn (
            *IAMCameraControl,
            LONG,
            LONG,
            LONG,
        ) callconv(.winapi) HRESULT,
        get: *const fn (
            *IAMCameraControl,
            LONG,
            *LONG,
            *LONG,
        ) callconv(.winapi) HRESULT,
    };
};
