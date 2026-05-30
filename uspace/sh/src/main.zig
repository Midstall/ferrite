const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;

const LINE_MAX = 1024;
const MAX_CMDS = 8; // pipeline stages
const MAX_ARGS = 32; // argv per command
const TOK_BUF = 2048; // backing store for token text

var tty: ferrite.fs.File = undefined;
var have_tty: bool = false;
var ttyctl: ferrite.fs.File = undefined;
var have_ttyctl: bool = false;
var cwd_buf: [256]u8 = undefined;
var cwd_len: usize = 1; // "/"

fn cwd() []const u8 {
    return cwd_buf[0..cwd_len];
}

// Tell the tty driver our cwd so its tab-completion can resolve relative paths.
fn sendCwd() void {
    if (!have_ttyctl) return;
    var b: [300]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, "cwd {s}", .{cwd()}) catch return;
    _ = ttyctl.writeAll(msg) catch {};
}

// Shell's own diagnostics/prompt output: the tty when interactive, else stdout
// (so `sh -c` and piped shells still print).
fn shellWrite(s: []const u8) void {
    if (have_tty) {
        _ = tty.writeAll(s) catch {};
    } else {
        ferrite.writeStdout(s);
    }
}

pub fn main() void {
    var tty_path: []const u8 = "/dev/tty0";
    var cmd_line: ?[]const u8 = null;
    var script_path: ?[]const u8 = null;
    var cmd_buf: [LINE_MAX]u8 = undefined;
    var argi: usize = 1;
    while (argi < ferrite.argv.len) : (argi += 1) {
        const arg = std.mem.span(ferrite.argv[argi]);
        if (std.mem.startsWith(u8, arg, "--tty=")) {
            tty_path = arg["--tty=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // First non-flag arg is a script path. Remaining args would be
            // positional params ($1...), which aren't supported yet.
            script_path = arg;
            break;
        } else if (std.mem.eql(u8, arg, "-c")) {
            // Join the remaining args into one command line (argv is already
            // space-split, so this reconstitutes `sh -c a | b c`).
            var w: usize = 0;
            var k = argi + 1;
            while (k < ferrite.argv.len) : (k += 1) {
                const a = std.mem.span(ferrite.argv[k]);
                if (w > 0 and w < cmd_buf.len) {
                    cmd_buf[w] = ' ';
                    w += 1;
                }
                const take = @min(a.len, cmd_buf.len - w);
                @memcpy(cmd_buf[w..][0..take], a[0..take]);
                w += take;
            }
            cmd_line = cmd_buf[0..w];
            break;
        }
    }
    cwd_buf[0] = '/';
    cwd_len = 1;

    // `sh -c "..."`: run one line and exit (no tty).
    if (cmd_line) |cl| {
        _ = runLine(cl);
        return;
    }

    // `sh script.sh`: run a script file line by line and exit (no tty).
    if (script_path) |sp| {
        runScript(sp);
        return;
    }

    var uri_buf: [128]u8 = undefined;
    const tty_uri = ferrite.fs.resolvePath(tty_path, &uri_buf) catch return;
    tty = ferrite.fs.open(tty_uri, .{ .mode = .rdwr }) catch return;
    have_tty = true;
    defer tty.close();

    // For the console tty, open the driver's ctl fid so we can feed it cwd hints
    // for relative-path tab-completion. (ssh sessions use a different tty.)
    if (std.mem.eql(u8, tty_path, "/dev/tty0")) {
        if (ferrite.fs.open("com.midstall.ferrite.devfs@v0:/tty0/ctl", .{ .mode = .write })) |c| {
            ttyctl = c;
            have_ttyctl = true;
            sendCwd();
        } else |_| {}
    }

    _ = tty.writeAll("ferrite sh. type `help`\n") catch {};

    var line_buf: [LINE_MAX]u8 = undefined;
    while (true) {
        reapJobs(); // print "[n] Done" notices for finished background jobs
        _ = tty.writeAll(cwd()) catch {};
        _ = tty.writeAll(" $ ") catch {};
        const line = readLine(&line_buf);
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (runLine(trimmed)) return; // `exit`
    }
}

fn readLine(buf: []u8) []const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        var one: [1]u8 = undefined;
        const got = tty.read(0, &one) catch return buf[0..0];
        if (got == 0) continue;
        if (one[0] == '\n' or one[0] == '\r') return buf[0..n];
        buf[n] = one[0];
        n += 1;
    }
    return buf[0..0];
}

