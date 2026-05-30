/* printf / fprintf / sprintf / snprintf / vprintf family.
 *
 * Written in C because Zig 0.16 stage2 LLVM disables va_list on
 * aarch64 (`@cVaArg` errors). The whole printf surface goes through
 * a single `vfmt` core that takes a write callback; each public
 * entry point picks the right callback (write(fd, ...) for printf
 * and friends, or a bounded buffer for sprintf/snprintf).
 *
 * Specifiers: %d %i %u %x %X %o %s %c %p %%, length modifiers
 * h/hh/l/ll/z/t, width, precision, flags `-` `0` `+` ` ` `#`.
 * No %f/%e/%g (deferred until something needs floats). Unknown
 * specifiers print verbatim so bugs are visible.
 */

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

extern ssize_t write(int fd, const void *buf, size_t n);

/* Direct hook into the runtime to bypass the libc's `write` wrapper.
 * Returns the byte count on success or a negative errno on failure
 * (Linux kernel convention). The libc's `write` does the negative→errno
 * translation but we don't need it here. */
extern ssize_t _ferrite_write(int fd, const void *buf, unsigned long n);

struct flags {
  unsigned left : 1;
  unsigned zero : 1;
  unsigned plus : 1;
  unsigned space : 1;
  unsigned alt : 1;
};

typedef int (*write_fn)(void *ctx, const char *bytes, size_t n);

struct fdctx {
  int fd;
};

static int fd_write(void *ctx, const char *b, size_t n) {
  struct fdctx *c = (struct fdctx *)ctx;
  size_t off = 0;
  while (off < n) {
    ssize_t r = write(c->fd, b + off, n - off);
    if (r < 0)
      return -1;
    if (r == 0)
      break;
    off += (size_t)r;
  }
  return 0;
}

struct bufctx {
  char *buf;
  size_t cap; /* 0 = sprintf (unlimited); else snprintf bound */
  size_t pos;
  size_t needed; /* total bytes the caller would have needed */
};

static int buf_write(void *ctx, const char *b, size_t n) {
  struct bufctx *c = (struct bufctx *)ctx;
  c->needed += n;
  if (c->cap == 0) {
    for (size_t i = 0; i < n; i++)
      c->buf[c->pos++] = b[i];
    return 0;
  }
  size_t room = (c->pos + 1 < c->cap) ? (c->cap - 1 - c->pos) : 0;
  size_t take = n < room ? n : room;
  for (size_t i = 0; i < take; i++)
    c->buf[c->pos + i] = b[i];
  c->pos += take;
  return 0;
}

/* Track total bytes "produced" so the public entry points can return
 * the C printf result, which is the count that *would* have been
 * written regardless of buffer capacity. */
struct out {
  write_fn write;
  void *ctx;
  int count;
  int failed;
};

static void emit(struct out *o, const char *b, size_t n) {
  if (o->failed)
    return;
  if (o->write(o->ctx, b, n) != 0) {
    o->failed = 1;
    return;
  }
  o->count += (int)n;
}

static void emit_pad(struct out *o, char c, size_t n) {
  char buf[16];
  for (size_t i = 0; i < sizeof buf; i++)
    buf[i] = c;
  while (n > 0) {
    size_t k = n < sizeof buf ? n : sizeof buf;
    emit(o, buf, k);
    n -= k;
  }
}

static size_t fmt_u64(uint64_t v, unsigned base, int upper, char *buf,
                      size_t len) {
  /* Render right-justified into buf[0..len]; return the offset
   * where the number starts. */
  size_t i = len;
  if (v == 0) {
    if (i == 0)
      return i;
    buf[--i] = '0';
    return i;
  }
  while (v > 0 && i > 0) {
    unsigned d = (unsigned)(v % base);
    buf[--i] = (char)(d < 10 ? '0' + d : (upper ? 'A' : 'a') + d - 10);
    v /= base;
  }
  return i;
}

static void write_uint(struct out *o, uint64_t v, unsigned base, int upper,
                       int width, int precision, struct flags fl,
                       const char *prefix, size_t prefix_len) {
  char buf[24];
  size_t idx = fmt_u64(v, base, upper, buf, sizeof buf);
  size_t digits = sizeof buf - idx;
  if (precision == 0 && v == 0)
    digits = 0;

  size_t zeros = 0;
  if (precision > 0 && (size_t)precision > digits) {
    zeros = (size_t)precision - digits;
  }

  size_t content = prefix_len + zeros + digits;
  size_t pad =
      (width > 0 && (size_t)width > content) ? (size_t)width - content : 0;

  int use_zero_pad = (fl.zero && !fl.left && precision < 0);

  if (!fl.left && !use_zero_pad)
    emit_pad(o, ' ', pad);
  if (prefix_len > 0)
    emit(o, prefix, prefix_len);
  if (use_zero_pad)
    emit_pad(o, '0', pad);
  if (zeros > 0)
    emit_pad(o, '0', zeros);
  if (digits > 0)
    emit(o, buf + idx, digits);
  if (fl.left)
    emit_pad(o, ' ', pad);
}

