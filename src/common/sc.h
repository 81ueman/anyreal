// seccomp user-notification and cross-process memory helpers.
#pragma once

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/uio.h>

namespace anyreal {

inline int notif_recv(int listener, struct seccomp_notif *n) {
    memset(n, 0, sizeof(*n));
    return ioctl(listener, SECCOMP_IOCTL_NOTIF_RECV, n);
}

inline int notif_send(int listener, struct seccomp_notif_resp *r) {
    return ioctl(listener, SECCOMP_IOCTL_NOTIF_SEND, r);
}

inline int notif_id_valid(int listener, uint64_t id) {
    return ioctl(listener, SECCOMP_IOCTL_NOTIF_ID_VALID, &id);
}

// Install srcfd into the target as a new fd. Returns the new fd number in the
// target, or -1 on error.
inline int notif_addfd_send(int listener, uint64_t id, uint32_t srcfd,
                            uint32_t newfd_flags) {
    struct seccomp_notif_addfd a;
    memset(&a, 0, sizeof(a));
    a.id = id;
    a.flags = SECCOMP_ADDFD_FLAG_SEND;
    a.srcfd = srcfd;
    a.newfd = 0;
    a.newfd_flags = newfd_flags;
    return ioctl(listener, SECCOMP_IOCTL_NOTIF_ADDFD, &a);
}

inline ssize_t read_mem(pid_t pid, const void *remote, void *local, size_t n) {
    struct iovec li{local, n};
    struct iovec ri{const_cast<void *>(remote), n};
    return process_vm_readv(pid, &li, 1, &ri, 1, 0);
}

inline ssize_t write_mem(pid_t pid, void *remote, const void *local, size_t n) {
    struct iovec li{const_cast<void *>(local), n};
    struct iovec ri{remote, n};
    return process_vm_writev(pid, &li, 1, &ri, 1, 0);
}

} // namespace anyreal
