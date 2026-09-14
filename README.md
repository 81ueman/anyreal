# AnyREAL

REAL（NSDI'26 *REAL: Emulating Control Plane at Simulator's Cost*）の制御プレーン
エミュレーションを、libc の関数差し替え（`LD_PRELOAD`）に依存せずに利用できるようにする
拡張プロジェクト。詳細な計画は [`PLAN.md`](PLAN.md) を参照。

- 主環境: **Ubuntu 24.04 / Linux ARM64 (aarch64)**
- 対象順序: **GoBGP → cEOS-lab**
- 元 REAL の参照 commit: `52f440cfb597fe9440ed3e862f98bd5bbf9171c4`
  ([ants-xjtu/REAL-artifact-evaluation](https://github.com/ants-xjtu/REAL-artifact-evaluation))

## 何を解決するか

REAL は `preload/libpreload.so` を NOS デーモンに `LD_PRELOAD` して libc の socket 系
呼び出しを横取りし、C++ の `controller` を介したメッセージ中継路へ BGP 通信を流す。
しかし GoBGP は Go runtime から直接 syscall を発行し libc を通らないため、この入口では
捕捉できない。

AnyREAL はその入口を **seccomp user notification + プロセス外 broker** へ移し、同じ
REAL の中継路（`controller` のプロトコル）へ接続する。対象バイナリは未改変。

```
GoBGP process                      broker (this repo)                controller (upstream)
  |  socket/connect/bind/...  -->  seccomp unotify  -->  virtual socket core  -->  REAL adapter
  |  read/write (socketpair)  <--  bridging fd     <--  REAL payload framing
```

## ディレクトリ

| パス | 内容 |
| --- | --- |
| `PLAN.md` | 開発計画（日本語） |
| `docs/` | 由来・差分、対応表、実験手順、方式判断 |
| `patches/` | 上流 REAL への ARM64 移植などのパッチ |
| `scripts/` | 環境構築・上流取得・実験補助 |
| `src/` | AnyREAL 本体（launcher / syscall backend / virtual socket core / REAL adapter / NOS adapter） |
| `tests/` | M2/M3 の小実験 |
| `third_party/REAL/` | 上流 REAL の固定チェックアウト（`scripts/fetch_upstream.sh` で取得） |

## 状態

PoC 1（GoBGP）の主要経路が成立。未改変 GoBGP 2 ノードを seccomp broker 配下で起動し、
上流 REAL controller 経由で BGP session 確立・経路広告・撤回まで確認済み。

| 段階 | 状態 |
| --- | --- |
| M0: ARM64 ビルド | preload/controller/lwc が aarch64 でビルド。`real-frr` ARM64 イメージ + lwc create/start/exec を確認。上流 baseline/preload テストは perf 前提のため未実行 |
| M1: native GoBGP | 2 ノード Established・広告・撤回 確認 |
| M2: 最小 syscall PoC | Go echo 100 逐次 + 16 並行 成功 |
| M2b: GoBGP + broker | 2 ノード Established・広告・撤回 成功（M2 relay） |
| M3: REAL controller | 2 ノード Established・広告・撤回 成功（上流 controller, 3/3） |
| M4: 判定・計測 | 反復と broker 通知数まで（M4-lite）。資源比較は未実装 |
| M5: cEOS 通常起動 | ARM64 cEOS 2 台で eBGP 確立・広告・撤回 確認。`Bgp` は libc リンク |
| M6: cEOS AnyREAL | **完了**（`M6_CEOS_PASS`）。ARM64 cEOS 2 ノードが preload（UDS/fake-fd）のまま REAL controller 経由で eBGP 確立・経路広告・撤回 |
| M7: cEOS 判定 | 未着手 |

再現手順と制約は [`docs/experiments.md`](docs/experiments.md)、
[`docs/compatibility.md`](docs/compatibility.md) を参照。

## 由来とライセンス

本リポジトリは上流 REAL の派生物を含む。参照 commit と変更点は
[`docs/upstream.md`](docs/upstream.md) に記録する。上流コードの再配布条件は確認中であり、
取り込んだコードの既存の権利表示は保持する。