static void write_sint(struct out *o, int64_t v, int width, int precision,
                       struct flags fl) {
  uint64_t mag;
  char prefix[1];
  size_t plen = 0;
  if (v < 0) {
    mag = (uint64_t)(-(v + 1)) + 1; /* handle INT_MIN */
    prefix[0] = '-';
    plen = 1;
  } else {
    mag = (uint64_t)v;
    if (fl.plus) {
      prefix[0] = '+';
      plen = 1;
    } else if (fl.space) {
      prefix[0] = ' ';
      plen = 1;
    }
  }
  write_uint(o, mag, 10, 0, width, precision, fl, prefix, plen);
}

static void write_str(struct out *o, const char *s, int width, int precision,
                      struct flags fl) {
  if (!s)
    s = "(null)";
  size_t len = 0;
  if (precision >= 0) {
    while (len < (size_t)precision && s[len])
      len++;
  } else {
    while (s[len])
      len++;
  }
  size_t pad = (width > 0 && (size_t)width > len) ? (size_t)width - len : 0;
  if (!fl.left)
    emit_pad(o, ' ', pad);
  emit(o, s, len);
  if (fl.left)
    emit_pad(o, ' ', pad);
}

/* va_list is passed by pointer because on some ABIs (notably aarch64)
 * passing it by value across multiple function frames produces wrong
 * arg reads. Inside this function we dereference `apptr` for each
 * `va_arg` call. */
static void vfmt(struct out *o, const char *fmt, va_list *apptr) {
  while (*fmt) {
    if (*fmt != '%') {
      const char *p = fmt;
      while (*fmt && *fmt != '%')
        fmt++;
      emit(o, p, (size_t)(fmt - p));
      continue;
    }
    fmt++; /* past '%' */

    struct flags fl = {0};
    for (;;) {
      switch (*fmt) {
      case '-':
        fl.left = 1;
        fmt++;
        continue;
      case '0':
        fl.zero = 1;
        fmt++;
        continue;
      case '+':
        fl.plus = 1;
        fmt++;
        continue;
      case ' ':
        fl.space = 1;
        fmt++;
        continue;
      case '#':
        fl.alt = 1;
        fmt++;
        continue;
      }
      break;
    }

    int width = 0;
    if (*fmt == '*') {
      width = va_arg(*apptr, int);
      fmt++;
      if (width < 0) {
        fl.left = 1;
        width = -width;
      }
    } else {
      while (*fmt >= '0' && *fmt <= '9') {
        width = width * 10 + (*fmt - '0');
        fmt++;
      }
    }

    int precision = -1;
    if (*fmt == '.') {
      fmt++;
      precision = 0;
      if (*fmt == '*') {
        precision = va_arg(*apptr, int);
        fmt++;
        if (precision < 0)
          precision = 0;
      } else {
        while (*fmt >= '0' && *fmt <= '9') {
          precision = precision * 10 + (*fmt - '0');
          fmt++;
        }
      }
    }

    /* Length modifier: hh, h, l, ll, z, t */
    int longness = 0; /* 0=int, 1=long, 2=long long */
    int sizet = 0;
    if (*fmt == 'h') {
      fmt++;
      if (*fmt == 'h')
        fmt++; /* short or shorter; we promote to int */
    } else if (*fmt == 'l') {
      fmt++;
      longness = 1;
      if (*fmt == 'l') {
        fmt++;
        longness = 2;
      }
    } else if (*fmt == 'z' || *fmt == 't') {
      fmt++;
      sizet = 1;
    }

    char conv = *fmt;
    if (conv)
      fmt++;
    switch (conv) {
    case '\0':
      return;
    case '%': {
      char c = '%';
      emit(o, &c, 1);
      break;
    }
    case 'd':
    case 'i': {
      int64_t v;
      if (sizet)
        v = (int64_t)va_arg(*apptr, ssize_t);
      else if (longness == 2)
        v = (int64_t)va_arg(*apptr, long long);
      else if (longness == 1)
        v = (int64_t)va_arg(*apptr, long);
      else
        v = (int64_t)va_arg(*apptr, int);
      write_sint(o, v, width, precision, fl);
      break;
    }
    case 'u':
    case 'x':
    case 'X':
    case 'o': {
      uint64_t v;
      if (sizet)
        v = (uint64_t)va_arg(*apptr, size_t);
      else if (longness == 2)
        v = (uint64_t)va_arg(*apptr, unsigned long long);
      else if (longness == 1)
        v = (uint64_t)va_arg(*apptr, unsigned long);
      else
        v = (uint64_t)va_arg(*apptr, unsigned int);
      unsigned base = (conv == 'o') ? 8u : (conv == 'u' ? 10u : 16u);
      int upper = (conv == 'X');
      const char *pre = "";
      size_t prelen = 0;
      if (fl.alt && v != 0) {
        if (conv == 'x') {
          pre = "0x";
          prelen = 2;
        } else if (conv == 'X') {
          pre = "0X";
          prelen = 2;
        } else if (conv == 'o') {
          pre = "0";
          prelen = 1;
        }
      }
      write_uint(o, v, base, upper, width, precision, fl, pre, prelen);
      break;
    }
    case 'c': {
      char c = (char)va_arg(*apptr, int);
      int w = width > 1 ? width - 1 : 0;
      if (!fl.left)
        emit_pad(o, ' ', (size_t)w);
      emit(o, &c, 1);
      if (fl.left)
        emit_pad(o, ' ', (size_t)w);
      break;
    }
    case 's': {
      const char *s = va_arg(*apptr, const char *);
      write_str(o, s, width, precision, fl);
      break;
    }
    case 'p': {
      void *p = va_arg(*apptr, void *);
      if (!p) {
        emit(o, "(nil)", 5);
      } else {
        uint64_t addr = (uint64_t)(uintptr_t)p;
        write_uint(o, addr, 16, 0, width, precision, fl, "0x", 2);
      }
      break;
    }
    default: {
      char buf[2] = {'%', conv};
      emit(o, buf, 2);
      break;
    }
    }
  }
}

