const std = @import("std");
const cap = @import("cap.zig");
const heap = @import("heap.zig");

pub const Entry = struct {
    /// Owned by the entry; freed at deinit.
    name: []u8,
    /// `cap.NULL_HANDLE` means a directory node with no target.
    target: cap.Handle,
    children: ?*Entry,
    sibling: ?*Entry,
};

pub const Namespace = struct {
    root: ?*Entry,

    pub const Error = error{ NameExists, NotFound, OutOfMemory, BadPath };

    pub fn init() Namespace {
        return .{ .root = null };
    }

    pub fn deinit(self: *Namespace) void {
        if (self.root) |r| destroyTree(r);
        self.root = null;
    }

    /// Latest bind wins. Intermediate directories are created as needed.
    pub fn bind(self: *Namespace, path: []const u8, target: cap.Handle) Error!void {
        if (target == cap.NULL_HANDLE) return error.BadPath;
        if (self.root == null) self.root = try makeEntry("", cap.NULL_HANDLE);

        var node = self.root.?;
        var it = componentIter(path);
        var maybe_comp = it.next();
        while (maybe_comp) |comp| {
            const next_comp = it.next();
            if (next_comp == null) {
                if (findChild(node, comp)) |existing| {
                    existing.target = target;
                } else {
                    const leaf = try makeEntry(comp, target);
                    insertChild(node, leaf);
                }
                return;
            } else {
                node = if (findChild(node, comp)) |child| child else blk: {
                    const dir = try makeEntry(comp, cap.NULL_HANDLE);
                    insertChild(node, dir);
                    break :blk dir;
                };
            }
            maybe_comp = next_comp;
        }
        return error.BadPath;
    }

    /// Only the leaf needs a non-null target.
    pub fn resolve(self: *const Namespace, path: []const u8) Error!cap.Handle {
        const root = self.root orelse return error.NotFound;
        var node = root;
        var it = componentIter(path);
        var last_target: cap.Handle = cap.NULL_HANDLE;
        while (it.next()) |comp| {
            const child = findChild(node, comp) orelse return error.NotFound;
            node = child;
            last_target = child.target;
        }
        if (last_target == cap.NULL_HANDLE) return error.NotFound;
        return last_target;
    }

    /// Caps are copied as raw handle values. Caller mints them in the
    /// child's cap table.
    pub fn clone(self: *const Namespace) Error!Namespace {
        var out: Namespace = .{ .root = null };
        if (self.root) |r| out.root = try cloneSubtree(r);
        return out;
    }
};

fn makeEntry(name: []const u8, target: cap.Handle) Namespace.Error!*Entry {
    const a = heap.allocator();
    const name_copy = a.dupe(u8, name) catch return error.OutOfMemory;
    errdefer a.free(name_copy);
    const e = a.create(Entry) catch return error.OutOfMemory;
    e.* = .{
        .name = name_copy,
        .target = target,
        .children = null,
        .sibling = null,
    };
    return e;
}

fn destroyTree(root: *Entry) void {
    var child = root.children;
    while (child) |c| {
        const next = c.sibling;
        destroyTree(c);
        child = next;
    }
    const a = heap.allocator();
    a.free(root.name);
    a.destroy(root);
}

fn cloneSubtree(src: *const Entry) Namespace.Error!*Entry {
    const dup = try makeEntry(src.name, src.target);
    errdefer destroyTree(dup);
    var child = src.children;
    var tail: ?*Entry = null;
    while (child) |c| : (child = c.sibling) {
        const new_child = try cloneSubtree(c);
        if (tail) |t| t.sibling = new_child else dup.children = new_child;
        tail = new_child;
    }
    return dup;
}

fn findChild(parent: *Entry, name: []const u8) ?*Entry {
    var c = parent.children;
    while (c) |cur| : (c = cur.sibling) {
        if (std.mem.eql(u8, cur.name, name)) return cur;
    }
    return null;
}

fn insertChild(parent: *Entry, child: *Entry) void {
    child.sibling = parent.children;
    parent.children = child;
}

const ComponentIter = struct {
    path: []const u8,
    cur: usize,

    fn next(self: *ComponentIter) ?[]const u8 {
        while (self.cur < self.path.len and self.path[self.cur] == '/') {
            self.cur += 1;
        }
        if (self.cur >= self.path.len) return null;
        const start = self.cur;
        while (self.cur < self.path.len and self.path[self.cur] != '/') {
            self.cur += 1;
        }
        return self.path[start..self.cur];
    }
};

fn componentIter(path: []const u8) ComponentIter {
    return .{ .path = path, .cur = 0 };
}
