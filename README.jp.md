
(English: [README.md](README.md))

# 目的

本リポジトリは、ホスト型のAPIではなく、ローカルで動かす `llama.cpp`（CUDAバックエンド）をバックエンドとして [Hermes Agent](https://github.com/NousResearch/hermes-agent) を動かすための、最小限の Docker Compose 構成です。
投稿・共有して最初から最後まで読み通せるよう、あえてファイル構成を単純にしています。

# 動作確認環境

- OS: Ubuntu 26.04 LTS
- CPU: Intel Xeon E-2276ME @ 2.80GHz (6コア / 12スレッド)
- RAM: 32GB
- GPU: NVIDIA Quadro P2200 (VRAM 5GB), driver 580.173.02

# 事前準備

以下の手順を実行する前に、ホスト側にNVIDIAドライバ・Docker Engine・NVIDIA Container Toolkitをインストールしておく必要があります（コンテナ内にはドライバは不要です）。

## NVIDIAドライバのインストール確認

```bash
nvidia-smi
```
これでGPU情報が表示されればOKです。
表示されない場合は先にドライバを入れてください。
ドライバは580を入れてください。
P2200はPascal世代のGPUです。
580はPascal世代への最後のフル機能ドライバブランチで、590以降はPascalのサポートが打ち切られているため、このバージョンに固定する必要があります。
```bash
sudo apt install nvidia-driver-580
# 再起動
sudo reboot
```

再起動後にGPU情報が表示されればOKです。

```bash
nvidia-smi
```

## Docker Engineのインストール（公式リポジトリから）

Snap版ではなく公式APT版を使うのが重要です。
Snap版はサンドボックス化されており、GPUデバイスファイルにアクセスできずGPU連携が失敗します。

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg

# 公式GPGキー追加
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# リポジトリ追加
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# install
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# ubuntu 26ではnewgrpが無いので入れる
sudo usermod -aG docker $USER
sudo apt install -y util-linux-extra
newgrp docker
```

## NVIDIA Container Toolkit

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update
sudo apt install -y nvidia-container-toolkit

sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

# モデルファイル

`models/` には `compose.e4b-qat.yml` が `llama-server` コンテナにマウントするGGUFモデルファイルを配置します。
gitignore対象なので本リポジトリには含まれません。
以下の3ファイルをHugging Faceの
[unsloth/gemma-4-E4B-it-qat-GGUF](https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF)からダウンロードし、
以下のように配置してください。

```
models/gemma-4-E4B-it-qat/
├── gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf   # 本体モデル（4bit動的量子化）
├── mmproj-F16.gguf                      # マルチモーダル用プロジェクタ
└── mtp-gemma-4-E4B-it.gguf              # Multi-Token Prediction用ドラフトモデル
```

# 初期設定

`./.hermes-data`はただのbind mountなので、docker-compose側の設定だけではサイズ上限を掛けられません。
Hermesが暴走してログ/DBを書き続けてもホストディスクを食い潰さないよう、
固定サイズのループバックイメージ（ext4でフォーマットしたファイル）を用意し、そこにマウントして容量上限を強制します。

`.hermes`（dashboardデータ）と`.hermes-web`（web資産）は同じイメージ・同じマウント先（`./.hermes-data`）を共有し、
その下のサブディレクトリとして分けます。

- `./.hermes-data/hermes` → コンテナの `/opt/data`
- `./.hermes-data/web` → コンテナの `/opt/hermes/web`

`tmpfs`やDocker volumeの`--storage-opt size=`ではなくループバックイメージを選んだ理由:
このデータ（dashboardの設定・履歴・web資産）はコンテナ再起動やホスト再起動をまたいで永続化する必要があり、
これは`tmpfs`（RAM上に載るため再起動で消える）では満たせません。
`--storage-opt size=`も検討しましたが、これはバッキングファイルシステムがXFS＋project quota
（または`tmpfs`タイプのvolume）の場合しか使えず、本リポジトリの動作確認環境であるext4では利用できません。
ループバックのext4イメージであればホスト側のファイルシステムに依存せず、ディスクに永続化できます。

## 初回セットアップ

```bash
# 1. 固定サイズのスパースイメージを作成（必要に応じてサイズ変更）
truncate -s 10G .hermes-data.img

# 2. ext4でフォーマット
mkfs.ext4 -q .hermes-data.img

# 3. マウントポイント作成
mkdir -p .hermes-data

# 4. ループマウント（root権限が必要）
sudo mount -o loop .hermes-data.img .hermes-data

# 5. 自分の所有に変更する。これは純粋に、以降のmkdir/cp手順をsudo無しで行うため。
#    コンテナ内のUIDと一致させる必要は無い: hermesイメージはプロセスをroot権限で
#    起動しており（`docker inspect nousresearch/hermes-agent:latest --format
#    '{{.Config.User}}'`で確認可）、user-namespaceのremapも無いため、ホスト側の
#    ファイル権限チェックを素通りしてどのみち書き込める。副作用として、以降コンテナが
#    作成するファイルはホスト上でroot所有になるので、.hermes-data/hermes配下を後から
#    確認・削除する際にsudoが要る場合がある。
sudo chown "$(id -u):$(id -g)" .hermes-data

# 6. サブディレクトリを作成
mkdir -p .hermes-data/hermes .hermes-data/web

# 7. 設定ファイルを配置
cp config.yaml .hermes-data/hermes/
```

## 起動のたびに必要なこと

ループマウントはホスト再起動やアンマウントで消えるため、`docker compose up`の前にマウントされているか確認します。

```bash
mountpoint -q .hermes-data || sudo mount -o loop .hermes-data.img .hermes-data
```

## 再起動時に自動マウントしたい場合（任意）

`/etc/fstab`は絶対パスしか書けないため、リポジトリのルートで以下を実行して
現在地から絶対パスを組み立てて追記します（`nofail`でイメージが無い場合も起動を止めない）。

```bash
echo "$(pwd)/.hermes-data.img $(pwd)/.hermes-data ext4 loop,nofail 0 0" | sudo tee -a /etc/fstab
```

追記した内容の確認:

```bash
grep hermes-data /etc/fstab
```

再起動せずに`fstab`の記述だけを検証したい場合は、一度アンマウントしてから
`mount -a`で`fstab`経由の再マウントを試します。

```bash
sudo umount .hermes-data
sudo mount -a
mountpoint .hermes-data
```

## 容量を使い切ったら

イメージ内の10GBを使い切ると、コンテナ側の書き込みが失敗します（ホストディスクは無事です）。
空き容量確認:

```bash
df -h .hermes-data
```

拡張したい場合は、コンテナを止めてアンマウントした上で`truncate`と`resize2fs`でイメージを拡張します。

```bash
sudo umount .hermes-data
truncate -s 20G .hermes-data.img
e2fsck -f .hermes-data.img
resize2fs .hermes-data.img
sudo mount -o loop .hermes-data.img .hermes-data
```

# 環境変数の設定

`docker-compose.yml` は `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`PASSWORD` を必須項目にしているため、
`docker compose` は `build` を含むどのサブコマンドでも `hermes` サービスの環境変数も含めてファイル全体を検証します。
`.env.sample`には`COMPOSE_FILE`も設定済みで、これは`docker compose`が`.env`から自動で読み込みます（変数展開用途だけではありません）。
毎回exportする代わりにサンプルをコピーして認証情報を編集してください。

```bash
cp .env.sample .env
$EDITOR .env  # 自分のusername/passwordを設定
```

`.env.sample`では`COMPOSE_FILE`がE4Bモデルのデフォルト構成（単一スロット）である`compose.e4b-qat.yml`を指しています。
本リポジトリには2並列スロットで動かす`compose.e4b-qat-np2.yml`も同梱しているので、
使いたい場合は`.env`の`COMPOSE_FILE`を書き換えてください。

```
COMPOSE_FILE=docker-compose.yml:compose.e4b-qat-np2.yml
```

並列負荷時の合計スループットはかなり速くなります。単一ストリームの63.3 tok/sに対し、2並列合計では約74 tok/s出ます
（詳細は[healthcheck / supervisor について](#healthcheck--supervisor-について)のベンチマーク表を参照）。
ただし使う前にそのセクションは確認してください。
「既知の穴」として、ストール検知のwatchdogに2スロット構成特有の見落としがある点も載せています。

本リポジトリの本命はE4Bですが、`compose.12b.yml` / `compose.12b-np2.yml` を12Bモデルの参考構成として同梱しています。
両ファイルともMTPによる投機的デコード（`-md` / `--spec-type draft-mtp`）を有効にしています。
本リポジトリのハードウェアで計測したところ明確な効果があり、
プロンプトによって生成速度がおよそ+60〜100%向上します:

| 構成 | MTP無効 | MTP有効（`--spec-draft-n-max 4`） |
|---|---|---|
| `compose.12b.yml`（`-np 1`）、`code`/`prose_ja` プロンプト | 約6.9 tok/s（`-ngl 28`） | 約12.0〜12.6 tok/s（`-ngl 24`） |
| `compose.12b.yml`（`-np 1`）、`factual` プロンプト | 約7.0 tok/s（`-ngl 28`） | 約8.6 tok/s（`-ngl 24`） |
| `compose.12b-np2.yml`（`-np 2`、単一ストリーム）、`code`/`prose_ja` プロンプト | 約5.9〜6.0 tok/s（`-ngl 23`） | 約10.5〜10.8 tok/s（`-ngl 19`） |
| `compose.12b-np2.yml`（`-np 2`、単一ストリーム）、`factual` プロンプト | 約5.2 tok/s（`-ngl 23`） | 約6.4 tok/s（`-ngl 19`） |

効果の大きさはプロンプト依存で、コードのように局所的に予測しやすい続きがあるプロンプトほど大きく、
自由記述の事実説明のようなプロンプトほど小さくなります。
計測条件は `temperature=0`、`top_k=1`、`n_predict=256`、キャッシュなしプロンプト、
`/completion` の `timings.predicted_per_second` を使用しています。

# build
```bash
docker compose build llama-server
docker compose pull hermes
```

# 実行
```bash
docker compose up -d
```

# healthcheck / supervisor について

`/health` が OK を返し続けたまま推論スロットがハングする現象が起こりました。
同様の報告されています（[llama.cpp#20921](https://github.com/ggml-org/llama.cpp/issues/20921)）。
issueはクローズ済みですが、根本原因の特定や有効性が確認された修正・回避策はなく、間欠的に再発しうる状態です。
そのため本リポジトリでは `/slots` エンドポイントの進捗（`id_task` / `n_prompt_tokens_processed` / `n_decoded` のいずれかが動いていれば健全）を監視し、
ハングを検知したらコンテナごと再起動する方式（`healthcheck-slots.sh` / `supervisor.sh`）で対応しています。

`/slots` は正常な prefill 中でも最大48秒程度タイムアウトすることがあります（`/health` は即座に応答するため区別可能）。
そのため単発のタイムアウトでは判定せず、応答が `SLOT_STALL_SECONDS` 秒（既定180秒）まったく返らない場合のみ unhealthy とします。

### ベンチマーク: `-np 1` と `-np 2`

本リポジトリの動作確認環境（Quadro P2200, VRAM 5GB）で、新規（キャッシュなし）プロンプトを使って計測しました。

| 構成 | VRAM使用量 | prefill | decode |
|---|---|---|---|
| `-np 1 -c 64000 -ngl auto`（`compose.e4b-qat.yml`、デフォルト） | 3926 MiB | 17.0 tok/s | 61.2 tok/s |
| `-np 2 -c 128000 -ngl 43`、単一ストリーム | 4818 MiB | 17.4 tok/s | 63.3 tok/s |
| `-np 2 -c 128000 -ngl 43`、2並列同時実行（合計 / 個別平均） | 4950 MiB | 220.0 / 110.0 tok/s | 74.0 / 37.0 tok/s |

「2並列同時実行」の行は、実際に2つのリクエストを同時に投げて両スロットを使わせた結果です。
decodeはストリームあたり約37 tok/sまで落ちますが、両ストリーム合計では約74 tok/sとなり、
単一スロット時のbaseline（63.3 tok/s）より合計スループットは上がっています（これが2スロット化する狙いです）。
このprefillの数値はクリーンな比較にはなっていません（プロンプトが22/29トークンと短く、片方は一部キャッシュヒットあり）。
参考値として載せていますが、prefillの正面比較としては見ないでください。

### 既知の穴: `compose.e4b-qat-np2.yml`（`-np 2`）はハングを見逃すことがある

このwatchdogは`/slots`のレスポンス全体から1本のfingerprint（全スロットの`id_task` / `n_prompt_tokens_processed` / `n_decoded`をまとめて連結したもの）を作っており、
スロットごとには追跡していません。

**見逃す条件は具体的に1つだけです: スロットAがハングしている間、
スロットBが`SLOT_STALL_SECONDS`の間ずっとリクエストを受け続けて動いている場合。**
fingerprintは両スロットを連結したものなので、Bのフィールドが毎回変わり続ける限り、
連結後のfingerprint全体も変化し続けてタイマーが一度もリセットされず満了しません。
結果としてAのハングは永久に気付かれません。
逆にBが無処理（idle）であれば、連結fingerprintは静止するので従来通り正しく検知できます。
穴が開くのは「健全な方のスロットがずっと稼働し続けている」場合だけです。

`compose.e4b-qat-np2.yml`を使う場合はこれを念頭に置いてください。
特に両スロットが常時ビジーになりうる継続的なトラフィックがある構成では注意が必要です。

`supervisor.sh` は llama-server を子プロセスとして起動し、
上記のストールを検知したら子プロセスを SIGKILL してコンテナごと終了させます（`restart: unless-stopped` により compose が作り直します）。
`docker.sock` を使わない設計にしているのは、ソケットの共有がホスト root 相当の権限を渡すことになるためです。
また llama-server を PID 1 ではなく子プロセスとして起動しているため、内部からの SIGKILL で確実に終了させられます。

### watchdog のタイミング系閾値

ストールを検知してコンテナを再起動するタイミングを制御する変数です。
これらの値が最適であることは確認できていません（妥当そうな値を仮に置いているだけです）。
短すぎると一時的な遅延をストールと誤判定し、不要な再起動が起きます。
長すぎると実際のハングを検知して復旧するまでの時間が延びます。

| 環境変数 | 既定値 | 説明 |
|---|---|---|
| `SLOT_STALL_SECONDS` | 180 | 無進捗/無応答をストールとみなすまでの秒数 |
| `WATCH_POLL_SECONDS` | 30 | supervisor の監視間隔 |
| `WATCH_START_PERIOD` | 120 | 起動直後、監視を始めるまでの猶予秒 |

### それ以外の変数

スクリプトが使うパスやURLです。
チューニング対象ではなく、コンテナの構成上、正誤が決まっているだけの値です。

| 環境変数 | 既定値 | 説明 |
|---|---|---|
| `LLAMA_URL` | `http://localhost:8080` | llama-server の URL |
| `SLOT_STATE_FILE` | `/tmp/llama-slots-watch` | 進捗を記録する状態ファイル |
| `LLAMA_SLOTS_FIXTURE` | (なし) | テスト用。指定するとこのファイルを `/slots` の応答として使う |
| `LLAMA_BIN` | `/app/llama-server` | llama-server 本体のパス |
