# PoC: cEOS-lab × REAL (M5-M7)

ARM64 cEOS-lab を REAL controller の中継路で駆動する PoC の結果。対象は
`ceos:4.36.0.1F`（aarch64, AlmaLinux 9.7）。

## 構成

- N 台の cEOS を **line トポロジ**（node i ↔ i±1）で起動。`10.70.0.<10+i>`, AS `65000+i`。
- 各ノードの **`/usr/bin/Bgp` だけ**を `LD_PRELOAD=/usr/lib/libpreload.so`（`IMAGE_CEOS`）でラップ。
  NOS 全体には `ld.so.preload` を掛けない。
- 共有ボリューム `/ripc` を controller と cEOS 双方にマウント。controller は
  `R2I_DISABLED=1 TWO_PHASE_DISABLED=1`。
- 再現: `scripts/experiments/run_ceos_topo.sh <N>`（`KEEP=1` で失敗時に残す）。

## 結果

| N | session Established | 広告が末端まで到達 | AS path（末端） | 撤回 | 備考 |
| --- | --- | --- | --- | --- | --- |
| 2 | ✅ | ✅ | `65001` | ✅ | M6 (`run_m6_ceos.sh`) |
| 3 | ✅ | ✅ | `65002 65001` | ✅ | |
| 4 | ✅ | ✅ | `65003 65002 65001` | ✅ | 撤回は反映が遅い（数十秒〜） |

- 反復（N=2）: **3/3 PASS**（各 22〜42s）。
- 実 TCP へのフォールバックなし。対象のソケットは AF_UNIX（fake-fd）のまま、
  BGP ペイロードは controller 経由で中継される。

## 資源（docker stats のサンプル）

| プロセス | メモリ |
| --- | --- |
| cEOS 1 ノード | 約 0.9〜1.8 GiB（起動中に増加） |
| controller | 約 240 MiB |

正確な peak / 収束時間の比較は未計測（M7 の残項目）。他実験とメモリを共有する場合は
**1 トポロジずつ実行し、終了時に掃除**する（`on_exit` trap が実施）。

## 対応範囲と制約

- cEOS の BGP デーモン `Bgp` は libc socket を使用（`connect(:179)` を捕捉確認）。UDS/fake-fd で動作。
- `IMAGE_CEOS` の hijack は `__progname == "Bgp"` かつ AF_INET/SOCK_STREAM に限定。NETLINK は native。
- cEOS 固有対応:
  - `setsockopt`/`getsockopt` のラウンドトリップ（`store_opt`/`replay_opt`）。
  - `send/recv/sendmsg/recvmsg/sendto/recvfrom` を read/write 経路へ。
  - **epoll 利用のため `read`/`readv` 内で peek**（poll slowpath 前提を回避）。
- 既知の制約:
  - controller の収束窓（`ANYREAL_CONVERGE_SEC`）が短いと TEARDOWN に入り、広告/撤回が
    中継されない。実時間実行では十分長い窓が必要。
  - 撤回の反映はホップ数に応じて遅い。検証はポーリングで行う。
  - NOS 全体（systemd/ProcMgr/Sysdb 等）は preload の hijack 対象外で native 動作。

## 混在 4 ノード（GoBGP + cEOS）— MIXED4_PASS

`scripts/experiments/run_mixed4.sh` で、**GoBGP 2 台（seccomp broker 経由）と cEOS 2 台
（preload 経由）を同一の REAL controller** に接続（line: GoBGP1 - cEOS2 - GoBGP3 - cEOS4）。

- 隣接 session すべて Established（**異実装 BGP の相互接続**）。
- node1(GoBGP) から広告した `192.168.1.0/24` が node4(cEOS) に到達。AS path は
  `65003 65002 65001`（GoBGP→cEOS→GoBGP→cEOS を中継）。撤回も成功。
- これは「runtime 差（Go）と libc 依存 NOS（cEOS）を同じ中継路で同居できる」ことの実証。

## seccomp broker 版での cEOS 適用（B: 進行）

preload を使わない統一経路として、cEOS の PID1 を `anyreal-run --real` で監視する方式も試した
（`scripts/experiments/run_b_ceos.sh`）。

- launcher に **`--supervise-self`** を追加（自分は PID1 のまま対象を exec、子プロセスが broker）。
  これで **systemd が PID1 として起動でき、cEOS の boot は成功**（以前の「telinit が見つからない」
  問題は PID1 でなかったため）。
- broker の改善:
  - 外部 connect を **非阻塞 + タイムアウト**（`proxy_real_connect`）。
  - **`--no-inet6`**：cEOS の AF_INET6 デュアルスタックリスナーは native のままにし、AF_INET のみ
    仮想化（preload 経路と同条件）。
  - option store/replay。
- 結果: cEOS が broker 下で boot し、**BGP メッセージが交換される**（MsgRcvd/MsgSent が増加）。
  例: node1 が `Estab`、node2 が `Active` の**非対称**。controller の `n_channel` は 0 のまま。
  AF_INET/AF_INET6 の経路混在が原因候補で、broker 統一は追加作業が必要。

現状の成立経路は preload（M6）と混在構成（MIXED4）。broker 統一は継続課題。

## M5 調査の残項目（依存関係）

- **forwarding agent**: cEOS は forwarding agent を含む構成で起動している。停止・省略は
  制御プレーンへの影響を検証してから判断する（未検証）。資源コストも未計測。
- **interface 管理**: cEOS の `Management0` に IP を設定して BGP を確立。interface の列挙・
  状態通知・route 操作は native（NETLINK は仮想化していない）。仮想トポロジーとの整合に
  必要な範囲は後続で整理する。
- **filter 継承**: 現状は `/usr/bin/Bgp` を wrapper にして `Bgp` にのみ `LD_PRELOAD` を適用。
  起動済みプロセスへ後付けはできないため、Bgp 起動時に読み込ませる方式。子孫（Bgp が
  spawn するもの）にも継承される。
- **起動時間**: cEOS の boot（systemd 一式）は数十秒。AnyREAL でも boot 自体は native と
  同様に走る（hijack は Bgp のみ）。

## 再接続（peer stop/restart）の現状

- GoBGP（M2 relay, `run_m2_reconnect.sh`）: peer 停止で session が落ちること、および
  **peer 再起動後に session が再確立（Established）する**ことを確認。
  ただし **経路の再広告は今回観測できず**（node2 の RIB が空のまま）。GoBGP の Adj-RIB-Out
  再送タイミング/条件の確認が必要。テストは `M2_RECONNECT_PASS` に達していない（部分成功）。
- GoBGP/cEOS（REAL controller）: controller は `try_buildup` を STAGE_BUILDUP でのみ実行し、
  CONVERGE 中の再接続は `restart_nodes`（STAGE 遷移）経由でしか再構築しない。したがって
  実行中の任意タイミングの peer 再起動は未対応。iterative convergence / 2-phase の導入時に
  整理する（PLAN.md §8）。

## 次の候補

- seccomp broker 版での cEOS 適用の継続（broker の非阻塞化、AF_INET6 方針）。
- peak memory・収束時間の native/AnyREAL 比較。
- より大きいトポロジ。
