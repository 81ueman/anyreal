# AnyREAL 開発計画

作成日: 2026-09-14

状態: PoCで成立性を検証するための初期計画。方式・工数は検証前の提案。

対象の順序: **GoBGP → cEOS-lab**。FRRを元REALとの比較・回帰確認に使う。

主環境: **ARM64 Linux（aarch64）**。Apple Silicon Mac上のARM64 Linux VMを第一候補とし、対象バイナリ・コンテナ・broker・controllerをARM64でそろえる。

## 1. 到達点

AnyREALは、REALの制御プレーンエミュレーションを、libcの関数差し替えに依存せず利用できるようにする拡張プロジェクトとする。

最初の到達点は、**同じ未改変のGoBGPバイナリを通常のLinux環境とAnyREALで2ノード実行し、BGP通信をREAL由来のメッセージ中継経路へ流して、経路広告・撤回・再接続の結果が一致すること**。続いてcEOS-labを対象に、NOS全体の起動・内部通信を保ちながら同じ実行方式を適用する。

ユーザーの希望により、今回の必須ゴールはこの順序での小規模PoCとする。混在構成・大規模評価・高速化・論文化は、成立性を確認した後に着手を判断する。

「Any」は長期的な方向性を表す。初期の対応範囲はLinuxの特定ABI上で動くBGP実装とし、対応するNOS・版・runtime・機能を実験結果とともに明示する。GoBGPの対応で示せるのはGo製BGPデーモンへの対応であり、NOS全体への対応はcEOSで別途検証する。

| 段階 | 示したいこと | 完了時の成果 |
| --- | --- | --- |
| PoC 1 / v0.1: GoBGP | libcを経由しないBGP実装を動かせる | GoBGP 2ノードの実験、再現手順、対応表 |
| PoC 2 / v0.2: cEOS | コンテナ型NOSにも方式を適用できる | cEOS 2ノードの実験、NOS依存機能の一覧 |
| 後続 / v0.3以降 | 対応範囲を広げてもREALの資源効率を保てる | 混在実験、スケジューリング統合、規模を増やした比較評価 |

今回作成したのは計画書のみ。実装・Linux上での実行検証はまだ行っていない。

## 2. 調査で確認した出発点

