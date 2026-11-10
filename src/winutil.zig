const std = @import("std");

const HANDLE = *anyopaque;
const TOKEN_QUERY: u32 = 0x0008;
const token_elevation_class: u32 = 20;

extern "kernel32" fn GetCurrentProcess() HANDLE;
extern "kernel32" fn CloseHandle(handle: HANDLE) i32;
extern "advapi32" fn OpenProcessToken(
    process_handle: HANDLE,
    desired_access: u32,
    token_handle: *?HANDLE,
) i32;
extern "advapi32" fn GetTokenInformation(
    token_handle: HANDLE,
    token_information_class: u32,
    token_information: *anyopaque,
    token_information_length: u32,
    return_length: *u32,
) i32;

const TokenElevation = extern struct {
    token_is_elevated: u32,
};

/// True when the current process runs with an Administrator token.
pub fn isElevated() bool {
    var token: ?HANDLE = null;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) == 0) return false;
    defer _ = CloseHandle(token.?);

    var elevation: TokenElevation = .{ .token_is_elevated = 0 };
    var return_length: u32 = 0;
    if (GetTokenInformation(
        token.?,
        token_elevation_class,
        &elevation,
        @sizeOf(TokenElevation),
        &return_length,
    ) == 0) return false;
    return elevation.token_is_elevated != 0;
}

/// Prints the standard elevation requirement message for an elevated command.
pub fn printRequiresElevation(command: []const u8) void {
    std.debug.print(
        "\n`{s}` requires an elevated (Administrator) Windows process.\n" ++
            "Open an elevated PowerShell and run it again. Do not bypass UAC.\n",
        .{command},
    );
}
