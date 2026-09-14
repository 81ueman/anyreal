# 上流 REAL との関係

## 参照

- リポジトリ: https://github.com/ants-xjtu/REAL-artifact-evaluation
- 参照 commit: `52f440cfb597fe9440ed3e862f98bd5bbf9171c4`（`nsdi26-ae` ブランチの調査時点）
- 取得: `scripts/fetch_upstream.sh` が `third_party/REAL/` へ固定チェックアウトする
  （`.gitignore` 済み。リポジトリには取り込まない）

`docs/upstream.md` は由来と差分を記録する文書であり、上流の権利表示は保持する。
現時点で本リポジトリは上流の fork ではなく、方式検証用の独立実装を含む。

## 上流の構造（制御プレーン経路）

```
                   upstream controller (C++)
/opt/lwc/volumes/ripc/msg_manager_socket  <-- UNIX socket
        ^                              ^
        | real_syn / real_pld          | real_syn / real_pld
   [ libpreload.so ]              [ libpreload.so ]
        ^ LD_PRELOAD                   ^ LD_PRELOAD
      bgpd (libc)                   bgpd (libc)
```

- `preload/`: `LD_PRELOAD` 用ライブラリ。libc の `socket`/`connect`/`bind`/`listen`/
  `accept4`/`read`/`write`/`ppoll` などをラップし、プロトコル `real_hdr_t` を実装する。
- `controller/`: 中継と収束制御。`MNG_SOCKET_PATH`（`/opt/lwc/volumes/ripc/msg_manager_socket`）
  で接続を受け、`real_syn_t` の `cli_id`/`svr_id` から channel を作る。
- `lwc/`: Rust 製のコンテナ実行。overlayfs で rootfs を組み、`unshare(CLONE_NEWPID|NEWNET|NEWUTS)`
  して `pivot_root`、`lwc exec` で対象を namespace へ入れる。

### プロトコル（`controller/const.hpp` / `preload/preload.h`）

```c
typedef struct { int32_t msg_type; int32_t msg_len; int64_t seq; } real_hdr_t;
typedef struct { real_hdr_t hdr; int32_t cli_id; int32_t svr_id; uint16_t cli_port; } real_syn_t;
typedef struct { real_hdr_t hdr; uint16_t cli_port; } real_synack_t;
typedef struct { real_hdr_t hdr; int32_t src_id; int32_t dst_id; } real_pld_t;
// msg_type: REAL_SYN=1, REAL_SYNACK=2, REAL_PAYLOAD=3, ...
```

### 接続確立の流れ（BGP, port 179）

1. 接続側: fd を `/ripc/emu-real-<self_id>/<peer_id>` に bind し、controller の
   `msg_manager_socket` へ `connect`。`REAL_SYN{cli_id,svr_id}` を送る。
2. controller: channel を作り、割り当てた `cli_port` を `REAL_SYNACK` で返す。
3. 待受側: fd を `/ripc/emu-real-<self_id>/listener:179` に bind して `listen`。
   controller がその path へ `connect` してきて、`accept4` した fd 上で `real_syn_t` を読む。
4. 以降は `REAL_PAYLOAD{src_id,dst_id}` を controller 経由で双方向に中継。`seq` は controller が付与。

## AnyREAL 側の差分（方針）

| 部分 | 上流 | AnyREAL |
| --- | --- | --- |
| 捕捉入口 | libc wrapper | seccomp user notification + broker |
| 対象 runtime | libc 利用 NOS | libc 非依存 runtime（GoBGP）を含む |
| 仮想 socket 実体 | プロセス内 fdesc + controller 接続 fd | broker 保持の socketpair + controller 接続 fd |
| controller | そのまま | そのまま利用（通常実行モードを追加） |
| lwc | そのまま | Launcher として利用 |

## AnyREAL パッチ一覧

`patches/` に置き、`scripts/apply_patches.sh` が `third_party/REAL` へ適用する
（`scripts/fetch_upstream.sh` から自動で呼ばれる）。

| パッチ | 対象 | 内容 | 理由 |
| --- | --- | --- | --- |
| `0001-preload-arm64-port.patch` | `preload/` | `-mcx16` を x86_64 以外では外す。`SYS_open`/`SYS_dup2` を `openat`/`dup3` に置換 | ARM64 に存在しない |
| `0002-controller-gobgp-adapter.patch` | `controller/node_ops.cpp` | `image == "gobgp"` の起動・停止・再起動・RIB 出力を追加。`anyreal-run` を起動し broker 経由で接続 | NOS adapter（PLAN.md §4.2） |
| `0003-controller-single-part-convergence.patch` | `controller/main.cpp` | 単一 part（非 iterative）で `globally_converged()` が成立せず `glb_all_parts[-1]` を参照して落ちる問題を修正。`ANYREAL_CONVERGE_SEC` で観測窓を延長可能に | v0.1 の通常実行モード |

### パスに関する注意

上流 controller は接続元 UDS path を `sscanf("/ripc/emu-real-%d/%d")` で解析し、
listener へは `/opt/lwc/volumes/ripc/emu-real-<id>/listener:179` で接続する。
一方 broker は文字列として `/ripc/...` に bind する必要がある。そのため実行環境では
`/ripc` を `/opt/lwc/volumes/ripc` への symlink にする（`run_m3.sh` が実施）。

## 上流への ARM64 移植差分（0001 の詳細）

`patches/` に置く。判明している項目:

| ファイル | 差分 | 理由 |
| --- | --- | --- |
| `preload/Makefile` | `-mcx16` を ARM64 では付けない | x86_64 専用オプション |
| （追加調査中） | | |

上流は Ubuntu 24.04 / x86_64 前提のため、ARM64 ビルド・同期処理・上流テストの
再現結果をここへ追記する。
