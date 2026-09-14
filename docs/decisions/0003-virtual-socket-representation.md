# ADR 0003: 仮想 socket の表現（socketpair + ADDFD）

- 状態: Accepted（M2 / M2b / M3 で検証）
- 日付: 2026-09-14

## 文脈

seccomp user notification で `socket()` を捕捉したとき、対象プロセスへ渡す fd の実体を
どうするかで互換性が大きく変わる。PLAN.md §4.3 は「整数の仮想 FD や eventfd を返すだけで
互換性が得られるとは仮定しない」とし、ADDFD で実 FD を渡す案と、その readiness が
仮想 TCP 状態と一致するかを確認することを求めている。

Go runtime は epoll の edge-triggered 通知で socket の readiness を監視するため、
readiness を偽装する方式（eventfd や擬似 fd）は Go の netpoll と整合しないおそれがあった。

## 決定

仮想 socket の実体を **broker が作る socketpair** とし、対象側の端を
`SECCOMP_IOCTL_NOTIF_ADDFD`（`SECCOMP_ADDFD_FLAG_SEND`）で注入する。

- `read` / `write` / `epoll` はカーネルが socketpair 上で処理するため、**捕捉不要**。
  readiness・EOF・edge-triggered 再通知・短い read/write がすべて native に成立する。
- broker はもう片端を持ち、BGP のときだけ `REAL_PAYLOAD` へ framing して controller へ
  中継する。非 BGP（gRPC 等）は実 socket へ raw 中継する。
- `socket` / `connect` / `bind` / `listen` / `accept4` / `getsockname` / `getpeername` /
  `getsockopt` / `setsockopt` / `shutdown` / `close` のみを捕捉し、AF_INET の意味論を
  エミュレートする。
- listener は socketpair では accept できないため、broker が接続到来時に待機 byte を
  書き、`accept4` を捕捉して新しい socketpair を返す。readiness byte は broker が
  保持する app 側 fd の複製から drain する。

## 検証（PLAN.md §5 M2 判定に対応）

| 必須ケース | 結果 |
| --- | --- |
| 接続・双方向通信 | Go echo 100 逐次 + 16 並行 成功 |
| 切断 | close 捕捉で vsock 破棄。EOF も処理 |
| FD 再利用 | 116 接続を同一プロセスで逐次処理して成功 |
| readiness | Go netpoll（edge-triggered）で accept/read がネイティブ動作 |
| 並行性 | 16 並行接続。ただし broker は単一スレッドで、通知処理中の同期 I/O は他を止める |

## 帰結

- data path の性能は kernel の socketpair に依存し、syscall 通知は接続管理に限定される。
- broker が対象より先に死ぬと、フィルタが残った対象の syscall は `ENOSYS` を返す
  （M3 の teardown で観測）。停止順序（対象→broker）を守る必要がある。
- 非 BGP の listener は broker が実 socket を張るため、broker と対象が同一 netns に
  ある場合のみ成立する。netns 分離時は broker 側の setns が必要（残課題）。
