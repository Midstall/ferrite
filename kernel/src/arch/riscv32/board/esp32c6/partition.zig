// Ferrite ESP32-C6 flash partition table format. Lives at flash offset
// 0x8000 (one 4 KB sector). Shared by the bootloader (reads it) and
// tools/partitiontable.zig (writes it).

pub const MAGIC: u32 = 0xFE71_50AB;
pub const TABLE_FLASH_OFFSET: u32 = 0x8000;
pub const VERSION: u32 = 1;
pub const MAX_ENTRIES: usize = 16;

pub const Type = enum(u8) {
    unused = 0,
    kernel = 1,
    initrd = 2,
    /// Generic blob - sdcard image, user partition, etc.
    data = 3,
};

pub const Entry = extern struct {
    type_raw: u8,
    subtype: u8,
    _pad: u16 = 0,
    offset: u32,
    size: u32,
    /// NUL-padded.
    label: [16]u8,
    flags: u32 = 0,

    pub fn ofType(self: Entry) Type {
        return @enumFromInt(self.type_raw);
    }
};

pub const Table = extern struct {
    magic: u32,
    version: u32,
    entry_count: u32,
    _reserved: u32 = 0,
    entries: [MAX_ENTRIES]Entry,
};

comptime {
    if (@sizeOf(Entry) != 32) @compileError("Entry must be 32 bytes");
    if (@sizeOf(Table) != 16 + MAX_ENTRIES * 32) @compileError("Table size wrong");
}

pub fn find(table: *const Table, want: Type) ?*const Entry {
    var i: u32 = 0;
    while (i < table.entry_count and i < MAX_ENTRIES) : (i += 1) {
        if (table.entries[i].ofType() == want) return &table.entries[i];
    }
    return null;
}
