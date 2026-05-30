//! Placeholder. The stdio surface (FILE *, printf family, puts/putchar/
//! fgets/fread/fwrite/fseek/...) is implemented in C (see
//! libc/src/stdio_file.c and libc/src/printf.c). Zig's stage2 LLVM
//! backend has aarch64 va_list disabled, so the format core has to be
//! in C; once that constraint goes away, the non-variadic helpers
//! could move back here.

const std = @import("std");
