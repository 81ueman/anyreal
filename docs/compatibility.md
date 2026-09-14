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
| REAL controller 接続 | broker の `--real` 実装あり。統合は M3 で検証 | 実装済み・未検証 |

## FRR（比較・回帰）

| 項目 | 値 | 状態 |
| --- | --- | --- |
| 上流基準版 | FRR 10.1.4（`docker/frr`） | 上流記載 |
| ARM64 イメージ | 未ビルド | TODO（M0） |

## cEOS-lab

| 項目 | 値 | 状態 |
| --- | --- | --- |
| ARM64 native イメージ | 未取得 | TODO（M0 で取得可否確認） |