元REALの参照先は[公式artifactのnsdi26-aeブランチ](https://github.com/ants-xjtu/REAL-artifact-evaluation/tree/nsdi26-ae)。今回コードを確認したcommitは `52f440cfb597fe9440ed3e862f98bd5bbf9171c4`。

- REALはlibcを介さず直接syscallを呼ぶGoBGPを未対応対象として挙げている。BGP以外のプロトコルやVM型イメージも初期対象外である。[REAL論文・Appendix A](https://www.usenix.org/system/files/nsdi26-xia.pdf)
- `preload/` にTCP・NETLINK・FD管理、`controller/` に中継・収束制御、`lwc/` にRust製のコンテナ実行処理がある。上流を基準にし、変更箇所をこの単位で整理する。[参照commit](https://github.com/ants-xjtu/REAL-artifact-evaluation/tree/52f440cfb597fe9440ed3e862f98bd5bbf9171c4)
- TCP処理にはBGPメッセージの組み立てとcontroller向けの送信処理が含まれる。通信処理を再利用する際は、対象プロセス内の状態やlibc呼び出しとの結合を外す必要がある。[tcp.cpp](https://github.com/ants-xjtu/REAL-artifact-evaluation/blob/52f440cfb597fe9440ed3e862f98bd5bbf9171c4/preload/tcp.cpp)
- 待機処理は`poll`/`ppoll`等と結び付いており、FD管理にはepoll対応のTODOが残る。GoのLinux runtimeはepollのedge-triggered通知を使うため、入口をsyscallに移すだけでは互換性を証明できない。[fdesc.h](https://github.com/ants-xjtu/REAL-artifact-evaluation/blob/52f440cfb597fe9440ed3e862f98bd5bbf9171c4/preload/fdesc.h)、[Goのnetpoll実装](https://go.dev/src/runtime/netpoll_epoll.go)
- REALの待機判定にはスレッド登録やプロセス固有の条件がある。汎用runtimeへのスケジューリング適用は独立した課題として扱う。[preload.cpp](https://github.com/ants-xjtu/REAL-artifact-evaluation/blob/52f440cfb597fe9440ed3e862f98bd5bbf9171c4/preload/preload.cpp)
- 上流の動作確認環境はUbuntu 24.04。今回の作業環境はmacOS/arm64なので、実験用のARM64 Linux環境を別途用意する。[環境構築手順](https://github.com/ants-xjtu/REAL-artifact-evaluation/blob/52f440cfb597fe9440ed3e862f98bd5bbf9171c4/ENV_SETUP.md)
- 上流の`preload/Makefile`にはx86向けの`-mcx16`指定がある。ARM64対応は未検証であり、ビルド設定・依存ライブラリ・同期処理の確認をM0に含める。[上流Makefile](https://github.com/ants-xjtu/REAL-artifact-evaluation/blob/52f440cfb597fe9440ed3e862f98bd5bbf9171c4/preload/Makefile)

作業リポジトリは計画作成時点で初期commit・remote・実装ファイルがない状態だった。上流コードは調査用の一時ディレクトリで確認した。

## 3. 初期スコープ

| 項目 | v0.1の範囲 | 後続で扱うもの |
| --- | --- | --- |
| 実行環境 | Ubuntu 24.04 / Linux ARM64（aarch64）を主環境として固定 | amd64（x86_64）、他ディストリビューション、別ABI |
| 対象 | GoBGP。FRRは比較・回帰確認 | cEOS-lab、その他のNOS |
| プロトコル | IPv4 unicast BGP、明示的なpeerアドレス | IPv6、EVPN、OSPF、BFD、TCP認証 |
| 規模 | 2ノード | 混在4ノード、16・64・256ノード以上、分散実行 |
| 時間 | 通常の実時間で動作 | 時間の仮想化・加速 |
| スケジューリング | Linux標準。中継側に通常実行用のモードを追加 | REALのtwo-phase / run-to-idle、iterative convergence |
| 正しさ | BGP session・RIB・経路属性・イベント後の到達状態 | FIB導出、パケット転送の忠実度 |

GoBGPは単独でBGPのRIBを検証する。FIBまで扱う場合の追加構成は後段で定義し、RIB一致をFIB一致と表現しない。FRRは元REALと同じ構成・版を基準にする。

「未改変」は、対象バイナリや言語runtimeをパッチせず、通常実行と同じバイナリを使うことと定義する。設定ファイル、起動用wrapper、必要なmountの追加は許容し、全て記録する。GoBGPではstatic buildを第一候補とし、ELF情報・依存ライブラリ・ビルド条件を確認して固定する。

GoBGPはLinux/arm64版を使い、FRRもARM64版を用意する。上流の配布イメージにARM64版がなければ、同じFRR版を基準にARM64イメージをビルドし、差分を記録する。cEOSはARM64 native版の取得可否と対応リリースを確認して選ぶ。GoBGPの公式ビルド設定にはarm64が含まれ、containerlabもARM64 nativeのcEOSを案内している。[GoBGPのビルド設定](https://github.com/osrg/gobgp/blob/master/.goreleaser.yml)、[containerlabのARM64環境案内](https://containerlab.dev/install/#apple-macos)

PoCの成立判定・性能計測はARM64 Linux上のnativeバイナリで行う。Apple Silicon上のARM64 Linux VMは利用可能な構成候補とし、x86バイナリのCPUエミュレーションを用いた実行は基準実験に含めない。VMのkernel設定とseccomp通知・FD追加・対象メモリ操作の利用可否をM0で確認する。

## 4. 実装方針の提案

### 4.1 syscall backendは小さな実験で選ぶ

第一候補は **seccomp user notification + プロセス外のbroker** とする。brokerは捕捉した操作を処理し、仮想socketの状態とREALの中継経路を接続する。seccompにはユーザー空間へのsyscall通知と対象プロセスへのFD追加機能がある。[Linux kernelの仕様](https://docs.kernel.org/userspace-api/seccomp_filter.html)

ただし、採用確定は後述のM2を通過してからとする。

| 方式 | この計画での役割 | 選択上の論点 |
| --- | --- | --- |
| LD_PRELOAD | 上流比較・既存FRRの回帰確認 | GoBGPのlibc非依存実行の検証には別の入口が必要 |
| seccomp user notification | PoCの第一候補 | 引数の読み書き、FD管理、通知コスト、待機処理を検証する |
| ptrace | syscall調査と、seccompで問題が出た場合の限定的な比較実験 | 切替時も同じ互換性テストを通し、性能を測る |
| kernel / eBPFを使う方式 | v0.3以降の検討対象 | 必要な操作を実現できるhookとコストを個別に確認する |

eBPFでsyscallを観測できることと、socketの戻り値・バッファ・FDの意味を置き換えられることは別の要件として評価する。初期段階では複数の本格backendを同時に実装しない。

### 4.2 分けて設計する責務

| 部分 | 責務 | 上流との接点 |
| --- | --- | --- |
| Launcher | filter設定、listener FD受け渡し、対象起動、終了処理 | 初期は小さなwrapper。後で`lwc`起動処理に組み込む |
| Syscall backend | syscall番号・引数・返値・対象メモリの取り扱い | libc wrapperの代わりになる入口 |
| Virtual socket core | 接続、FD状態、バッファ、readiness、エラー | `preload/tcp.*`と`fdesc.*`から必要部分を抽出 |
| REAL adapter | peer/node対応、BGPメッセージ化、中継プロトコル | `controller/`の既存経路を利用 |
| NOS adapter | 設定生成、起動条件、状態取得、依存機能 | GoBGP用、次にcEOS用を追加 |

coreはlibcの関数名やGoBGPの実行ファイル名に依存させない。`node_id`、プロセス・スレッド、FD table、共有されるsocket状態を区別する。controllerのプロトコルと上流テストを当初の互換境界とする。

syscall番号、アーキテクチャ識別、構造体の解釈はLinux ARM64のABIに合わせ、backend内にまとめる。x86向けの番号やレジスタ配置を流用しない。将来amd64へ対応する際も、BGP・仮想socketの共通処理とABI固有の処理を分けて検証できる構成にする。

中継処理はC++の既存実装を基本にし、Launcherの`lwc`統合では既存のRustを利用する。最初から全面的な言語変更や大規模なディレクトリ再編は行わない。

### 4.3 M2で先に解決する難所

1. **socketのreadiness**: `EINPROGRESS`、`SO_ERROR`、`EAGAIN`、短いread/write、EOF、切断を扱う。接続完了前の`EPOLLOUT`、edge-triggeredの再通知、native FDと仮想FDが混在する待機を検証する。
2. **FDの実体と寿命**: ADDFDで実FDを渡す案を試す。UNIX socket等で裏付ける場合も、そのreadinessが仮想TCP状態と一致するかを確認する。整数の仮想FDやeventfdを返すだけで互換性が得られるとは仮定しない。
3. **プロセス外からのメモリ操作**: `sockaddr`、`iovec`、`msghdr`等をコピーし、返値と出力バッファを整合させる。通知の失効、signal、途中終了、別スレッドによる変更を扱う。ADDFDの対応有無も起動時に調べる。[seccomp user notificationの詳細](https://man7.org/linux/man-pages/man2/seccomp_unotify.2.html)
4. **並行性**: brokerが1件のblocking操作を待つことで、他のpeerや同一Goプロセスの別スレッドを止めない構造にする。FD共有、`dup`、close・再利用、exec時の扱いをテストする。
5. **捕捉範囲**: peerアドレス・node・FD状態で仮想化対象を識別する。GoBGPの管理API、ファイルI/O、UNIX IPC等は通常動作を保つ。port 179だけで全通信を分類しない。
6. **時間と待機判定**: vDSO経由の時計読み取りはsyscall捕捉だけでは扱えないため、v0.1は実時間を使う。1スレッドがepoll待ちになったことをNOS全体のidleと見なさない。[kernelのvDSOに関する注意](https://docs.kernel.org/userspace-api/seccomp_filter.html#caveats)

捕捉候補は`socket`、`bind`、`listen`、`connect`、`accept4`、`read/write`系列、`send/recv`系列、`getsockopt/setsockopt`、名前取得、`fcntl/ioctl`、`shutdown/close`、FD複製、`poll/epoll`系列とする。実際のsyscallはM1のtraceで確定し、CのAPI名とLinux syscall名を対応付ける。socket typeに含まれるNONBLOCK/CLOEXEC等のフラグも検証する。

Go runtimeの`futex`やtimer等はまずnative実行を保つ。NETLINKによるinterface取得が必要なら通常kernelの情報を利用して始め、仮想トポロジーとの整合に必要な範囲を順に置き換える。kernelに残すinterface・route・NETLINK処理を各実験の構成として記録する。

## 5. GoBGPまでの進め方

工数は1名が集中して作業する場合の暫定的な実働日数。環境調達や未知の互換性問題による待ち時間は含まない。ARM64への移植確認を含め、M0〜M4でおおむね4〜7週間を仮置きし、M0とM2の終了時に再見積もりする。まずM0〜M2を最初の作業単位とし、ここで方式の成立性を判定する。

| 段階 | 作業 | 成果物・終了条件 | 目安 |
| --- | --- | --- | --- |
| M0: ARM64移植・上流再現 | ARM64 Linux環境と必要なkernel機能を確認。上流のビルド設定・依存関係を調整し、ARM64 FRRでbaselineとpreloadを実行 | ARM64で上流テストが通る。移植差分・版・コマンド・時間・メモリ・RIBを保存 | 3〜7日 |
| M1: GoBGP調査 | Linux/arm64版GoBGP 2ノードでBGPを確立し、起動から撤回・再接続までtrace | ARM64のsyscall対応表、runtime/ELF情報、期待RIB、必要なNETLINK操作が分かる | 2〜4日 |
| M2: 最小syscall PoC | CとGoの小プログラムで仮想socket・非同期I/Oを試す | LD_PRELOADなしで接続・双方向通信・切断・FD再利用が通る。backend採用判断を書く | 5〜10日 |
| M3: REAL接続 | brokerをREALのメッセージ中継へ接続し、通常実行用モードを追加 | GoBGP 2ノードで経路広告・撤回・再接続が通る | 5〜10日 |
| M4: PoC 1の判定 | 2ノードの回帰・繰り返し実行・簡単な計測をまとめる | 対応表、再現手順、コストの内訳、残課題を整理。cEOSへ進む判断ができる | 1〜2日 |

M0では上流READMEの`test/basic_coverage/baseline/frr.yaml`と`test/basic_coverage/preload/frr.yaml`を出発点にする。まず小規模再現を完了し、全論文実験の再実行は後回しにする。[上流の実行例](https://github.com/ants-xjtu/REAL-artifact-evaluation/blob/52f440cfb597fe9440ed3e862f98bd5bbf9171c4/README.md)

M0でARM64移植の問題が長引く場合も、独立して実施できるM1のGoBGP通常実行とM2のsyscall小実験は進める。元REALとの接続を含むPoC完了にはM0の再現が必要とし、再現前に上流互換性を確認済みとは扱わない。

**M2の判定**: syscallを捕捉できたことだけでは通過としない。readiness・並行性・FD寿命の必須ケースが再現可能なテストで通れば採用する。難所が残ったら、上流controllerへの統合作業を増やす前に、失敗する最小ケースで別のFD表現やptraceを比較する。

**M3の判定**: 管理APIだけが動く状態や、BGP通信が通常のveth/TCP経路へ流れている状態を成功としない。broker/controllerのカウンタと通信観測を突き合わせ、BGPが意図した中継経路を通ったことを確認する。

FRRの元REALでの実験は回帰用に残す。余裕があれば新backendでFRRを実行する。後続の混在実験でFRRを既存preload経由で使う場合は、GoBGP側と同じ実時間・通常スケジューリング条件にそろえる変更を記録する。

## 6. cEOSへの展開

GoBGPのv0.1完了後、cEOS-labを次の主対象にする。cEOSで問うのは、libcを回避するruntimeへの対応に加え、**NOSの起動・内部状態・interface管理を保ったまま制御プレーン通信を置き換えられるか**である。

containerlabにはcEOS用の起動設定・mount・interface対応があり、イメージの版によってcgroup要件も異なる。これを通常実行の基準にする。[containerlabのcEOS仕様](https://containerlab.dev/manual/kinds/ceos/)

| 段階 | 作業 | 終了条件 | 目安 |
| --- | --- | --- | --- |
| M5: 通常起動と依存調査 | ARM64 nativeのcEOSイメージを1版に固定し、ARM64 Linux上のcontainerlabで2台を起動。BGP、プロセス構成、IPC、NETLINK、interface、起動時の権限を調査 | 通常環境で広告・撤回・再接続が通り、仮想化が必要な境界を説明できる | 3〜5日 |
| M6: AnyREAL実行 | 起動・内部IPCを保ちながら対象通信をbrokerへ接続。必要なNETLINK/ioctl応答を追加 | cEOS 2ノードでBGPとRIBが基準実験に一致 | 10〜20日 |
| M7: PoC 2の判定 | 広告・撤回・再起動を繰り返し、既存GoBGP/FRRテストと簡単な計測を行う | cEOSの対応版・条件・制約を示したPoCレポート | 2〜3日 |

cEOS側は追加で約3〜6週間の仮置きとし、M5の依存調査後に見積もり直す。GoBGPとの混在4ノードはPoC成立後の最初の拡張候補とする。

M5では次の点を調べ、結果をcEOS対応表にする。

- BGP socketを所有するプロセスと、その起動・再起動経路。
- Sysdb等の内部IPC、共有メモリ、UNIX socket、管理通信の依存関係。名前だけで必要性を決めずtraceで確定する。
- interfaceの列挙・状態通知・IP設定・route操作の利用方法。起動が完了しただけではこの項目を完了としない。
- forwarding agent等を残した構成で動かせるか、その資源コストはどれだけか。停止・省略は制御プレーンへの影響を検証してから判断する。
- filterをどの時点で設定し、対象プロセスと子孫へどう継承するか。起動済みの任意プロセスへ後付けできるとは仮定しない。

最初はcEOSに必要なkernel interfaceや起動処理を残す構成を許容する。その場合は「BGP通信を仮想化した構成」と明記し、REALと同等の起動時間・メモリ削減を達成したとは扱わない。削減は差分を測って段階的に進める。

cEOSイメージの取得には利用者のAristaアカウントが必要になるため、M0でARM64版の利用可能なリリースと取得見通しを確認しておく。ダウンロードしたイメージのアーキテクチャも確認する。実装の主作業はGoBGPを先に進める。[イメージ取得手順](https://containerlab.dev/manual/kinds/ceos/#getting-arista-ceos-image)

## 7. 評価方法と成功条件

### 正しさ

同じトポロジー・設定・対象バイナリでnative実行とAnyREALを比較する。設定生成は共通の入力から行い、取得したRIBはnode・prefix・選択path・next-hop・AS path・必要な属性を正規化して比較する。単純な経路件数の一致だけでは合格にしない。

| シナリオ | 確認する結果 |
| --- | --- |
| 初期収束 | 全対象sessionがEstablished。定義した全prefixと属性が一致 |
| 広告・撤回 | 追加したprefixが伝播し、撤回後に消える |
| Policy変更（後続） | 明示的なlocal-prefやfilter変更で期待するpathが選ばれる |
| peer停止・再起動 | sessionが落ち、撤回・再接続・再広告が完了する |
| I/Oの境界条件 | 分割・結合されたBGPメッセージ、短いread/write、EAGAIN、切断を正しく処理 |
| 並行処理 | 小プログラムで複数接続を作り、runtimeの別スレッドが動作しても無期限停止やFD取り違えがない |

最初のトポロジーは期待結果が一意になる設定にする。等コストや到着順に依存する選択は別ケースとし、許容する結果集合を定義する。パケットの順序や収束時間がnativeと完全一致することはv0.1の要求に含めない。

各必須シナリオを最低10回実行し、全回で期待する最終状態を得ることを暫定の合格条件とする。収束判定は期待RIBの成立と、タイマー設定に基づく観測期間を組み合わせる。controllerのキューが一時的に空になっただけで収束と判定しない。

### 性能・資源

比較対象は、通常のLinuxネットワークでのGoBGP実行とAnyREALのGoBGPとし、元REALのFRRも参考値として記録する。新backendでのFRR実行は追加評価とする。cEOS追加後は通常のcontainerlab+cEOSを対応するbaselineにする。GoBGPとcEOSの単純な速度差をbackendの改善量とは扱わない。

baselineとAnyREALは同じARM64 Linux環境で測る。元REALの参考値もARM64移植版で測定し、元論文の別ハードウェア上の数値とは区別する。

PoCで測る項目は起動時間、設定完了からの収束時間、イベント後の再収束時間、全体のpeak memory、CPU時間、broker通知数。遅い場合は通知処理時間やcontext switchを調べる。broker・controller・残しているNOSプロセスのコストも集計し、中央値とばらつきを残す。ノード数に対する増え方は後続評価とする。

trace付きの実行は診断用とし、性能評価はtraceを外した構成で別に行う。バイナリhash、イメージdigest、kernel、runtime、CPU・メモリ割当、設定、ログ、生データ、計測コマンドを一つの実験IDにまとめる。

v0.1は機能成立を必須条件とし、高速化の達成は約束しない。M2/M4で通常実行と比べたコストを見て、v0.3の具体的な目標値を決める。性能差を小さく見せるためにbrokerやnativeに残した機能を集計から外さない。

## 8. PoC成立後の拡張候補

ここからは今回のPoC完了条件に含めない。まずGoBGP/cEOSの混在4ノード、次に16ノードを試し、その後は次の順序で統合する。

1. **通常実行時のコストを減らす**: 不要な通知、コピー、中継待ちを計測して削減する。
2. **runtimeに依存しない待機判定を設計する**: epoll待ちのスレッド以外に、実行可能なthread、timer、futex、内部IPC、未処理メッセージがある場合を扱う。
3. **two-phase / run-to-idleを追加する**: GCや補助スレッドを持つGoBGP、複数プロセスのcEOSで誤って停止・収束判定しないことを検証する。
4. **iterative convergenceを検討する**: 再起動・再送・状態復元の意味を確認し、必要な状態が再現できる対象に限定して追加する。
5. **64・256ノード以上へ拡大する**: nativeとAnyREALで同じ条件を使い、資源効率と対応範囲の両方を評価する。

時間の仮想化と分散実行は別の設計課題として残す。スケジューリング変更の前後で実時間timerの挙動も比較する。

論文化を目指す場合は、GoBGPが起動することに加え、「runtime差を吸収する実行境界」「cEOSを含む互換性の実証」「資源効率と忠実度のトレードオフ」を貢献候補にする。新規性は関連研究を追加調査して評価する。仮題は *AnyREAL: Runtime-Agnostic Control-Plane Emulation for Heterogeneous Network Operating Systems*。

## 9. リスクと方針を見直す条件

| リスク | 早期に得る証拠 | 対応 |
| --- | --- | --- |
| syscall捕捉はできてもGoの非同期I/Oが動かない | M2の最小プログラムとreadinessテスト | FD表現・待機方式を見直し、統合前に方式を決め直す |
| brokerが性能を支配する | 通知数・コピー量・CPU内訳 | 捕捉範囲を絞り、必要ならbackend候補を再評価 |
| GoBGPで動くがcEOSでは依存機能が広い | M5の起動・IPC・interface依存表 | kernelに残す範囲を明示し、BGP仮想化から段階的に進める |
| schedulerがruntimeをidleと誤認する | GC、timer、内部IPCを含む負荷ケース | 通常スケジューリングを維持し、最適化を切り離す |
| 実験環境の差で結果が再現しない | 版・digest・CPU割当を固定した反復実験 | まず単一Linux環境で再現性を確立 |
| 元REALのARM64移植で問題が出る | M0のビルド・リンク結果、同期処理と上流テスト | 移植差分を分離し、GoBGP単体の小実験を進めながら解消する |
| cEOSのARM64版を確保できない | M0での利用可能なリリース・取得可否の確認 | GoBGPのPoCを進め、cEOS段階はARM64イメージ確保を開始条件とする |
| 上流コードの再配布条件が不明 | 参照commitにはプロジェクト全体のLICENSE/COPYINGを発見できなかった | コード取り込み・公開に使う条件を確認し、既存の権利表示を保持する |

上流との関係はREADMEに明記し、参照commitとAnyREAL側の変更点を記録する。現時点ではforkとしてのコード取り込みは未実施であり、計画書を置いた状態と区別する。

## 10. 着手時のチェックリスト

- [x] 実験用のARM64 LinuxホストまたはVMを決め、kernel・使用可能メモリ・必要なseccomp機能を確認する。
      → OrbStack の `anyreal-dev`（Ubuntu 24.04 / aarch64、`user_notif` あり）。`docs/compatibility.md`。
- [x] 上流コードの利用条件を確認し、参照commitを固定した開発基点を用意する。
      → `third_party/REAL`（`52f440c`、gitignore）、`patches/`、`LICENSE`（MIT、patches は対象外）。
- [x] 元REALのビルド設定・依存関係をARM64向けに調整し、移植差分を記録する。
      → `patches/0001-preload-arm64-and-ceos.patch`。
- [ ] ARM64のFRRイメージを用意し、上流baseline/preloadを小規模で再現して結果を保存する。
      → `real-frr` ARM64 と lwc 経路は確認済み。上流テスト本体は `perf` 前提のため未実行（別ホスト）。
- [x] GoBGPの版・Linux/arm64バイナリを固定し、通常環境で2ノードBGPを確立する。
      → v4.9.0、`scripts/experiments/run_m1_native.sh`。
- [ ] 広告・撤回・再接続の設定と期待RIBを保存する。
      → 広告・撤回は保存済み。再接続は M2 relay で切断まで確認、controller 経由は未。
- [x] GoBGPのsyscallを採取し、捕捉・native維持・要調査に分類する。
      → `docs/compatibility.md`（`strace -e trace=%network`）。
- [x] seccomp通知、メモリ操作、ADDFD、Goのepollを組み合わせたM2の最小実験を作る。
      → `scripts/experiments/run_m2.sh`（100 逐次 + 16 並行）。
- [x] cEOS-labのARM64イメージの取得可否・利用可能な版を記録し、M5の開始条件を明確にする。
      → `ceos:4.36.0.1F`（arm64）。M5〜M7 実施済み。

### 追加で成立した範囲

- M3/M6: 未改変 GoBGP / cEOS を REAL controller 経由で確立・広告・撤回（preload/UDS）。
- 混在 4 ノード（GoBGP×2 + cEOS×2、同一 controller）。
- 計測: `docs/measurements.md`。

### 残（このリポジトリの作業）

- B: cEOS を seccomp broker で統一（boot は成功、中継は broker の非阻塞化が課題）。
- 上流 FRR baseline/preload の再現（perf が使える Linux ホスト）。
- 再接続（controller 経由）、資源比較の反復・実験ID固定、より大きいトポロジ。


実装開始後に追加する文書は、`docs/upstream.md`（由来と差分）、`docs/compatibility.md`（対応表）、`docs/experiments.md`（再現手順）、`docs/decisions/`（検証後の方式選択）を想定する。今はこの計画書を議論と更新の基点とする。
