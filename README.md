# Ferrite

A modular real-time microkernel, written in Zig, inspired by Plan 9.

## Design

The kernel only owns what hardware demands: **threads, address spaces, IPC,
capabilities, IRQ routing.** Drivers, filesystems, networking, console, and
policy are all userspace processes that speak a 9P-shaped channel protocol
to their clients. A process's view of the world is its **namespace**, a
mapping from names to capabilities, built by mounting services rather than
configuring a monolith.

## Status

Boot matrix:

| arch     | raw  | mb1   | mb2   | limine | uefi  | esp image |
|----------|------|-------|-------|--------|-------|-----------|
| aarch64  | y    | n/a   | n/a   | y      | y     | n/a       |
| riscv64  | y    | n/a   | n/a   | y[1]   | n[2]  | n/a       |
| riscv32  | n/a  | n/a   | n/a   | n/a    | n/a   | y[4]      |
| i386     | n/a  | y     | y[3]  | n/a    | n/a   | n/a       |
| x86_64   | n/a  | y[3]  | y[3]  | y      | y     | n/a       |

[1] Via OpenSBI + U-Boot EFI.  
[2] Zig 0.16's COFF writer can't emit riscv64 PE.  
[3] Build only. QEMU's `-kernel` accepts MB1 on i386 only, ELF64 multiboot needs GRUB.  
[4] ESP32-C6 only. Two-stage bootloader -> kernel XIP from flash, data in IRAM.

In kernel today:

- Per-arch MMU, traps, timer, and IRQ-controller HAL. On chips without
  an MMU (ESP32-C6) PMP regions stand in for per-process isolation.
- Priority-preemptive scheduler with EDF tiebreak. Preemption + PI locks.
- Physical page frame allocator + slab heap.
- Capability-based namespaces, channel IPC, 9P-shaped service protocol.
- Mach-O userspace binaries with Ed25519 signatures, verified on load.
- TCP/IP networking on the QEMU virt targets (DHCP, DNS, NTP, TLS 1.3,
  HTTP, SSH server).

Targets in scope:

- QEMU virt for aarch64, riscv64, i386, x86_64. Reaches a login prompt
  with sshd + wget over slirp networking.
- ESP32-C6 (riscv32). DEF CON badge target. Reaches `kmain` and idles
  cleanly. Userspace integration is deferred until the init binary is
  small enough for the 4 MB flash + 512 KB SRAM budget.

## Roadmap

- **Graphics + audio** drivers (framebuffer, GPU command submission,
  PCM audio) so the badge target has more than serial.
- **`unshare`** - userspace utility to spawn a program inside a fresh
  namespace, mirroring Linux's tool.
- **Hypervisor mode** - defer execution of selected programs into a
  microVM (riscv H-extension on rv64, VT-x/AMD-V on x86_64, EL2 on
  aarch64).

## Build

```
zig build -Dboard=qemu-virt-aarch64                  # default - raw aarch64
zig build run -Dboard=qemu-pc-x86_64 -Dboot=limine   # x86_64 + limine
zig build -Dboard=esp32-c6                           # ESP32-C6 build (flash + run via esptool/tio)
zig build libc                                       # standalone libc.a
```

See `build/src/common.zig` for the supported `-Dboard` / `-Dboot` combinations
and the `supports()` function that enforces the matrix.
