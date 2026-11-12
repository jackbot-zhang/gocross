# gocross —— 固定编译环境（Ubuntu 18.04 + 多版本 Go）

## 为什么有这套东西

本地系统 glibc 新（2.35/2.39），编出来的二进制拿到线上老系统（Ubuntu 18.04 / glibc 2.27）一跑就报：

```
/lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.34' not found
```

原因是 **cgo 编译时链接了本地 libc**，版本号被打进了二进制的符号引用里。
解决办法只有一条：**在老系统里编译**。

本目录把编译环境固化成 Docker 镜像，被 `/home/zhang/code/` 下所有 Go 项目共用。
项目里只需要一个 `Makefile`，不需要放任何 Dockerfile。

---

## 一、目录结构与各文件职责

```
code/docker/gocross/
├── versions.conf              ★要装的 Go 版本清单（唯一数据源，改这里）
├── goenv.sh                   ★镜像管理入口（status/apply/build/add/use/list/projects/clean）
├── Dockerfile                 基础镜像定义（OS + 工具链 + C 库 + 多个 Go 版本）
├── install-go.sh              镜像内下载安装 Go（多个源依次尝试，被 Dockerfile 调用）
├── Dockerfile.project-env     项目环境层（选 GOROOT + 映射宿主机用户）
├── Dockerfile.gocross         ★编译流程（所有项目共用，项目里不用放 Dockerfile）
├── gocross-build.sh           ★项目构建入口，由项目 Makefile 调用
├── templates/Makefile.tmpl    项目 Makefile 模板
├── .build-env-image           自动生成，记录当前生效的基础镜像名
└── .gitignore
```

按"改什么去哪里"对照：

| 我想做的事 | 改哪个文件 | 之后要做什么 |
|---|---|---|
| 加/删/换 Go 版本 | `versions.conf` | `./goenv.sh apply` |
| 预装新的 C 库、换 apt 源 | `Dockerfile` | `./goenv.sh apply --force` |
| 改所有项目的编译流程（如加 `-s -w`） | `Dockerfile.gocross` | 下次 `make docker-build` 自动生效 |
| 改某个项目的包路径/Go 版本 | 项目的 `Makefile` | `make docker-build` |
| 改构建脚本逻辑（版本检查、glibc 检查） | `gocross-build.sh` | 下次编译生效 |
| 换一台机器 | 整个目录拷走 | `./goenv.sh apply` |

---

## 二、镜像是怎么分层的

一张图看懂三层，**层数决定了编译速度**：

```
ubuntu:18.04  (glibc 2.27)
      │  Dockerfile                  ← 工具链 + C 库 + 多个 Go 版本
      ▼
gocross/build-env:ubuntu-18.04-go<版本>-...           【基础镜像】构建一次，长期复用
      │  Dockerfile.project-env     ← 选 GOROOT + 用户映射，只 COPY 无关的几条指令
      ▼
<项目>-buildenv:go<版本>-<hash>                       【项目环境镜像】每次编译重建，秒级
      │  Dockerfile.gocross         ← COPY 源码 + go build
      ▼
<项目>-builder:go<版本>                               【产物镜像】每次编译重建，包含源码层
      │  docker run ... tar -c /app/bin
      ▼
宿主机的 ./bin
```

| 镜像 | 内容 | 重建频率 | 耗时 |
|---|---|---|---|
| `gocross/build-env:*` | OS + gcc/g++/pkg-config + 常用 C 库 + N 个 Go 版本 | 改 `versions.conf` 或 `Dockerfile` 时 | 首次 3~5 分钟，加版本 1~2 分钟 |
| `<项目>-buildenv:*` | 只设 `GOROOT`、建用户，几乎不含文件 | 每次编译（走缓存，近乎 0 秒） | 秒级 |
| `<项目>-builder:*` | 源码 + 编译出的二进制 | 每次编译 | 20~40 秒 |

**两个关键设计**：

1. **源码永远是 build context**。所以改代码一定生效，不存在"缓存导致用了旧代码"。
   反过来，`BUILD_TIME` 每次都变，最后几步一定会重跑——这是刻意的，保证时间戳真实。
2. **项目环境镜像名带 hash**。hash 由 `Go版本 + 宿主机uid` 算出，切换 Go 版本不会
   误命中另一个版本的缓存层。

工具链、C 库、Go 版本都在**基础镜像**里，项目镜像里一条 `apt-get` 都没有——这是速度快的原因。

---

