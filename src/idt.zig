//! Interrupt Descriptor Table implementation.
//!
//! Covers:
//!   - The 256-entry IDT itself + `lidt` loading
//!   - Remapping the 8259 PIC so hardware IRQs land on vectors 32-47
//!     instead of colliding with CPU exception vectors 0-31
//!   - Generating one small assembly stub per vector (0-47) via a
//!     comptime function, so we don't have to hand-write 48 near-
//!     identical stubs
//!   - A single Zig-side dispatcher (`isrHandler`) that both exception
//!     and IRQ stubs funnel into
//!
//! Call `idt.init()` once, after `gdt.init()`. Call `idt.enable()`
//! (which just executes `sti`) only once every subsystem the handlers
//! touch (e.g. the console) is actually ready -- an interrupt firing
//! before that will crash into uninitialized state.

const std = @import("std");
const console = @import("console.zig");

// ============================================================
// Port I/O helpers
// ============================================================

inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

/// A tiny throwaway I/O write, used as a delay: some ancient hardware
/// (the PIC included) needs a moment to process each command byte.
inline fn ioWait() void {
    outb(0x80, 0);
}

// ============================================================
// PIC (8259) remapping
// ============================================================

const PIC1_COMMAND: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_COMMAND: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

const ICW1_INIT: u8 = 0x10;
const ICW1_ICW4: u8 = 0x01;
const ICW4_8086: u8 = 0x01;

/// By default IRQ0-7 fire on interrupt vectors 0x08-0x0F, which
/// collides head-on with CPU exceptions (0x08 is Double Fault!).
/// This remaps them to 0x20-0x2F (master) and 0x28-0x2F (slave).
fn remapPic() void {
    // Save the current interrupt masks -- we restore them below so we
    // don't accidentally unmask an IRQ the caller didn't ask for.
    const mask1 = inb(PIC1_DATA);
    const mask2 = inb(PIC2_DATA);

    outb(PIC1_COMMAND, ICW1_INIT | ICW1_ICW4);
    ioWait();
    outb(PIC2_COMMAND, ICW1_INIT | ICW1_ICW4);
    ioWait();

    outb(PIC1_DATA, 0x20); // Master PIC vector offset: IRQ0 -> int 0x20
    ioWait();
    outb(PIC2_DATA, 0x28); // Slave PIC vector offset: IRQ8 -> int 0x28
    ioWait();

    outb(PIC1_DATA, 4); // Tell master PIC there's a slave at IRQ2 (bit 2)
    ioWait();
    outb(PIC2_DATA, 2); // Tell slave PIC its cascade identity (IRQ2)
    ioWait();

    outb(PIC1_DATA, ICW4_8086);
    ioWait();
    outb(PIC2_DATA, ICW4_8086);
    ioWait();

    outb(PIC1_DATA, mask1);
    outb(PIC2_DATA, mask2);
}

// ============================================================
// IDT structures
// ============================================================

/// One 8-byte IDT gate. Zig 0.16 requires an explicit backing integer
/// on precisely-sized packed structs.
const IdtEntry = packed struct(u64) {
    offset_low: u16,
    selector: u16,
    zero: u8 = 0,
    type_attr: u8,
    offset_high: u16,
};

/// The 6-byte structure loaded by `lidt`: 16-bit limit, 32-bit base.
const IdtPtr = packed struct(u48) {
    limit: u16,
    base: u32,
};

// Present=1, DPL=00 (ring0), 32-bit interrupt gate (0xE type).
const IDT_FLAGS: u8 = 0x8E;
const KERNEL_CODE_SELECTOR: u16 = 0x08; // must match your GDT's kernel code entry

var idt_entries: [256]IdtEntry = undefined;
var idt_ptr: IdtPtr = undefined;

fn setGate(index: u8, handler: usize, selector: u16, flags: u8) void {
    idt_entries[index] = IdtEntry{
        .offset_low = @truncate(handler & 0xFFFF),
        .selector = selector,
        .zero = 0,
        .type_attr = flags,
        .offset_high = @truncate((handler >> 16) & 0xFFFF),
    };
}

fn load(ptr: *const IdtPtr) void {
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (ptr),
    );
}

// ============================================================
// Register snapshot passed to the Zig handler
// ============================================================

/// Layout MUST exactly match what `isrCommonStub` pushes, in reverse
/// (first field = top of stack = most recently pushed). This is the
/// same layout used by the classic James Molloy IDT tutorial, ported
/// to Zig.
pub const Registers = extern struct {
    ds: u32,
    edi: u32,
    esi: u32,
    ebp: u32,
    esp: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
    int_no: u32,
    err_code: u32,
    eip: u32,
    cs: u32,
    eflags: u32,
    user_esp: u32,
    ss: u32,
};

// ============================================================
// ISR / IRQ stub generation
// ============================================================

/// Which CPU exceptions push their own error code onto the stack.
/// Everything else (including all IRQs) does not, so we push a dummy
/// 0 in its place to keep the stack layout uniform for every vector.
fn hasErrorCode(comptime vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17 => true,
        else => false,
    };
}

/// Generates one tiny naked stub per vector. Each instantiation of
/// this generic function (one per distinct `num`) is a genuinely
/// separate function with its own address, which is exactly what we
/// need for 48 distinct IDT gates.
fn makeIsr(comptime num: u8, comptime has_error_code: bool) fn () callconv(.naked) noreturn {
    return struct {
        fn stub() callconv(.naked) noreturn {
            if (!has_error_code) {
                asm volatile ("pushl $0");
            }
            asm volatile ("pushl %[num]"
                :
                : [num] "n" (num),
            );
            // Jump to the shared handler by symbol, the same trick
            // used for _start -> kmain: pass the function as a
            // comptime-known operand and let LLVM emit a direct jump.
            asm volatile ("jmp %[target:P]"
                :
                : [target] "X" (&isrCommonStub),
            );
        }
    }.stub;
}

