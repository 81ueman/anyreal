# 計測（M4/M7）

環境: macOS(arm64) 上の OrbStack `anyreal-dev`（Ubuntu 24.04 / aarch64, kernel 7.0.11-orbstack）。
GoBGP v4.9.0（static）。数値は単発のサンプルで、反復・ピン留め・実験ID固定は未実施。

## GoBGP 2 ノード: native vs AnyREAL

`scripts/experiments/run_m4_measure.sh`（dev コンテナ内）。

| mode | 収束（session Established まで） | gobgpd VmHWM | broker VmHWM | controller VmHWM |
| --- | --- | --- | --- | --- |
| native | 1.63 s | 70.7 MiB | – | – |
| AnyREAL (controller) | 1.92 s | 71.0 MiB | 6.7 MiB | 245 MiB |

- 収束はほぼ同等（+0.3s）。GoBGP 自体の RSS はほぼ同じ。
- AnyREAL の追加コストは **broker 約 7 MiB/ノード** と **controller 約 245 MiB**。
  controller は 2 ノードでも固定オーバーヘッドが大きい（`MAX_CONNS`/`MAX_CLIENTS` の配列等）。
- GoBGP の gRPC API は broker が proxy するため、native と同様に CLI から検証できる。

注意:
- native 側 gobgpd は netns 内で動作するため、`gobgp` CLI も netns 内から実行して計測。
- VmHWM は収束後 1 秒時点の peak。負荷や GC により変動する。最低 10 回の反復は未実施。
- cEOS の資源は `docs/poc-ceos.md` を参照（サンプル: 1 ノード 0.9〜1.8 GiB）。

## broker 通知数（参考）

M3 の 2 ノードで、broker の syscall 通知数は node1 約 220〜248 / node2 約 119〜125
（`ANYREAL_STATS=1`）。転送バイトも再現的。詳細は `docs/compatibility.md`。

## 未計測

- CPU 時間、context switch、broker の通知内訳（read/write 以外）。
- cEOS の収束時間・peak の native 比較。
- 反復（各シナリオ 10 回）と実験IDの固定（バイナリ hash / digest / 資源割当）。
