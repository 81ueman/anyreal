# 実験手順（再現用）

作業は Ubuntu 24.04 / aarch64 の開発コンテナ内で行う。macOS 側ではコンテナの起動・
ファイル共有のみを担う。

## 0. 開発コンテナ

```bash
scripts/dev/setup_dev_container.sh
```

- コンテナ `anyreal-dev`（`--privileged`, `--platform linux/arm64`）を起動し、
  リポジトリを `/work` に、Docker socket を `/var/run/docker.sock` に、
  `/opt/lwc` を named volume に割り当てる。
- 中に入る: `scripts/dev/enter.sh`

## 1. 上流 REAL の取得

```bash
scripts/fetch_upstream.sh          # third_party/REAL を固定 commit で取得
```

## 2. 上流の ARM64 ビルド（M0）

```bash
# preload（-mcx16 は ARM64 では外す）
make -C third_party/REAL/preload

# controller
make -C third_party/REAL/controller

# lwc
cargo build --release --manifest-path third_party/REAL/lwc/Cargo.toml
```

## 3. GoBGP の native 2 ノード（M1）

TODO: バイナリ固定、設定生成、RIB 取得、syscall trace。

## 4. M2 最小 syscall PoC

TODO: `tests/m2/` の手順を記述。

## 実験 ID に含めるもの

バイナリ hash、イメージ digest、kernel、runtime、CPU・メモリ割当、設定、ログ、
生データ、計測コマンド。
