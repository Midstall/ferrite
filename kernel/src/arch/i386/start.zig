const std = @import("std");
const kernel = @import("kernel");
const arch = @import("arch");

extern var __bss_start: u8;
extern var __bss_end: u8;
extern const __stack_top: u8;
extern const __kernel_start: u8;
extern const __kernel_end: u8;

// Multiboot1: %eax = 0x2BADB002, %ebx = info pointer on entry.
const MB1_MAGIC: u32 = 0x1BADB002;
const MB1_FLAGS: u32 = 0;
const MB1_CHECKSUM: u32 = 0 -% (MB1_MAGIC +% MB1_FLAGS);

const Mb1Header = extern struct {
    magic: u32,
    flags: u32,
    checksum: u32,
};

export const multiboot1_header: Mb1Header linksection(".multiboot1") = .{
    .magic = MB1_MAGIC,
    .flags = MB1_FLAGS,
    .checksum = MB1_CHECKSUM,
};

// Multiboot2: %eax = 0x36D76289, %ebx = info pointer; 8-byte aligned, null-terminated.
const MB2_MAGIC: u32 = 0xE85250D6;
const MB2_ARCH_I386: u32 = 0;

const Mb2Header = extern struct {
    magic: u32,
    arch: u32,
    length: u32,
    checksum: u32,
    end_type: u16,
    end_flags: u16,
    end_size: u32,
};

const MB2_LEN: u32 = @sizeOf(Mb2Header);
const MB2_CHECKSUM: u32 = 0 -% (MB2_MAGIC +% MB2_ARCH_I386 +% MB2_LEN);

export const multiboot2_header: Mb2Header align(8) linksection(".multiboot2") = .{
    .magic = MB2_MAGIC,
    .arch = MB2_ARCH_I386,
    .length = MB2_LEN,
    .checksum = MB2_CHECKSUM,
    .end_type = 0,
    .end_flags = 0,
    .end_size = 8,
};

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ cli
        \\ movl $__stack_top, %esp
        \\ xorl %ebp, %ebp
        \\ // Push zigStart args before CR0 fiddle clobbers %eax. cdecl: mbi, magic.
        \\ pushl %ebx
        \\ pushl %eax
        \\ // FPU init: clear CR0.EM, set CR0.MP, FNINIT.
        \\ movl %cr0, %eax
        \\ andl $0xfffffffb, %eax
        \\ orl $0x2, %eax
        \\ movl %eax, %cr0
        \\ fninit
        \\ call zigStart
        \\0: hlt
        \\   jmp 0b
    );
}

const MB1_BOOT_MAGIC: u32 = 0x2BADB002;

const Mb1Info = extern struct {
    flags: u32,
    mem_lower: u32,
    mem_upper: u32,
    boot_device: u32,
    cmdline: u32,
    mods_count: u32,
    mods_addr: u32,
    syms: [4]u32,
    mmap_length: u32,
    mmap_addr: u32,
};

const Mb1MmapEntry = extern struct {
    // `size` excludes itself. Next entry sits at &this + size + 4.
    size: u32,
    base_addr: u64 align(4),
    length: u64 align(4),
    type_: u32,
};

const MB1_INFO_MEMMAP: u32 = 1 << 6;
const MB1_INFO_MODS: u32 = 1 << 3;

const Mb1Module = extern struct {
    mod_start: u32,
    mod_end: u32,
    string: u32,
    reserved: u32,
};

fn mb1Kind(type_: u32) kernel.memory.RegionKind {
    return switch (type_) {
        1 => .usable,
        3 => .reclaimable,
        else => .reserved,
    };
}

fn parseMb1Info(mbi_addr: u32) void {
    const info: *const Mb1Info = @ptrFromInt(mbi_addr);
    if ((info.flags & MB1_INFO_MEMMAP) != 0) {
        var addr: u32 = info.mmap_addr;
        const end: u32 = info.mmap_addr + info.mmap_length;
        while (addr < end) {
            const ent: *const Mb1MmapEntry = @ptrFromInt(addr);
            kernel.memory.register(ent.base_addr, ent.length, mb1Kind(ent.type_));
            addr += ent.size + 4;
        }
    }

    // First multiboot module becomes the initrd.
    if ((info.flags & MB1_INFO_MODS) != 0 and info.mods_count > 0) {
        const mod: *const Mb1Module = @ptrFromInt(info.mods_addr);
        const lo: usize = @intCast(mod.mod_start);
        const hi: usize = @intCast(mod.mod_end);
        const ptr: [*]const u8 = @ptrFromInt(lo);
        kernel.initrd.init(ptr[0 .. hi - lo]) catch {};
        kernel.memory.register(mod.mod_start, hi - lo, .reserved);
    }
}