## 三、一次 `make docker-build` 到底做了什么

`gocross-build.sh` 的完整执行顺序（对应源码里的注释编号）：

```
0. 解析参数、确定 PKG（主包）/ OUTPUT（产物名）
   └─ PKG 必须是绝对路径；没传则用 <项目根>/cmd/<项目名>，目录不存在直接报错

1. 检查基础镜像
   └─ 读 .build-env-image，镜像不存在就调 goenv.sh build 构建一次（首次）

2. 决定用哪个 Dockerfile
   └─ -f / DOCKERFILE 指定  >  默认用 Dockerfile.gocross

2.1 确定 Go 版本：指定了就用指定的，没指定用镜像默认；镜像里没有就报错

3. 构建项目环境镜像 <项目>-buildenv:goX-<hash>（秒级）

4. 编译：docker build -f <Dockerfile> --build-arg PKG/OUTPUT/GIT_INFO/BUILD_TIME .
   └─ CGO_ENABLED=1，固定打开

5. 导出产物：docker run ... tar -c /app/bin | tar -x -C ./bin
   └─ 容器内已把当前用户建好，落盘的文件属主就是你自己，不是 root

6. glibc 检查：对每个 ELF 取最高 GLIBC_x.y 符号，和 2.27 比较
   └─ 超过就告警——这在编译期就能发现线上会炸的产物
```

产物目录（默认 `./bin`）里：

| 文件 | 说明 |
|---|---|
| 项目二进制 | 属主是当前用户 |
| `config.toml` / `config.json` 等 | **只有** Makefile 的 `DIST_FILES` 里列了才有，由 Makefile 从本地复制，不经过容器 |

构建信息（Go 版本、容器 glibc、cgo、包路径、git、时间）只在构建日志里打一份，不落文件：

```
--- build info ---
go_version=go version go<版本> linux/amd64
glibc=ldd (Ubuntu GLIBC 2.27-3ubuntu1.6) 2.27
cgo=1
pkg=./cmd/wriggler
git=03d8dea 协议修改
build_time=2026-11-12 15:02:35
```

---

## 四、cgo 的两条路线（写死，不可配置）

| 命令 | CGO_ENABLED | 产物 | 适用 |
|---|---|---|---|
| `make build` | 固定 `0` | 纯静态，**不依赖 glibc** | 纯 Go 项目 |
| `make docker-build` | 固定 `1` | 动态链接，glibc ≤ 2.27 | 依赖 cgo 的项目 |

判断依据：`go.mod` 里有 `import "C"`、`confluent-kafka-go`、`mattn/go-sqlite3`、`pebbe/zmq4` 之类就得走 docker。

- 纯 Go 项目**不要**进容器——本地编出来的静态二进制最稳，线上什么 glibc 都能跑。
- cgo 项目 `make build` 会报编译错误，改用 `make docker-build` 即可。

基础镜像已预装的 C 库：

```
gcc g++ make pkg-config  git curl wget zip unzip
libssl-dev  libsqlite3-dev  zlib1g-dev  libbz2-dev  liblzma-dev
libcurl4-openssl-dev  libxml2-dev  uuid-dev  libzmq3-dev
```

> 需要其他 C 库时，**改 `Dockerfile` 的 apt 列表然后 `./goenv.sh apply --force`**，
> 不要往项目里塞 apt-get（那会退化成每个项目各自装一遍）。

---

## 五、日常使用

### 项目里（推荐）

```bash
cd ~/code/wriggler          # cgo 项目
make docker-build                       # 容器编译，产物 -> ./bin
make docker-build GO_VERSION=<版本>      # 临时换 Go 版本
make docker-zip                         # 编完打个 zip
make clean

cd ~/code/mudslide_drone    # 纯 Go 项目
make build                              # 本地编译，纯静态，不进容器
```

项目 Makefile 里有哪些目标取决于该项目：纯 Go 项目只需 `build`，
cgo 项目用 `docker-build`。两者可以共存，各自独立。

### 直接调脚本（临时验证、没 Makefile 的项目）

> 注意：直接跑脚本**不会读项目 Makefile 里的 `GO_VERSION`**，不传 `-g` 就用镜像的默认版本。
> 日常尽量用 `make docker-build`，配置才集中在一处。

