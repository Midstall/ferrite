#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

void *malloc(size_t size);
void *calloc(size_t nmemb, size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);

void exit(int status) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));
void _Exit(int status) __attribute__((noreturn));

int atexit(void (*func)(void));

int atoi(const char *s);
long atol(const char *s);
long long atoll(const char *s);
long strtol(const char *s, char **endp, int base);
long long strtoll(const char *s, char **endp, int base);
unsigned long strtoul(const char *s, char **endp, int base);
unsigned long long strtoull(const char *s, char **endp, int base);

int abs(int n);
long labs(long n);
long long llabs(long long n);

void *bsearch(const void *key, const void *base, size_t nmemb, size_t size,
              int (*compare)(const void *, const void *));
void qsort(void *base, size_t nmemb, size_t size,
           int (*compare)(const void *, const void *));

char *getenv(const char *name);
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);

int rand(void);
void srand(unsigned seed);

#ifdef __cplusplus
}
#endif
