/* hello-c: smoke test for the Ferrite C toolchain.
 *
 * Exercises (in order):
 *   - puts / printf with width/precision/hex/string/pointer
 *   - open + read + close against /etc/users via fd 3+
 *   - strtol/atoi + ctype.h
 *   - strstr/strdup/strchr
 *   - snprintf into a stack buffer
 *   - fopen/fread/fclose + fputs/fgets (FILE * layer)
 *   - fprintf(stderr)
 *   - time / clock_gettime / strftime
 *   - assert + atexit + getpid + isatty
 */

#include <assert.h>
#include <ctype.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void say_bye(void) {
  fputs("[hello-c] atexit ran\n", stdout);
  fflush(stdout);
}

int main(int argc, char **argv) {
  puts("[hello-c] tier 3 smoke");
  atexit(say_bye);

  printf("argc=%d argv[0]=%s\n", argc, argv[0]);
  printf("hex=0x%08x  ptr=%p  pct=%%  pad=[%-8s]\n", 0xdeadbeefu, (void *)main,
         "hi");
  printf("ll signed: %lld  ll hex: %llx\n", (long long)-12345678901LL,
         0xffffffffffffULL);

  char buf[64];
  int n = snprintf(buf, sizeof buf, "snprintf: %d + %d = %d", 21, 21, 42);
  printf("buf[%d] = %s\n", n, buf);

  char *end;
  long v = strtol("0xCAFE", &end, 0);
  printf("strtol(0xCAFE) = %ld; rest=%s\n", v, end);

  const char *s = "the quick brown fox";
  const char *q = strstr(s, "brown");
  printf("strstr: %s\n", q ? q : "(null)");
  char *dup = strdup("dup-me");
  if (dup)
    printf("strdup: %s len=%zu\n", dup, strlen(dup));

  int letters = 0, digits = 0;
  for (const char *p = "abc123XYZ!?"; *p; p++) {
    if (isalpha((unsigned char)*p))
      letters++;
    if (isdigit((unsigned char)*p))
      digits++;
  }
  printf("ctype: letters=%d digits=%d\n", letters, digits);

  int fd = open("/etc/users", O_RDONLY);
  if (fd < 0) {
    printf("open(/etc/users) failed\n");
    return 1;
  }
  char filebuf[128];
  ssize_t got = read(fd, filebuf, sizeof filebuf);
  close(fd);
  if (got > 0) {
    printf("[hello-c] /etc/users head (%zd bytes):\n", got);
    write(STDOUT_FILENO, filebuf, (size_t)got);
  }

  FILE *f = fopen("/etc/services", "r");
  if (f) {
    char line[128];
    int lines = 0;
    while (lines < 3 && fgets(line, sizeof line, f)) {
      fputs("[svc] ", stdout);
      fputs(line, stdout);
      lines++;
    }
    fclose(f);
    printf("[hello-c] read %d service lines\n", lines);
  } else {
    fputs("[hello-c] fopen(/etc/services) failed\n", stderr);
  }

  time_t now = time(NULL);
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
    printf("[hello-c] mono=%lld.%09lds\n", (long long)ts.tv_sec, ts.tv_nsec);
  }
  struct tm utc;
  if (gmtime_r(&now, &utc)) {
    char tbuf[64];
    strftime(tbuf, sizeof tbuf, "%Y-%m-%d %H:%M:%S UTC", &utc);
    printf("[hello-c] utc=%s (epoch=%" PRId64 ")\n", tbuf, (int64_t)now);
  }

  pid_t pid = getpid();
  printf("[hello-c] pid=%d  stdout-isatty=%d\n", (int)pid,
         isatty(STDOUT_FILENO));
  assert(pid > 0);

  /* Allocate + free a 1 MB segment four times. With SYS_FREE_PAGES
   * working, each cycle returns the segment to the kernel and the
   * heap stays small. Without it, peak usage would grow to 4 MB. */
  for (int j = 0; j < 4; j++) {
    void *big = malloc(1024 * 1024);
    if (!big) {
      printf("[hello-c] malloc(1MB) #%d failed\n", j);
      break;
    }
    ((char *)big)[0] = (char)j;
    ((char *)big)[1024 * 1024 - 1] = (char)j;
    free(big);
  }
  puts("[hello-c] 4x 1MB malloc/free cycles survived");

  /* malloc/free stress: allocate, free, reallocate to exercise
   * coalescing + grow path. */
  void *blocks[64];
  for (int j = 0; j < 64; j++) {
    blocks[j] = malloc(1024);
    if (!blocks[j]) {
      printf("[hello-c] malloc(%d) failed\n", j);
      break;
    }
    ((char *)blocks[j])[0] = (char)j;
  }
  /* Free even-indexed blocks, leaving odd ones, fragments the heap. */
  for (int j = 0; j < 64; j += 2) {
    free(blocks[j]);
    blocks[j] = NULL;
  }
  /* Re-alloc those slots with bigger blocks; should coalesce with their
   * freed twin or grow the heap. */
  for (int j = 0; j < 64; j += 2) {
    blocks[j] = malloc(2048);
    if (!blocks[j]) {
      printf("[hello-c] re-malloc(%d) failed\n", j);
      break;
    }
  }
  char *grow = realloc(blocks[1], 8192);
  printf("[hello-c] heap: 64 alloc + 32 free + 32 realloc OK, grow=%p\n",
         (void *)grow);
  /* Free everything. */
  blocks[1] = grow;
  for (int j = 0; j < 64; j++)
    free(blocks[j]);

  fprintf(stderr, "[hello-c] (this went to stderr)\n");
  return 0;
}
