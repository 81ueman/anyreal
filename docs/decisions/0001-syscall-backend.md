# ADR 0001: syscall backend の選定（提案）

- 状態: Proposed（M2 の結果待ち）
- 日付: 2026-09-14

## 文脈

GoBGP は Go runtime から直接 syscall を発行し、libc の socket 関数を通らない。
REAL 上流の `LD_PRELOAD` 方式では接続・read/write を捕捉できないため、別の入口が要る。

## 決定（候補）

**seccomp user notification + プロセス外 broker** を第一候補とする。
Launcher が対象プロセスに `SECCOMP_FILTER_FLAG_NEW_LISTENER` 付きで filter を入れ、
得た listener fd を broker（別プロセス or 親）へ渡す。broker は `SECCOMP_IOCTL_NOTIF_RECV`
で通知を受け、`SECCOMP_USER_NOTIF_FLAG_CONTINUE` か、`SECCOMP_IOCTL_NOTIF_SEND` +
`SECCOMP_IOCTL_NOTIF_ADDFD` で応答する。

### 仮想 socket の表現

- アプリ側 fd は broker が作った **socketpair の片端**を `ADDFD` で注入したもの。
  これにより `read`/`write`/`epoll` は通常の kernel 経路で動き、data を毎回 syscall 通知で
  扱わずに済む。readiness も kernel が保証する。
- broker はもう片端を保持し、`REAL_PAYLOAD` へ framing して controller へ中継する。
- `socket`/`connect`/`bind`/`listen`/`accept4`/`getsockname`/`getpeername`/
  `getsockopt`/`setsockopt`/`shutdown` のみ通知を横取りする。
- BGP 判定は port 179 だけでなく peer アドレスと FD 種別で行い、gRPC API 等の
  AF_INET 通信は通常動作を保つ（broker 経由で proxy するか `CONTINUE` する）。

## 代替

| 方式 | 利点 | 欠点 |
| --- | --- | --- |
| ptrace | 実装が容易 | 停止・再開コスト、並行性 |
| eBPF | 観測は可能 | socket の返値・FD の意味を置換できない |
| kernel module | 完全な制御 | 配布・保守コスト |

## 帰結

M2 で readiness・並行性・FD 寿命の必須ケースを通せた場合のみ採用する。
失敗する最小ケースが残る場合は socketpair 表現や ptrace と比較する。
