// Per-arch boot stubs declare request vars in .limine_requests; shared types
// and response walks live here.

const std = @import("std");
const initrd = @import("initrd.zig");
const cmdline = @import("cmdline.zig");

pub const LimineFile = extern struct {
    revision: u64,
    address: [*]const u8,
    size: u64,
    path: [*:0]const u8,
    cmdline: [*:0]const u8,
    media_type: u32,
    unused: u32,
    tftp_ip: u32,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: [16]u8,
    gpt_part_uuid: [16]u8,
    part_uuid: [16]u8,
};

pub const ModuleResponse = extern struct {
    revision: u64,
    module_count: u64,
    modules: [*]const *const LimineFile,
};

pub const ModuleRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*const ModuleResponse,
};

pub const MODULE_REQUEST_UUID: [2]u64 = .{ 0x3e7e279702be32af, 0xca1c4f3bd1280cee };

pub const ExecutableFileResponse = extern struct {
    revision: u64,
    executable_file: *const LimineFile,
};

pub const ExecutableFileRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*const ExecutableFileResponse,
};

pub const EXECUTABLE_FILE_REQUEST_UUID: [2]u64 = .{ 0xad97e90e83f1ed67, 0x31eb5d1c5ff23b69 };

pub const RsdpResponse = extern struct {
    revision: u64,
    address: u64,
};

pub const RsdpRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*const RsdpResponse,
};

pub const RSDP_REQUEST_UUID: [2]u64 = .{ 0xc5e77b6b397e7b43, 0x27637845accdcf3c };

pub fn registerCmdline(resp: *const ExecutableFileResponse) void {
    const s = std.mem.span(resp.executable_file.cmdline);
    cmdline.init(s);
}

pub const Region = struct { phys: u64, len: u64 };
var registered_initrd: ?Region = null;

pub fn initrdRegion() ?Region {
    return registered_initrd;
}

/// Prefers a module named "initrd" / "initrd.cpio"; falls back to the first
/// module that starts with the cpio newc magic.
pub fn findAndRegisterInitrd(resp: *const ModuleResponse) void {
    var named_initrd: ?[]const u8 = null;
    var first_cpio: ?[]const u8 = null;

    var i: usize = 0;
    while (i < resp.module_count) : (i += 1) {
        const f = resp.modules[i].*;
        const bytes = f.address[0..@intCast(f.size)];
        const path = std.mem.span(f.path);
        const base = std.fs.path.basenamePosix(path);

        if (std.mem.eql(u8, base, "initrd") or std.mem.eql(u8, base, "initrd.cpio")) {
            named_initrd = bytes;
            break;
        }
        if (first_cpio == null and looksLikeCpio(bytes)) first_cpio = bytes;
    }

    const chosen = named_initrd orelse first_cpio orelse return;
    initrd.init(chosen) catch {};
    registered_initrd = .{ .phys = @intFromPtr(chosen.ptr), .len = chosen.len };
}

fn looksLikeCpio(bytes: []const u8) bool {
    return bytes.len >= 6 and std.mem.eql(u8, bytes[0..6], "070701");
}