```bash
cd /path/to/project
~/code/docker/gocross/gocross-build.sh                 # 默认产物到 <项目>/bin
~/code/docker/gocross/gocross-build.sh -g <版本>       # 指定 Go 版本
~/code/docker/gocross/gocross-build.sh -C /path/to/x   # 指定项目目录
~/code/docker/gocross/gocross-build.sh -o /tmp/out     # 指定产物目录
~/code/docker/gocross/gocross-build.sh --no-cache      # 不用缓存
PKG=/abs/path/to/project/cmd/server ~/code/docker/gocross/gocross-build.sh  # 指定主包（必须绝对路径）
~/code/docker/gocross/gocross-build.sh --help          # 完整参数
```

### 环境镜像管理

```bash
cd ~/code/docker/gocross
./goenv.sh status        # 清单 vs 镜像，要不要重建
./goenv.sh apply         # 按清单重建（无差异自动跳过）
./goenv.sh build         # 只构建并输出镜像名（gocross-build.sh 首次自动调用）
./goenv.sh add <版本>    # 加版本：改 versions.conf 并立即重建
./goenv.sh use <版本>    # 设默认版本（项目没写 GO_VERSION 时用它）
./goenv.sh list          # 列版本
./goenv.sh projects      # 扫所有项目 go.mod，看覆盖情况
./goenv.sh clean         # 删旧镜像
```

---

## 六、Go 版本：怎么配、怎么选

### 配（versions.conf）

```sh
GO_VERSIONS="<版本A> <版本B>"                       # 第一个 = 默认版本
BASE_IMAGE="ubuntu:18.04"
GO_DIST_MIRRORS="https://golang.google.cn/dl https://go.dev/dl https://mirrors.aliyun.com/golang"
```

改完 `./goenv.sh apply`。也可以直接 `./goenv.sh add <版本>`，它会自动改文件、排序、保留默认版本在最前，再重建。

**加版本不会动原有版本**，重建后所有项目照常可用。删版本时 `apply` 会提示哪些版本将被移除。

### 选（指定就用，不做兜底）

```sh
GO_VERSION  ?= <版本>     # 项目 Makefile 里写
```

规则只有两条：

- **没指定** → 用基础镜像的默认版本（`versions.conf` 里 `GO_VERSIONS` 的第一个）
- **指定了** → 必须和镜像里装好的版本**完全一致**，否则直接报错

```
!! 镜像里没有 go1.20
   可用版本：<镜像里的版本列表>
   加版本：  ./goenv.sh add 1.20
```

写 `1.18` 而镜像里装的是 `1.18.x` 也不会自动匹配，同样是上面的报错。
这是刻意的：版本必须**写死、对得上**，方便一眼看出每个项目用的是哪个工具链。

### 已知限制：低版本 Go 读不了高版本 go.mod

go1.18/1.19 遇到三位版本号（如 `go 1.24.1`）会直接报 `invalid go version`。这是 Go 自身的限制。
遇到就二选一：用匹配的高版本工具链，或把 go.mod 的 `go` 行调低。

## 七、移植到新项目

### 步骤

```bash
cd /path/to/newproj
cp ~/code/docker/gocross/templates/Makefile.tmpl Makefile
sed -i "s/__PROJECT__/$(basename $(pwd))/g" Makefile
make docker-build
```

### 需要核对的变量（只有这几个）

| 变量 | 说明 |
|---|---|
| `PROJECT` | 项目名，决定 `PKG` 和 `OUTPUT` 的默认值 |
| `PKG` | 主包目录的**绝对路径**：`PKG = $(ROOT_DIR)/cmd/$(PROJECT)`。默认就是 `<项目根>/cmd/<项目名>`，`main.go` 在别处时改这一行 |
| `DIST_FILES` | 交付时从 `cmd/项目/` 复制进 `bin` 的配置，空格分隔，不存在的自动跳过 |
| `GO_VERSION` | 必须是镜像里装好的版本 |

### 固有两个约定

**1. main.go 里版本信息的变量名固定为 `gitInfo` / `buildTime`**

```go
var (
    gitInfo   string   // 编译时 -X 注入，git 提交信息
    buildTime string   // 编译时 -X 注入，构建时间
)
```

> `-X` 对不存在的变量是**静默忽略**的：名字写错不会报错，只会一直是空字符串。
> 老项目常见叫 `commitID`，移植时务必改名并验证：
> `./bin/<程序> --version` 或 `grep -a "$(git show --format='%h' -s)" bin/<程序>`

**2. 交付文件由 Makefile 从本地复制，不进容器**

```make
DIST_FILES = config.toml kafka.pem
```

Makefile 里这段负责复制（不存在就跳过，不会报错）：

