// Minimal bidirectional relay for the M2 experiments.
//
// It stands in for the REAL controller so the seccomp/socketpair mechanism can
// be validated before controller integration (M3). Protocol: src/common/m2.h.
#include "../common/m2.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <string>
#include <unordered_map>
#include <vector>

using namespace anyreal;

namespace {

int write_all(int fd, const void *buf, size_t n) {
    const char *p = (const char *)buf;
    size_t off = 0;
    while (off < n) {
        ssize_t r = write(fd, p + off, n - off);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)r;
    }
    return 0;
}

int read_all(int fd, void *buf, size_t n) {
    char *p = (char *)buf;
    size_t off = 0;
    while (off < n) {
        ssize_t r = read(fd, p + off, n - off);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) return -1;
        off += (size_t)r;
    }
    return 0;
}

int connect_unix(const std::string &path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    if (path.size() >= sizeof(sa.sun_path)) {
        close(fd);
        return -1;
    }
    memcpy(sa.sun_path, path.c_str(), path.size() + 1);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

struct PendingConnect {
    int fd;
    int cli;
    int svr;
};

int g_epfd;
std::unordered_map<int, std::string> g_listeners;
std::vector<PendingConnect> g_pending;
std::unordered_map<int, int> g_pair;
uint32_t g_next_port = 10000;

void add_epoll(int fd) {
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = EPOLLIN;
    ev.data.fd = fd;
    epoll_ctl(g_epfd, EPOLL_CTL_ADD, fd, &ev);
}

void del_close(int fd) {
    epoll_ctl(g_epfd, EPOLL_CTL_DEL, fd, nullptr);
    close(fd);
}

void pair_them(int client_fd, int cli, int svr) {
    auto it = g_listeners.find(svr);
    if (it == g_listeners.end()) return;
    int lc = connect_unix(it->second);
    if (lc < 0) {
        M2Hdr rej{};
        rej.type = M2_REJECTED;
        write_all(client_fd, &rej, sizeof(rej));
        del_close(client_fd);
        return;
    }
    uint32_t port = g_next_port++;
    M2Hdr acc{};
    acc.type = M2_ACCEPTED;
    acc.a = port;
    if (write_all(client_fd, &acc, sizeof(acc)) < 0) {
        del_close(client_fd);
        del_close(lc);
        return;
    }
    M2Hdr nc{};
    nc.type = M2_NEW_CONN;
    nc.a = (uint32_t)cli;
    nc.b = port;
    if (write_all(lc, &nc, sizeof(nc)) < 0) {
        del_close(client_fd);
        del_close(lc);
        return;
    }
    g_pair[client_fd] = lc;
    g_pair[lc] = client_fd;
    add_epoll(client_fd);
    add_epoll(lc);
    fprintf(stderr, "[relay] paired cli=%d svr=%d (fds %d<->%d port=%u)\n", cli, svr,
            client_fd, lc, port);
}

void flush_pending() {
    for (size_t i = 0; i < g_pending.size();) {
        PendingConnect &p = g_pending[i];
        if (g_listeners.count(p.svr)) {
            int fd = p.fd;
            int cli = p.cli, svr = p.svr;
            g_pending.erase(g_pending.begin() + i);
            pair_them(fd, cli, svr);
        } else {
            ++i;
        }
    }
}

void on_conn(int fd) {
    M2Hdr h{};
    if (read_all(fd, &h, sizeof(h)) < 0) {
        del_close(fd);
        return;
    }
    if (h.type == M2_REG_LISTENER) {
        std::string path;
        path.resize(h.b);
        if (h.b && read_all(fd, &path[0], h.b) < 0) {
            del_close(fd);
            return;
        }
        g_listeners[(int)h.a] = path;
        fprintf(stderr, "[relay] listener id=%u path=%s\n", h.a, path.c_str());
        // Keep the registration fd open; watch it for EOF but do not relay.
        add_epoll(fd);
        flush_pending();
        return;
    }
    if (h.type == M2_CONNECT) {
        int cli = (int)h.a, svr = (int)h.b;
        if (g_listeners.count(svr)) {
            pair_them(fd, cli, svr);
        } else {
            g_pending.push_back({fd, cli, svr});
            fprintf(stderr, "[relay] queued cli=%d svr=%d (no listener yet)\n", cli, svr);
        }
        return;
    }
    del_close(fd);
}

void on_data(int fd) {
    int peer = g_pair[fd];
    char buf[65536];
    ssize_t r = read(fd, buf, sizeof(buf));
    if (r <= 0) {
        del_close(fd);
        g_pair.erase(fd);
        auto it = g_pair.find(peer);
        if (it != g_pair.end()) {
            int p = it->first;
            g_pair.erase(it);
            shutdown(p, SHUT_WR);
            del_close(p);
        }
        return;
    }
    if (write_all(peer, buf, (size_t)r) < 0) {
        del_close(fd);
    }
}

} // namespace

int main(int argc, char **argv) {
    std::string path = "/tmp/anyreal-relay.sock";
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--path") && i + 1 < argc) path = argv[++i];
    }

    g_epfd = epoll_create1(EPOLL_CLOEXEC);
    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0) {
        perror("socket");
        return 1;
    }
    unlink(path.c_str());
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    memcpy(sa.sun_path, path.c_str(), path.size() + 1);
    if (bind(lfd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        perror("bind");
        return 1;
    }
    chmod(path.c_str(), 0666);
    listen(lfd, 128);
    add_epoll(lfd);
    fprintf(stderr, "[relay] listening on %s\n", path.c_str());

    for (;;) {
        struct epoll_event events[64];
        int n = epoll_wait(g_epfd, events, 64, -1);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("epoll_wait");
            return 1;
        }
        for (int i = 0; i < n; ++i) {
            int fd = events[i].data.fd;
            if (fd == lfd) {
                int cfd = accept(lfd, nullptr, nullptr);
                if (cfd < 0) continue;
                on_conn(cfd);
            } else if (g_pair.count(fd)) {
                on_data(fd);
            } else {
                // registration fd or a client whose CONNECT is queued: check EOF.
                char c;
                ssize_t r = recv(fd, &c, 1, MSG_PEEK | MSG_DONTWAIT);
                if (r == 0) del_close(fd);
            }
        }
    }
}
