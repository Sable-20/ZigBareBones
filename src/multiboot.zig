//! Multiboot (v1) boot information parsing.
//!
//! GRUB leaves a pointer to this structure in EBX at kernel entry
//! (and the magic number 0x2BADB002 in EAX). Which fields are valid
//! depends on the `flags` bitfield -- always check the corresponding
//! flag bit before reading a field, since GRUB only fills in what it
//! was able to determine.
//!
//! Reference: https://www.gnu.org/software/grub/manual/multiboot/multiboot.html#Boot-information-format

const console = @import("console.zig");

pub const MULTIBOOT_MAGIC: u32 = 0x2BADB002;

// Flags bitfield -- bit N set means the corresponding field(s) below are valid.
pub const FLAG_MEM: u32 = 1 << 0; // mem_lower / mem_upper valid
pub const FLAG_BOOTDEV: u32 = 1 << 1; // boot_device valid
pub const FLAG_CMDLINE: u32 = 1 << 2; // cmdline valid
pub const FLAG_MODS: u32 = 1 << 3; // mods_count / mods_addr valid
pub const FLAG_AOUT_SYMS: u32 = 1 << 4; // syms as a.out format
pub const FLAG_ELF_SYMS: u32 = 1 << 5; // syms as ELF format
pub const FLAG_MMAP: u32 = 1 << 6; // mmap_length / mmap_addr valid
pub const FLAG_DRIVES: u32 = 1 << 7; // drives_length / drives_addr valid
pub const FLAG_CONFIG_TABLE: u32 = 1 << 8; // config_table valid
pub const FLAG_BOOT_LOADER_NAME: u32 = 1 << 9; // boot_loader_name valid
pub const FLAG_APM_TABLE: u32 = 1 << 10; // apm_table valid
pub const FLAG_VBE: u32 = 1 << 11; // vbe_* fields valid

/// Matches the C `struct multiboot_info` layout field-for-field.
/// Plain scalar fields with natural alignment, so `extern struct`
/// lays this out identically to the C version on i386.
pub const MultibootInfo = extern struct {
    flags: u32,

    mem_lower: u32,
    mem_upper: u32,

    boot_device: u32,

    cmdline: u32,

    mods_count: u32,
    mods_addr: u32,

    // Either a.out symbol table info or ELF section header info,
    // depending on which of FLAG_AOUT_SYMS / FLAG_ELF_SYMS is set.
    syms: [4]u32,

    mmap_length: u32,
    mmap_addr: u32,

    drives_length: u32,
    drives_addr: u32,

    config_table: u32,

    boot_loader_name: u32, // physical address of a null-terminated C string

    apm_table: u32,

    vbe_control_info: u32,
    vbe_mode_info: u32,
    vbe_mode: u16,
    vbe_interface_seg: u16,
    vbe_interface_off: u16,
    vbe_interface_len: u16,
};

/// One entry in the memory map. NOTE: `size` is the size of the rest
/// of this entry (addr + len + type), NOT including the `size` field
/// itself -- that's what makes walking the array a bit unusual (see
/// forEachMmapEntry below).
pub const MmapEntry = packed struct(u192) {
    size: u32,
    addr: u64,
    len: u64,
    region_type: u32,
};

pub const MEMORY_AVAILABLE: u32 = 1;
pub const MEMORY_RESERVED: u32 = 2;
pub const MEMORY_ACPI_RECLAIMABLE: u32 = 3;
pub const MEMORY_NVS: u32 = 4;
pub const MEMORY_BADRAM: u32 = 5;

fn memoryTypeName(t: u32) []const u8 {
    return switch (t) {
        MEMORY_AVAILABLE => "available",
        MEMORY_RESERVED => "reserved",
        MEMORY_ACPI_RECLAIMABLE => "ACPI reclaimable",
        MEMORY_NVS => "ACPI NVS",
        MEMORY_BADRAM => "bad RAM",
        else => "unknown",
    };
}

/// Walks every entry in the memory map, calling `callback` for each.
/// Handles the "size field excludes itself" quirk internally.
pub fn forEachMmapEntry(info: *const MultibootInfo, comptime callback: fn (*const MmapEntry) void) void {
    if (info.flags & FLAG_MMAP == 0) return;

    var addr = info.mmap_addr;
    const end = info.mmap_addr + info.mmap_length;

    while (addr < end) {
        const entry: *const MmapEntry = @ptrFromInt(addr);
        callback(entry);
        // Skip past this entry: the size field doesn't count itself,
        // so the real stride is size + 4 bytes.
        addr += entry.size + 4;
    }
}

fn cStringToSlice(addr: u32) []const u8 {
    if (addr == 0) return "(none)";
    const ptr: [*:0]const u8 = @ptrFromInt(addr);
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn printMmapEntry(entry: *const MmapEntry) void {
    console.printf(
        "  base=0x{x:0>16} len=0x{x:0>16} type={s}\n",
        .{ entry.addr, entry.len, memoryTypeName(entry.region_type) },
    );
}

/// Prints everything useful for a boot-time diagnostic log. Call this
/// early in kmain, right after validating the multiboot magic.
pub fn printBootInfo(info: *const MultibootInfo) void {
    if (info.flags & FLAG_BOOT_LOADER_NAME != 0) {
        console.printf("bootloader: {s}\n", .{cStringToSlice(info.boot_loader_name)});
    }

    if (info.flags & FLAG_MEM != 0) {
        console.printf(
            "mem_lower: {d} KB, mem_upper: {d} KB ({d} MB)\n",
            .{ info.mem_lower, info.mem_upper, info.mem_upper / 1024 },
        );
    }

    if (info.flags & FLAG_CMDLINE != 0) {
        console.printf("cmdline: {s}\n", .{cStringToSlice(info.cmdline)});
    }

    if (info.flags & FLAG_MMAP != 0) {
        console.puts("memory map:\n");
        forEachMmapEntry(info, printMmapEntry);
    } else {
        console.puts("memory map: not provided by bootloader\n");
    }
}
