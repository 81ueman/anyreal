# 対応表（Compatibility）

対象 NOS・版・ABI・利用した機能・実験結果を記録する。値は実験で確認できたものだけを
「確認済み」とし、それ以外は仮説として明示する。

## 環境

| 項目 | 値 | 状態 |
| --- | --- | --- |
| ホスト | macOS 26.2 / Apple Silicon (arm64) | 確認済み |
| 実行環境 | OrbStack 上の Ubuntu 24.04.4 LTS (aarch64) コンテナ（privileged） | 確認済み |
| kernel | `7.0.11-orbstack`（OrbStack 内 Linux） | 確認済み |
| seccomp `actions_avail` | `kill_process kill_thread trap errno user_notif trace log allow` | 確認済み |
| seccomp user notification | native aarch64 で動作。`socket/connect/bind/listen/accept4/getsockname/getpeername/getsockopt/setsockopt/shutdown/close` を捕捉 | 確認済み |
| `SECCOMP_IOCTL_NOTIF_ADDFD` + `SECCOMP_ADDFD_FLAG_SEND` | 動作（socketpair の片端を対象プロセスへ注入） | 確認済み |
| x86_64 CPU エミュレーション | OrbStack/Rosetta で amd64 コンテナは起動できるが、seccomp filter のロードが常に `EINVAL`（trivial な `RET ALLOW` でも失敗）。基準実験には使わない | 確認済み |

P-1 の計測: OrbStack/Rosetta 上の amd64 `gcc:14` で `seccomp(SECCOMP_SET_MODE_FILTER, 0, &prog)`
が `EINVAL`。native aarch64 では同じコードが成功し、`SECCOMP_RET_ERRNO` が発火した。
→ 本 PoC は native ARM64 を主環境とする（PLAN.md §3 と一致）。

## GoBGP

| 項目 | 値 | 状態 |
| --- | --- | --- |
| 版 | v4.9.0（tag `v4.9.0`, commit `01c5c4c`） | 確認済み |
| ビルド | `CGO_ENABLED=0 go build ./cmd/gobgpd`（Linux/arm64, statically linked） | 確認済み |
| native 2 ノード | netns + veth で Established、192.168.1.0/24 の広告・撤回を確認 | 確認済み（M1） |
| syscall | 未採取 | TODO（M1） |

## AnyREAL broker（PoC 1）

| 項目 | 値 | 状態 |
| --- | --- | --- |
| 監視方式 | Launcher が子で `SECCOMP_FILTER_FLAG_NEW_LISTENER`、listener fd を SCM_RIGHTS で broker へ | 確認済み |
| 仮想 socket | socketpair の片端を `ADDFD`。read/write/epoll は native 経路 | 確認済み |
| AF_INET / AF_INET6 | Go のワイルドカード listen は IPv6 dual-stack になるため両方を仮想化（v4-mapped） | 確認済み |
| M2（Go 小プログラム） | 100 逐次 + 16 並行の echo 接続が成功。close・FD 再利用を含む | 確認済み |
| M2b（GoBGP を broker で実行） | 未改変 GoBGP v4.9.0 の 2 ノードで session Established、prefix 広告・撤回が成功（M2 relay 経由） | 確認済み |
| M3（REAL controller 接続） | 未改変 GoBGP 2 ノードを **上流 controller 経由**で接続。session Established、`192.168.1.0/24` の広告・撤回が成功。controller の `n_channel: 2` と一致。3/3 回成功 | 確認済み |
| M4-lite（反復と計測） | M3 シナリオ 3/3 成功。broker 通知数は node1 約 240 / node2 約 122（gRPC 操作の差）、bytes も再現的 | 確認済み |
| 切断（peer 停止） | peer 停止で session が落ちることを確認（M2 relay 経由） | 確認済み |
| 再接続（peer 再起動） | relay の再ペアリングまでは確認。ピア再起動後の BGP 再確立は未確認 | 未検証 |

### GoBGP の network syscall（strace, `-e trace=%network`）

| syscall | broker の扱い |
| --- | --- |
| `socket` / `connect` / `bind` / `listen` / `accept4` | 仮想化（捕捉） |
| `getsockname` / `getsockopt` / `setsockopt` | 仮想化（AF_INET 情報を返す） |
| `read` / `write` / `sendto` / `recvfrom` | native 維持（socketpair 経由。捕捉不要） |
| `futex` / timer / NETLINK | native 維持 |

短期 trace のため Establish 後の `read`/`write` は出ていないが、Go は socketpair 上で
native の read/write を使う設計であり捕捉対象に含めない。


## 既知の制約（PoC 1 時点）

- broker は単一スレッド。通知処理中の同期ハンドシェイク（REAL の SYN/SYNACK 等）は
  他の通知を一時的に止める。並行性の検証は M2 の小実験まで。
- 非 BGP の AF_INET listener（GoBGP の gRPC 等）は broker が実 socket を張って
  proxy する。broker と対象が同一 network namespace にある場合のみ成立。
- fd の寿命管理は `close` の横取りと socketpair の EOF に依存する。対象が
  broker より先に強制終了した場合は後始末が遅れる。
