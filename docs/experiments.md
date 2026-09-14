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
scripts/apply_patches.sh          # third_party/REAL に ARM64 移植などを適用
make -C third_party/REAL/preload
make -C third_party/REAL/controller
cargo build --release --manifest-path third_party/REAL/lwc/Cargo.toml
```

FRR の baseline/preload 再現は ARM64 イメージをビルドして行う:

```bash
cd third_party/REAL/docker/frr
curl -fsSL -o /tmp/frr.tgz https://github.com/FRRouting/frr/archive/refs/tags/frr-10.1.4.tar.gz
tar -xzf /tmp/frr.tgz && mv frr-frr-10.1.4 frr
docker build --platform linux/arm64 -t real-frr .
```

上流の `docker/frr/Dockerfile` は apt ミラーを TUNA へ書き換えるが、arm64 では
`ports.ubuntu.com` が使われるため既定ミラーのままビルドされる。
`real-frr` 取得後、`scripts/utils/lwc_load_img.sh` 相当で `/opt/lwc/image` へ展開する。

```bash
mkdir -p /opt/lwc/{image,containers,volumes,layers}
docker image save real-frr -o /tmp/real-frr.tar
tar -xpf /tmp/real-frr.tar -C /opt/lwc/image/real-frr
./lwc/target/release/lwc create real-frr test-frr
./lwc/target/release/lwc start test-frr tini -- sleep infinity
./lwc/target/release/lwc exec test-frr ls /usr/lib/frr
```

注意: 上流 `run.sh` / `run_one.sh` は `perf record`/`perf stat` を前提とする。
OrbStack kernel（`7.0.11-orbstack`）では perf が使えないため、上流テスト全体の
再実行は別の Linux ホストで行う。ARM64 イメージと lwc 経路はここまでで確認済み。



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

## 7. 反復と計測（M4-lite）

```bash
N=5 scripts/experiments/run_m4.sh
```

M3 シナリオを N 回実行し、成功数と broker の syscall 通知数・転送バイト数を集計する
（`ANYREAL_STATS=1` で broker が終了時に `[anyreal-stats]` を stderr へ出力）。
性能の native 比較（CPU・peak memory・収束時間）は未実装。

## 8. cEOS 通常起動（M5）

```bash
scripts/experiments/run_m5_ceos.sh
```

ARM64 cEOS 2 台を containerlab 相当設定で起動し、Docker bridge 上で eBGP を確立して
`192.168.1.0/24` の広告・撤回を確認する。成功時は `M5_CEOS_PASS`。

メモ:
- ノードの flash は共有しない（各ノード個別。共有するとクローンになる）。
- `router bgp` の前に `ip routing` が必要。
- CLI は `/usr/bin/Cli`（= FastCli）。EOS の出力は `Estab` と省略される。

### libc socket を使うかの確認（LD_PRELOAD プローブ）

```bash
# 開発コンテナ内
gcc -shared -fPIC -O2 -o build/libprobe.so src/probe/probe.c -ldl
```

これを cEOS コンテナへコピーし `/etc/ld.so.preload` に登録して再起動すると、
`/tmp/anyreal-probe.log` に libc wrapper 経由の `socket`/`connect`/`accept4` が出る。
cEOS `Bgp` では `connect(fd, <peer>:179)` が記録され、libc 経由であることを確認済み。

## 9. cEOS への AnyREAL 適用（M6, 進行中）

cEOS は AlmaLinux 9.7 / glibc 2.34 のため、preload は同系列でビルドする:

```bash
docker run --rm --platform linux/arm64 \
  -v "$PWD/third_party/REAL/preload":/src -w /src almalinux:9 \
  bash -c 'dnf install -y gcc-c++ make && make clean; make IMAGE_CEOS=1'
```

注入は全体の `/etc/ld.so.preload` ではなく、`Bgp` だけをラップする:

```bash
mv /usr/bin/Bgp /usr/bin/Bgp.real
printf '#!/bin/bash\nexport LD_PRELOAD=/usr/lib/libpreload.so\nexec /usr/bin/Bgp.real "$@"\n' > /usr/bin/Bgp
chmod 755 /usr/bin/Bgp
printf 'NODE_ID=1\nPEER_LIST=10.30.0.2:10.30.0.3:2,\nBASE_TS=0\nRT_BASE_TS=0\nMONO_RAW_BASE_TS=0\n' > /real_env
```

現状 `IMAGE_CEOS` で NETLINK 仮想化・`add_if`・`set_nht_ready` を無効化しても `Bgp` が
preload 下で abort するため、M6 は原因切り分けが必要（`docs/compatibility.md` 参照）。

## 10. cEOS × REAL controller（M6）

```bash
scripts/experiments/run_m6_ceos.sh
```

- cEOS の preload は `almalinux:9` で `make IMAGE_CEOS=1`（`third_party/REAL/preload/libpreload.so`）。
- controller は `make R2I_DISABLED=1 TWO_PHASE_DISABLED=1`（`third_party/REAL/controller/controller`）。
- 共有 `/ripc` ボリュームを controller と cEOS 双方にマウントし、`/usr/bin/Bgp` だけを
  `LD_PRELOAD` でラップする。成功時は `M6_CEOS_PASS`。
- `KEEP=1` を付けると失敗時にコンテナを残す（調査用）。

## 11. cEOS の N ノード／混在トポロジ（M7）

```bash
scripts/experiments/run_ceos_topo.sh 4      # cEOS line N=2/3/4
scripts/experiments/run_mixed4.sh           # GoBGP x2 + cEOS x2 (line, 1 controller)
```

- `run_ceos_topo.sh N`: cEOS の line トポロジ。session 確立・末端までの広告・撤回を検証。
- `run_mixed4.sh`: GoBGP（`anyreal-run` broker 経由）と cEOS（preload 経由）を同一 controller で
  相互接続。異実装 BGP の同居を検証。成功時は `MIXED4_PASS`。

## 12. seccomp broker で cEOS（B: 試行）

```bash
# launcher/broker を cEOS 用にビルド（AlmaLinux 9）
docker run --rm --platform linux/arm64 -v "$PWD":/work -w /work/src almalinux:9 \
  bash -c 'dnf install -y gcc-c++ make && g++ -std=c++17 -O2 -g -o /work/build/anyreal-run-ala9 launcher/main.cpp broker/broker.cpp -lpthread'
scripts/experiments/run_b_ceos.sh
```

`--supervise-self` で launcher が PID1 のまま `/sbin/init` を exec し、子が broker を担う。
cEOS の boot は通るが、broker が単一スレッドのためプロセスツリーが詰まり、BGP 中継は未成立。








## 実験 ID に含めるもの

バイナリ hash、イメージ digest、kernel、runtime、CPU・メモリ割当、設定、ログ、
生データ、計測コマンド。
