const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const URI_PREFIX = "com.midstall.ferrite.tty@v0";
const DEV_NAME = "tty0";

const MAX_FIDS = 16;
const LINE_MAX = 256;
const QUEUE_SIZE = 1024;
const HISTORY_SIZE = 16;

const FidKind = enum { data, ctl };

const Fid = struct {
    used: bool = false,
    opened: bool = false,
    kind: FidKind = .data,
};

const EscState = enum { none, esc, csi };

const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
    edit_buf: [LINE_MAX]u8 = undefined,
    edit_len: usize = 0,
    cursor: usize = 0,
    history: [HISTORY_SIZE][LINE_MAX]u8 = @splat(@splat(0)),
    history_lens: [HISTORY_SIZE]usize = @splat(0),
    history_count: usize = 0,
    history_head: usize = 0,
    history_pos: ?usize = null,
    esc: EscState = .none,
    queue: [QUEUE_SIZE]u8 = undefined,
    qhead: usize = 0,
    qtail: usize = 0,
    qcount: usize = 0,
    echo: bool = true,
    // cwd hint from the shell (via `ctl` "cwd <path>"), used for relative-path
    // tab-completion. Defaults to "/".
    cwd_buf: [LINE_MAX]u8 = undefined,
    cwd_len: usize = 0,
};

var state: State = .{};

pub fn main() void {
    _ = ferrite.ttyRaw(true);

    state.cwd_buf[0] = '/';
    state.cwd_len = 1;
    state.fids[0] = .{ .used = true, .opened = true };

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.registerDevice(DEV_NAME, .char, svc_send) catch |e| {
        ferrite.console.print("[drv.tty] registerDevice failed: {t}\n", .{e}) catch {};
        return;
    };

    const handlers: fs.Handlers(State) = .{
        .on_walk = onWalk,
        .on_open = onOpen,
        .on_read = onRead,
        .on_write = onWrite,
        .on_close = onClose,
        .on_status = onStatus,
    };
    fs.serve(State, svc_recv, &state, &handlers);
}

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    var kind: FidKind = .data;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    if (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "ctl")) {
            kind = .ctl;
        } else return error.NotFound;
        if (it.next() != null) return error.NotFound;
    }
    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) {
            s.fids[i] = .{ .used = true, .opened = false, .kind = kind };
            return .{ .bound = i };
        }
    }
    return error.ServerBusy;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
}

fn onRead(s: *State, fid: u32, _: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    while (s.qcount == 0) {
        var raw_buf: [64]u8 = undefined;
        const n = ferrite.readConsole(&raw_buf);
        if (n <= 0) return error.BadOp;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) : (i += 1) cookByte(s, raw_buf[i]);
    }
    var n: usize = 0;
    while (n < out.len and s.qcount > 0) : (n += 1) {
        out[n] = s.queue[s.qhead];
        s.qhead = (s.qhead + 1) % s.queue.len;
        s.qcount -= 1;
    }
    return n;
}

fn onWrite(s: *State, fid: u32, _: u64, data: []const u8) fs.HandlerError!u32 {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    switch (s.fids[fid].kind) {
        .data => {
            _ = ferrite.console.writeAll(data) catch return error.BadOp;
            return @intCast(data.len);
        },
        .ctl => {
            const cmd = std.mem.trim(u8, data, " \t\r\n");
            if (std.mem.eql(u8, cmd, "echo off")) {
                s.echo = false;
            } else if (std.mem.eql(u8, cmd, "echo on")) {
                s.echo = true;
            } else if (std.mem.startsWith(u8, cmd, "cwd ")) {
                const p = cmd[4..];
                if (p.len > 0 and p.len <= s.cwd_buf.len) {
                    @memcpy(s.cwd_buf[0..p.len], p);
                    s.cwd_len = p.len;
                }
            }
            return @intCast(data.len);
        },
    }
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    return .{ .kind = .file, .size = 0 };
}

fn cookByte(s: *State, byte: u8) void {
    switch (s.esc) {
        .none => {},
        .esc => {
            if (byte == '[') {
                s.esc = .csi;
            } else {
                s.esc = .none;
            }
            return;
        },
        .csi => {
            switch (byte) {
                'A' => historyPrev(s),
                'B' => historyNext(s),
                'C' => cursorRight(s),
                'D' => cursorLeft(s),
                else => {},
            }
            s.esc = .none;
            return;
        },
    }

    switch (byte) {
        0x03 => {
            _ = ferrite.ttyKillFg();
            s.edit_len = 0;
            s.cursor = 0;
            s.history_pos = null;
            echoStr("^C\r\n");
        },
        '\r', '\n' => {
            echoStr("\r\n");
            commitEditLine(s);
        },
        0x7f, 0x08 => backspace(s),
        0x09 => tabComplete(s),
        0x1b => {
            s.esc = .esc;
        },
        else => insertChar(s, byte),
    }
}

