const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const ns = ferrite.nameserver;

const ETC_MOUNTS = "etc/mounts";

fn seedMounts(mounts: *ns.MountTable) void {
    var buf: [1024]u8 = undefined;
    const n = ferrite.readInitrdFile(ETC_MOUNTS, &buf);
    if (n == 0) {
        ferrite.console.print("[nameserver] {s} missing. No mounts\n", .{ETC_MOUNTS}) catch {};
        return;
    }
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |raw_line| {
        const line = stripComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
        const prefix = tok.next() orelse continue;
        const authority = tok.next() orelse continue;
        mounts.add(prefix, authority) catch |e| {
            ferrite.console.print("[nameserver] /etc/mounts: {s} -> {s} failed: {t}\n", .{ prefix, authority, e }) catch {};
        };
    }
}

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |i| return line[0..i];
    return line;
}

pub fn main() void {
    const recv_h = ferrite.nsLookup("nameserver-recv");
    if (recv_h < 0) {
        ferrite.console.print("[nameserver] no `nameserver-recv` in namespace: {d}\n", .{recv_h}) catch {};
        return;
    }
    const req_chan: u32 = @intCast(recv_h);

    var registry: ns.Registry = .{};
    var mounts: ns.MountTable = .{};
    seedMounts(&mounts);

    var req_buf: [p9.MAX_MSG]u8 = undefined;
    var resp_buf: [p9.MAX_MSG]u8 = undefined;

    while (true) {
        var in_cap: u32 = 0;
        const n = ferrite.recv(req_chan, &req_buf, &in_cap);
        if (n < 0) {
            ferrite.console.print("[nameserver] recv error: {d}\n", .{n}) catch {};
            return;
        }
        const decoded = p9.decodeRequest(req_buf[0..@intCast(n)]) catch {
            ferrite.console.print("[nameserver] decode failed, dropping\n", .{}) catch {};
            continue;
        };

        switch (decoded.req) {
            .register => |m| {
                registry.register(m.prefix, in_cap) catch |e| {
                    ferrite.console.print("[nameserver] register {s} failed: {t}\n", .{ m.prefix, e }) catch {};
                    continue;
                };
            },
            .lookup => |m| {
                const reply_chan = in_cap;
                if (reply_chan == 0) {
                    ferrite.console.print("[nameserver] lookup {s} dropped: no reply cap\n", .{m.prefix}) catch {};
                    continue;
                }
                if (registry.lookup(m.prefix)) |svc| {
                    // SYS_SEND transfers and revokes from the sender, so dup to retain our copy.
                    const dup = ferrite.capDup(svc);
                    if (dup < 0) {
                        const elen = p9.encodeErrReply(&resp_buf, decoded.hdr.tag, .server_busy) catch continue;
                        _ = ferrite.send(reply_chan, resp_buf[0..elen], 0);
                        _ = ferrite.capRelease(reply_chan);
                        continue;
                    }
                    const rlen = p9.encodeLookupReply(&resp_buf, decoded.hdr.tag) catch continue;
                    _ = ferrite.send(reply_chan, resp_buf[0..rlen], @intCast(dup));
                } else |_| {
                    const elen = p9.encodeErrReply(&resp_buf, decoded.hdr.tag, .not_found) catch continue;
                    _ = ferrite.send(reply_chan, resp_buf[0..elen], 0);
                }
                _ = ferrite.capRelease(reply_chan);
            },
            .resolve_mount => |m| {
                const reply_chan = in_cap;
                if (reply_chan == 0) {
                    ferrite.console.print("[nameserver] resolve_mount {s} dropped: no reply cap\n", .{m.path}) catch {};
                    continue;
                }
                if (mounts.resolve(m.path)) |hit| {
                    const authority = hit.entry.authority_buf[0..hit.entry.authority_len];
                    const rlen = p9.encodeResolveMountReply(&resp_buf, decoded.hdr.tag, authority, hit.sub) catch continue;
                    _ = ferrite.send(reply_chan, resp_buf[0..rlen], 0);
                } else {
                    const elen = p9.encodeErrReply(&resp_buf, decoded.hdr.tag, .not_found) catch continue;
                    _ = ferrite.send(reply_chan, resp_buf[0..elen], 0);
                }
                _ = ferrite.capRelease(reply_chan);
            },
            .list_mounts => |m| {
                const reply_chan = in_cap;
                if (reply_chan == 0) continue;
                var names: [512]u8 = undefined;
                const names_len = mounts.childrenOf(m.path, &names);
                const rlen = p9.encodeListMountsReply(&resp_buf, decoded.hdr.tag, names[0..names_len]) catch continue;
                _ = ferrite.send(reply_chan, resp_buf[0..rlen], 0);
                _ = ferrite.capRelease(reply_chan);
            },
            .dump_mounts => {
                const reply_chan = in_cap;
                if (reply_chan == 0) continue;
                var table: [1024]u8 = undefined;
                const table_len = mounts.dumpInto(&table);
                const rlen = p9.encodeDumpMountsReply(&resp_buf, decoded.hdr.tag, table[0..table_len]) catch continue;
                _ = ferrite.send(reply_chan, resp_buf[0..rlen], 0);
                _ = ferrite.capRelease(reply_chan);
            },
            .add_mount => |m| {
                const reply_chan = in_cap;
                if (reply_chan == 0) continue;
                const errno: ?p9.Errno = if (mounts.add(m.prefix, m.authority))
                    null
                else |e| switch (e) {
                    error.TableFull, error.NameTooLong => p9.Errno.server_busy,
                    error.AlreadyRegistered => p9.Errno.permission,
                    else => p9.Errno.bad_op,
                };
                if (errno) |code| {
                    const elen = p9.encodeErrReply(&resp_buf, decoded.hdr.tag, code) catch continue;
                    _ = ferrite.send(reply_chan, resp_buf[0..elen], 0);
                } else {
                    const rlen = p9.encodeAddMountReply(&resp_buf, decoded.hdr.tag) catch continue;
                    _ = ferrite.send(reply_chan, resp_buf[0..rlen], 0);
                }
                _ = ferrite.capRelease(reply_chan);
            },
            else => {
                ferrite.console.print("[nameserver] unsupported op\n", .{}) catch {};
            },
        }
    }
}