// Read a script file fully and run it line by line. Blank lines, comments, and
// the shebang are all dropped by the tokenizer (`#` starts a comment), so each
// non-empty line just feeds runLine. `exit` stops the script.
fn runScript(path: []const u8) void {
    var uri_buf: [320]u8 = undefined;
    const uri = ferrite.fs.resolvePath(path, &uri_buf) catch {
        shellWrite("sh: cannot open script\n");
        return;
    };
    var f = ferrite.fs.open(uri, .{ .mode = .read }) catch {
        shellWrite("sh: cannot open script\n");
        return;
    };
    defer f.close();
    var buf: [16384]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = f.read(got, buf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    var it = std.mem.splitScalar(u8, buf[0..got], '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (runLine(line)) return; // `exit`
    }
}

// Tokenizer: splits a line into words + operators, honoring '...' / "..."
// quoting. Operators: | < > >> ; && || &

const TokKind = enum { word, pipe, lt, gt, gtgt, semi, andand, oror, amp };
const Token = struct { kind: TokKind, text: []const u8 = "" };

var tok_buf: [TOK_BUF]u8 = undefined;
var tok_used: usize = 0;

fn stash(s: []const u8) ?[]const u8 {
    if (tok_used + s.len > tok_buf.len) return null;
    const dst = tok_buf[tok_used..][0..s.len];
    @memcpy(dst, s);
    tok_used += s.len;
    return dst;
}

const MAX_TOKS = 128;
var toks: [MAX_TOKS]Token = undefined;

fn tokenize(line: []const u8) ?[]Token {
    tok_used = 0;
    var nt: usize = 0;
    var i: usize = 0;
    var word: [LINE_MAX]u8 = undefined;
    while (i < line.len) {
        const c = line[i];
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        // Comment: '#' at a word boundary ignores the rest of the line. This
        // covers script shebangs (`#!/bin/sh`) and inline/full-line comments.
        if (c == '#') break;
        // Operators.
        const op: ?Token = switch (c) {
            '|' => if (i + 1 < line.len and line[i + 1] == '|') Token{ .kind = .oror } else Token{ .kind = .pipe },
            '&' => if (i + 1 < line.len and line[i + 1] == '&') Token{ .kind = .andand } else Token{ .kind = .amp },
            '>' => if (i + 1 < line.len and line[i + 1] == '>') Token{ .kind = .gtgt } else Token{ .kind = .gt },
            '<' => Token{ .kind = .lt },
            ';' => Token{ .kind = .semi },
            else => null,
        };
        if (op) |o| {
            if (nt >= MAX_TOKS) return null;
            toks[nt] = o;
            nt += 1;
            i += switch (o.kind) {
                .oror, .andand, .gtgt => 2,
                else => 1,
            };
            continue;
        }
        // A word, possibly with quoted spans.
        var wl: usize = 0;
        while (i < line.len) {
            const ch = line[i];
            if (ch == ' ' or ch == '\t' or ch == '|' or ch == '<' or ch == '>' or ch == ';' or ch == '&') break;
            if (ch == '\'' or ch == '"') {
                const q = ch;
                i += 1;
                while (i < line.len and line[i] != q) : (i += 1) {
                    if (wl < word.len) {
                        word[wl] = line[i];
                        wl += 1;
                    }
                }
                if (i < line.len) i += 1; // closing quote
                continue;
            }
            if (wl < word.len) {
                word[wl] = ch;
                wl += 1;
            }
            i += 1;
        }
        if (nt >= MAX_TOKS) return null;
        toks[nt] = .{ .kind = .word, .text = stash(word[0..wl]) orelse return null };
        nt += 1;
    }
    return toks[0..nt];
}

// Pipeline model.

const Command = struct {
    argv: [MAX_ARGS][]const u8 = undefined,
    argc: usize = 0,
    in_file: ?[]const u8 = null,
    out_file: ?[]const u8 = null,
    append: bool = false,
};

const Pipeline = struct {
    cmds: [MAX_CMDS]Command = undefined,
    ncmds: usize = 0,
    background: bool = false,
};

// Run a whole line: pipelines separated by ; && || (left to right, honoring
// exit codes). Returns true if `exit` was run.
fn runLine(line: []const u8) bool {
    const tl = tokenize(line) orelse {
        shellWrite("sh: line too complex\n");
        return false;
    };
    var i: usize = 0;
    var last_code: i32 = 0;
    var sep: TokKind = .semi; // how to combine with the previous pipeline
    while (i < tl.len) {
        // Collect one pipeline up to the next ; && || (or end).
        const start = i;
        while (i < tl.len and tl[i].kind != .semi and tl[i].kind != .andand and tl[i].kind != .oror) : (i += 1) {}
        const seg = tl[start..i];
        const next_sep: TokKind = if (i < tl.len) tl[i].kind else .semi;
        if (i < tl.len) i += 1; // consume the separator

        const run_it = switch (sep) {
            .andand => last_code == 0,
            .oror => last_code != 0,
            else => true,
        };
        if (run_it and seg.len > 0) {
            if (parsePipeline(seg)) |pl| {
                if (pl.ncmds == 0) {
                    last_code = 0; // assignment-only segment: no command to run
                } else if (pl.ncmds == 1 and isBuiltin(pl.cmds[0].argv[0..pl.cmds[0].argc])) {
                    var ec: i32 = 0;
                    if (runBuiltin(pl.cmds[0].argv[0..pl.cmds[0].argc], &ec)) return true; // exit
                    last_code = ec;
                } else {
                    last_code = runPipeline(&pl);
                }
            } else {
                shellWrite("sh: parse error\n");
                last_code = 2;
            }
            g_last_code = last_code; // for $?
        }
        sep = next_sep;
    }
    return false;
}

// Shell variables + $VAR expansion + glob (*/?). Variables are shell-local
// (children don't inherit yet); `$VAR` is expanded by the shell before spawn,
// which covers the common case. `$?` is the last command's exit status.

const MAX_VARS = 48;
var var_names: [MAX_VARS][]const u8 = undefined;
var var_vals: [MAX_VARS][]const u8 = undefined;
var nvars: usize = 0;
var var_buf: [4096]u8 = undefined;
var var_used: usize = 0;
var g_last_code: i32 = 0;

// Per-pipeline scratch for expanded/globbed argv words (reset each parse).
var exp_buf: [4096]u8 = undefined;
var exp_used: usize = 0;

fn varStash(s: []const u8) ?[]const u8 {
    if (var_used + s.len > var_buf.len) return null;
    const dst = var_buf[var_used..][0..s.len];
    @memcpy(dst, s);
    var_used += s.len;
    return dst;
}

fn getVar(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < nvars) : (i += 1) {
        if (std.mem.eql(u8, var_names[i], name)) return var_vals[i];
    }
    return null;
}

