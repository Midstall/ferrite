//! Ferrite stand-in for `std.posix.system`.
//!
//! Mirrors the minimum surface the catch-all `else => struct { ... }`
//! arm of `std.posix.system` exposes (pid_t, fd_t, uid_t, gid_t, ...),
//! upgrading `fd_t` to u32 so `std.Io.Dir.Handle` / `std.Io.File.Handle`
//! are slab-index-shaped rather than `void`.
//!
//! Anything in `std.posix` that pulls a more specific field (`system.O`,
//! `system.AT`, `system.AF`, ...) won't compile through this struct.
//! That's intentional for Phase 1: uspace must use the std.Io vtable
//! (which routes through our backend), not raw posix syscalls.

pub const pid_t = u32;
pub const pollfd = void;
pub const fd_t = u32;
pub const uid_t = u32;
pub const gid_t = u32;
pub const mode_t = u32;
pub const nlink_t = u32;
pub const blksize_t = u32;
pub const ino_t = u64;
pub const IFNAMESIZE = {};
pub const SIG = void;
