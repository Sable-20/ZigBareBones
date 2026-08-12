//! Global Descriptor Table implementation.
//!
//! We build a minimal flat GDT: base = 0, limit = 4 GiB for both
//! code and data, so segmentation is effectively a no-op and we
//! rely entirely on paging for memory protection later on.
//!
//! Layout (standard convention, matches what most tutorials/OSes use):
//!   0x00  Null descriptor      (required by the CPU)
//!   0x08  Kernel code segment  (ring 0)
//!   0x10  Kernel data segment  (ring 0)
//!   0x18  User code segment    (ring 3) -- for later, when you add user mode
//!   0x20  User data segment    (ring 3) -- for later
//!
//! The selector values above (0x08, 0x10, ...) are just the byte
//! offset of each entry into the table -- that's what you load into
//! CS/DS/etc.

const std = @import("std");

/// A single 8-byte GDT entry, laid out exactly as the CPU expects it.
/// Zig 0.16 requires an explicit backing integer on exported/precisely-
/// sized packed structs, so we pin this to u64.
const GdtEntry = packed struct(u64) {
    limit_low: u16,
    base_low: u16,
    base_middle: u8,
    access: u8,
    // granularity is actually two nibbles: flags (4 bits) + limit_high (4 bits)
    granularity: u8,
    base_high: u8,
};

/// The pointer structure loaded by `lgdt`: a 16-bit limit (size of the
/// table minus 1) followed by a 32-bit base address. Must be exactly
/// 6 bytes with no padding, hence packed struct(u48).
const GdtPtr = packed struct(u48) {
    limit: u16,
    base: u32,
};

// --- Access byte flags ---
// Bit layout: P DPL(2) S Type(4)
const ACCESS_PRESENT: u8 = 0x80; // Present bit, must be 1 for valid selectors
const ACCESS_RING0: u8 = 0x00; // DPL = 0 (kernel)
const ACCESS_RING3: u8 = 0x60; // DPL = 3 (user)
const ACCESS_DESCRIPTOR: u8 = 0x10; // S bit: 1 = code/data segment (not a system segment)
const ACCESS_EXEC: u8 = 0x08; // Executable (code segment)
const ACCESS_RW: u8 = 0x02; // Readable (code) / Writable (data)

// --- Granularity byte flags (high nibble) ---
const GRAN_4K: u8 = 0x80; // Limit is scaled by 4 KiB
const GRAN_32BIT: u8 = 0x40; // 32-bit protected mode segment

var gdt_entries: [5]GdtEntry = undefined;
var gdt_ptr: GdtPtr = undefined;

/// Build one descriptor from human-readable base/limit/access/granularity.
fn setEntry(index: usize, base: u32, limit: u32, access: u8, gran_flags: u8) void {
    const limit_high: u8 = @truncate((limit >> 16) & 0x0F);

    gdt_entries[index] = GdtEntry{
        .limit_low = @truncate(limit & 0xFFFF),
        .base_low = @truncate(base & 0xFFFF),
        .base_middle = @truncate((base >> 16) & 0xFF),
        .access = access,
        .granularity = (gran_flags & 0xF0) | limit_high,
        .base_high = @truncate((base >> 24) & 0xFF),
    };
}

/// Load the GDTR and reload every segment register so the CPU
/// actually starts using the new table. Written as one inline asm
/// block because the far jump has to immediately follow `lgdt` in the
/// instruction stream conceptually (the CPU only re-fetches CS via
/// the far jump; the other segment regs are just plain `mov`s).
fn flush(ptr: *const GdtPtr) void {
    asm volatile (
        \\ lgdt (%[p])
        \\ mov $0x10, %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%fs
        \\ mov %%ax, %%gs
        \\ mov %%ax, %%ss
        \\ ljmp $0x08, $1f
        \\ 1:
        :
        : [p] "r" (ptr),
        : .{ .ax = true, .memory = true });
}

/// Public entry point: call this once, early in kmain, before you
/// touch anything else.
pub fn init() void {
    // Null descriptor -- required, index 0 is always all zeros.
    setEntry(0, 0, 0, 0, 0);

    // Kernel code: base 0, limit 4GiB, present + ring0 + code + readable
    setEntry(
        1,
        0,
        0xFFFFF,
        ACCESS_PRESENT | ACCESS_RING0 | ACCESS_DESCRIPTOR | ACCESS_EXEC | ACCESS_RW,
        GRAN_4K | GRAN_32BIT,
    );

    // Kernel data: base 0, limit 4GiB, present + ring0 + data + writable
    setEntry(
        2,
        0,
        0xFFFFF,
        ACCESS_PRESENT | ACCESS_RING0 | ACCESS_DESCRIPTOR | ACCESS_RW,
        GRAN_4K | GRAN_32BIT,
    );

    // User code (ring 3) -- unused until you implement user mode, but
    // wiring it up now saves you a headache later.
    setEntry(
        3,
        0,
        0xFFFFF,
        ACCESS_PRESENT | ACCESS_RING3 | ACCESS_DESCRIPTOR | ACCESS_EXEC | ACCESS_RW,
        GRAN_4K | GRAN_32BIT,
    );

    // User data (ring 3)
    setEntry(
        4,
        0,
        0xFFFFF,
        ACCESS_PRESENT | ACCESS_RING3 | ACCESS_DESCRIPTOR | ACCESS_RW,
        GRAN_4K | GRAN_32BIT,
    );

    gdt_ptr = GdtPtr{
        .limit = @as(u16, @sizeOf(@TypeOf(gdt_entries)) - 1),
        .base = @intFromPtr(&gdt_entries),
    };

    flush(&gdt_ptr);
}