- epoll のイベントは fd 番号で引く。同一 `epoll_wait` バッチ内で先行イベントが
  vsock を破棄しても、後続イベントが解放済みポインタを参照しない（M2 並行テストで
  観測した use-after-free の修正）。
- controller の two-phase / run-to-idle は `R2I_DISABLED` + `TWO_PHASE_DISABLED` で
  通常実行モードとして使用。iterative convergence は未検証。
- vDSO 経由の時計は捕捉しないため実時間動作のみ。

## FRR（比較・回帰）

| 項目 | 値 | 状態 |
| --- | --- | --- |
| 上流基準版 | FRR 10.1.4（`docker/frr`） | 上流記載 |
| ARM64 イメージ | `real-frr:latest`（`docker build --platform linux/arm64`, 1.99GB, image id `a2ef7b2dd6bc`） | 確認済み |
| lwc コンテナ | `lwc create real-frr` → `lwc start`（tini）→ `lwc exec` 成功。`/usr/lib/frr/bgpd` 等を確認 | 確認済み |
| 上流 baseline/preload テスト | 未実行。上流 run.sh は `perf` 前提で、OrbStack kernel では perf が使えないため | 未検証 |

## cEOS-lab

| 項目 | 値 | 状態 |
| --- | --- | --- |
| イメージ | `ceos:4.36.0.1F`（arm64, 2.74GB, image id `b732cecde18a`） | 確認済み |
| 起動 | containerlab 相当（privileged, `CEOS/EOS_PLATFORM=ceoslab/INTFTYPE=eth/MAPETH0/MGMT_INTF=eth0`, `/sbin/init` + `systemd.setenv`） | 確認済み |
| CLI | `/usr/bin/Cli -> /usr/bin/FastCli`。`Cli -p 15 -c '...'` | 確認済み |
| BGP 起動 | `ip routing` を有効化してから `router bgp <as>`。ProcMgr/Launcher が `Bgp` を起動 | 確認済み |
| 2 ノード session | Docker bridge 上で eBGP Established、`192.168.1.0/24` の広告・撤回 | 確認済み（M5） |
| `Bgp` の実体 | 動的リンク aarch64 ELF。`libc.so.6`, `libstdc++`, `libAgentBase.so`, `libMarco.so` に依存 | 確認済み |
| socket 捕捉 | `LD_PRELOAD` プローブ（`src/probe/probe.c`）で **`connect(fd, <peer>:179)` が libc wrapper 経由**であることを確認 | 確認済み |
| プロセス/IPC | PID1 systemd、`ProcMgr`、`Sysdb`(Python)、`ConfigAgent`、`Launcher`、各種 agent。UNIX socket/共有メモリで連携 | 確認済み（概要） |
| 多数プロセスへの filter 継承 | PID1 に filter を入れ子孫へ継承させる方針。broker 側で `n->pid` を使う対応が必要 | 未検証 |

M5 の結論: cEOS の `Bgp` は libc socket を使うため、**元 REAL の `LD_PRELOAD` 方式が
そのまま適用できる**（GoBGP とは対照的）。AnyREAL の seccomp broker でも扱えるが、
cEOS は多プロセスなので PID1 へ filter を入れて子孫へ継承させる構成と、broker が
通知元プロセス（`seccomp_notif.pid`）ごとに fd table・メモリ操作を行う対応が必要。
M6 ではどちらを使うか（併用含む）を、実 socket の捕捉結果で決める。

## cEOS AnyREAL（M6a: 現状）

| 項目 | 値 | 状態 |
| --- | --- | --- |
| preload のビルド | cEOS は AlmaLinux 9.7 / glibc 2.34 のため、同系列の `almalinux:9` で `make IMAGE_CEOS=1` してビルド | 確認済み |
| 注入方法 | 全体の `/etc/ld.so.preload` は cEOS を壊す。`/usr/bin/Bgp` を wrapper にして `LD_PRELOAD` を設定する方式が有効 | 確認済み |
| hijack 対象 | `IMAGE_CEOS` で `__progname == "Bgp"` に限定。NETLINK は native 維持 | 実装済み |
| `Bgp` 起動 | wrapper + preload で `Bgp` は `add_if`/`set_nht_ready` を回避すると起動が進むが、その後 NOS 内部で abort | 未達（要対応） |

M6a の残作業:
- `Bgp` が preload 下で abort する原因の特定（preload が fd/挙動を変えることによる
  NOS 内部 assert の可能性）。REAL 固有の順序制御（`set_nht_ready`）や NETLINK 仮想化を
  外した状態で、どの前提が崩れているかを切り分ける。
- cEOS の BGP socket だけを対象にするための最小 hijack（port 179 / peer アドレス限定）の検討。



`Bgp` が libc リンクであることは、元 REAL の `LD_PRELOAD` 方式が cEOS の BGP にも
適用できる可能性を示す。AnyREAL の seccomp broker でも同じ境界を扱える。M6 では
どちらを使うか（または併用）を、実際の socket 呼び出しの捕捉で決める。

