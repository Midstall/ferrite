#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#ifdef NDEBUG
#define assert(expr) ((void)0)
#else
void __assert_fail(const char *expr, const char *file, unsigned line,
                   const char *func) __attribute__((noreturn));
#define assert(expr)                                                           \
  ((expr) ? (void)0 : __assert_fail(#expr, __FILE__, __LINE__, __func__))
#endif

#define static_assert _Static_assert

#ifdef __cplusplus
}
#endif