int vprintf(const char *fmt, va_list ap) {
  struct fdctx fc = {.fd = 1};
  struct out o = {.write = fd_write, .ctx = &fc, .count = 0, .failed = 0};
  vfmt(&o, fmt, &ap);
  return o.failed ? -1 : o.count;
}

/* Forward declaration matching stdio_file.c's `struct _FILE`. We only
 * touch the leading `fd` field so the full layout doesn't have to be
 * visible here. */
struct _FILE_partial {
  int fd;
  int flags; /* rest unused */
};

int vfprintf(void *stream, const char *fmt, va_list ap) {
  int fd = 1;
  if (stream)
    fd = ((struct _FILE_partial *)stream)->fd;
  struct fdctx fc = {.fd = fd};
  struct out o = {.write = fd_write, .ctx = &fc, .count = 0, .failed = 0};
  vfmt(&o, fmt, &ap);
  return o.failed ? -1 : o.count;
}

int vsnprintf(char *buf, size_t n, const char *fmt, va_list ap) {
  if (n == 0) {
    /* Just count what would have been written. */
    struct bufctx bc = {.buf = buf, .cap = 1, .pos = 0, .needed = 0};
    struct out o = {.write = buf_write, .ctx = &bc, .count = 0, .failed = 0};
    vfmt(&o, fmt, &ap);
    return (int)bc.needed;
  }
  struct bufctx bc = {.buf = buf, .cap = n, .pos = 0, .needed = 0};
  struct out o = {.write = buf_write, .ctx = &bc, .count = 0, .failed = 0};
  vfmt(&o, fmt, &ap);
  buf[bc.pos] = 0;
  return (int)bc.needed;
}

int vsprintf(char *buf, const char *fmt, va_list ap) {
  struct bufctx bc = {.buf = buf, .cap = 0, .pos = 0, .needed = 0};
  struct out o = {.write = buf_write, .ctx = &bc, .count = 0, .failed = 0};
  vfmt(&o, fmt, &ap);
  buf[bc.pos] = 0;
  return (int)bc.needed;
}

int printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vprintf(fmt, ap);
  va_end(ap);
  return r;
}

int fprintf(void *stream, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vfprintf(stream, fmt, ap);
  va_end(ap);
  return r;
}

int sprintf(char *buf, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vsprintf(buf, fmt, ap);
  va_end(ap);
  return r;
}

int snprintf(char *buf, size_t n, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vsnprintf(buf, n, fmt, ap);
  va_end(ap);
  return r;
}
