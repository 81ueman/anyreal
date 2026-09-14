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

## seccomp broker 版での cEOS 適用（B: 試行）

preload を使わない統一経路として、cEOS の PID1（`/sbin/init`）を `anyreal-run --real` で
監視する方式も試した（`scripts/experiments/run_b_ceos.sh`）。

- broker を **AlmaLinux 9（glibc 2.34）でビルド**して cEOS コンテナへ注入
  （`build/anyreal-run-ala9`）。
- broker 側にも preload と同じ **option store/replay** を追加（`setsockopt` を記憶し
  `getsockopt` で返す）。
- 結果: cEOS の boot が early に落ちた（systemd が起動を継続できず）。
  - 原因候補: broker が cEOS の全プロセスの AF_INET/AF_INET6 stream socket を仮想化するため、
    boot 中の socket パターン（多数・多様なオプション/待機）を満たせていない。
  - broker は単一スレッドで、boot 時の通知量も負荷。

現状は **preload 経路（M6）が cEOS の成立経路**。broker 統一は追加作業（対象プロセスの
boot 時 socket の把握、必要なら per-process/非同期化）が必要。

## 次の候補

- seccomp broker 版での cEOS 適用の継続（boot 時 socket の対応）。
- peak memory・収束時間の native/AnyREAL 比較。
- 混在 4 ノード（GoBGP + cEOS）、より大きいトポロジ。