fn setVar(name: []const u8, val: []const u8) void {
    const nm = varStash(name) orelse return;
    const vl = varStash(val) orelse return;
    var i: usize = 0;
    while (i < nvars) : (i += 1) {
        if (std.mem.eql(u8, var_names[i], name)) {
            var_vals[i] = vl; // old storage leaks in var_buf; fine per session
            return;
        }
    }
    if (nvars >= MAX_VARS) return;
    var_names[nvars] = nm;
    var_vals[nvars] = vl;
    nvars += 1;
}

inline fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

// `NAME=...` with a valid leading identifier.
fn isAssignment(w: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, w, '=') orelse return false;
    if (eq == 0) return false;
    if (w[0] >= '0' and w[0] <= '9') return false;
    for (w[0..eq]) |c| if (!isNameChar(c)) return false;
    return true;
}

fn applyAssignment(w: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, w, '=').?;
    var vbuf: [1024]u8 = undefined;
    const val = expandInto(w[eq + 1 ..], &vbuf) orelse return;
    setVar(w[0..eq], val);
}

// Expand $VAR / ${VAR} / $? from `in` into `out`, returning the slice.
fn expandInto(in: []const u8, out: []u8) ?[]const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < in.len) {
        if (in[i] == '$' and i + 1 < in.len) {
            i += 1;
            var name: []const u8 = "";
            if (in[i] == '?') {
                var nb: [12]u8 = undefined;
                const s = std.fmt.bufPrint(&nb, "{d}", .{g_last_code}) catch "";
                if (w + s.len > out.len) return null;
                @memcpy(out[w..][0..s.len], s);
                w += s.len;
                i += 1;
                continue;
            } else if (in[i] == '{') {
                i += 1;
                const start = i;
                while (i < in.len and in[i] != '}') i += 1;
                name = in[start..i];
                if (i < in.len) i += 1; // closing }
            } else {
                const start = i;
                while (i < in.len and isNameChar(in[i])) i += 1;
                name = in[start..i];
            }
            if (getVar(name)) |val| {
                if (w + val.len > out.len) return null;
                @memcpy(out[w..][0..val.len], val);
                w += val.len;
            } // unset -> empty
            continue;
        }
        if (w >= out.len) return null;
        out[w] = in[i];
        w += 1;
        i += 1;
    }
    return out[0..w];
}

// Expand a word's $vars into exp_buf, returning a persistent slice.
fn expandWord(in: []const u8) ?[]const u8 {
    if (exp_used >= exp_buf.len) return null;
    const r = expandInto(in, exp_buf[exp_used..]) orelse return null;
    exp_used += r.len;
    return r;
}

