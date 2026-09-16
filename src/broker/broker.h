// AnyREAL syscall broker.
//
// Supervises an unmodified target process. The target installs a seccomp filter
// with SECCOMP_FILTER_FLAG_NEW_LISTENER and hands the listener fd back to this
// process. Every intercepted syscall is answered here:
//
//   * socket() is turned into a socketpair whose target-side end is injected
//     with SECCOMP_IOCTL_NOTIF_ADDFD. read()/write()/epoll() therefore stay on
//     the normal kernel path and readiness is native.
//   * connect()/bind()/listen()/accept4()/getsockname()/getpeername()/
//     getsockopt()/setsockopt()/shutdown() are emulated so the socket keeps
//     AF_INET TCP semantics while the bytes travel over the broker's backhaul.
//
// Two backhauls are supported:
//   * "relay": a minimal out-of-process relay used by the M2 experiments.
//   * "real":  the upstream REAL controller protocol (M3).
#pragma once

#include <cstdint>
#include <netinet/in.h>
#include <string>
#include <vector>

namespace anyreal {

struct Peer {
    in_addr_t self_addr = 0;
    in_addr_t peer_addr = 0;
    int peer_id = -1;
};

struct BrokerConfig {
    int self_id = 1;
    std::vector<Peer> peers;   // keyed by peer_id
    std::string relay_path;    // M2 backhaul
    std::string ripc_dir = "/ripc";
    bool use_real = false;     // M3: talk the REAL controller protocol
    std::string mng_socket = "/ripc/msg_manager_socket";
    bool virtualize_inet6 = true; // false: leave AF_INET6 sockets native (cEOS)
};

// Runs the broker loop until the target exits. Returns the target exit status.
int run_broker(int listener_fd, pid_t target_pid, const BrokerConfig &cfg);

} // namespace anyreal
