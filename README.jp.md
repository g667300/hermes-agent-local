
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

`models/` には `compose.e4b-qat.yml` が `llama-server` コンテナにマウントするGGUFモデルファイルを
配置します。gitignore対象なので本リポジトリには含まれません。以下の3ファイルをHugging Faceの
[unsloth/gemma-4-E4B-it-qat-GGUF](https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF) から
ダウンロードし、以下のように配置してください。

```
models/gemma-4-E4B-it-qat/
├── gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf   # 本体モデル（4bit動的量子化）
├── mmproj-F16.gguf                      # マルチモーダル用プロジェクタ
└── mtp-gemma-4-E4B-it.gguf              # Multi-Token Prediction用ドラフトモデル
```

# 初期設定

`./.hermes-data`はただのbind mountなので、docker-compose側の設定だけではサイズ上限を
掛けられません。Hermesが暴走してログ/DBを書き続けてもホストディスクを食い潰さないよう、
固定サイズのループバックイメージ（ext4でフォーマットしたファイル）を用意し、そこに
マウントして容量上限を強制します。

`.hermes`（dashboardデータ）と`.hermes-web`（web資産）は同じイメージ・同じマウント先
（`./.hermes-data`）を共有し、その下のサブディレクトリとして分けます。

- `./.hermes-data/hermes` → コンテナの `/opt/data`
- `./.hermes-data/web` → コンテナの `/opt/hermes/web`

`tmpfs`やDocker volumeの`--storage-opt size=`ではなくループバックイメージを選んだ理由:
このデータ（dashboardの設定・履歴・web資産）はコンテナ再起動やホスト再起動をまたいで
永続化する必要があり、これは`tmpfs`（RAM上に載るため再起動で消える）では満たせません。
`--storage-opt size=`も検討しましたが、これはバッキングファイルシステムがXFS＋project
quota（または`tmpfs`タイプのvolume）の場合しか使えず、本リポジトリの動作確認環境である
ext4では利用できません。ループバックのext4イメージであればホスト側のファイルシステムに
依存せず、ディスクに永続化できます。

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

ループマウントはホスト再起動やアンマウントで消えるため、`docker compose up`の前に
マウントされているか確認します。

```bash
mountpoint -q .hermes-data || sudo mount -o loop .hermes-data.img .hermes-data
```

## 再起動時に自動マウントしたい場合（任意）

`/etc/fstab`は絶対パスしか書けないため、リポジトリのルートで以下を実行して
現在地から絶対パスを組み立てて追記します（`nofail`でイメージが無い場合も起動を
止めない）。

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

イメージ内の10GBを使い切ると、コンテナ側の書き込みが失敗します（ホストディスクは
無事です）。空き容量確認:

```bash
df -h .hermes-data
```

拡張したい場合は、コンテナを止めてアンマウントした上で`truncate`と`resize2fs`で
イメージを拡張します。

```bash
sudo umount .hermes-data
truncate -s 20G .hermes-data.img
e2fsck -f .hermes-data.img
resize2fs .hermes-data.img
sudo mount -o loop .hermes-data.img .hermes-data
```

# 環境変数の設定

`docker-compose.yml` は `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`PASSWORD` を必須項目にしているため、
`docker compose` は `build` を含むどのサブコマンドでも `hermes` サービスの環境変数も含めてファイル
全体を検証します。Docker Composeはプロジェクトルートの`.env`ファイルを変数展開に自動で読み込むので、
毎回exportする代わりにサンプルをコピーして編集してください。

```bash
cp .env.sample .env
$EDITOR .env  # 自分のusername/passwordを設定
```

`COMPOSE_FILE`（どのモデル構成を使うか選ぶ変数）は`run.sh` / `run-12b.sh`が自前でexportするので、
シェルごとに以下は引き続き必要です。

```bash
export COMPOSE_FILE=docker-compose.yml:compose.e4b-qat.yml
```

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
そのため本リポジトリでは `/slots` エンドポイントの進捗（`id_task` / `n_prompt_tokens_processed` / `n_decoded` のいずれかが動いていれば健全）を監視し、ハングを検知したらコンテナごと再起動する方式（`healthcheck-slots.sh` / `supervisor.sh`）で対応しています。

`/slots` は正常な prefill 中でも最大48秒程度タイムアウトすることがあります（`/health` は即座に応答するため区別可能）。
そのため単発のタイムアウトでは判定せず、応答が `SLOT_STALL_SECONDS` 秒（既定180秒）まったく返らない場合のみ unhealthy とします。

`supervisor.sh` は llama-server を子プロセスとして起動し、上記のストールを検知したら子プロセスを SIGKILL してコンテナごと終了させます（`restart: unless-stopped` により compose が作り直します）。
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
