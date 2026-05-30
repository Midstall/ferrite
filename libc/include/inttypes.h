#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* PRI{d,i,u,o,x,X}{8,16,32,64,MAX,PTR} format-specifier macros for
 * printf/scanf. Sized to LP64 since Ferrite is 64-bit (or 32-bit on
 * riscv32/i386, where long stays "l" and long long stays "ll"). */

#define PRId8 "d"
#define PRIi8 "i"
#define PRIu8 "u"
#define PRIo8 "o"
#define PRIx8 "x"
#define PRIX8 "X"

#define PRId16 "d"
#define PRIi16 "i"
#define PRIu16 "u"
#define PRIo16 "o"
#define PRIx16 "x"
#define PRIX16 "X"

#define PRId32 "d"
#define PRIi32 "i"
#define PRIu32 "u"
#define PRIo32 "o"
#define PRIx32 "x"
#define PRIX32 "X"

#if __SIZEOF_LONG__ == 8
#define __PRI64 "l"
#else
#define __PRI64 "ll"
#endif

#define PRId64 __PRI64 "d"
#define PRIi64 __PRI64 "i"
#define PRIu64 __PRI64 "u"
#define PRIo64 __PRI64 "o"
#define PRIx64 __PRI64 "x"
#define PRIX64 __PRI64 "X"

#define PRIdMAX PRId64
#define PRIiMAX PRIi64
#define PRIuMAX PRIu64
#define PRIoMAX PRIo64
#define PRIxMAX PRIx64
#define PRIXMAX PRIX64

#if __SIZEOF_POINTER__ == 8
#define PRIdPTR __PRI64 "d"
#define PRIiPTR __PRI64 "i"
#define PRIuPTR __PRI64 "u"
#define PRIxPTR __PRI64 "x"
#define PRIXPTR __PRI64 "X"
#else
#define PRIdPTR "d"
#define PRIiPTR "i"
#define PRIuPTR "u"
#define PRIxPTR "x"
#define PRIXPTR "X"
#endif

intmax_t strtoimax(const char *nptr, char **endptr, int base);
uintmax_t strtoumax(const char *nptr, char **endptr, int base);

#ifdef __cplusplus
}
#endif