// Glob match: `*` (any run), `?` (one char). Anchored full-string match.
fn wildMatch(pat: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star: ?usize = null;
    var star_ni: usize = 0;
    while (ni < name.len) {
        if (pi < pat.len and (pat[pi] == '?' or pat[pi] == name[ni])) {
            pi += 1;
            ni += 1;
        } else if (pi < pat.len and pat[pi] == '*') {
            star = pi;
            star_ni = ni;
            pi += 1;
        } else if (star) |sp| {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
        } else return false;
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

// Add `word` to cur.argv, expanding a trailing-component glob against the
// filesystem. Hidden files (leading '.') are skipped unless the pattern starts
// with '.'. On no match (or no wildcard) the literal word is kept.
fn addWordGlobbed(cur: *Command, word: []const u8) bool {
    const has_glob = std.mem.indexOfScalar(u8, word, '*') != null or std.mem.indexOfScalar(u8, word, '?') != null;
    if (!has_glob) return addArg(cur, word);

    const slash = std.mem.lastIndexOfScalar(u8, word, '/');
    const dir = if (slash) |s| word[0 .. s + 1] else ""; // "/etc/" or "" (incl trailing slash, for the full path)
    const pat = if (slash) |s| word[s + 1 ..] else word; // "r*"
    // resolvePath wants no trailing slash; "/" stays "/".
    const dir_path = if (slash) |s| (if (s == 0) word[0..1] else word[0..s]) else cwd();

    var uri_buf: [320]u8 = undefined;
    const uri = ferrite.fs.resolvePath(dir_path, &uri_buf) catch return addArg(cur, word);
    const d = ferrite.fs.open(uri, .{ .mode = .read }) catch return addArg(cur, word);
    defer d.close();

    var names: [8192]u8 = undefined;
    var got: usize = 0;
    while (got < names.len) {
        const n = d.read(got, names[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    var matched = false;
    var it = std.mem.tokenizeScalar(u8, names[0..got], '\n');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        if (name[0] == '.' and pat[0] != '.') continue;
        if (!wildMatch(pat, name)) continue;
        var full: [320]u8 = undefined;
        const fp = if (dir.len == 0) name else std.fmt.bufPrint(&full, "{s}{s}", .{ dir, name }) catch continue;
        const stored = expandWord(fp) orelse return false; // park in exp_buf
        if (!addArg(cur, stored)) return false;
        matched = true;
    }
    if (!matched) return addArg(cur, word); // nullglob off: keep literal
    return true;
}

fn addArg(cur: *Command, w: []const u8) bool {
    if (cur.argc >= MAX_ARGS) return false;
    cur.argv[cur.argc] = w;
    cur.argc += 1;
    return true;
}

fn parsePipeline(seg: []const Token) ?Pipeline {
    exp_used = 0; // fresh expansion scratch for this pipeline
    var pl: Pipeline = .{};
    var cur: Command = .{};
    var j: usize = 0;
    while (j < seg.len) : (j += 1) {
        const t = seg[j];
        switch (t.kind) {
            .word => {
                if (cur.argc == 0 and isAssignment(t.text)) {
                    applyAssignment(t.text);
                    continue;
                }
                const ex = expandWord(t.text) orelse return null;
                if (!addWordGlobbed(&cur, ex)) return null;
            },
            .lt, .gt, .gtgt => {
                if (j + 1 >= seg.len or seg[j + 1].kind != .word) return null;
                j += 1;
                switch (t.kind) {
                    .lt => cur.in_file = seg[j].text,
                    .gt => {
                        cur.out_file = seg[j].text;
                        cur.append = false;
                    },
                    .gtgt => {
                        cur.out_file = seg[j].text;
                        cur.append = true;
                    },
                    else => unreachable,
                }
            },
            .amp => pl.background = true,
            .pipe => {
                if (cur.argc == 0 or pl.ncmds >= MAX_CMDS) return null;
                pl.cmds[pl.ncmds] = cur;
                pl.ncmds += 1;
                cur = .{};
            },
            else => return null,
        }
    }
    if (cur.argc == 0) {
        // ncmds==0 here means the segment was assignment-only (vars already
        // set) or empty -> return an empty pipeline that runLine no-ops.
        if (pl.ncmds == 0) return pl;
        return null; // trailing pipe (e.g. "a |")
    }
    if (pl.ncmds >= MAX_CMDS) return null;
    pl.cmds[pl.ncmds] = cur;
    pl.ncmds += 1;
    return pl;
}

// Builtins (run in the shell; standalone only).

fn isBuiltin(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const c = argv[0];
    return std.mem.eql(u8, c, "exit") or std.mem.eql(u8, c, "cd") or
        std.mem.eql(u8, c, "pwd") or std.mem.eql(u8, c, "help") or
        std.mem.eql(u8, c, "clear") or std.mem.eql(u8, c, "export") or
        std.mem.eql(u8, c, "jobs") or std.mem.eql(u8, c, "fg") or
        std.mem.eql(u8, c, "bg");
}

// Parse a job spec: "%n" or "n" -> job id; empty/null -> the highest-id job.
fn findJob(argv: []const []const u8) ?*Job {
    if (argv.len > 1) {
        var s = argv[1];
        if (s.len > 0 and s[0] == '%') s = s[1..];
        const want = std.fmt.parseUnsigned(u32, s, 10) catch 0;
        for (&jobs) |*j| {
            if (j.used and j.id == want) return j;
        }
        return null;
    }
    var best: ?*Job = null;
    for (&jobs) |*j| {
        if (j.used and (best == null or j.id > best.?.id)) best = j;
    }
    return best;
}

// Returns true if the shell should exit. Sets `code`.
fn runBuiltin(argv: []const []const u8, code: *i32) bool {
    const c = argv[0];
    code.* = 0;
    if (std.mem.eql(u8, c, "exit")) return true;
    if (std.mem.eql(u8, c, "help")) {
        shellWrite(
            \\built-ins: cd, pwd, exit, help, clear, export, jobs, fg, bg
            \\pipes (a | b), redirection (< > >>), and ; && || are supported.
            \\$VAR / ${VAR} / $? expansion, NAME=val, and * ? globbing too.
            \\cmd & runs in the background; jobs lists them, fg %n foregrounds.
            \\anything else runs as bin/<name> (initrd) or an absolute path.
            \\run scripts with `sh file.sh` or `./file.sh` (#! shebang).
            \\
        );
        return false;
    }
    if (std.mem.eql(u8, c, "clear")) {
        shellWrite("\x1b[2J\x1b[H");
        return false;
    }
    if (std.mem.eql(u8, c, "pwd")) {
        shellWrite(cwd());
        shellWrite("\n");
        return false;
    }
    if (std.mem.eql(u8, c, "cd")) {
        const target = if (argv.len > 1) argv[1] else "/";
        if (chdir(target)) {
            sendCwd();
        } else |_| {
            shellWrite("cd: ");
            shellWrite(target);
            shellWrite(": no such directory\n");
            code.* = 1;
        }
        return false;
    }
    if (std.mem.eql(u8, c, "export")) {
        // Args already $-expanded; "NAME=value" sets a shell var. (Children
        // don't inherit env yet, so this is effectively a var assignment.)
        var k: usize = 1;
        while (k < argv.len) : (k += 1) {
            if (std.mem.indexOfScalar(u8, argv[k], '=')) |eq| {
                if (eq > 0) setVar(argv[k][0..eq], argv[k][eq + 1 ..]);
            }
        }
        return false;
    }
    if (std.mem.eql(u8, c, "jobs")) {
        reapJobs(); // print Done notices + drop finished jobs first
        for (&jobs) |*j| {
            if (!j.used) continue;
            var b: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "[{d}] Running   {s}\n", .{ j.id, j.cmd[0..j.cmd_len] }) catch "";
            shellWrite(m);
        }
        return false;
    }
    if (std.mem.eql(u8, c, "fg")) {
        const j = findJob(argv) orelse {
            shellWrite("fg: no such job\n");
            code.* = 1;
            return false;
        };
        shellWrite(j.cmd[0..j.cmd_len]);
        shellWrite("\n");
        _ = ferrite.ttyFgSet(j.pgid); // give it the terminal
        var rc: i32 = 0;
        var k: usize = 0;
        while (k < j.nhandles) : (k += 1) {
            if (j.handles[k] < 0) continue;
            const r = ferrite.wait(@intCast(j.handles[k]));
            if (k == j.nhandles - 1) rc = if (r < 0) 1 else @intCast(r);
        }
        _ = ferrite.ttyFgSet(0);
        j.used = false;
        code.* = rc;
        g_last_code = rc;
        return false;
    }
    if (std.mem.eql(u8, c, "bg")) {
        // bg resumes a STOPPED job in the background. Stopping needs Ctrl-Z /
        // SIGTSTP + a kernel "stopped" thread state, not yet implemented, so a
        // running &-job is already in the background and there's nothing to do.
        shellWrite("bg: suspend/resume (Ctrl-Z) not supported yet\n");
        return false;
    }
    return false;
}

fn chdir(target: []const u8) !void {
    var newp: [256]u8 = undefined;
    const np = resolvePathInto(target, &newp) orelse return error.TooLong;
    // Verify it exists + is a directory by opening it.
    var uri_buf: [320]u8 = undefined;
    const uri = ferrite.fs.resolvePath(np, &uri_buf) catch return error.NotFound;
    const d = ferrite.fs.open(uri, .{ .mode = .read }) catch return error.NotFound;
    d.close();
    if (np.len > cwd_buf.len) return error.TooLong;
    @memcpy(cwd_buf[0..np.len], np);
    cwd_len = np.len;
}

// Resolve `path` against cwd into `out`, normalizing . and .. Returns the slice.
fn resolvePathInto(path: []const u8, out: []u8) ?[]const u8 {
    var len: usize = 0;
    if (path.len == 0 or path[0] != '/') {
        // relative: start from cwd
        if (cwd().len > out.len) return null;
        @memcpy(out[0..cwd().len], cwd());
        len = cwd().len;
    } else {
        out[0] = '/';
        len = 1;
    }
    var it = std.mem.tokenizeAny(u8, path, "/");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            // pop a component
            while (len > 1 and out[len - 1] != '/') len -= 1;
            if (len > 1) len -= 1; // drop trailing slash
            if (len == 0) {
                out[0] = '/';
                len = 1;
            }
            continue;
        }
        if (len == 0 or out[len - 1] != '/') {
            if (len >= out.len) return null;
            out[len] = '/';
            len += 1;
        }
        if (len + comp.len > out.len) return null;
        @memcpy(out[len..][0..comp.len], comp);
        len += comp.len;
    }
    if (len == 0) {
        out[0] = '/';
        len = 1;
    }
    return out[0..len];
}

// Execution.

// Spawn one command with explicit stdio caps (0 = console). Returns the child
// process handle, or -1.
fn spawnCmd(cmd: *const Command, stdin_cap: u32, stdout_cap: u32) i64 {
    var args_buf: [1024]u8 = undefined;
    var args_len: usize = 0;
    // argv[1..] packed NUL-separated.
    var k: usize = 1;
    while (k < cmd.argc) : (k += 1) {
        const a = cmd.argv[k];
        if (args_len + a.len + 1 > args_buf.len) return -1;
        @memcpy(args_buf[args_len..][0..a.len], a);
        args_len += a.len;
        args_buf[args_len] = 0;
        args_len += 1;
    }
    const stdio: [3]u32 = .{ stdin_cap, stdout_cap, 0 };
    const argv0 = cmd.argv[0];

    if (argv0.len > 0 and (argv0[0] == '/' or std.mem.startsWith(u8, argv0, "./") or std.mem.startsWith(u8, argv0, "../"))) {
        // Path command: resolve against cwd, read into a buffer, exec.
        var pbuf: [256]u8 = undefined;
        const p = resolvePathInto(argv0, &pbuf) orelse return -1;
        return spawnPathStdio(p, args_buf[0..args_len], &stdio);
    }
    // bin/<name> from the initrd.
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "bin/{s}", .{argv0}) catch return -1;
    return ferrite.spawnArgsStdio(path, args_buf[0..args_len], &stdio);
}

// Read a file fully into a freshly-allocated page region and SYS_EXEC it with
// stdio. Mirrors fs.spawnPath but threads stdio caps through.
fn spawnPathStdio(path: []const u8, args: []const u8, stdio: *const [3]u32) i64 {
    var uri_buf: [320]u8 = undefined;
    const uri = ferrite.fs.resolvePath(path, &uri_buf) catch return -1;
    var f = ferrite.fs.open(uri, .{ .mode = .read }) catch return -1;
    defer f.close();
    const st = f.status() catch return -1;
    const size: usize = @intCast(st.size);
    if (size == 0) return -1;
    const npages = (size + ferrite.pageSize() - 1) / ferrite.pageSize();
    var base: usize = 0;
    if (ferrite.allocPages(npages, &base) != 0) return -1;
    const buf: [*]u8 = @ptrFromInt(base);
    var got: usize = 0;
    while (got < size) {
        const n = f.read(got, buf[got..size]) catch break;
        if (n == 0) break;
        got += n;
    }
    // Shebang: a `#!` text script is run by the shell, not exec'd as a Mach-O.
    // We re-spawn `bin/sh <path>` (the interpreter line itself is ignored; sh is
    // always the interpreter). The script's own args aren't forwarded since sh
    // has no positional params yet.
    if (got >= 2 and buf[0] == '#' and buf[1] == '!') {
        _ = ferrite.freePages(base);
        var sargs: [320]u8 = undefined;
        if (path.len + 1 > sargs.len) return -1;
        @memcpy(sargs[0..path.len], path);
        sargs[path.len] = 0;
        return ferrite.spawnArgsStdio("bin/sh", sargs[0 .. path.len + 1], stdio);
    }
    const r = ferrite.execStdio(buf[0..got], args, stdio);
    _ = ferrite.freePages(base);
    return r;
}

// Open a file for an output/input redirect, returning an fs.File. For output we
// create/truncate (or append). Returns null on failure.
fn openRedirOut(path: []const u8, append: bool) ?ferrite.fs.File {
    var pbuf: [256]u8 = undefined;
    const p = resolvePathInto(path, &pbuf) orelse return null;
    var uri_buf: [320]u8 = undefined;
    // Ensure the file exists (create), then open for writing.
    const uri = ferrite.fs.resolvePath(p, &uri_buf) catch return null;
    if (!append) ferrite.fs.create(p, .file) catch {}; // best-effort truncate-create
    const f = ferrite.fs.open(uri, .{ .mode = .write }) catch {
        ferrite.fs.create(p, .file) catch return null;
        return ferrite.fs.open(uri, .{ .mode = .write }) catch null;
    };
    return f;
}

fn openRedirIn(path: []const u8) ?ferrite.fs.File {
    var pbuf: [256]u8 = undefined;
    const p = resolvePathInto(path, &pbuf) orelse return null;
    var uri_buf: [320]u8 = undefined;
    const uri = ferrite.fs.resolvePath(p, &uri_buf) catch return null;
    return ferrite.fs.open(uri, .{ .mode = .read }) catch null;
}

// Job control. Background pipelines (`cmd &`) are recorded here instead of
// waited on; `jobs` lists them (reaping finished ones), `fg` foregrounds one.
// Suspend/resume (Ctrl-Z / bg) needs a kernel "stopped" state + SIGTSTP/SIGCONT
// and is a follow-up; `bg` reports that for now.

const MAX_JOBS = 16;
const Job = struct {
    used: bool = false,
    id: u32 = 0,
    pgid: u32 = 0,
    handles: [MAX_CMDS]i64 = .{-1} ** MAX_CMDS,
    nhandles: usize = 0,
    cmd: [96]u8 = undefined,
    cmd_len: usize = 0,
};
var jobs: [MAX_JOBS]Job = .{Job{}} ** MAX_JOBS;
var next_job_id: u32 = 1;

fn jobCmdString(pl: *const Pipeline, out: []u8) usize {
    var w: usize = 0;
    var s: usize = 0;
    while (s < pl.ncmds) : (s += 1) {
        if (s > 0) {
            for (" | ") |ch| {
                if (w < out.len) {
                    out[w] = ch;
                    w += 1;
                }
            }
        }
        var a: usize = 0;
        while (a < pl.cmds[s].argc) : (a += 1) {
            if (a > 0 and w < out.len) {
                out[w] = ' ';
                w += 1;
            }
            for (pl.cmds[s].argv[a]) |ch| {
                if (w < out.len) {
                    out[w] = ch;
                    w += 1;
                }
            }
        }
    }
    return w;
}

fn addJob(pl: *const Pipeline, hs: []const i64, pgid: u32) ?u32 {
    var idx: ?usize = null;
    for (&jobs, 0..) |*j, i| {
        if (!j.used) {
            idx = i;
            break;
        }
    }
    const slot = idx orelse return null;
    var j = &jobs[slot];
    j.* = .{ .used = true, .id = next_job_id, .pgid = pgid };
    next_job_id += 1;
    var k: usize = 0;
    while (k < hs.len and k < MAX_CMDS) : (k += 1) j.handles[k] = hs[k];
    j.nhandles = @min(hs.len, MAX_CMDS);
    j.cmd_len = jobCmdString(pl, &j.cmd);
    return j.id;
}

// All of a job's stages have exited?
fn jobDone(j: *const Job) bool {
    var k: usize = 0;
    while (k < j.nhandles) : (k += 1) {
        if (j.handles[k] >= 0 and ferrite.tryWait(@intCast(j.handles[k])) == 0) return false;
    }
    return true;
}

// Reap any finished background jobs, printing a "Done" notice. Called at the prompt.
fn reapJobs() void {
    for (&jobs) |*j| {
        if (!j.used) continue;
        if (!jobDone(j)) continue;
        var k: usize = 0;
        while (k < j.nhandles) : (k += 1) {
            if (j.handles[k] >= 0) _ = ferrite.wait(@intCast(j.handles[k]));
        }
        var b: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&b, "[{d}] Done   {s}\n", .{ j.id, j.cmd[0..j.cmd_len] }) catch "";
        shellWrite(m);
        j.used = false;
    }
}

