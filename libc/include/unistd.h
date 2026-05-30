#pragma once

#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
int close(int fd);

off_t lseek(int fd, off_t offset, int whence);

int dup(int oldfd);
int dup2(int oldfd, int newfd);

int pipe(int pipefd[2]);

pid_t fork(void);
pid_t getpid(void);
pid_t getppid(void);

uid_t getuid(void);
uid_t geteuid(void);
gid_t getgid(void);
gid_t getegid(void);

int execve(const char *path, char *const argv[], char *const envp[]);
int execv(const char *path, char *const argv[]);
int execvp(const char *file, char *const argv[]);

unsigned sleep(unsigned seconds);
int usleep(unsigned long usec);

int isatty(int fd);
char *getcwd(char *buf, size_t size);
int chdir(const char *path);
int unlink(const char *path);

#ifdef __cplusplus
}
#endif
