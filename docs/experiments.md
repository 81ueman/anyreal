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

```bash
cd /work/src && make          # anyreal-run, m2-relay
cd /work/tests/m2 && CGO_ENABLED=0 go build -o /work/build/m2-server ./server \
    && CGO_ENABLED=0 go build -o /work/build/m2-client ./client
cd /work && scripts/experiments/run_m2.sh
```

`run_m2.sh` は M2 relay（`src/relay/m2_relay.cpp`）と 2 つの未改変 Go プログラムを
起動し、100 逐次 + 16 並行の echo 接続を検証する。成功時は `M2 PASS`。

## 5. GoBGP を broker で動かす（M2b）

```bash
scripts/experiments/run_m2_gobgp.sh
```

未改変の `gobgpd` 2 台を broker 配下で起動し、M2 relay 経由で BGP session を確立、
`192.168.1.0/24` の広告・撤回を検証する。成功時は `M2B_GOBGP_PASS`。

## 6. REAL controller 接続（M3）

```bash
scripts/experiments/run_m3.sh
```

未改変の `gobgpd` 2 台を **上流 REAL controller** 経由で接続する。controller が
`conf/gobgp/topo2/blueprint.json` を読み、`node_ops.cpp` の gobgp adapter 経由で
`anyreal-run --real` を起動する。`/ripc` は `/opt/lwc/volumes/ripc` への symlink。
成功時は `M3_PASS`。

- 観測窓は `CONVERGE_SEC`（既定 30 秒, controller の `ANYREAL_CONVERGE_SEC`）。
- controller は `R2I_DISABLED=1 TWO_PHASE_DISABLED=1` でビルドする（通常実行モード）。


## 実験 ID に含めるもの

バイナリ hash、イメージ digest、kernel、runtime、CPU・メモリ割当、設定、ログ、
生データ、計測コマンド。
