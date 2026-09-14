// anyreal-run: launch an unmodified target under AnyREAL supervision.
//
//   anyreal-run --node <id> --peers "<self>:<peer>:<peerid>[;...]" \
//               [--relay <unix_path> | --real [--mng <path>]] \
//               [--ripc <dir>] -- <command> [args...]
//
// The child installs a seccomp filter with SECCOMP_FILTER_FLAG_NEW_LISTENER and
// passes the listener fd back over a socketpair; the parent runs the broker.
#include "../broker/broker.h"
#include "../common/sc.h"

#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#include <arpa/inet.h>

#include <cstddef>
#include <string>
#include <vector>

using namespace anyreal;

namespace {

std::vector<sock_filter> build_filter() {
    std::vector<sock_filter> f;
    auto stmt = [&](unsigned short code, unsigned int k) {
        sock_filter s{};
        s.code = code;
        s.jt = 0;
        s.jf = 0;
        s.k = k;
        f.push_back(s);
    };
    auto jump = [&](unsigned short code, unsigned int k, unsigned char jt,
                    unsigned char jf) {
        sock_filter s{};
        s.code = code;
        s.jt = jt;
        s.jf = jf;
        s.k = k;
        f.push_back(s);
    };
    stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
    jump(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_AARCH64, 1, 0);
    stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
    stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
    const int syscalls[] = {
        __NR_socket,     __NR_connect,     __NR_bind,       __NR_listen,
        __NR_accept,     __NR_accept4,     __NR_getsockname, __NR_getpeername,
        __NR_getsockopt, __NR_setsockopt,  __NR_shutdown,   __NR_close,
    };
    for (int sc : syscalls) {
        jump(BPF_JMP | BPF_JEQ | BPF_K, (unsigned int)sc, 0, 1);
        stmt(BPF_RET | BPF_K, SECCOMP_RET_USER_NOTIF);
    }
    stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
    return f;
}

bool send_fd(int sock, int fd) {
    char buf[1] = {0};
    struct iovec iov = {buf, sizeof(buf)};
    char cbuf[CMSG_SPACE(sizeof(int))];
    memset(cbuf, 0, sizeof(cbuf));
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cbuf;
    msg.msg_controllen = sizeof(cbuf);
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd, sizeof(fd));
    return sendmsg(sock, &msg, 0) == (ssize_t)sizeof(buf);
}

int recv_fd(int sock) {
    char buf[1];
    struct iovec iov = {buf, sizeof(buf)};
    char cbuf[CMSG_SPACE(sizeof(int))];
    memset(cbuf, 0, sizeof(cbuf));
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cbuf;
    msg.msg_controllen = sizeof(cbuf);
    if (recvmsg(sock, &msg, 0) <= 0) return -1;
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (!cmsg) return -1;
    int fd = -1;
    memcpy(&fd, CMSG_DATA(cmsg), sizeof(fd));
    return fd;
}

void parse_peers(const std::string &s, std::vector<Peer> *out) {
    size_t pos = 0;
    while (pos < s.size()) {
        size_t semi = s.find(';', pos);
        std::string item = s.substr(pos, semi == std::string::npos ? std::string::npos
                                                                   : semi - pos);
        pos = (semi == std::string::npos) ? s.size() : semi + 1;
        if (item.empty()) continue;
        // self:peer:peerid
        std::vector<std::string> parts;
        size_t p = 0;
        while (p <= item.size()) {
            size_t colon = item.find(':', p);
            parts.push_back(item.substr(p, colon == std::string::npos ? std::string::npos
                                                                      : colon - p));
            if (colon == std::string::npos) break;
            p = colon + 1;
        }
        if (parts.size() != 3) {
            fprintf(stderr, "bad peer spec: %s\n", item.c_str());
            exit(2);
        }
        Peer peer;
        peer.self_addr = inet_addr(parts[0].c_str());
        peer.peer_addr = inet_addr(parts[1].c_str());
        peer.peer_id = atoi(parts[2].c_str());
        out->push_back(peer);
    }
}

} // namespace

int main(int argc, char **argv) {
    BrokerConfig cfg;
    std::vector<std::string> cmd;
    bool saw_dashdash = false;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (saw_dashdash) {
            cmd.push_back(a);
            continue;
        }
        if (a == "--") {
            saw_dashdash = true;
        } else if (a == "--node" && i + 1 < argc) {
            cfg.self_id = atoi(argv[++i]);
        } else if (a == "--peers" && i + 1 < argc) {
            parse_peers(argv[++i], &cfg.peers);
        } else if (a == "--relay" && i + 1 < argc) {
            cfg.relay_path = argv[++i];
            cfg.use_real = false;
        } else if (a == "--real") {
            cfg.use_real = true;
        } else if (a == "--mng" && i + 1 < argc) {
            cfg.mng_socket = argv[++i];
        } else if (a == "--ripc" && i + 1 < argc) {
            cfg.ripc_dir = argv[++i];
        } else {
            fprintf(stderr, "unknown argument: %s\n", a.c_str());
            return 2;
        }
    }
    if (cmd.empty()) {
        fprintf(stderr, "usage: anyreal-run ... -- <command> [args...]\n");
        return 2;
    }

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        perror("socketpair");
        return 1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }
    if (pid == 0) {
        close(sv[0]);
        if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) {
            perror("prctl(NO_NEW_PRIVS)");
            _exit(1);
        }
        std::vector<sock_filter> filter = build_filter();
        struct sock_fprog prog;
        prog.len = (unsigned short)filter.size();
        prog.filter = filter.data();
        int lfd = (int)syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER,
                               SECCOMP_FILTER_FLAG_NEW_LISTENER, &prog);
        if (lfd < 0) {
            perror("seccomp");
            _exit(1);
        }
        if (!send_fd(sv[1], lfd)) {
            perror("sendmsg");
            _exit(1);
        }
        close(lfd);
        close(sv[1]);

        std::vector<char *> cargv;
        for (auto &s : cmd) cargv.push_back(const_cast<char *>(s.c_str()));
        cargv.push_back(nullptr);
        execvp(cargv[0], cargv.data());
        perror("execvp");
        _exit(127);
    }

    close(sv[1]);
    int listener = recv_fd(sv[0]);
    close(sv[0]);
    if (listener < 0) {
        fprintf(stderr, "failed to receive seccomp listener fd\n");
        return 1;
    }

    int rc = run_broker(listener, pid, cfg);
    close(listener);
    return rc;
}
