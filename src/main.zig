const console = @import("console.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const keyboard = @import("keyboard.zig");
const multibootInfo = @import("multiboot.zig");

const MB_HEADER_MAGIC = 0x1BADB002;
const MB_FLAG_ALIGN = 1 << 0;
const MB_FLAG_MEMINFO = 1 << 1;
const FLAGS = MB_FLAG_ALIGN | MB_FLAG_MEMINFO;

/// https://www.gnu.org/software/grub/manual/multiboot/multiboot.html#Header-layout
const MultibootHeader = packed struct(u128) {
    magic: u32 = MB_HEADER_MAGIC,
    flags: u32 = FLAGS,
    checksum: u32,
    padding: u32 = 0,
};

export var multiboot: MultibootHeader align(4) linksection(".multiboot") = .{
    // Here we are adding magic and flags and ~ to get 1's complement and by adding 1 we get 2's complement
    .checksum = ~@as(u32, (MB_HEADER_MAGIC + FLAGS)) + 1,
};

var stack_bytes: [16 * 1024]u8 align(16) linksection(".bss") = undefined;

// We specify that this function is "naked" to let the compiler know
// not to generate a standard function prologue and epilogue, since
// we don't have a stack yet.
export fn _start() callconv(.naked) noreturn {
    // We use inline assembly to set up the stack before jumping to
    // our kernel entry point.
    asm volatile (
        \\ movl %[stack_top], %%esp
        \\ movl %%esp, %%ebp
        \\ push %%ebx
        \\ push %%eax
        \\ call %[kmain:P]
        :
        // The stack grows downwards on x86, so we need to point ESP register
        // to one element past the end of `stack_bytes`.
        //
        // Finally, we pass the whole expression as an input operand with the
        // "immediate" constraint to force the compiler to encode this as an
        // absolute address. This prevents the compiler from doing unnecessary
        // extra steps to compute the address at runtime (especially in Debug mode),
        // which could possibly clobber registers that are specified by multiboot
        // to hold special values (e.g. EAX).
        //
        // IMPORTANT: this is exactly why the pushes above must happen
        // AFTER esp is repointed to stack_top, and BEFORE anything
        // else -- eax/ebx hold the multiboot magic/info-pointer GRUB
        // set for us, and we can't let them get clobbered before we
        // save them onto the stack.
        : [stack_top] "i" (@as([*]align(16) u8, @ptrCast(&stack_bytes)) + @sizeOf(@TypeOf(stack_bytes))),
          // We let the compiler handle the reference to kmain by passing it as an input operand as well.
          [kmain] "X" (&kmain),
    );
}

// We use noinline to make sure it don't get inlined by compiler
noinline fn kmain(magic: u32, mbinfo_addr: u32) callconv(.c) noreturn {
    // gdt.init();
    // idt.init();
    // keyboard.init();
    // Initialize our VGA driver
    console.init();

    if (magic != multibootInfo.MULTIBOOT_MAGIC) {
        console.puts("PANIC: invalid multiboot magic\n");
        while (true) asm volatile ("cli; hlt");
    }

    const mbinfo: *multibootInfo.MultibootInfo = @ptrFromInt(mbinfo_addr);
    console.printf("mem_lower: {d} KB, mem_upper: {d} KB\n", .{ mbinfo.mem_lower, mbinfo.mem_upper });

    gdt.init();
    console.puts("[OK] GDT INITIALIZED\n");

    idt.init();
    console.puts("[OK] IDT INITIALIZED\n");

    keyboard.init();
    console.puts("[OK] KEYBOARD INITIALIZED\n\n\n");

    // Printing string
    console.printf("Hello {s} kernel!\n", .{"zig"});
    // Loop forever as there is nothing to do
    idt.enable();
    while (true) {
        asm volatile ("hlt");
    }
}
