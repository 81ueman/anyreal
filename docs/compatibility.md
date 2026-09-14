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
| seccomp user notification | 未検証（M2 で確認） | 仮説 |
| `SECCOMP_IOCTL_NOTIF_ADDFD` | 未検証（M2 で確認） | 仮説 |
| x86_64 CPU エミュレーション | OrbStack/Rosetta で amd64 コンテナは起動できるが、seccomp filter のロードが常に `EINVAL`（trivial な `RET ALLOW` でも失敗）。基準実験には使わない | 確認済み |

P-1 の計測: OrbStack/Rosetta 上の amd64 `gcc:14` で `seccomp(SECCOMP_SET_MODE_FILTER, 0, &prog)`
が `EINVAL`。native aarch64 では同じコードが成功し、`SECCOMP_RET_ERRNO` が発火した。
→ 本 PoC は native ARM64 を主環境とする（PLAN.md §3 と一致）。

## GoBGP

| 項目 | 値 | 状態 |
| --- | --- | --- |
| 版 | 未固定 | TODO |
| ビルド | Linux/arm64 static 第一候補 | TODO |
| syscall | 未採取 | TODO（M1） |

## FRR（比較・回帰）

| 項目 | 値 | 状態 |
| --- | --- | --- |
| 上流基準版 | FRR 10.1.4（`docker/frr`） | 上流記載 |
| ARM64 イメージ | 未ビルド | TODO（M0） |

## cEOS-lab

| 項目 | 値 | 状態 |
| --- | --- | --- |
| ARM64 native イメージ | 未取得 | TODO（M0 で取得可否確認） |
