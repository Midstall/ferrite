/* FILE * layer.
 *
 * Owns the `struct _FILE` definition, the static stdin/stdout/stderr
 * pointers, and a 16-entry slab for fopen()-returned files. Each FILE
 * carries a default-sized buffer (BUFSIZ = 1024) used for fread/fwrite
 * batching; reads are pulled in one BUFSIZ-chunk at a time, writes
 * accumulate until BUFSIZ-1 then flush. Line-buffered streams (stdout
 * when attached to a tty) additionally flush on newline.
 *
 * Operations route through the libc's existing fd surface (open/read/
 * write/close/lseek), so fopen("/etc/users", "r") shares the same
 * fd-table + p9 fs plumbing as raw open().
 */

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#define O_RDONLY 0x0
#define O_WRONLY 0x1
#define O_RDWR 0x2
#define O_CREAT 0x40
#define O_TRUNC 0x200
#define O_APPEND 0x400

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

#define BUFSIZ 1024

extern int open(const char *path, int flags, ...);
extern int close(int fd);
extern ssize_t read(int fd, void *buf, size_t n);
extern ssize_t write(int fd, const void *buf, size_t n);
extern off_t lseek(int fd, off_t off, int whence);
extern int *__errno_location(void);

#define F_READ 0x01
#define F_WRITE 0x02
#define F_EOF 0x04
#define F_ERR 0x08
#define F_LINEBUF 0x10
#define F_NOBUF 0x20

struct _FILE {
  int fd;
  int flags;
  char *buf;
  int buf_cap;
  int buf_pos; /* next byte to fill (write) or consume (read) */
  int buf_end; /* for read: end of buffered data */
  int in_use;
  char default_buf[BUFSIZ];
};

typedef struct _FILE FILE;

#define MAX_FILES 16
static FILE file_pool[MAX_FILES];

/* The header declares `extern FILE *stdin;` etc.; the libc must define
 * them. They point at slots 0/1/2 which we eagerly initialize on the
 * first FILE * call (no real constructor support yet). */
FILE *stdin = &file_pool[0];
FILE *stdout = &file_pool[1];
FILE *stderr = &file_pool[2];

static int std_initialized = 0;

static void init_std_files(void) {
  if (std_initialized)
    return;
  file_pool[0].fd = 0;
  file_pool[0].flags = F_READ | F_NOBUF;
  file_pool[0].in_use = 1;
  /* stdout is unbuffered for now. The natural choice would be
   * line-buffered (F_LINEBUF), but `zig cc -O2` on aarch64
   * miscompiles fwrite's per-newline flush: the optimizer caches
   * `f->buf_pos` in a register across flush_write and the post-flush
   * reset to 0 is invisible, so buf_pos accumulates and each flush
   * re-emits the full write history. Until we narrow the trigger
   * (volatile/barrier/noinline didn't fix it; only an opaque
   * `write(2,...)` call between flush and the next iteration did),
   * keep stdout unbuffered like stderr. */
  file_pool[1].fd = 1;
  file_pool[1].flags = F_WRITE | F_NOBUF;
  file_pool[1].in_use = 1;
  file_pool[1].buf = file_pool[1].default_buf;
  file_pool[1].buf_cap = BUFSIZ;
  file_pool[2].fd = 2;
  file_pool[2].flags = F_WRITE | F_NOBUF;
  file_pool[2].in_use = 1;
  std_initialized = 1;
}

static FILE *alloc_file(void) {
  init_std_files();
  for (int i = 3; i < MAX_FILES; i++) {
    if (!file_pool[i].in_use) {
      FILE *f = &file_pool[i];
      *f = (FILE){0};
      f->in_use = 1;
      return f;
    }
  }
  return NULL;
}

static int parse_mode(const char *mode, int *want_flags) {
  if (!mode || !mode[0]) {
    *__errno_location() = 22;
    return -1;
  }
  int o = 0;
  int f = 0;
  int append = 0;
  int plus = 0;
  switch (mode[0]) {
  case 'r':
    o = O_RDONLY;
    f = F_READ;
    break;
  case 'w':
    o = O_WRONLY | O_CREAT | O_TRUNC;
    f = F_WRITE;
    break;
  case 'a':
    o = O_WRONLY | O_CREAT | O_APPEND;
    f = F_WRITE;
    append = 1;
    break;
  default:
    *__errno_location() = 22;
    return -1;
  }
  for (int i = 1; mode[i]; i++) {
    if (mode[i] == '+')
      plus = 1;
    /* 'b' is ignored (binary == text on POSIX), 'e' = O_CLOEXEC also ignored */
  }
  if (plus) {
    o = (o & ~(O_RDONLY | O_WRONLY)) | O_RDWR;
    f = F_READ | F_WRITE;
  }
  if (append)
    f |= F_WRITE;
  *want_flags = f;
  return o;
}

