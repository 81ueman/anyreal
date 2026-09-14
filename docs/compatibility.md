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
| `Bgp` 起動 | wrapper + preload で `Bgp` は起動が進む（`add_if`/`set_nht_ready` 回避）。ただし BGP socket を扱う段で crash | 未達（原因判明） |

M6a/M6b の症状と原因:
- `Bgp` は preload 下で起動し、`add_if`/`set_nht_ready`（REAL 固有の NETLINK・順序制御）を
  回避すれば socket 段まで進む。
- preload 側の `socket()` 失敗時に `fd=-1` を `fdesc_set` に入れて abort する問題は修正
  （`ret<0` をそのまま返す）。
- preload の `setsockopt`/`getsockopt` 未対応オプションでの `assert(0)` は `IMAGE_CEOS`
  では無視するよう修正（cEOS は未対応 TCP オプションを渡す）。
- その後 **cEOS 自身の `Arnet::setSocketOptionInteger`（`TcpClientServer.tin:147`）が
  assert して abort** する。cEOS の `Bgp` は独自 TCP オプション（観測: `optname=932717413`）を
  前提にソケットを検証しており、preload の fake-fd/socket エミュレーションと噛み合わない。

M6 の結論（方針）:
- 上流 preload は FRR のふるまいに密結合しており、cEOS の `Bgp` にはそのまま適用できない
  （PLAN.md §4.3 の「対象プロセス内の状態や libc 呼び出しとの結合を外す必要」を裏付け）。
- 次は seccomp broker を多プロセス対応にして cEOS を統一する（PID1 に filter、broker が
  `seccomp_notif.pid` ごとに fd table・メモリ操作）。REAL controller のプロトコルは流用する。

### D: cEOS 側 assert の解析結果

- assert 関数は `Arnet::setSocketOptionInteger`（`libTcpClientServer.so`, `TcpClientServer.tin:147`）。
- cEOS の `Bgp` は BGP ソケットに `level=IPPROTO_TCP` で `optname=14`(TCP_MD5SIG) /
  `optname=32`(TCP_MD5SIG_EXT) 相当、および SOL_SOCKET オプションを設定し、`setsockopt` が
  失敗すると自前で assert する（逆アセンブルで確認）。
- preload は AF_INET ソケットを AF_UNIX に置換するため、実 TCP のオプション意味論
  （戻り値・`getsockopt` での検証・ソケット family）を満たせず assert に至る。

**B への示唆**: seccomp broker も socketpair(AF_UNIX) を使うため同じ壁に当たり得る。
cEOS では「対象プロセスには実 TCP ソケットを持たせ、`connect()` を broker 側のローカル中継へ
向ける」方式（ソケットオブジェクトを置換しない）を検討する。

### B: preload の cEOS 適合（進行）

計測により、socketpair（fake-fd）方式のままでも cEOS `Bgp` を通せることが判明:
1. `Arnet::setSocketOptionInteger` の assert は式 `valueLength == sizeof(verificationValue)`。
   `setsockopt` したオプションを `tcp_fdesc` に記憶し `getsockopt` で同じ値・長さを返す
   （`store_opt`/`replay_opt`）ことで解消。**実 TCP に逃げずに済む**。
2. cEOS の `Bgp` は `send/recv/sendmsg/recvmsg/sendto/recvfrom` を使うため、`tcp_fdesc` の
   未実装パス（`debug_assert(0)`）を read/write 経路へ委譲して実装。
3. その結果、`Bgp` は **BGP connect 段**まで到達。残る assert は `tcp.cpp:472`
   `debug_assert(r == 0)` = controller の manager socket が無い（`ENOENT`）ことによるもので、
   **controller を起動すれば解消する見込み**。

この結果は「cEOS 用に実 TCP へ全面フォールバック」ではなく、**socketpair/UNIX のまま
（REAL の効率思想を維持して）cEOS を通せる**方向を示す。次は controller を
`ceos` トポロジで起動し、共有 `/ripc` 経由で 2 ノードの BGP を確立する。

### B: broker の多プロセス対応（実装済み・回帰なし）

- `seccomp_notif.pid` は tid のため、`/proc/<tid>/status` の Tgid でプロセス単位に正規化。
- fd table を `(tgid, fd)` でキー化。`process_vm_readv/writev` は通知元プロセスの tgid に対して実行。
- これにより PID1 に filter を入れ子孫へ継承させる構成（cEOS の systemd/ProcMgr/Bgp）で、
  複数プロセスの socket を 1 つの broker が扱える。
- 単一プロセス（GoBGP）の M2/M3 は回帰なしで成功を確認。

（注: preload 適合の結果、cEOS でも socketpair/UNIX のままで通せる見込みとなったため、
実 TCP へのフォールバックは不要になった。broker を cEOS へ適用する場合も同じ
`store_opt`/`replay_opt` 相当を broker 側に持たせればよい。）

### M6 統合の状況（あと一歩）

`scripts/experiments/run_m6_ceos.sh` を追加: 2 台の cEOS を preload 付きで起動し、
controller を `ceos` トポロジ（`conf/ceos/topo2`）で起動、共有 `/ripc` 経由で BGP を
確立する。`node_ops.cpp` に `ceos` の no-op アダプタを追加。

確認できたこと:
- cEOS の `Bgp` が preload 下で起動し、BGP connect 段で abort しない。
- `/ripc/emu-real-<i>/listener:179`（listener）と `/ripc/emu-real-<i>/<peer>`（connector）が
  両ノードに作成される。
- ceos1 は BGP で `OpenSent` まで進む（controller へ OPEN を送信している）。

未成立:
- controller の `n_channel` が 0 のまま。connector の payload が対向 listener チャネルへ
  中継されず、ceos2 は `Active`、ceos1 は `OpenSent` のまま留まる。
- DEBUG ビルドの controller は `logPath/ctrl/` 未作成で落ちる等、ログ取得に難がある。

次の切り分け:
- controller の `try_buildup` が node2 の listener へ connect できているか、payload が
  replay manager から (2,1) チャネルへ送られているかを、DEBUG ログを安定化して確認する。

追加の計測結果（非 DEBUG controller に一時ログ）:
- `try_buildup i=2 j=1 path=.../emu-real-2/listener:179 connect=0` — node2 の listener への
  接続は成功している。
- `payload self=1 peer=2 len=81` — node1 の BGP OPEN を controller は受信している。
- しかし以降 `payload self=2 ...` が出ず、`n_channel` は 0 のまま。すなわち
  controller は OPEN を受けたが **対向 (2,1) チャネルへ中継していない**か、node2 へ届いて
  いない。`node_replay_one_msg` は BGP_OPEN を常に replay する実装なので、チャネル状態
  （`get(2,1)` の state）または配送（`sendmsg`→pollout）の成立を DEBUG ログで確認するのが次段。









`Bgp` が libc リンクであることは、元 REAL の `LD_PRELOAD` 方式が cEOS の BGP にも
適用できる可能性を示す。AnyREAL の seccomp broker でも同じ境界を扱える。M6 では
どちらを使うか（または併用）を、実際の socket 呼び出しの捕捉で決める。

