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
- virtio drivers in userspace: GPU (multi-display, cursor, zero-copy
  buffers), sound (PCM sink with a software synth), input (keyboard,
  mouse, tablet), net, block, and rng.
- Userspace VMM: the kernel owns the world-switch and exits to a U-mode
  process. `vmboot` runs a whole guest kernel + initrd like QEMU (riscv64
  H-extension, aarch64 EL2, x86_64 AMD SVM + Intel VT-x); `vmexec` sandboxes a single
  program inside a hardware-isolated VM and proxies its syscalls through an
  allow-list.

Targets in scope:

- QEMU virt for aarch64, riscv64, i386, x86_64. Reaches a login prompt
  with sshd + wget over slirp networking.
- ESP32-C6 (riscv32). A minimal target we are experimenting with to see how
  far Ferrite shrinks. Reaches `kmain` and idles cleanly. Userspace
  integration is deferred until the init binary is small enough for the
  4 MB flash + 512 KB SRAM budget.

## Roadmap

- **`unshare`** - userspace utility to spawn a program inside a fresh
  namespace, mirroring Linux's tool.
- **Hypervisor mode** - boot an unmodified guest kernel in a microVM.
  The userspace VMM works on riscv64 and aarch64; the x86_64 backends
  (AMD SVM + Intel VT-x, picked by CPU vendor at runtime) are in but
  validatable only on real hardware with nested KVM, since QEMU TCG has
  no nested virt. Still ahead are a real S-mode/EL1 guest kernel + DTB
  and a proper IRQ-driven guest timer.
- **Graphics + audio showcase** - a software-rendered demo (DOOM 1993 +
  Bad Apple, with live synthesised audio) to push the real-time path.

## Build

```
zig build -Dboard=qemu-virt-aarch64                  # default - raw aarch64
zig build run -Dboard=qemu-pc-x86_64 -Dboot=limine   # x86_64 + limine
zig build -Dboard=esp32-c6                           # ESP32-C6 build (flash + run via esptool/tio)
zig build libc                                       # standalone libc.a
```

See `build/src/common.zig` for the supported `-Dboard` / `-Dboot` combinations
and the `supports()` function that enforces the matrix.