FILE *fopen(const char *path, const char *mode) {
  init_std_files();
  int want_flags;
  int oflags = parse_mode(mode, &want_flags);
  if (oflags < 0)
    return NULL;
  int fd = open(path, oflags);
  if (fd < 0)
    return NULL;
  FILE *f = alloc_file();
  if (!f) {
    close(fd);
    return NULL;
  }
  f->fd = fd;
  f->flags = want_flags;
  f->buf = f->default_buf;
  f->buf_cap = BUFSIZ;
  return f;
}

FILE *fdopen(int fd, const char *mode) {
  init_std_files();
  int want_flags;
  if (parse_mode(mode, &want_flags) < 0)
    return NULL;
  FILE *f = alloc_file();
  if (!f)
    return NULL;
  f->fd = fd;
  f->flags = want_flags;
  f->buf = f->default_buf;
  f->buf_cap = BUFSIZ;
  return f;
}

/* Drain the write buffer to fd. Returns 0 on success, -1 on error.
 *
 * Marked noinline: when this was inlined into fwrite under
 * `zig cc -O2`, the optimizer cached `f->buf_pos` in a register
 * across the inlined `f->buf_pos = 0` reset, so subsequent fwrite
 * calls observed the stale pre-flush value and buf_pos accumulated.
 * Forcing a real call boundary makes the reset visible. */
__attribute__((noinline)) static int flush_write(FILE *f) {
  if (!(f->flags & F_WRITE))
    return 0;
  int pos = f->buf_pos;
  int off = 0;
  while (off < pos) {
    ssize_t n = write(f->fd, f->buf + off, (size_t)(pos - off));
    if (n <= 0) {
      f->flags |= F_ERR;
      return -1;
    }
    off += (int)n;
  }
  f->buf_pos = 0;
  return 0;
}

int fflush(FILE *f) {
  init_std_files();
  if (!f) {
    /* fflush(NULL) flushes all open output streams. */
    int err = 0;
    for (int i = 0; i < MAX_FILES; i++) {
      if (file_pool[i].in_use && (file_pool[i].flags & F_WRITE)) {
        if (flush_write(&file_pool[i]))
          err = -1;
      }
    }
    return err;
  }
  return flush_write(f);
}

int fclose(FILE *f) {
  if (!f) {
    *__errno_location() = 22;
    return -1;
  }
  int rc = 0;
  if (f->flags & F_WRITE) {
    if (flush_write(f))
      rc = -1;
  }
  if (f->fd >= 0 && close(f->fd) < 0)
    rc = -1;
  if (f >= &file_pool[3] && f < &file_pool[MAX_FILES]) {
    f->in_use = 0;
  }
  return rc;
}

/* Read into the buffer; returns bytes read into buf (0 on EOF, -1 on err). */
static int refill_read(FILE *f) {
  if (!(f->flags & F_READ))
    return -1;
  ssize_t n = read(f->fd, f->buf, (size_t)f->buf_cap);
  if (n < 0) {
    f->flags |= F_ERR;
    return -1;
  }
  if (n == 0) {
    f->flags |= F_EOF;
    return 0;
  }
  f->buf_pos = 0;
  f->buf_end = (int)n;
  return (int)n;
}

size_t fread(void *ptr, size_t size, size_t nmemb, FILE *f) {
  init_std_files();
  if (size == 0 || nmemb == 0 || !f || !(f->flags & F_READ))
    return 0;
  size_t total = size * nmemb;
  char *dst = (char *)ptr;
  size_t got = 0;
  while (got < total) {
    if (f->buf_pos >= f->buf_end) {
      int n = refill_read(f);
      if (n <= 0)
        break;
    }
    int avail = f->buf_end - f->buf_pos;
    int want = (int)(total - got);
    int take = avail < want ? avail : want;
    for (int i = 0; i < take; i++)
      dst[got + i] = f->buf[f->buf_pos + i];
    got += (size_t)take;
    f->buf_pos += take;
  }
  return got / size;
}