// Run a pipeline of N commands wired by pipes, with optional input redirect on
// the first command and output redirect on the last. Returns the last stage's
// exit code.
fn runPipeline(pl: *const Pipeline) i32 {
    const n = pl.ncmds;
    var handles: [MAX_CMDS]i64 = .{-1} ** MAX_CMDS;

    // Inter-stage pipes: pipe[i] connects cmd[i].stdout -> cmd[i+1].stdin.
    var pipes: [MAX_CMDS - 1]ferrite.Pipe = undefined;
    var p: usize = 0;
    while (p + 1 < n) : (p += 1) {
        pipes[p] = ferrite.pipe(4) orelse {
            shellWrite("sh: out of pipes\n");
            return 1;
        };
    }

    // Redirect pumping channels (shell <-> first/last stage).
    const first = &pl.cmds[0];
    const last = &pl.cmds[n - 1];
    var feed: ?ferrite.Pipe = null; // shell writes file -> first stdin
    var drain: ?ferrite.Pipe = null; // last stdout -> shell writes file
    var in_file: ?ferrite.fs.File = null;
    var out_file: ?ferrite.fs.File = null;

    if (first.in_file) |fp| {
        in_file = openRedirIn(fp) orelse {
            shellWrite("sh: cannot open input\n");
            return 1;
        };
        feed = ferrite.pipe(4);
    }
    if (last.out_file) |fp| {
        out_file = openRedirOut(fp, last.append) orelse {
            shellWrite("sh: cannot open output\n");
            if (in_file) |f| f.close();
            return 1;
        };
        drain = ferrite.pipe(4);
    }

    // Spawn every stage.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var sin: u32 = 0;
        var sout: u32 = 0;
        if (i == 0) {
            if (feed) |fp| sin = fp.read;
        } else sin = pipes[i - 1].read;
        if (i == n - 1) {
            if (drain) |dp| sout = dp.write;
        } else sout = pipes[i].write;
        handles[i] = spawnCmd(&pl.cmds[i], sin, sout);
        if (handles[i] < 0) {
            shellWrite(pl.cmds[i].argv[0]);
            shellWrite(": command not found\n");
        }
    }

    // Put the whole pipeline in one process group (leader = first stage's pid)
    // and make it the tty's foreground group, so Ctrl-C delivers SIGINT to every
    // stage, not just the last. Foreground group is restored to 0 after the wait.
    var leader_pid: u32 = 0;
    i = 0;
    while (i < n) : (i += 1) {
        if (handles[i] < 0) continue;
        const pid_r = ferrite.handlePid(@intCast(handles[i]));
        if (pid_r <= 0) continue;
        const pid: u32 = @intCast(pid_r);
        if (leader_pid == 0) leader_pid = pid;
        _ = ferrite.setpgid(pid, leader_pid);
    }
    if (leader_pid != 0 and !pl.background) _ = ferrite.ttyFgSet(leader_pid);

    // Drop the shell's copies of the inter-stage pipe caps so EOF propagates
    // once the writing stage exits (the child holds its own minted copy).
    p = 0;
    while (p + 1 < n) : (p += 1) {
        _ = ferrite.capRelease(pipes[p].read);
        _ = ferrite.capRelease(pipes[p].write);
    }
    if (feed) |fp| _ = ferrite.capRelease(fp.read); // child holds its copy
    if (drain) |dp| _ = ferrite.capRelease(dp.write);

    // Background (`cmd &`): record a job and return immediately instead of
    // waiting. (Shell-side redirect pumping would block the prompt, so it's not
    // supported for background pipelines; release those caps and move on.)
    if (pl.background) {
        if (feed) |fp| _ = ferrite.capRelease(fp.write);
        if (drain) |dp| _ = ferrite.capRelease(dp.read);
        if (addJob(pl, handles[0..n], leader_pid)) |jid| {
            var b: [32]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "[{d}] {d}\n", .{ jid, leader_pid }) catch "";
            shellWrite(m);
        } else shellWrite("sh: too many jobs\n");
        return 0;
    }

    // Pump redirects. Feed first (so a buffering filter gets all input), then
    // drain. Streaming filters with BOTH redirects can stall; that's a known
    // single-threaded-shell limitation.
    if (feed) |fp| {
        pumpFileToChannel(&in_file.?, fp.write);
        _ = ferrite.capRelease(fp.write); // EOF to the first stage
        in_file.?.close();
    }
    if (drain) |dp| {
        pumpChannelToFile(dp.read, &out_file.?);
        _ = ferrite.capRelease(dp.read);
        out_file.?.close();
    }

    // Wait for all stages; the pipeline's status is the last stage's. A stage
    // that never spawned (command not found) yields 127, like a POSIX shell, so
    // `||` / `&&` react to typos.
    var code: i32 = 0;
    i = 0;
    while (i < n) : (i += 1) {
        if (i == n - 1) {
            if (handles[i] >= 0) {
                const r = ferrite.wait(@intCast(handles[i]));
                code = if (r < 0) 1 else @intCast(r);
            } else code = 127;
        } else if (handles[i] >= 0) {
            _ = ferrite.wait(@intCast(handles[i]));
        }
    }
    // Clear the foreground group: at the prompt the shell isn't foreground, so
    // Ctrl-C cancels the input line (tty driver) rather than killing the shell
    // (we have no catchable SIGINT yet).
    if (leader_pid != 0 and !pl.background) _ = ferrite.ttyFgSet(0);
    return code;
}

fn pumpFileToChannel(f: *ferrite.fs.File, write_cap: u32) void {
    var buf: [ferrite.STDIO_CHUNK]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = f.read(off, &buf) catch break;
        if (n == 0) break;
        if (ferrite.send(write_cap, buf[0..n], 0) != 0) break; // reader gone
        off += n;
    }
}

fn pumpChannelToFile(read_cap: u32, f: *ferrite.fs.File) void {
    var buf: [ferrite.STDIO_CHUNK]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = ferrite.recv(read_cap, &buf, null);
        if (n <= 0) break; // EOF / closed
        // Track offset: writeAll() always starts at 0, so consecutive chunks
        // would otherwise overwrite each other at the file head.
        var w: usize = 0;
        const got: usize = @intCast(n);
        while (w < got) {
            const m = f.write(off, buf[w..got]) catch break;
            if (m == 0) break;
            w += m;
            off += m;
        }
    }
}
