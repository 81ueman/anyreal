// Minimal LD_PRELOAD probe: log libc socket-family calls to a file.
//
// Used in M5 to decide whether a libc-based NOS daemon (cEOS Bgp) goes through
// libc's socket wrappers (and is therefore LD_PRELOAD-able like upstream REAL),
// or issues raw syscalls (like GoBGP, which needs the seccomp broker).
//
// Build: gcc -shared -fPIC -O2 -o libprobe.so probe.c -ldl
// Use:   copy into the container, add its path to /etc/ld.so.preload, restart.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

static int logfd(void) {
    static int fd = -1;
    if (fd < 0) {
        fd = open("/tmp/anyreal-probe.log", O_CREAT | O_WRONLY | O_APPEND, 0644);
        if (fd < 0) fd = 2;
    }
    return fd;
}

static void plog(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) {
        ssize_t r = write(logfd(), buf, (size_t)n);
        (void)r;
    }
}

typedef int (*socket_fn)(int, int, int);
typedef int (*connect_fn)(int, const struct sockaddr *, socklen_t);
typedef int (*accept4_fn)(int, struct sockaddr *, socklen_t *, int);

int socket(int domain, int type, int protocol) {
    static socket_fn real;
    if (!real) real = (socket_fn)dlsym(RTLD_NEXT, "socket");
    int r = real(domain, type, protocol);
    plog("[probe] socket(%d, 0x%x, %d) = %d\n", domain, type, protocol, r);
    return r;
}

int connect(int fd, const struct sockaddr *addr, socklen_t len) {
    static connect_fn real;
    if (!real) real = (connect_fn)dlsym(RTLD_NEXT, "connect");
    char a[64] = "?";
    if (addr && addr->sa_family == AF_INET) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
        inet_ntop(AF_INET, &in->sin_addr, a, sizeof(a));
        snprintf(a + strlen(a), sizeof(a) - strlen(a), ":%d", ntohs(in->sin_port));
    } else if (addr && addr->sa_family == AF_UNIX) {
        snprintf(a, sizeof(a), "unix:%s", addr->sa_data);
    }
    int r = real(fd, addr, len);
    plog("[probe] connect(fd=%d, %s) = %d errno=%d\n", fd, a, r, errno);
    return r;
}

int accept4(int fd, struct sockaddr *addr, socklen_t *len, int flags) {
    static accept4_fn real;
    if (!real) real = (accept4_fn)dlsym(RTLD_NEXT, "accept4");
    int r = real(fd, addr, len, flags);
    plog("[probe] accept4(fd=%d) = %d\n", fd, r);
    return r;
}
