#pragma once

#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CLOCKS_PER_SEC 1000000L

#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1
#define CLOCK_PROCESS_CPUTIME_ID 2
#define CLOCK_THREAD_CPUTIME_ID 3
#define CLOCK_MONOTONIC_RAW 4
#define CLOCK_BOOTTIME 7

/* clock_t comes from sys/types.h */

struct timespec {
  time_t tv_sec;
  long tv_nsec;
};

struct timeval {
  time_t tv_sec;
  suseconds_t tv_usec;
};

struct tm {
  int tm_sec;
  int tm_min;
  int tm_hour;
  int tm_mday;
  int tm_mon;
  int tm_year;
  int tm_wday;
  int tm_yday;
  int tm_isdst;
  long tm_gmtoff;
  const char *tm_zone;
};

time_t time(time_t *t);
int gettimeofday(struct timeval *tv, void *tz);
int clock_gettime(int clk, struct timespec *ts);
clock_t clock(void);

struct tm *gmtime(const time_t *t);
struct tm *gmtime_r(const time_t *t, struct tm *out);
struct tm *localtime(const time_t *t);
struct tm *localtime_r(const time_t *t, struct tm *out);
time_t mktime(struct tm *tm);
double difftime(time_t end, time_t start);

size_t strftime(char *buf, size_t cap, const char *fmt, const struct tm *tm);

#ifdef __cplusplus
}
#endif
