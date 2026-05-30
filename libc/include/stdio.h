#pragma once

#include <stdarg.h>
#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The full layout matches `struct _FILE` in libc/src/stdio_file.c.
 * Programs typically use `FILE *` opaquely, but exposing the struct
 * here lets fopen/fclose etc. allocate slots from the C side. */
#define BUFSIZ 1024
struct _FILE {
  int fd;
  int flags;
  char *buf;
  int buf_cap;
  int buf_pos;
  int buf_end;
  int in_use;
  char default_buf[BUFSIZ];
};
typedef struct _FILE FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

#define EOF (-1)

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

int printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
int fprintf(FILE *stream, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));
int sprintf(char *s, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));
int snprintf(char *s, size_t n, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));
int vprintf(const char *fmt, va_list ap);
int vfprintf(FILE *stream, const char *fmt, va_list ap);
int vsprintf(char *s, const char *fmt, va_list ap);
int vsnprintf(char *s, size_t n, const char *fmt, va_list ap);

int puts(const char *s);
int fputs(const char *s, FILE *stream);
int putchar(int c);
int putc(int c, FILE *stream);
int fputc(int c, FILE *stream);
int getchar(void);
int getc(FILE *stream);
int fgetc(FILE *stream);
char *fgets(char *s, int size, FILE *stream);

FILE *fopen(const char *path, const char *mode);
FILE *fdopen(int fd, const char *mode);
int fclose(FILE *stream);
size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream);
size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);
int fflush(FILE *stream);
int fseek(FILE *stream, long offset, int whence);
long ftell(FILE *stream);
int feof(FILE *stream);
int ferror(FILE *stream);
void clearerr(FILE *stream);
int fileno(FILE *stream);

void perror(const char *s);

#ifdef __cplusplus
}
#endif
