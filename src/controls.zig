//! The extra, user-customisable camera controls.
//!
//! The frozen white balance (`VideoProcAmp_WhiteBalance`, property 7) and
//! power-line frequency (property 13) are deliberately absent: a compile-time
//! check below refuses a table that contains them.
const std = @import("std");
const directshow = @import("directshow.zig");
const settings = @import("settings.zig");

/// Which DirectShow interface a control belongs to.
pub const Interface = enum {
    /// `IAMVideoProcAmp`: image adjustments.
    video_proc_amp,
    /// `IAMCameraControl`: physical camera controls.
    camera_control,
};

/// The window groups the controls by this.
pub const Group = enum { image, camera };

/// How the window draws a control.
pub const Kind = enum {
    /// A slider over the driver's range.
    level,
    /// An on/off switch for 0/1 properties such as `color_enable`.
    boolean,
};

pub const Spec = struct {
    /// Stable key used in the settings file; never rename it.
    name: []const u8,
    /// Text shown in the window and in log lines.
    label: []const u8,
    group: Group,
    interface: Interface,
    property_id: i32,
    kind: Kind = .level,
};

/// DirectShow `VideoProcAmp_WhiteBalance`; frozen, never user-editable.
const frozen_white_balance: i32 = 7;

/// DirectShow `VideoProcAmp_PowerlineFrequency`; frozen, never user-editable.
const frozen_powerline_frequency: i32 = directshow.video_proc_amp_powerline_frequency;

/// Every control the window offers, apart from the two frozen ones.
pub const specs = [_]Spec{
    .{
        .name = "brightness",
        .label = "Brightness",
        .group = .image,
        .interface = .video_proc_amp,
        .property_id = 0,
    },
    .{
        .name = "contrast",
        .label = "Contrast",
        .group = .image,
        .interface = .video_proc_amp,
        .property_id = 1,
    },
    .{
        .name = "hue",
        .label = "Hue",
        .group = .image,
        .interface = .video_proc_amp,
        .property_id = 2,
    },
    .{
        .name = "saturation",
        .label = "Saturation",
        .group = .image,
        .interface = .video_proc_amp,
        .property_id = 3,
    },
    .{
        .name = "sharpness",
        .label = "Sharpness",
        .group = .image,
        .interface = .video_proc_amp,
        .property_id = 4,
    },
    .{
        .name = "gamma",
        .label = "Gamma",
        .group = .image,
        .interface = .video_proc_amp,
        .property_id = 5,
    },
    .{
        .name = "color_enable",
        .label = "Color",
        .group = .image,
        .interface = .video_proc_amp,
        .property_id = 6,
        .kind = .boolean,
    },
    .{
        .name = "backlight_compensation",
        .label = "Backlight compensation",
        .group = .image,
        .interface = .video_proc_amp,
        .property_id = 8,
    },
    .{
        .name = "gain",
        .label = "Gain",
        .group = .image,
        .interface = .video_proc_amp,
        .property_id = 9,
    },
    .{
        .name = "exposure",
        .label = "Exposure",
        .group = .camera,
        .interface = .camera_control,
        .property_id = 4,
    },
    .{
        .name = "focus",
        .label = "Focus",
        .group = .camera,
        .interface = .camera_control,
        .property_id = 6,
    },
    .{
        .name = "zoom",
        .label = "Zoom",
        .group = .camera,
        .interface = .camera_control,
        .property_id = 3,
    },
    .{
        .name = "pan",
        .label = "Pan",
        .group = .camera,
        .interface = .camera_control,
        .property_id = 0,
    },
    .{
        .name = "tilt",
        .label = "Tilt",
        .group = .camera,
        .interface = .camera_control,
        .property_id = 1,
    },
    .{
        .name = "roll",
        .label = "Roll",
        .group = .camera,
        .interface = .camera_control,
        .property_id = 2,
    },
    .{
        .name = "iris",
        .label = "Iris",
        .group = .camera,
        .interface = .camera_control,
        .property_id = 5,
    },
};

comptime {
    for (specs) |spec| {
        if (isFrozen(spec)) {
            @compileError("the frozen white balance and power-line controls " ++
                "must not appear in the extra control table");
        }
    }
}

pub fn isFrozen(spec: Spec) bool {
    if (spec.interface != .video_proc_amp) return false;
    return spec.property_id == frozen_white_balance or
        spec.property_id == frozen_powerline_frequency;
}

