// SBI ecall wrappers. a7=ext, a6=fid, a0..a5=args, return (err, value) in (a0, a1).

const EXT_TIME: u64 = 0x54494D45;
const EXT_DBCN: u64 = 0x4442434E;
const EXT_HSM: u64 = 0x48534D00;
const EXT_LEGACY_PUTCHAR: u64 = 0x01;

pub const SbiRet = extern struct {
    err: i64,
    value: i64,
};

inline fn ecall(ext: u64, fid: u64, a0: u64, a1: u64, a2: u64) SbiRet {
    var err: i64 = undefined;
    var val: i64 = undefined;
    asm volatile ("ecall"
        : [err] "={a0}" (err),
          [val] "={a1}" (val),
        : [a0_in] "{a0}" (a0),
          [a1_in] "{a1}" (a1),
          [a2_in] "{a2}" (a2),
          [a6_in] "{a6}" (fid),
          [a7_in] "{a7}" (ext),
        : .{ .a3 = true, .a4 = true, .a5 = true, .memory = true });
    return .{ .err = err, .value = val };
}

pub fn setTimer(stime_value: u64) void {
    _ = ecall(EXT_TIME, 0, stime_value, 0, 0);
}

/// Debug fallback before MMIO mappings exist.
pub fn legacyPutchar(c: u8) void {
    _ = ecall(EXT_LEGACY_PUTCHAR, 0, c, 0, 0);
}