fn insertChar(s: *State, byte: u8) void {
    if (byte < 0x20 or byte == 0x7f) return;
    if (s.edit_len >= s.edit_buf.len) return;
    var i: usize = s.edit_len;
    while (i > s.cursor) : (i -= 1) s.edit_buf[i] = s.edit_buf[i - 1];
    s.edit_buf[s.cursor] = byte;
    s.edit_len += 1;
    s.cursor += 1;
    s.history_pos = null;
    if (s.echo) redrawTail(s, s.cursor - 1);
}

fn backspace(s: *State) void {
    if (s.cursor == 0) return;
    s.cursor -= 1;
    var i: usize = s.cursor;
    while (i + 1 < s.edit_len) : (i += 1) s.edit_buf[i] = s.edit_buf[i + 1];
    s.edit_len -= 1;
    s.history_pos = null;
    if (s.echo) {
        echoStr("\x08");
        redrawTail(s, s.cursor);
    }
}

fn cursorLeft(s: *State) void {
    if (s.cursor == 0) return;
    s.cursor -= 1;
    echoStr("\x1b[D");
}

fn cursorRight(s: *State) void {
    if (s.cursor >= s.edit_len) return;
    s.cursor += 1;
    echoStr("\x1b[C");
}

fn redrawTail(s: *State, from: usize) void {
    if (from < s.edit_len) {
        echoStr(s.edit_buf[from..s.edit_len]);
    }
    echoStr(" \x1b[K");
    const back = (s.edit_len - s.cursor) + 1;
    moveCursorLeft(back);
}

