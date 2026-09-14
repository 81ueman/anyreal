#include "broker.h"

#include "../common/m2.h"
#include "../common/real_proto.h"
#include "../common/sc.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstring>
#include <deque>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace anyreal {
namespace {

volatile sig_atomic_t g_stop = 0;
volatile sig_atomic_t g_debug = 0;

void on_stop_signal(int sig) {
    g_stop = 1;
    if (g_debug) {
        char buf[8];
        buf[0] = 'S';
        buf[1] = 'I';
        buf[2] = 'G';
        buf[3] = (char)('0' + (sig % 10));
        buf[4] = '\n';
        (void)!write(2, buf, 5);
    }
}

constexpr int kMaxFrame = 1 << 16;

void set_nonblock(int fd, bool on) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0) return;
    fcntl(fd, F_SETFL, on ? (fl | O_NONBLOCK) : (fl & ~O_NONBLOCK));
}

// Bound blocking handshake I/O so a missing peer cannot wedge the broker.
void set_timeout(int fd, int seconds) {
    struct timeval tv{seconds, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

int write_all(int fd, const void *buf, size_t n) {
    const char *p = static_cast<const char *>(buf);
    size_t off = 0;
    while (off < n) {
        if (g_stop) return -1;
        ssize_t r = write(fd, p + off, n - off);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += static_cast<size_t>(r);
    }
    return 0;
}

int read_all(int fd, void *buf, size_t n) {
    char *p = static_cast<char *>(buf);
    size_t off = 0;
    while (off < n) {
        if (g_stop) return -1;
        ssize_t r = read(fd, p + off, n - off);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) return -1; // EOF
        off += static_cast<size_t>(r);
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
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(sa.sun_path, path.c_str(), path.size() + 1);
    if (connect(fd, reinterpret_cast<struct sockaddr *>(&sa), sizeof(sa)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

} // namespace

enum class FdKind { BrokerEnd, Backhaul, Listen };

struct VSock {
    int app_fd = -1;
    int app_ref = -1;    // broker's copy of the target-side end (sv[0])
    int broker_end = -1; // broker's end of the data socketpair (sv[1])

    bool is_bgp = false;
    bool is_listener = false;
    bool connected = false;
    int domain = AF_INET;
    int sk_err = 0;
    bool nodelay = true;

    in_addr_t self_addr = 0;
    in_addr_t peer_addr = 0;
    uint16_t self_port = 0;
    uint16_t peer_port = 0;
    int peer_id = -1;

    int backhaul_fd = -1; // established data backhaul
    int listen_fd = -1;   // backhaul listener (virtual) or real AF_INET listener
    bool listen_is_real = false;
    int reg_fd = -1;      // M2: listener registration connection

    struct Pending {
        int fd;
        int peer_id;
        in_addr_t peer_addr;
        uint16_t peer_port;
    };
    std::deque<Pending> pending;
};

struct FdCtx {
    VSock *vs;
    FdKind kind;
};

class Broker {
  public:
    Broker(int listener_fd, pid_t target_pid, const BrokerConfig &cfg)
        : listener_fd_(listener_fd), target_pid_(target_pid), cfg_(cfg) {
        epfd_ = epoll_create1(EPOLL_CLOEXEC);
        for (const auto &p : cfg_.peers) {
            by_peer_id_[p.peer_id] = p;
            by_peer_addr_[p.peer_addr] = p.peer_id;
        }
    }

    int run() {
        if (getenv("ANYREAL_DEBUG")) g_debug = 1;
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = on_stop_signal;
        sigaction(SIGTERM, &sa, nullptr);
        sigaction(SIGINT, &sa, nullptr);
        // Exit promptly when the supervised target dies (also breaks a blocking
        // SECCOMP_IOCTL_NOTIF_RECV, which does not otherwise wake on target exit).
        sigaction(SIGCHLD, &sa, nullptr);
        int rc = run_loop();
        if (getenv("ANYREAL_STATS")) dump_stats();
        return rc;
    }

    int run_loop() {
        struct epoll_event ev;
        memset(&ev, 0, sizeof(ev));
        ev.events = EPOLLIN;
        ev.data.fd = listener_fd_;
        epoll_ctl(epfd_, EPOLL_CTL_ADD, listener_fd_, &ev);
        set_nonblock(listener_fd_, true);

        for (;;) {
            if (g_stop) return 0;
            struct epoll_event events[64];
            int n = epoll_wait(epfd_, events, 64, 100);
            if (n < 0) {
                if (errno == EINTR) continue;
                return 1;
            }
            for (int i = 0; i < n; ++i) {
                int fd = events[i].data.fd;
                if (getenv("ANYREAL_DEBUG")) {
                    auto it = fd_ctx_.find(fd);
                    fprintf(stderr, "[broker] epoll fd=%d kind=%d ev=0x%x\n", fd,
                            it == fd_ctx_.end() ? -1 : (int)it->second.kind,
                            events[i].events);
                }
                if (fd == listener_fd_) {
                    handle_notifications();
                    continue;
                }
                // The fd may have been closed earlier in this same event batch;
                // look it up fresh instead of trusting a stored pointer.
                auto it = fd_ctx_.find(fd);
                if (it == fd_ctx_.end()) continue;
                FdCtx *ctx = &it->second;
                switch (ctx->kind) {
                case FdKind::BrokerEnd:
                    on_broker_end(ctx->vs);
                    break;
                case FdKind::Backhaul:
                    on_backhaul(ctx->vs);
                    break;
                case FdKind::Listen:
                    on_listen(ctx->vs);
                    break;
                }
            }
            int status = 0;
            pid_t r = waitpid(target_pid_, &status, WNOHANG);
            if (r == target_pid_) {
                return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
            }
            if (r < 0 && errno == ECHILD) return 0;
        }
    }

  private:
    // ---- epoll bookkeeping -------------------------------------------------
    FdCtx *track(int fd, VSock *vs, FdKind kind) {
        struct epoll_event ev;
        memset(&ev, 0, sizeof(ev));
        ev.events = EPOLLIN;
        ev.data.fd = fd;
        if (epoll_ctl(epfd_, EPOLL_CTL_ADD, fd, &ev) < 0) {
            return nullptr;
        }
        fd_ctx_[fd] = FdCtx{vs, kind};
        if (getenv("ANYREAL_DEBUG"))
            fprintf(stderr, "[broker] track fd=%d kind=%d\n", fd, (int)kind);
        return &fd_ctx_[fd];
    }

    void untrack(int fd) {
        auto it = fd_ctx_.find(fd);
        if (it == fd_ctx_.end()) return;
        epoll_ctl(epfd_, EPOLL_CTL_DEL, fd, nullptr);
        fd_ctx_.erase(it);
    }

    void destroy(VSock *vs) {
        for (int fd : {vs->backhaul_fd, vs->listen_fd, vs->reg_fd, vs->broker_end,
                       vs->app_ref}) {
            if (fd >= 0) untrack(fd);
        }
        for (auto &p : vs->pending) untrack(p.fd);
        if (vs->backhaul_fd >= 0) close(vs->backhaul_fd);
        if (vs->listen_fd >= 0) close(vs->listen_fd);
        if (vs->reg_fd >= 0) close(vs->reg_fd);
        if (vs->broker_end >= 0) close(vs->broker_end);
        if (vs->app_ref >= 0) close(vs->app_ref);
        for (auto &p : vs->pending) close(p.fd);
        vs->pending.clear();
        if (vs->app_fd >= 0) by_app_fd_.erase(vs->app_fd);
    }

    // ---- notification helpers ---------------------------------------------
    static void resp_ok(struct seccomp_notif_resp *r, uint64_t id, long val) {
        memset(r, 0, sizeof(*r));
        r->id = id;
        r->val = val;
    }
    static void resp_err(struct seccomp_notif_resp *r, uint64_t id, int err) {
        memset(r, 0, sizeof(*r));
        r->id = id;
        r->val = -1;
        r->error = -err;
    }
    static void resp_continue(struct seccomp_notif_resp *r, uint64_t id) {
        memset(r, 0, sizeof(*r));
        r->id = id;
        r->flags = SECCOMP_USER_NOTIF_FLAG_CONTINUE;
    }

    VSock *find(int app_fd) {
        auto it = by_app_fd_.find(app_fd);
        if (getenv("ANYREAL_DEBUG"))
            fprintf(stderr, "[broker] find(%d) map=%zu -> %s\n", app_fd, by_app_fd_.size(),
                    it == by_app_fd_.end() ? "nil" : "hit");
        return it == by_app_fd_.end() ? nullptr : it->second.get();
    }

    const Peer *peer_by_id(int id) {
        auto it = by_peer_id_.find(id);
        return it == by_peer_id_.end() ? nullptr : &it->second;
    }

    // ---- syscall dispatch --------------------------------------------------
    void handle_notifications() {
        // NOTIF_RECV blocks and does not honor O_NONBLOCK; process exactly one
        // notification per epoll readiness so the broker always returns to the
        // event loop. epoll is level-triggered, so queued notifications re-fire.
        struct seccomp_notif req;
        if (notif_recv(listener_fd_, &req) < 0) {
            return;
        }
        struct seccomp_notif_resp resp;
        bool responded = handle(&req, &resp);
        if (responded) notif_send(listener_fd_, &resp);
    }

    bool handle(struct seccomp_notif *n, struct seccomp_notif_resp *resp) {
        notif_total_++;
        syscall_counts_[n->data.nr]++;
        if (getenv("ANYREAL_DEBUG"))
            fprintf(stderr, "[broker] syscall %lld a0=%lld a1=%lld a2=%lld\n",
                    (long long)n->data.nr, (long long)n->data.args[0],
                    (long long)n->data.args[1], (long long)n->data.args[2]);
        switch (n->data.nr) {
        case __NR_socket:
            return do_socket(n, resp);
        case __NR_connect:
            return do_connect(n, resp);
        case __NR_bind:
            return do_bind(n, resp);
        case __NR_listen:
            return do_listen(n, resp);
        case __NR_accept:
        case __NR_accept4:
            return do_accept(n, resp, n->data.nr == __NR_accept4);
        case __NR_getsockname:
            return do_getname(n, resp, true);
        case __NR_getpeername:
            return do_getname(n, resp, false);
        case __NR_getsockopt:
            return do_getsockopt(n, resp);
        case __NR_setsockopt:
            return do_setsockopt(n, resp);
        case __NR_shutdown:
            return do_shutdown(n, resp);
        case __NR_close:
            return do_close(n, resp);
        default:
            resp_continue(resp, n->id);
            return true;
        }
    }

    bool do_socket(struct seccomp_notif *n, struct seccomp_notif_resp *resp) {
        int domain = (int)n->data.args[0];
        int type = (int)n->data.args[1];
        if (getenv("ANYREAL_DEBUG"))
            fprintf(stderr, "[broker] socket domain=%d type=0x%x\n", domain, type);
        if ((domain != AF_INET && domain != AF_INET6) || (type & 0xf) != SOCK_STREAM) {
            resp_continue(resp, n->id);
            return true;
        }
        int sv[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
            resp_err(resp, n->id, errno);
            return true;
        }
        bool nonblock = (type & SOCK_NONBLOCK) != 0;
        set_nonblock(sv[0], nonblock);
        set_nonblock(sv[1], true);
        uint32_t newfd_flags = (type & SOCK_CLOEXEC) ? O_CLOEXEC : 0;
        int appfd = notif_addfd_send(listener_fd_, n->id, (uint32_t)sv[0], newfd_flags);
        if (appfd < 0) {
            close(sv[0]);
            close(sv[1]);
            resp_err(resp, n->id, errno);
            return true;
        }
        if (getenv("ANYREAL_DEBUG"))
            fprintf(stderr, "[broker] socket AF_INET type=0x%x -> appfd=%d\n", type, appfd);
        auto vs = std::make_unique<VSock>();
        vs->app_fd = appfd;
        vs->app_ref = sv[0];
        vs->broker_end = sv[1];
        vs->domain = domain;
        VSock *raw = vs.get();
        by_app_fd_[appfd] = std::move(vs);
        if (getenv("ANYREAL_DEBUG"))
            fprintf(stderr, "[broker] inserted vsock appfd=%d map=%zu\n", appfd,
                    by_app_fd_.size());
        track(sv[1], raw, FdKind::BrokerEnd);
        return false; // ADDFD already sent the response
    }

    // Parses an AF_INET or AF_INET6 (v4-mapped / wildcard) sockaddr from the target.
    bool read_sockaddr(const void *remote, socklen_t len, in_addr_t *v4, uint16_t *port) {
        uint8_t raw[sizeof(struct sockaddr_in6)];
        if (len < 2 || len > sizeof(raw)) return false;
        if (read_mem(target_pid_, remote, raw, len) != (ssize_t)len) return false;
        uint16_t fam = 0;
        memcpy(&fam, raw, 2);
        if (fam == AF_INET) {
            struct sockaddr_in sin;
            memcpy(&sin, raw, sizeof(sin));
            *v4 = sin.sin_addr.s_addr;
            *port = ntohs(sin.sin_port);
            return true;
        }
        if (fam == AF_INET6) {
            struct sockaddr_in6 sin6;
            memset(&sin6, 0, sizeof(sin6));
            memcpy(&sin6, raw, len < sizeof(sin6) ? len : sizeof(sin6));
            *port = ntohs(sin6.sin6_port);
            const uint8_t *b = sin6.sin6_addr.s6_addr;
            bool zero = true;
            for (int i = 0; i < 16; ++i)
                if (b[i]) {
                    zero = false;
                    break;
                }
            if (zero) {
                *v4 = 0;
            } else if (b[10] == 0xff && b[11] == 0xff) {
                memcpy(v4, b + 12, 4);
            } else {
                return false; // pure IPv6 is out of scope for v0.1
            }
            return true;
        }
        return false;
    }

    // Writes an AF_INET or AF_INET6 sockaddr (and addrlen) into the target.
    void write_sockaddr(void *addr, void *addrlen_p, int domain, in_addr_t v4,
                        uint16_t port) {
        if (addr) {
            if (domain == AF_INET6) {
                struct sockaddr_in6 sin6;
                memset(&sin6, 0, sizeof(sin6));
                sin6.sin6_family = AF_INET6;
                sin6.sin6_port = htons(port);
                sin6.sin6_addr.s6_addr[10] = 0xff;
                sin6.sin6_addr.s6_addr[11] = 0xff;
                memcpy(&sin6.sin6_addr.s6_addr[12], &v4, 4);
                write_mem(target_pid_, addr, &sin6, sizeof(sin6));
            } else {
                struct sockaddr_in sin;
                memset(&sin, 0, sizeof(sin));
                sin.sin_family = AF_INET;
                sin.sin_addr.s_addr = v4;
                sin.sin_port = htons(port);
                write_mem(target_pid_, addr, &sin, sizeof(sin));
            }
        }
        if (addrlen_p) {
            socklen_t len = (domain == AF_INET6) ? sizeof(struct sockaddr_in6)
                                                 : sizeof(struct sockaddr_in);
            write_mem(target_pid_, addrlen_p, &len, sizeof(len));
        }
    }

    in_addr_t last_addr_ = 0;

    bool do_bind(struct seccomp_notif *n, struct seccomp_notif_resp *resp) {
        int fd = (int)n->data.args[0];
        VSock *vs = find(fd);
        if (getenv("ANYREAL_DEBUG"))
            fprintf(stderr, "[broker] bind fd=%d vsock=%p\n", fd, (void *)vs);
        if (!vs) {
            resp_continue(resp, n->id);
            return true;
        }
        in_addr_t v4 = 0;
        uint16_t port = 0;
        if (!read_sockaddr((void *)n->data.args[1], (socklen_t)n->data.args[2], &v4,
                           &port)) {
            resp_err(resp, n->id, EFAULT);
            return true;
        }
        vs->self_addr = v4;
        vs->self_port = port;
        vs->is_bgp = (vs->self_port == BGP_PORT);
        if (getenv("ANYREAL_DEBUG"))
            fprintf(stderr, "[broker] bind fd=%d port=%u is_bgp=%d\n", fd, vs->self_port,
                    (int)vs->is_bgp);
        // Go binds a local address for outbound sockets with port 0.
        resp_ok(resp, n->id, 0);
        return true;
    }

    bool do_listen(struct seccomp_notif *n, struct seccomp_notif_resp *resp) {
        int fd = (int)n->data.args[0];
        VSock *vs = find(fd);
        if (!vs) {
            resp_continue(resp, n->id);
            return true;
        }
        vs->is_listener = true;
        if (getenv("ANYREAL_DEBUG"))
            fprintf(stderr, "[broker] listen fd=%d is_bgp=%d\n", fd, (int)vs->is_bgp);
        if (vs->is_bgp) {
            if (setup_virtual_listener(vs) < 0) {
                resp_err(resp, n->id, errno);
                return true;
            }
        } else {
            if (setup_real_listener(vs) < 0) {
                resp_err(resp, n->id, errno);
                return true;
            }
        }
        resp_ok(resp, n->id, 0);
        return true;
    }

    bool do_connect(struct seccomp_notif *n, struct seccomp_notif_resp *resp) {
        int fd = (int)n->data.args[0];
        VSock *vs = find(fd);
        if (!vs) {
            resp_continue(resp, n->id);
            return true;
        }
        uint16_t port = 0;
        in_addr_t addr = 0;
        if (!read_sockaddr((void *)n->data.args[1], (socklen_t)n->data.args[2], &addr,
                           &port)) {
            resp_err(resp, n->id, EFAULT);
            return true;
        }
        bool is_bgp = (port == BGP_PORT) || by_peer_addr_.count(addr);

        if (is_bgp) {
            int peer_id = -1;
            auto it = by_peer_addr_.find(addr);
            if (it != by_peer_addr_.end()) peer_id = it->second;
            if (peer_id < 0) {
                // 127.0.0.1 self connection or unknown: fall back to real proxy.
                if (proxy_real_connect(vs, addr, port) < 0) {
                    resp_err(resp, n->id, ECONNREFUSED);
                    return true;
                }
                resp_ok(resp, n->id, 0);
                return true;
            }
            vs->is_bgp = true;
            vs->peer_id = peer_id;
            vs->peer_addr = addr;
            vs->peer_port = port;
            const Peer *p = peer_by_id(peer_id);
            if (p) vs->self_addr = p->self_addr;
            int bh = backhaul_connect(vs);
            if (bh < 0) {
                vs->sk_err = ECONNREFUSED;
                resp_err(resp, n->id, ECONNREFUSED);
                return true;
            }
            vs->backhaul_fd = bh;
            vs->connected = true;
            track(bh, vs, FdKind::Backhaul);
            resp_ok(resp, n->id, 0);
            return true;
        }

        if (proxy_real_connect(vs, addr, port) < 0) {
            resp_err(resp, n->id, ECONNREFUSED);
            return true;
        }
        vs->connected = true;
        resp_ok(resp, n->id, 0);
        return true;
    }

    int proxy_real_connect(VSock *vs, in_addr_t addr, uint16_t port) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        struct sockaddr_in sin;
        memset(&sin, 0, sizeof(sin));
        sin.sin_family = AF_INET;
        sin.sin_addr.s_addr = addr;
        sin.sin_port = htons(port);
        if (connect(fd, reinterpret_cast<struct sockaddr *>(&sin), sizeof(sin)) < 0) {
            close(fd);
            return -1;
        }
        set_nonblock(fd, true);
        vs->backhaul_fd = fd;
        vs->peer_addr = addr;
        vs->peer_port = port;
        track(fd, vs, FdKind::Backhaul);
        return 0;
    }

    bool do_accept(struct seccomp_notif *n, struct seccomp_notif_resp *resp,
                   bool is_accept4) {
        int fd = (int)n->data.args[0];
        VSock *vs = find(fd);
        if (getenv("ANYREAL_DEBUG"))
            fprintf(stderr, "[broker] accept fd=%d listener=%d pending=%zu\n", fd,
                    vs ? (int)vs->is_listener : -1, vs ? vs->pending.size() : 0);
        if (!vs || !vs->is_listener) {
            resp_continue(resp, n->id);
            return true;
        }
        if (vs->pending.empty()) {
            resp_err(resp, n->id, EAGAIN);
            return true;
        }
        VSock::Pending p = vs->pending.front();
        vs->pending.pop_front();

        // Fill the peer address before handing the fd back. Our peers are IPv4,
        // so report an AF_INET peer even when the listener was dual-stack
        // (GoBGP matches neighbors by IPv4 address).
        if (n->data.args[1] != 0) {
            write_sockaddr((void *)n->data.args[1], (void *)n->data.args[2], AF_INET,
                           p.peer_addr, p.peer_port);
        }

        int sv[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
            resp_err(resp, n->id, errno);
            return true;
        }
        set_nonblock(sv[0], true);
        set_nonblock(sv[1], true);
        int flags = is_accept4 ? (int)n->data.args[3] : 0;
        uint32_t newfd_flags = (flags & SOCK_CLOEXEC) ? O_CLOEXEC : 0;
        int appfd = notif_addfd_send(listener_fd_, n->id, (uint32_t)sv[0], newfd_flags);
        if (appfd < 0) {
            if (getenv("ANYREAL_DEBUG"))
                fprintf(stderr, "[broker] accept ADDFD failed: %s\n", strerror(errno));
            close(sv[0]);
            close(sv[1]);
            resp_err(resp, n->id, errno);
            return true;
        }
        // Drain the readiness byte we wrote into the listener socketpair.
        char c;
        (void)read(vs->app_ref, &c, 1);

        auto nv = std::make_unique<VSock>();
        nv->app_fd = appfd;
        nv->app_ref = sv[0];
        nv->broker_end = sv[1];
        nv->is_bgp = vs->is_bgp;
        nv->connected = true;
        nv->domain = AF_INET;
        nv->peer_id = p.peer_id;
        nv->peer_addr = p.peer_addr;
        nv->peer_port = p.peer_port;
        nv->self_addr = vs->self_addr;
        nv->self_port = vs->self_port;
        nv->backhaul_fd = p.fd;
        VSock *raw = nv.get();
        by_app_fd_[appfd] = std::move(nv);
        track(sv[1], raw, FdKind::BrokerEnd);
        track(p.fd, raw, FdKind::Backhaul);
        return false; // ADDFD already sent the response
    }

    bool do_getname(struct seccomp_notif *n, struct seccomp_notif_resp *resp,
                    bool self) {
        int fd = (int)n->data.args[0];
        VSock *vs = find(fd);
        if (!vs) {
            resp_continue(resp, n->id);
            return true;
        }
        if (!self && !vs->connected) {
            resp_err(resp, n->id, ENOTCONN);
            return true;
        }
        void *addr = (void *)n->data.args[1];
        void *addrlen = (void *)n->data.args[2];
        write_sockaddr(addr, addrlen, vs->domain,
                       self ? vs->self_addr : vs->peer_addr,
                       self ? vs->self_port : vs->peer_port);
        resp_ok(resp, n->id, 0);
        return true;
    }

    bool do_getsockopt(struct seccomp_notif *n, struct seccomp_notif_resp *resp) {
        int fd = (int)n->data.args[0];
        VSock *vs = find(fd);
        if (!vs) {
            resp_continue(resp, n->id);
            return true;
        }
        int level = (int)n->data.args[1];
        int opt = (int)n->data.args[2];
        void *optval = (void *)n->data.args[3];
        void *optlen_p = (void *)n->data.args[4];
        socklen_t optlen = 0;
        if (optlen_p) read_mem(target_pid_, optlen_p, &optlen, sizeof(optlen));

        char buf[256];
        memset(buf, 0, sizeof(buf));
        socklen_t out = 0;
        auto put_int = [&](int v) {
            memcpy(buf, &v, sizeof(v));
            out = sizeof(v);
        };
        if (level == SOL_SOCKET) {
            switch (opt) {
            case SO_ERROR:
                put_int(vs->sk_err);
                vs->sk_err = 0;
                break;
            case SO_TYPE:
                put_int(SOCK_STREAM);
                break;
            case SO_DOMAIN:
                put_int(AF_INET);
                break;
            case SO_PROTOCOL:
                put_int(IPPROTO_TCP);
                break;
            case SO_SNDBUF:
            case SO_RCVBUF:
                put_int(65536);
                break;
            case SO_ACCEPTCONN:
                put_int(vs->is_listener ? 1 : 0);
                break;
            case SO_REUSEADDR:
                put_int(1);
                break;
            case SO_KEEPALIVE:
                put_int(0);
                break;
            default:
                out = optlen;
                break;
            }
        } else if (level == IPPROTO_TCP) {
            switch (opt) {
            case TCP_NODELAY:
                put_int(vs->nodelay ? 1 : 0);
                break;
            case TCP_MAXSEG:
                put_int(1500);
                break;
            case TCP_INFO:
                out = sizeof(struct tcp_info);
                break;
            default:
                out = optlen;
                break;
            }
        } else {
            out = optlen;
        }
        if (out > optlen && optlen != 0) out = optlen;
        if (out > sizeof(buf)) out = sizeof(buf);
        if (optval && out) write_mem(target_pid_, optval, buf, out);
        if (optlen_p) write_mem(target_pid_, optlen_p, &out, sizeof(out));
        resp_ok(resp, n->id, 0);
        return true;
    }

    bool do_setsockopt(struct seccomp_notif *n, struct seccomp_notif_resp *resp) {
        int fd = (int)n->data.args[0];
        VSock *vs = find(fd);
        if (!vs) {
            resp_continue(resp, n->id);
            return true;
        }
        int level = (int)n->data.args[1];
        int opt = (int)n->data.args[2];
        if (level == IPPROTO_TCP && opt == TCP_NODELAY) {
            int v = 0;
            read_mem(target_pid_, (void *)n->data.args[3], &v, sizeof(v));
            vs->nodelay = v != 0;
        }
        resp_ok(resp, n->id, 0);
        return true;
    }

    bool do_shutdown(struct seccomp_notif *n, struct seccomp_notif_resp *resp) {
        int fd = (int)n->data.args[0];
        VSock *vs = find(fd);
        if (!vs) {
            resp_continue(resp, n->id);
            return true;
        }
        int how = (int)n->data.args[1];
        if (vs->broker_end >= 0 && (how == SHUT_WR || how == SHUT_RDWR)) {
            shutdown(vs->broker_end, SHUT_WR);
        }
        resp_ok(resp, n->id, 0);
        return true;
    }

    bool do_close(struct seccomp_notif *n, struct seccomp_notif_resp *resp) {
        int fd = (int)n->data.args[0];
        auto it = by_app_fd_.find(fd);
        if (it != by_app_fd_.end()) {
            destroy(it->second.get());
        }
        resp_continue(resp, n->id);
        return true;
    }

    // ---- listener setup ----------------------------------------------------
    std::string ripc_path(const std::string &suffix) {
        return cfg_.ripc_dir + "/emu-real-" + std::to_string(cfg_.self_id) + "/" + suffix;
    }

    int setup_virtual_listener(VSock *vs) {
        std::string path = ripc_path("listener:" + std::to_string(vs->self_port));
        mkdir(cfg_.ripc_dir.c_str(), 0777);
        mkdir((cfg_.ripc_dir + "/emu-real-" + std::to_string(cfg_.self_id)).c_str(), 0777);
        unlink(path.c_str());
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        struct sockaddr_un sa;
        memset(&sa, 0, sizeof(sa));
        sa.sun_family = AF_UNIX;
        if (path.size() >= sizeof(sa.sun_path)) {
            close(fd);
            errno = ENAMETOOLONG;
            return -1;
        }
        memcpy(sa.sun_path, path.c_str(), path.size() + 1);
        if (bind(fd, reinterpret_cast<struct sockaddr *>(&sa), sizeof(sa)) < 0) {
            close(fd);
            return -1;
        }
        if (listen(fd, 1000) < 0) {
            close(fd);
            return -1;
        }
        chmod(path.c_str(), 0666);
        set_nonblock(fd, true);
        vs->listen_fd = fd;
        track(fd, vs, FdKind::Listen);

        if (!cfg_.use_real) {
            // Register this listener with the M2 relay.
            int reg = connect_unix(cfg_.relay_path);
            if (reg < 0) {
                if (getenv("ANYREAL_DEBUG"))
                    fprintf(stderr, "[broker] relay connect failed: %s\n", strerror(errno));
                return -1;
            }
            M2Hdr h{};
            h.type = M2_REG_LISTENER;
            h.a = (uint32_t)cfg_.self_id;
            h.b = (uint32_t)path.size();
            if (write_all(reg, &h, sizeof(h)) < 0 ||
                write_all(reg, path.data(), path.size()) < 0) {
                close(reg);
                return -1;
            }
            if (getenv("ANYREAL_DEBUG"))
                fprintf(stderr, "[broker] registered listener id=%d path=%s\n",
                        cfg_.self_id, path.c_str());
            vs->reg_fd = reg;
        }
        return 0;
    }

    int setup_real_listener(VSock *vs) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in sin;
        memset(&sin, 0, sizeof(sin));
        sin.sin_family = AF_INET;
        sin.sin_addr.s_addr = vs->self_addr;
        sin.sin_port = htons(vs->self_port);
        if (bind(fd, reinterpret_cast<struct sockaddr *>(&sin), sizeof(sin)) < 0) {
            close(fd);
            return -1;
        }
        if (listen(fd, 128) < 0) {
            close(fd);
            return -1;
        }
        set_nonblock(fd, true);
        vs->listen_fd = fd;
        vs->listen_is_real = true;
        track(fd, vs, FdKind::Listen);
        return 0;
    }

    // ---- backhaul ----------------------------------------------------------
    int backhaul_connect(VSock *vs) {
        if (!cfg_.use_real) {
            int fd = connect_unix(cfg_.relay_path);
            if (fd < 0) return -1;
            set_timeout(fd, 5);
            M2Hdr h{};
            h.type = M2_CONNECT;
            h.a = (uint32_t)cfg_.self_id;
            h.b = (uint32_t)vs->peer_id;
            if (write_all(fd, &h, sizeof(h)) < 0) {
                close(fd);
                return -1;
            }
            M2Hdr r{};
            if (read_all(fd, &r, sizeof(r)) < 0) {
                close(fd);
                return -1;
            }
            if (r.type == M2_REJECTED) {
                close(fd);
                return -1;
            }
            if (r.type != M2_ACCEPTED) {
                close(fd);
                return -1;
            }
            vs->self_port = (uint16_t)r.a;
            set_nonblock(fd, true);
            return fd;
        }
        // REAL controller: bind <ripc>/emu-real-<self>/<peer>, send SYN, wait SYNACK.
        std::string srcpath = ripc_path(std::to_string(vs->peer_id));
        mkdir(cfg_.ripc_dir.c_str(), 0777);
        mkdir((cfg_.ripc_dir + "/emu-real-" + std::to_string(cfg_.self_id)).c_str(), 0777);
        unlink(srcpath.c_str());
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        struct sockaddr_un sa;
        memset(&sa, 0, sizeof(sa));
        sa.sun_family = AF_UNIX;
        if (srcpath.size() >= sizeof(sa.sun_path)) {
            close(fd);
            return -1;
        }
        memcpy(sa.sun_path, srcpath.c_str(), srcpath.size() + 1);
        bind(fd, reinterpret_cast<struct sockaddr *>(&sa), sizeof(sa));
        if (connect_unix_into(fd, cfg_.mng_socket) < 0) {
            close(fd);
            return -1;
        }
        set_timeout(fd, 5);
        real_syn_t syn;
        memset(&syn, 0, sizeof(syn));
        syn.hdr.msg_type = REAL_SYN;
        syn.hdr.msg_len = synsiz;
        syn.cli_id = cfg_.self_id;
        syn.svr_id = vs->peer_id;
        if (write_all(fd, &syn, synsiz) < 0) {
            close(fd);
            return -1;
        }
        real_synack_t ack;
        if (read_all(fd, &ack, synacksiz) < 0) {
            close(fd);
            return -1;
        }
        if (ack.cli_port == 0) {
            close(fd);
            return -1;
        }
        vs->self_port = ack.cli_port;
        return fd;
    }

    int connect_unix_into(int fd, const std::string &path) {
        struct sockaddr_un sa;
        memset(&sa, 0, sizeof(sa));
        sa.sun_family = AF_UNIX;
        if (path.size() >= sizeof(sa.sun_path)) return -1;
        memcpy(sa.sun_path, path.c_str(), path.size() + 1);
        return connect(fd, reinterpret_cast<struct sockaddr *>(&sa), sizeof(sa));
    }

    // ---- epoll events ------------------------------------------------------
    void on_broker_end(VSock *vs) {
        char buf[kMaxFrame];
        ssize_t r = read(vs->broker_end, buf, sizeof(buf));
        if (r <= 0) return;
        bytes_to_backhaul_ += r;
        if (vs->backhaul_fd < 0) return;
        if (cfg_.use_real && vs->is_bgp) {
            real_pld_t pld;
            memset(&pld, 0, sizeof(pld));
            pld.hdr.msg_type = REAL_PAYLOAD;
            pld.hdr.msg_len = (int32_t)r + pldhdrsiz;
            pld.src_id = cfg_.self_id;
            pld.dst_id = vs->peer_id;
            struct iovec iov[2];
            iov[0].iov_base = &pld;
            iov[0].iov_len = pldhdrsiz;
            iov[1].iov_base = buf;
            iov[1].iov_len = (size_t)r;
            writev_all(vs->backhaul_fd, iov, 2);
        } else {
            write_all(vs->backhaul_fd, buf, (size_t)r);
        }
    }

    static void writev_all(int fd, struct iovec *iov, int n) {
        ssize_t total = 0;
        for (int i = 0; i < n; ++i) total += (ssize_t)iov[i].iov_len;
        ssize_t written = 0;
        while (written < total) {
            ssize_t w = writev(fd, iov, n);
            if (w < 0) {
                if (errno == EINTR) continue;
                return;
            }
            written += w;
            // Advance iov (simple case: total is small enough for one writev
            // in practice; re-issue from scratch is avoided by zeroing).
            if (written < total) break;
        }
    }

    void on_backhaul(VSock *vs) {
        if (cfg_.use_real && vs->is_bgp) {
            real_pld_t pld;
            if (read_all(vs->backhaul_fd, &pld, pldhdrsiz) < 0) {
                shutdown(vs->broker_end, SHUT_WR);
                return;
            }
            if (pld.hdr.msg_type != REAL_PAYLOAD) {
                int skip = pld.hdr.msg_len - pldhdrsiz;
                char tmp[4096];
                while (skip > 0) {
                    int c = skip > (int)sizeof(tmp) ? (int)sizeof(tmp) : skip;
                    if (read_all(vs->backhaul_fd, tmp, c) < 0) return;
                    skip -= c;
                }
                return;
            }
            int len = pld.hdr.msg_len - pldhdrsiz;
            char buf[kMaxFrame];
            if (len < 0 || len > (int)sizeof(buf)) {
                // drain
                return;
            }
            if (read_all(vs->backhaul_fd, buf, (size_t)len) < 0) return;
            bytes_to_app_ += len;
            write_all(vs->broker_end, buf, (size_t)len);
            return;
        }
        char buf[kMaxFrame];
        ssize_t r = read(vs->backhaul_fd, buf, sizeof(buf));
        if (r <= 0) {
            shutdown(vs->broker_end, SHUT_WR);
            return;
        }
        bytes_to_app_ += r;
        write_all(vs->broker_end, buf, (size_t)r);
    }

    void on_listen(VSock *vs) {
        if (vs->listen_is_real) {
            struct sockaddr_in sin;
            socklen_t slen = sizeof(sin);
            int cfd = accept(vs->listen_fd, reinterpret_cast<struct sockaddr *>(&sin), &slen);
            if (cfd < 0) return;
            set_nonblock(cfd, true);
            VSock::Pending p;
            p.fd = cfd;
            p.peer_id = -1;
            p.peer_addr = sin.sin_addr.s_addr;
            p.peer_port = ntohs(sin.sin_port);
            vs->pending.push_back(p);
            signal_accept(vs);
            return;
        }
        int cfd = accept(vs->listen_fd, nullptr, nullptr);
        if (cfd < 0) return;
        set_timeout(cfd, 5);
        VSock::Pending p;
        p.fd = cfd;
        p.peer_id = -1;
        p.peer_addr = 0;
        p.peer_port = 0;
        if (cfg_.use_real) {
            real_syn_t syn;
            if (read_all(cfd, &syn, synsiz) < 0) {
                close(cfd);
                return;
            }
            p.peer_id = syn.cli_id;
            p.peer_port = syn.cli_port;
        } else {
            M2Hdr h{};
            if (read_all(cfd, &h, sizeof(h)) < 0 || h.type != M2_NEW_CONN) {
                close(cfd);
                return;
            }
            p.peer_id = (int)h.a;
            p.peer_port = (uint16_t)h.b;
        }
        const Peer *peer = peer_by_id(p.peer_id);
        if (peer) p.peer_addr = peer->peer_addr;
        set_nonblock(cfd, true);
        vs->pending.push_back(p);
        if (getenv("ANYREAL_DEBUG"))
            fprintf(stderr, "[broker] on_listen accepted peer_id=%d port=%d pending=%zu\n",
                    p.peer_id, p.peer_port, vs->pending.size());
        signal_accept(vs);
    }

    void signal_accept(VSock *vs) {
        char c = 0;
        ssize_t r = write(vs->broker_end, &c, 1);
        if (getenv("ANYREAL_DEBUG"))
            fprintf(stderr, "[broker] signal_accept write=%zd errno=%d\n", r, errno);
    }

    void dump_stats() {
        fprintf(stderr,
                "[anyreal-stats] self_id=%d notifications=%ld bytes_to_backhaul=%ld "
                "bytes_to_app=%ld\n",
                cfg_.self_id, notif_total_, bytes_to_backhaul_, bytes_to_app_);
        for (const auto &kv : syscall_counts_) {
            fprintf(stderr, "[anyreal-stats]   syscall %ld: %d\n", kv.first, kv.second);
        }
    }

    long notif_total_ = 0;
    long bytes_to_backhaul_ = 0;
    long bytes_to_app_ = 0;
    std::unordered_map<long, int> syscall_counts_;

    int listener_fd_;
    pid_t target_pid_;
    BrokerConfig cfg_;
    int epfd_ = -1;
    std::unordered_map<int, std::unique_ptr<VSock>> by_app_fd_;
    std::unordered_map<int, FdCtx> fd_ctx_;
    std::unordered_map<int, Peer> by_peer_id_;
    std::unordered_map<in_addr_t, int> by_peer_addr_;
};

int run_broker(int listener_fd, pid_t target_pid, const BrokerConfig &cfg) {
    Broker b(listener_fd, target_pid, cfg);
    return b.run();
}

} // namespace anyreal