```make
@$(foreach f,$(DIST_FILES),[ -f $(CMD_DIR)/$(f) ] && cp $(CMD_DIR)/$(f) $(BIN_DIR)/ || true;)
```

### 已移植的项目

| 项目 | 方式 | GO_VERSION |
|---|---|---|
| `wriggler` | cgo，走 `docker-build` | 1.26.11 |
| `dragonfly` | cgo，走 `docker-build` | 1.26.11 |
| `mudslide_drone` | 纯 Go，只走本地 `build`，没有 docker 目标 | — |

### 想改编译流程怎么办

只有一份编译流程 `Dockerfile.gocross`，没有 per-project 的 Dockerfile。

- **所有项目都要改**（比如加 `-s -w`）→ 直接改 `Dockerfile.gocross`，下次编译全部生效
- **需要换编译环境**（加 C 库）→ 改 `Dockerfile` 的 apt 列表，再 `./goenv.sh apply --force`
- **单个项目要特殊处理** → 在 Makefile 里用 `BUILD_EXTRA_ARGS` 传参，
  或 `make docker-build DOCKERFILE=/path/to/自定义 Dockerfile`

---

## 八、排错手册

| 现象 | 原因 | 处理 |
|---|---|---|
| `version `GLIBC_2.34' not found` | 用的是本地产物 | 改用 `make docker-build` |
| `镜像里没有 goX.Y.Z` + 可用版本列表 | 版本没装，或 Makefile 写错 | `./goenv.sh add X.Y.Z`，或改 Makefile 的 `GO_VERSION` |
| `invalid go version 'x.y.z'` | go1.18/1.19 读不了三位版本号 | 换高版本工具链，或调低 go.mod |
| `PKG 必须是绝对路径` | 写成了 `./cmd/xxx` 这种相对路径 | 改成 `$(ROOT_DIR)/cmd/xxx` |
| `主包目录不存在：/abs/...` | `main.go` 不在这个目录下 | 按实际位置改 `PKG` |
| 编译成功但 `--version` 是空的 | `gitInfo` 变量名不对 | 见第七章约定 1 |
| 产物文件属主是 root | 不该出现（已映射 uid/gid） | 检查 `Dockerfile.project-env` 的 `USER_ID` |
| 构建变慢 | 前面镜像层失效了 | `./goenv.sh status` 看清单是否和镜像一致 |
| `DEPRECATED: The legacy builder` | 用的是传统 builder | 可忽略，为兼容性刻意不用 BuildKit |

常用排查命令：

```bash
./goenv.sh status                      # 镜像和清单一致吗
./goenv.sh projects                    # 各项目的 go 版本覆盖情况
docker images | grep -E 'gocross|buildenv'
readelf -V bin/<程序> | grep -o 'GLIBC_[0-9.]*' | sort -u   # 产物到底要求什么
docker images gocross/build-env        # 基础镜像列表
```

---

## 九、换机器 / 重建

```bash
# 整目录拷到新机器后
cd ~/code/docker/gocross
./goenv.sh apply            # 首次会下载 Go，3~5 分钟

# 改了 Dockerfile 之后必须强制重建
./goenv.sh apply --force
./goenv.sh apply --force --no-cache   # 完全不用缓存
```

要点：

- 镜像是**联网下载安装** Go（`golang.google.cn` → `go.dev` → 阿里云），不需要本地 SDK
- Ubuntu 18.04 已 EOL，官方源会 404，`Dockerfile` 里已把 apt 源换成阿里云；**公司内网请改那一行 `sed`**
- 项目 Makefile 里的 `GOCROSS_DIR` 默认写死 `/home/zhang/code/docker/gocross`，换用户/换路径时改它

---

## 十、设计上的几个取舍

**为什么不用 `golang:1.26` 官方镜像？**
官方镜像基于较新的 Debian，glibc 版本高——那正是问题的来源。

**为什么不用 BuildKit 的 `--mount=type=cache`？**
能更快，但需要 BuildKit。当前用传统 builder 保持最大兼容，`go build` 自身缓存已足够。

**为什么项目环境镜像每次都要重建？**
它只有 `ENV`/`RUN useradd` 几条指令，走缓存几乎不花时间；换来的是切换 Go 版本、
切换用户时永远不会拿错镜像。

**为什么产物不用 `docker cp` 而用 `tar | tar`？**
`docker run ... tar -c | tar -x` 不需要容器常驻，且属主由容器内映射的用户决定，落盘即是当前用户。