fn moveCursorLeft(n: usize) void {
    // Hand-rolled itoa: std.fmt.bufPrint("{d}") overflows under ubsan.
    if (n == 0) return;
    var digits: [10]u8 = undefined;
    var i: usize = digits.len;
    var v = n;
    while (v > 0) {
        i -= 1;
        digits[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    echoStr("\x1b[");
    echoStr(digits[i..]);
    echoStr("D");
}

fn commitEditLine(s: *State) void {
    var i: usize = 0;
    while (i < s.edit_len and s.qcount < s.queue.len) : (i += 1) {
        s.queue[s.qtail] = s.edit_buf[i];
        s.qtail = (s.qtail + 1) % s.queue.len;
        s.qcount += 1;
    }
    if (s.qcount < s.queue.len) {
        s.queue[s.qtail] = '\n';
        s.qtail = (s.qtail + 1) % s.queue.len;
        s.qcount += 1;
    }
    if (s.edit_len != 0) historyPush(s, s.edit_buf[0..s.edit_len]);
    s.edit_len = 0;
    s.cursor = 0;
    s.history_pos = null;
}

fn historyPush(s: *State, line: []const u8) void {
    if (s.history_count > 0) {
        const last_idx = (s.history_head + HISTORY_SIZE - 1) % HISTORY_SIZE;
        const last_len = s.history_lens[last_idx];
        if (last_len == line.len and std.mem.eql(u8, s.history[last_idx][0..last_len], line)) {
            return;
        }
    }
    @memcpy(s.history[s.history_head][0..line.len], line);
    s.history_lens[s.history_head] = line.len;
    s.history_head = (s.history_head + 1) % HISTORY_SIZE;
    if (s.history_count < HISTORY_SIZE) s.history_count += 1;
}

fn historyPrev(s: *State) void {
    if (s.history_count == 0) return;
    const new_offset: usize = if (s.history_pos) |off|
        @min(off + 1, s.history_count - 1)
    else
        0;
    showHistoryEntry(s, new_offset);
}

fn historyNext(s: *State) void {
    const cur = s.history_pos orelse return;
    if (cur == 0) {
        clearLineAndShow(s, "");
        s.history_pos = null;
        return;
    }
    showHistoryEntry(s, cur - 1);
}

fn showHistoryEntry(s: *State, offset: usize) void {
    s.history_pos = offset;
    const idx = (s.history_head + HISTORY_SIZE - 1 - offset) % HISTORY_SIZE;
    const len = s.history_lens[idx];
    clearLineAndShow(s, s.history[idx][0..len]);
}

fn clearLineAndShow(s: *State, new: []const u8) void {
    moveCursorLeft(s.cursor);
    echoStr("\x1b[K");
    if (new.len > s.edit_buf.len) return;
    @memcpy(s.edit_buf[0..new.len], new);
    s.edit_len = new.len;
    s.cursor = new.len;
    echoStr(new);
}

// Tab completion. Completes the word under the cursor: command names (first
// word) from /bin + builtins, or filesystem paths for arguments. A single match
// completes fully (with a trailing '/' for dirs, ' ' for files); multiple
// matches complete to their longest common prefix. cwd (for relative paths)
// comes from the shell's "cwd" ctl hint.

const Match = struct {
    count: usize = 0,
    lcp: [LINE_MAX]u8 = undefined,
    lcp_len: usize = 0,
};

fn consider(m: *Match, name: []const u8, prefix: []const u8) void {
    if (name.len < prefix.len) return;
    if (!std.mem.eql(u8, name[0..prefix.len], prefix)) return;
    if (m.count == 0) {
        const n = @min(name.len, m.lcp.len);
        @memcpy(m.lcp[0..n], name[0..n]);
        m.lcp_len = n;
    } else {
        const lim = @min(m.lcp_len, name.len);
        var i: usize = 0;
        while (i < lim and m.lcp[i] == name[i]) i += 1;
        m.lcp_len = i;
    }
    m.count += 1;
}

// List a directory by URI path and feed each entry name to `consider`.
fn listDir(dir_path: []const u8, prefix: []const u8, m: *Match) void {
    var uri_buf: [320]u8 = undefined;
    const uri = fs.resolvePath(dir_path, &uri_buf) catch return;
    const d = fs.open(uri, .{ .mode = .read }) catch return;
    defer d.close();
    var names: [4096]u8 = undefined;
    var got: usize = 0;
    while (got < names.len) {
        const n = d.read(got, names[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    var it = std.mem.tokenizeScalar(u8, names[0..got], '\n');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        if (name[0] == '.' and (prefix.len == 0 or prefix[0] != '.')) continue;
        consider(m, name, prefix);
    }
}

// Is `dir_path`/`name` a directory? Best-effort; false on any error.
fn pathIsDir(dir_path: []const u8, name: []const u8) bool {
    var full: [320]u8 = undefined;
    const fp = if (std.mem.eql(u8, dir_path, "/"))
        std.fmt.bufPrint(&full, "/{s}", .{name}) catch return false
    else
        std.fmt.bufPrint(&full, "{s}/{s}", .{ dir_path, name }) catch return false;
    var uri_buf: [320]u8 = undefined;
    const uri = fs.resolvePath(fp, &uri_buf) catch return false;
    const f = fs.open(uri, .{ .mode = .read }) catch return false;
    defer f.close();
    const st = f.status() catch return false;
    return st.kind == .dir;
}

fn tabComplete(s: *State) void {
    // The word under the cursor: back up to the previous whitespace/operator.
    var ws: usize = s.cursor;
    while (ws > 0) {
        const c = s.edit_buf[ws - 1];
        if (c == ' ' or c == '\t' or c == '|' or c == ';' or c == '&' or c == '<' or c == '>') break;
        ws -= 1;
    }
    const word = s.edit_buf[ws..s.cursor];

    // Command position = nothing but whitespace before the word, or an operator.
    var is_cmd = true;
    var k: usize = ws;
    while (k > 0) {
        k -= 1;
        const c = s.edit_buf[k];
        if (c == ' ' or c == '\t') continue;
        is_cmd = (c == '|' or c == ';' or c == '&');
        break;
    }
    const has_slash = std.mem.indexOfScalar(u8, word, '/') != null;

    var m: Match = .{};
    var dir_path: ?[]const u8 = null; // set for path completion (to stat dirs)
    var prefix: []const u8 = word;
    var dir_buf: [LINE_MAX]u8 = undefined;

    if (is_cmd and !has_slash) {
        const builtins = [_][]const u8{ "cd", "pwd", "exit", "help", "clear", "export" };
        for (builtins) |bi| consider(&m, bi, word);
        listDir("/bin", word, &m);
    } else {
        const slash = std.mem.lastIndexOfScalar(u8, word, '/');
        prefix = if (slash) |sp| word[sp + 1 ..] else word;
        dir_path = completeDir(s, word, slash, &dir_buf) orelse return;
        listDir(dir_path.?, prefix, &m);
    }

    if (m.count == 0) {
        echoStr("\x07"); // bell
        return;
    }
    // Insert the chars beyond what's already typed.
    if (m.lcp_len > prefix.len) {
        var i: usize = prefix.len;
        while (i < m.lcp_len) : (i += 1) insertChar(s, m.lcp[i]);
    } else if (m.count > 1) {
        echoStr("\x07"); // ambiguous, nothing to add
        return;
    }
    if (m.count == 1) {
        const is_dir = if (dir_path) |dp| pathIsDir(dp, m.lcp[0..m.lcp_len]) else false;
        insertChar(s, if (is_dir) '/' else ' ');
    }
}

// Resolve the directory to list for path completion. `slash` is the index of the
// last '/' in `word` (or null). Returns a slice into `buf` (or cwd/"/").
fn completeDir(s: *State, word: []const u8, slash: ?usize, buf: []u8) ?[]const u8 {
    const sp = slash orelse return s.cwd_buf[0..s.cwd_len]; // no slash: list cwd
    if (word.len > 0 and word[0] == '/') {
        // absolute: "/x" -> "/", "/a/b" -> "/a"
        return if (sp == 0) "/" else word[0..sp];
    }
    // relative: cwd + "/" + word[0..sp]
    const cwd = s.cwd_buf[0..s.cwd_len];
    const rel = word[0..sp];
    const r = if (std.mem.eql(u8, cwd, "/"))
        std.fmt.bufPrint(buf, "/{s}", .{rel}) catch return null
    else
        std.fmt.bufPrint(buf, "{s}/{s}", .{ cwd, rel }) catch return null;
    return r;
}

fn echoStr(s: []const u8) void {
    _ = ferrite.console.writeAll(s) catch {};
}