const MB2_BOOT_MAGIC: u32 = 0x36D76289;

const Mb2Info = extern struct {
    total_size: u32,
    reserved: u32,
};

const Mb2Tag = extern struct {
    type_: u32,
    size: u32,
};

const Mb2TagMemmap = extern struct {
    type_: u32,
    size: u32,
    entry_size: u32,
    entry_version: u32,
};

const Mb2MmapEntry = extern struct {
    base_addr: u64,
    length: u64,
    type_: u32,
    reserved: u32,
};

const MB2_TAG_END: u32 = 0;
const MB2_TAG_MODULE: u32 = 3;
const MB2_TAG_MMAP: u32 = 6;

const Mb2TagModule = extern struct {
    type_: u32,
    size: u32,
    mod_start: u32,
    mod_end: u32,
};

fn parseMb2Info(mbi_addr: u32) void {
    const info: *const Mb2Info = @ptrFromInt(mbi_addr);
    var off: u32 = @sizeOf(Mb2Info);
    var initrd_done = false;
    while (off < info.total_size) {
        const tag: *const Mb2Tag = @ptrFromInt(mbi_addr + off);
        if (tag.type_ == MB2_TAG_END) return;
        switch (tag.type_) {
            MB2_TAG_MMAP => {
                const mmap: *const Mb2TagMemmap = @ptrFromInt(mbi_addr + off);
                var ent_off: u32 = @sizeOf(Mb2TagMemmap);
                while (ent_off < mmap.size) : (ent_off += mmap.entry_size) {
                    const ent: *const Mb2MmapEntry = @ptrFromInt(mbi_addr + off + ent_off);
                    kernel.memory.register(ent.base_addr, ent.length, mb1Kind(ent.type_));
                }
            },
            MB2_TAG_MODULE => if (!initrd_done) {
                const mod: *const Mb2TagModule = @ptrFromInt(mbi_addr + off);
                const lo: usize = @intCast(mod.mod_start);
                const hi: usize = @intCast(mod.mod_end);
                const ptr: [*]const u8 = @ptrFromInt(lo);
                kernel.initrd.init(ptr[0 .. hi - lo]) catch {};
                kernel.memory.register(mod.mod_start, hi - lo, .reserved);
                initrd_done = true;
            },
            else => {},
        }
        // Tags are 8-byte aligned.
        off += (tag.size + 7) & ~@as(u32, 7);
    }
}

export fn zigStart(magic: u32, mbi_addr: u32) callconv(.c) noreturn {
    const bss_start: [*]u8 = @ptrCast(&__bss_start);
    const bss_end: [*]u8 = @ptrCast(&__bss_end);
    const len = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    @memset(bss_start[0..len], 0);

    if (mbi_addr != 0) switch (magic) {
        MB1_BOOT_MAGIC => parseMb1Info(mbi_addr),
        MB2_BOOT_MAGIC => parseMb2Info(mbi_addr),
        else => {},
    };
    // Multiboot memmaps cover the kernel image as usable. Reserve it.
    const k_start = @intFromPtr(&__kernel_start);
    const k_end = @intFromPtr(&__kernel_end);
    kernel.memory.register(k_start, k_end - k_start, .reserved);
    // Protected mode without paging: PA == VA.
    kernel.memory.init(0);

    arch.mmu.init(.{
        .alloc_page = &kernel.memory.allocPage,
        .free_page = &kernel.memory.freePage,
    });
    arch.mmu.enable();

    kernel.kmain();
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    arch.uart.write("\n[PANIC] ");
    arch.uart.write(msg);
    if (ra) |r| {
        arch.uart.print(" @ {x}", .{r});
    }
    arch.uart.write("\n");
    while (true) asm volatile ("hlt");
}