/// Shared tail for every stub: save registers, switch to kernel data
/// segments, call into Zig, restore, and return from the interrupt.
fn isrCommonStub() callconv(.naked) noreturn {
    asm volatile (
        \\ pusha
        \\ mov %%ds, %%ax
        \\ push %%eax
        \\ mov $0x10, %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%fs
        \\ mov %%ax, %%gs
        \\ push %%esp
        \\ call %[handler:P]
        \\ add $4, %%esp
        \\ pop %%eax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%fs
        \\ mov %%ax, %%gs
        \\ popa
        \\ add $8, %%esp
        \\ iret
        :
        : [handler] "X" (&isrHandler),
        : .{ .memory = true });
}

/// The actual Zig-level interrupt handler. Called with a pointer to
/// the saved register state (cdecl: single stack argument).
fn isrHandler(regs: *Registers) callconv(.c) void {
    if (regs.int_no < 32) {
        // CPU exception. We don't have recovery logic yet, so just
        // report what happened and halt rather than silently reset.
        console.puts("\nPANIC: unhandled CPU exception ");
        console.printf("{d}", .{regs.int_no});
        console.puts(", error code ");
        console.printf("{d}", .{regs.err_code});
        console.puts("\n");
        while (true) {
            asm volatile ("cli");
            asm volatile ("hlt");
        }
    } else {
        // Hardware IRQ. int_no 32-47 maps back to IRQ 0-15.
        const irq: u8 = @truncate(regs.int_no - 32);

        if (irq_handlers[irq]) |handler| {
            handler(regs);
        }

        // EOI must be sent regardless of whether a handler was
        // registered, or the PIC will never deliver that line again.
        if (regs.int_no >= 40) {
            outb(PIC2_COMMAND, 0x20); // EOI to slave PIC
        }
        outb(PIC1_COMMAND, 0x20); // EOI to master PIC
    }
}

// ============================================================
// Per-IRQ handler registry
// ============================================================

/// One slot per hardware IRQ line (0-15). `isrHandler` consults this
/// table for every IRQ instead of hardcoding behavior, so other
/// modules (keyboard, timer, ...) can plug themselves in without
/// touching this file again.
var irq_handlers: [16]?*const fn (*Registers) void = [_]?*const fn (*Registers) void{null} ** 16;

/// Register `handler` to run whenever IRQ `irq` (0-15) fires.
/// Does NOT unmask the IRQ for you -- call unmaskIrq() too, or it'll
/// never actually be delivered.
pub fn registerIrqHandler(irq: u8, handler: *const fn (*Registers) void) void {
    irq_handlers[irq] = handler;
}

// ============================================================
// PIC IRQ masking
// ============================================================
// Each PIC has an 8-bit mask register: bit=1 means that IRQ line is
// *disabled*. After remapPic() every line keeps whatever mask it had
// before (often "everything but timer/keyboard masked" under QEMU,
// but don't rely on that -- explicitly unmask what you register).

pub fn unmaskIrq(irq: u8) void {
    if (irq < 8) {
        const mask = inb(PIC1_DATA) & ~(@as(u8, 1) << @as(u3, @intCast(irq)));
        outb(PIC1_DATA, mask);
    } else {
        const bit = irq - 8;
        const mask = inb(PIC2_DATA) & ~(@as(u8, 1) << @as(u3, @intCast(bit)));
        outb(PIC2_DATA, mask);
    }
}

pub fn maskIrq(irq: u8) void {
    if (irq < 8) {
        const mask = inb(PIC1_DATA) | (@as(u8, 1) << @as(u3, @intCast(irq)));
        outb(PIC1_DATA, mask);
    } else {
        const bit = irq - 8;
        const mask = inb(PIC2_DATA) | (@as(u8, 1) << @as(u3, @intCast(bit)));
        outb(PIC2_DATA, mask);
    }
}

// ============================================================
// Public API
// ============================================================

pub fn enable() void {
    asm volatile ("sti");
}

pub fn disable() void {
    asm volatile ("cli");
}

pub fn init() void {
    // Start every gate as "not present" so unused vectors fault
    // predictably instead of jumping into garbage.
    for (&idt_entries) |*entry| {
        entry.* = IdtEntry{
            .offset_low = 0,
            .selector = 0,
            .zero = 0,
            .type_attr = 0,
            .offset_high = 0,
        };
    }

    remapPic();

    // CPU exceptions: vectors 0-31.
    inline for (0..32) |i| {
        const vector: u8 = i;
        setGate(
            vector,
            @intFromPtr(&makeIsr(vector, comptime hasErrorCode(vector))),
            KERNEL_CODE_SELECTOR,
            IDT_FLAGS,
        );
    }

    // Hardware IRQs: vectors 32-47 (remapped by remapPic() above).
    inline for (32..48) |i| {
        const vector: u8 = i;
        setGate(
            vector,
            @intFromPtr(&makeIsr(vector, false)),
            KERNEL_CODE_SELECTOR,
            IDT_FLAGS,
        );
    }

    idt_ptr = IdtPtr{
        .limit = @as(u16, @sizeOf(@TypeOf(idt_entries)) - 1),
        .base = @intFromPtr(&idt_entries),
    };

    load(&idt_ptr);

    // NOTE: interrupts are still masked/off here -- call enable()
    // separately once the rest of kernel init is done.
}