size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *f) {
  init_std_files();
  if (size == 0 || nmemb == 0 || !f || !(f->flags & F_WRITE))
    return 0;
  const char *src = (const char *)ptr;
  size_t total = size * nmemb;

  /* Unbuffered: just write straight through. */
  if (f->flags & F_NOBUF) {
    size_t off = 0;
    while (off < total) {
      ssize_t n = write(f->fd, src + off, total - off);
      if (n <= 0) {
        f->flags |= F_ERR;
        break;
      }
      off += (size_t)n;
    }
    return off / size;
  }

  size_t written = 0;
  while (written < total) {
    int room = f->buf_cap - f->buf_pos;
    if (room <= 0) {
      if (flush_write(f))
        break;
      room = f->buf_cap;
    }
    int want = (int)(total - written);
    int take = room < want ? room : want;
    for (int i = 0; i < take; i++)
      f->buf[f->buf_pos + i] = src[written + i];
    f->buf_pos += take;
    written += (size_t)take;
    if ((f->flags & F_LINEBUF)) {
      /* Line-buffered: flush if we just wrote a newline.
       * Currently dead: stdout is unbuffered to avoid the
       * zig-cc miscompile noted in init_std_files. */
      for (int i = take - 1; i >= 0; i--) {
        if (f->buf[f->buf_pos - take + i] == '\n') {
          if (flush_write(f))
            goto out;
          break;
        }
      }
    }
  }
out:
  return written / size;
}

int fgetc(FILE *f) {
  init_std_files();
  if (!f || !(f->flags & F_READ))
    return -1;
  if (f->flags & F_NOBUF) {
    unsigned char c;
    ssize_t n = read(f->fd, &c, 1);
    if (n <= 0) {
      f->flags |= (n == 0) ? F_EOF : F_ERR;
      return -1;
    }
    return c;
  }
  if (f->buf_pos >= f->buf_end) {
    int n = refill_read(f);
    if (n <= 0)
      return -1;
  }
  return (unsigned char)f->buf[f->buf_pos++];
}

int getc(FILE *f) { return fgetc(f); }
int getchar(void) { return fgetc(stdin); }

int fputc(int c, FILE *f) {
  init_std_files();
  if (!f || !(f->flags & F_WRITE))
    return -1;
  unsigned char b = (unsigned char)c;
  if (fwrite(&b, 1, 1, f) != 1)
    return -1;
  return (unsigned char)c;
}

int putc(int c, FILE *f) { return fputc(c, f); }
int putchar(int c) { return fputc(c, stdout); }

int fputs(const char *s, FILE *f) {
  init_std_files();
  if (!s || !f)
    return -1;
  size_t len = 0;
  while (s[len])
    len++;
  if (fwrite(s, 1, len, f) != len)
    return -1;
  return (int)len;
}

int puts(const char *s) {
  if (fputs(s, stdout) < 0)
    return -1;
  if (fputc('\n', stdout) < 0)
    return -1;
  return 0;
}

char *fgets(char *s, int size, FILE *f) {
  init_std_files();
  if (!s || size <= 0 || !f)
    return NULL;
  int i = 0;
  while (i < size - 1) {
    int c = fgetc(f);
    if (c < 0) {
      if (i == 0)
        return NULL;
      break;
    }
    s[i++] = (char)c;
    if (c == '\n')
      break;
  }
  s[i] = 0;
  return s;
}

int feof(FILE *f) { return f && (f->flags & F_EOF) ? 1 : 0; }
int ferror(FILE *f) { return f && (f->flags & F_ERR) ? 1 : 0; }
void clearerr(FILE *f) {
  if (f)
    f->flags &= ~(F_EOF | F_ERR);
}

int fseek(FILE *f, long off, int whence) {
  init_std_files();
  if (!f) {
    *__errno_location() = 22;
    return -1;
  }
  if (f->flags & F_WRITE) {
    if (flush_write(f))
      return -1;
  }
  /* Reads: drop the buffer so the next read pulls from the new pos. */
  f->buf_pos = 0;
  f->buf_end = 0;
  f->flags &= ~F_EOF;
  off_t r = lseek(f->fd, off, whence);
  return r < 0 ? -1 : 0;
}

long ftell(FILE *f) {
  init_std_files();
  if (!f) {
    *__errno_location() = 22;
    return -1;
  }
  off_t r = lseek(f->fd, 0, SEEK_CUR);
  if (r < 0)
    return -1;
  /* Account for buffered data not yet consumed/flushed. */
  if (f->flags & F_READ)
    r -= (f->buf_end - f->buf_pos);
  if (f->flags & F_WRITE)
    r += f->buf_pos;
  return (long)r;
}

int fileno(FILE *f) { return f ? f->fd : -1; }

void perror(const char *s) {
  extern char *strerror(int);
  if (s && s[0]) {
    fputs(s, stderr);
    fputs(": ", stderr);
  }
  fputs(strerror(*__errno_location()), stderr);
  fputc('\n', stderr);
}
