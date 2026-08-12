//! Minimal PS/2 keyboard driver.
//!
//! Demonstrates the full loop for "using interrupts": register a
//! handler for a specific IRQ, unmask that IRQ so the PIC actually
//! delivers it, and read whatever data the device left waiting.

const idt = @import("idt.zig");
const console = @import("console.zig");

const DATA_PORT: u16 = 0x60;

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

// Set 1 scancode -> ASCII, US QWERTY, unshifted, printable keys only.
// Index = scancode. 0 means "no mapping" (function keys, modifiers,
// etc). This is intentionally minimal -- extend as needed.
const scancode_to_ascii = [_]u8{
    0, 0, '1', '2', '3', '4', '5', '6', '7', '8', // 0x00-0x09
    '9', '0', '-', '=', 8, '\t', 'q', 'w', 'e', 'r', // 0x0A-0x13
    't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0, // 0x14-0x1D (0x1D = left ctrl)
    'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', // 0x1E-0x27
    '\'', '`', 0, '\\', 'z', 'x', 'c', 'v', 'b', 'n', // 0x28-0x31 (0x2A = left shift)
    'm', ',', '.', '/', 0, '*', 0, ' ', 0, 0, // 0x32-0x3B
};

fn onKeyboardIrq(regs: *idt.Registers) void {
    _ = regs;
    const scancode = inb(DATA_PORT);

    // Bit 7 set = key release, not press -- ignore those for now.
    if (scancode & 0x80 != 0) return;

    if (scancode < scancode_to_ascii.len) {
        const ch = scancode_to_ascii[scancode];
        if (ch != 0) {
            console.printChar(ch);
        }
    }
}

pub fn init() void {
    idt.registerIrqHandler(1, onKeyboardIrq);
    idt.unmaskIrq(1);
}
