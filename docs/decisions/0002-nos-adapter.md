# ADR 0002: REAL controller への接続方法（GoBGP NOS adapter）

- 状態: Accepted（M3 で 3/3 成功）
- 日付: 2026-09-14

## 文脈

M2 で seccomp broker と virtual socket core は成立した。PoC 1 の到達条件は、
broker を **REAL のメッセージ中継路（上流 controller）** に接続し、未改変 GoBGP の
経路広告・撤回が通ることを示すこと（PLAN.md §5 M3）。

上流 controller は `node_ops.cpp` で自分が lwc 経由で NOS を起動する構成になっており、
接続元 UDS path を `sscanf("/ripc/emu-real-%d/%d")` で解析する。

## 決定

1. broker 側に `--real` モードを実装し、上流プロトコル（`real_syn_t` / `real_payload_t`）を
   直接話す。connect 側は `/ripc/emu-real-<self>/<peer>` に bind して manager socket へ
   SYN を送り、listener 側は `/ripc/emu-real-<self>/listener:179` を listen する。
2. controller に `image == "gobgp"` の adapter を追加し、`anyreal-run --real` を起動する
   （`patches/0002`）。
3. broker と controller のパスを一致させるため、実行環境で `/ripc` を
   `/opt/lwc/volumes/ripc` への symlink にする。
4. v0.1 の通常実行モードとして `R2I_DISABLED=1 TWO_PHASE_DISABLED=1` でビルドし、
   単一 part の収束バグを修正する（`patches/0003`）。

## 理由

- 中継の並び替え・順序制御・カウンタは上流実装をそのまま使う（PLAN.md §4.2 の
  「controller のプロトコルと上流テストを当初の互換境界とする」）。
- libc 非依存 runtime の捕捉は broker の seccomp backend が担い、controller は入口を
  問わない。この分離により FRR（preload）と GoBGP（broker）を同じ controller で扱える。

## 帰結 / 残課題

- 再接続は controller の STAGE 遷移（restart_nodes）経由でのみ実施される。
  CONVERGE 中の任意タイミングの再接続は未対応。
- two-phase / run-to-idle / iterative convergence は無効化して検証した。有効化時の
  Go runtime の idle 判定は別課題（PLAN.md §8）。
- 単一 part の `globally_converged()` 修正は上流の非 iterative 経路に対する bugfix であり、
  上流の意図（iterative 前提）と衝突しないよう `n_parts == 0` の場合に限定した。