pub fn specByName(name: []const u8) ?Spec {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

pub fn range(camera: *directshow.CameraDevice, spec: Spec) !directshow.PropertyRange {
    return switch (spec.interface) {
        .video_proc_amp => camera.propertyRange(spec.property_id),
        .camera_control => camera.cameraControlRange(spec.property_id),
    };
}

pub fn value(camera: *directshow.CameraDevice, spec: Spec) !directshow.PropertyValue {
    return switch (spec.interface) {
        .video_proc_amp => camera.propertyValue(spec.property_id),
        .camera_control => camera.cameraControlValue(spec.property_id),
    };
}

pub fn set(
    camera: *directshow.CameraDevice,
    spec: Spec,
    new_value: directshow.LONG,
    flags: directshow.LONG,
) !void {
    return switch (spec.interface) {
        .video_proc_amp => camera.setProperty(spec.property_id, new_value, flags),
        .camera_control => camera.setCameraControl(spec.property_id, new_value, flags),
    };
}

/// True when the driver offers automatic mode for this control.
pub fn supportsAuto(property_range: directshow.PropertyRange) bool {
    return property_range.capabilities & directshow.video_proc_amp_flag_auto != 0;
}

/// True when the driver offers manual mode for this control. Properties
/// without any mode flags (discrete values) are manual-only.
pub fn supportsManual(property_range: directshow.PropertyRange) bool {
    const modes = directshow.video_proc_amp_flag_auto |
        directshow.video_proc_amp_flag_manual;
    if (property_range.capabilities & modes == 0) return true;
    return property_range.capabilities & directshow.video_proc_amp_flag_manual != 0;
}

pub fn isManual(property_value: directshow.PropertyValue) bool {
    return property_value.flags & directshow.video_proc_amp_flag_manual != 0 and
        property_value.flags & directshow.video_proc_amp_flag_auto == 0;
}

pub fn valueInRange(property_range: directshow.PropertyRange, candidate: i32) bool {
    return property_range.step > 0 and
        candidate >= property_range.min and
        candidate <= property_range.max and
        @mod(candidate - property_range.min, property_range.step) == 0;
}

/// Snaps an arbitrary value onto the driver's step grid, clamped to its range.
pub fn snapToRange(
    min: i32,
    max: i32,
    step: i32,
    candidate: f32,
) i32 {
    const safe_step: i32 = if (step > 0) step else 1;
    const bounded = std.math.clamp(
        candidate,
        @as(f32, @floatFromInt(min)),
        @as(f32, @floatFromInt(max)),
    );
    const steps = @round((bounded - @as(f32, @floatFromInt(min))) / @as(f32, @floatFromInt(safe_step)));
    const snapped: i32 = min + @as(i32, @intFromFloat(steps)) * safe_step;
    return std.math.clamp(snapped, min, max);
}

pub const Outcome = enum {
    /// The control was written and verified.
    applied,
    /// The camera already reported the wanted state.
    unchanged,
    /// The camera does not offer this control or value; nothing was written.
    skipped,
};

/// Reads, compares, and only then writes one entry. Never touches the frozen
/// white balance or power-line properties.
pub fn applyEntry(
    camera: *directshow.CameraDevice,
    spec: Spec,
    entry: settings.Entry,
    verbose: bool,
) !Outcome {
    if (isFrozen(spec)) return error.FrozenControlRejected;

    const property_range = range(camera, spec) catch |err| switch (err) {
        error.PropertyNotSupported => {
            if (verbose) {
                std.debug.print(
                    "[controls] {s}: the camera does not expose this control.\n",
                    .{spec.label},
                );
            }
            return .skipped;
        },
        else => return err,
    };

    const modes = directshow.video_proc_amp_flag_auto |
        directshow.video_proc_amp_flag_manual;
    const has_modes = property_range.capabilities & modes != 0;
    const can_auto = supportsAuto(property_range);
    const can_manual = supportsManual(property_range);

    if (entry.auto) {
        if (!can_auto) {
            if (verbose) {
                std.debug.print(
                    "[controls] {s}: automatic mode is not supported; leaving it alone.\n",
                    .{spec.label},
                );
            }
            return .skipped;
        }

        const current = try value(camera, spec);
        if (current.flags & directshow.video_proc_amp_flag_auto != 0 and
            current.flags & directshow.video_proc_amp_flag_manual == 0)
        {
            return .unchanged;
        }

        try set(camera, spec, current.value, directshow.video_proc_amp_flag_auto);
        const verified = try value(camera, spec);
        if (verified.flags & directshow.video_proc_amp_flag_auto == 0 or
            verified.flags & directshow.video_proc_amp_flag_manual != 0)
        {
            return error.ControlVerificationFailed;
        }
        if (verbose) {
            std.debug.print("[controls] {s}: automatic mode applied.\n", .{spec.label});
        }
        return .applied;
    }

    if (!can_manual) {
        if (verbose) {
            std.debug.print(
                "[controls] {s}: manual mode is not supported; leaving it alone.\n",
                .{spec.label},
            );
        }
        return .skipped;
    }

    if (!valueInRange(property_range, entry.value)) {
        if (verbose) {
            std.debug.print(
                "[controls] {s}: value {d} is outside the driver range {d}..{d} step {d}.\n",
                .{ spec.label, entry.value, property_range.min, property_range.max, property_range.step },
            );
        }
        return .skipped;
    }

    const flags: i32 = if (has_modes) directshow.video_proc_amp_flag_manual else 0;

    const current = try value(camera, spec);
    const mode_matches = if (has_modes)
        (current.flags & directshow.video_proc_amp_flag_manual != 0 and
            current.flags & directshow.video_proc_amp_flag_auto == 0)
    else
        true;
    if (current.value == entry.value and mode_matches) return .unchanged;

    try set(camera, spec, entry.value, flags);
    const verified = try value(camera, spec);
    if (verified.value != entry.value) return error.ControlVerificationFailed;
    if (has_modes and !isManual(verified)) return error.ControlVerificationFailed;

    if (verbose) {
        std.debug.print(
            "[controls] {s}: manual {d} applied.\n",
            .{ spec.label, entry.value },
        );
    }
    return .applied;
}

pub const Stats = struct {
    applied: u32 = 0,
    unchanged: u32 = 0,
    skipped: u32 = 0,
    failed: u32 = 0,
};

/// Applies every managed entry of `config`. Unsupported or out-of-range
/// entries are reported as skipped, never as camera failures.
pub fn applySettings(
    camera: *directshow.CameraDevice,
    config: settings.Settings,
    verbose: bool,
) Stats {
    var stats: Stats = .{};

    for (specs) |spec| {
        const entry = config.find(spec.name) orelse continue;
        if (!entry.manage) continue;

        const outcome = applyEntry(camera, spec, entry.*, verbose) catch |err| {
            stats.failed += 1;
            if (verbose) {
                std.debug.print(
                    "[controls] {s}: {s}.\n",
                    .{ spec.label, @errorName(err) },
                );
            }
            continue;
        };

        switch (outcome) {
            .applied => stats.applied += 1,
            .unchanged => stats.unchanged += 1,
            .skipped => stats.skipped += 1,
        }
    }

    return stats;
}

test "the frozen settings never appear in the extra control table" {
    for (specs) |spec| {
        try std.testing.expect(!isFrozen(spec));
    }
    try std.testing.expect(specByName("brightness") != null);
    try std.testing.expect(specByName("white_balance") == null);
    try std.testing.expect(specByName("powerline_frequency") == null);
}

test "values snap onto the driver grid and stay inside the range" {
    try std.testing.expectEqual(@as(i32, 1), snapToRange(1, 5, 1, 0.2));
    try std.testing.expectEqual(@as(i32, 4), snapToRange(1, 5, 1, 4.4));
    try std.testing.expectEqual(@as(i32, 5), snapToRange(1, 5, 1, 9));
    try std.testing.expectEqual(@as(i32, 1), snapToRange(1, 5, 1, -9));
    try std.testing.expectEqual(@as(i32, -13), snapToRange(-13, 0, 1, -12.6));
    try std.testing.expectEqual(@as(i32, 0), snapToRange(-13, 0, 1, -0.4));
    try std.testing.expectEqual(@as(i32, 10), snapToRange(0, 100, 10, 12));
}

test "range checks honour step and bounds" {
    const range_value = directshow.PropertyRange{
        .min = -13,
        .max = 0,
        .step = 1,
        .default = -7,
        .capabilities = directshow.video_proc_amp_flag_auto |
            directshow.video_proc_amp_flag_manual,
    };
    try std.testing.expect(valueInRange(range_value, -13));
    try std.testing.expect(valueInRange(range_value, 0));
    try std.testing.expect(!valueInRange(range_value, -14));
    try std.testing.expect(!valueInRange(range_value, 1));
    try std.testing.expect(supportsAuto(range_value));
    try std.testing.expect(supportsManual(range_value));

    const discrete = directshow.PropertyRange{
        .min = 0,
        .max = 1,
        .step = 1,
        .default = 1,
        .capabilities = 0,
    };
    try std.testing.expect(!supportsAuto(discrete));
    try std.testing.expect(supportsManual(discrete));
}
