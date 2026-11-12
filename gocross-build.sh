#!/usr/bin/env bash
# =============================================================================
# gocross-build.sh —— 在固定环境（Ubuntu 18.04）里编译 Go 项目
#
# 解决的问题：本地系统 glibc 较新，编出来的二进制到线上（老系统）运行报
#   "/lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.34' not found"。
#   Ubuntu 18.04 的 glibc 是 2.27，在这里编译即可兼容 glibc >= 2.27 的线上机器。
#
# 用到的镜像（决定了日常编译速度）：
#   1) gocross/build-env:xxx     基础镜像：OS + 工具链 + C 库 + 多个 Go 版本
#                                —— 由 goenv.sh 构建一次，之后不动
#   2) <project>-buildenv:goX    项目环境镜像：FROM 基础镜像，只设 GOROOT 和用户
#                                —— 每次编译都重建，走缓存几乎不耗时
#   3) <project>-builder:goX     编译镜像：FROM 项目环境镜像 + 源码 + 编译结果
#                                —— 每次编译都重建，源码在其中
#   源码作为 build context 参与，所以改代码一定生效，不会用到旧代码。
#
# 用法（在项目根目录）:
#   /home/zhang/code/docker/gocross/gocross-build.sh
#   GO_VERSION=<版本> /home/zhang/code/docker/gocross/gocross-build.sh
#
# 用法（在别的目录指定项目）:
#   /home/zhang/code/docker/gocross/gocross-build.sh -C /path/to/project
#
# 可用环境变量（Makefile 就是通过设置它们来驱动的）:
#   GO_VERSION   Go 版本，必须是镜像里装好的完整版本（goenv.sh list 查看）
#                不设则用基础镜像的默认版本
#   PKG          主包路径，如 ./cmd/xxx；不设则用 ./cmd/<项目名>
#   OUTPUT       产物文件名，默认 = 项目目录名
#   DOCKERFILE   指定用哪个 Dockerfile（也支持 -f）
#   OUTPUT_DIR   宿主机产物落盘目录，默认 <project>/bin（也可用 -o）
#   BUILD_EXTRA_ARGS  传给 docker build 的额外参数，如 "--build-arg X=1"
#   GOPROXY      Go 模块代理，默认 https://goproxy.cn,direct
#   DOCKER_HOST_UID   产物文件属主（默认当前用户），避免 root 生成的文件本地改不了
#   GIT_INFO / BUILD_TIME   注入版本信息，默认自动取 git 提交 / 当前时间
#
# 注意：本脚本固定 CGO_ENABLED=1（走 docker 的就是 cgo 项目）。
#       纯 Go 项目别进容器，本地 make build 出静态二进制即可。
#
# 可选参数:
#   -C <dir>              项目目录（默认当前目录）
#   -g|--go <version>     Go 版本
#   -f|--file <path>      项目构建文件
#   -o|--output <dir>     宿主机产物目录
#   -t|--tag <tag>        额外打一个标签，如 v1.2.3
#   --no-cache            docker build 不用缓存
#   --env-dir <dir>       基础镜像/脚本所在目录（默认: 本脚本所在目录）
# =============================================================================
set -euo pipefail

# 打印本文件开头那段注释作为帮助（第 1 行是 shebang，跳过）
show_help() { awk 'NR==1 {next} /^#[^=]/ {sub(/^# ?/,""); print; next} /^#=/ {next} /^#/ {print ""; next} {exit}' "$0"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 计时 + 日志
# ---------------------------------------------------------------------------
_T0=$SECONDS
step()  { printf '\n\033[1;36m==> %s\033[0m  \033[2m[t+%ss]\033[0m\n' "$*" "$((SECONDS - _T0))"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
die()   { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
PROJECT_DIR="$PWD"
GO_VERSION="${GO_VERSION:-}"
PROJECT_FILE=""
OUTPUT_DIR=""
EXTRA_TAG=""
NO_CACHE=""
ENV_DIR="$SELF_DIR"

while [ $# -gt 0 ]; do
    case "$1" in
        -C)                 PROJECT_DIR="$2"; shift 2 ;;
        -g|--go)            GO_VERSION="$2"; shift 2 ;;
        -f|--file)          PROJECT_FILE="$2"; shift 2 ;;
        -o|--output)        OUTPUT_DIR="$2"; shift 2 ;;
        -t|--tag)           EXTRA_TAG="$2"; shift 2 ;;
        --no-cache)         NO_CACHE="--no-cache"; shift ;;
        --env-dir)          ENV_DIR="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *)                  die "unknown argument: $1 (try --help)" ;;
    esac
done

PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || die "project dir not found"
cd "$PROJECT_DIR"

PROJECT="$(basename "$PROJECT_DIR")"
# docker 镜像 tag 只允许小写：dingyueGo / club-system 这类目录名要转小写
PROJECT_TAG="$(printf '%s' "$PROJECT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-')"
GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
BUILD_EXTRA_ARGS="${BUILD_EXTRA_ARGS:-}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/bin}"
DOCKER_HOST_UID="${DOCKER_HOST_UID:-$(id -u):$(id -g)}"

# 产物名 / 主包路径（PKG 必须是绝对路径，由 Makefile 的 $(ROOT_DIR) 拼出来）
OUTPUT="${OUTPUT:-${PROJECT}}"
PKG="${PKG:-${PROJECT_DIR}/cmd/${PROJECT}}"
case "$PKG" in
    /*) ;;
    *)  die "PKG 必须是绝对路径，如 \$(ROOT_DIR)/cmd/xxx（当前：${PKG}）" ;;
esac
[ -d "$PKG" ] || die "主包目录不存在：${PKG}"
# go build 需要相对路径，容器内工作目录是 /app
PKG="./${PKG#${PROJECT_DIR}/}"

command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "docker daemon not running"

# ---------------------------------------------------------------------------
# 1. 基础镜像：不存在就让 goenv.sh 构建一次（之后永远复用）
# ---------------------------------------------------------------------------
[ -f "${ENV_DIR}/goenv.sh" ] || die "cannot find ${ENV_DIR}/goenv.sh (use --env-dir)"
BASE_IMAGE="$(cat "${ENV_DIR}/.build-env-image" 2>/dev/null || true)"
if [ -z "$BASE_IMAGE" ] || ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    step "build-env image not found, building it (first time only)"
    BASE_IMAGE="$("${ENV_DIR}/goenv.sh" build)"
fi
step "base image: ${BASE_IMAGE}"

# ---------------------------------------------------------------------------
# 2. 确定 Dockerfile 和 Go 版本
# ---------------------------------------------------------------------------
# 用哪个 Dockerfile：-f / DOCKERFILE 指定，否则用本目录的 Dockerfile.gocross
PROJECT_FILE="${PROJECT_FILE:-${DOCKERFILE:-${ENV_DIR}/Dockerfile.gocross}}"
[ -f "$PROJECT_FILE" ] || die "build file not found: $PROJECT_FILE"

# Go 版本：指定了就用指定的，没指定用镜像默认；必须是镜像里装好的完整版本
GO_VERSION="${GO_VERSION:-$(docker run --rm "$BASE_IMAGE" sh -c 'basename "$GOROOT" | sed "s/^go//"')}"
docker run --rm "$BASE_IMAGE" test -x "/opt/go/go${GO_VERSION}/bin/go" || die "镜像里没有 go${GO_VERSION}
   可用版本：$(docker run --rm "$BASE_IMAGE" sh -c 'for d in /opt/go/*; do basename "$d" | sed "s/^go//"; done' | sort -V | tr '\n' ' ')
   加版本：  ${ENV_DIR}/goenv.sh add ${GO_VERSION}"
step "go version: go${GO_VERSION}   cgo=1   project=${PROJECT}"

# ---------------------------------------------------------------------------
# 3. 项目镜像：FROM 基础镜像，只叠加版本选择 + 用户映射（秒级）
#    版本名带哈希，切换 Go 版本不会命中错误的缓存层
# ---------------------------------------------------------------------------
PROJECT_IMAGE_ID="$(printf '%s|uid=%s' "$GO_VERSION" "$DOCKER_HOST_UID" \
    | sha256sum | cut -c1-12)"
PROJECT_IMAGE="${PROJECT_TAG}-buildenv:go${GO_VERSION}-${PROJECT_IMAGE_ID}"

GIT_INFO="${GIT_INFO:-$(git -C "$PROJECT_DIR" show --oneline -s 2>/dev/null || true)}"
BUILD_TIME="${BUILD_TIME:-$(date '+%Y-%m-%d %H:%M:%S')}"

step "building project env image: ${PROJECT_IMAGE}"
docker build \
    ${NO_CACHE:+$NO_CACHE} \
    -f "${ENV_DIR}/Dockerfile.project-env" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "GO_VERSION=${GO_VERSION}" \
    --build-arg "GOPROXY=${GOPROXY}" \
    --build-arg "USER_ID=${DOCKER_HOST_UID%%:*}" \
    --build-arg "GROUP_ID=${DOCKER_HOST_UID##*:}" \
    -t "$PROJECT_IMAGE" \
    "$ENV_DIR" \
    | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 4. 编译：源码作为 build context（改代码即失效缓存，不会用到旧代码）
# ---------------------------------------------------------------------------
step "compiling (context: ${PROJECT_DIR})"
docker build \
    ${NO_CACHE:+$NO_CACHE} \
    -f "$PROJECT_FILE" \
    --build-arg "BASE_IMAGE=${PROJECT_IMAGE}" \
    --build-arg "PROJECT_NAME=${PROJECT}" \
    --build-arg "GO_VERSION=${GO_VERSION}" \
    --build-arg "PKG=${PKG}" \
    --build-arg "OUTPUT=${OUTPUT}" \
    --build-arg "GIT_INFO=${GIT_INFO}" \
    --build-arg "BUILD_TIME=${BUILD_TIME}" \
    ${BUILD_EXTRA_ARGS:+$BUILD_EXTRA_ARGS} \
    -t "${PROJECT_TAG}-builder:go${GO_VERSION}" \
    "$PROJECT_DIR" \
    | sed 's/^/    /'

if [ -n "$EXTRA_TAG" ]; then
    docker tag "${PROJECT_TAG}-builder:go${GO_VERSION}" "${PROJECT_TAG}-builder:${EXTRA_TAG}"
    info "additionally tagged: ${PROJECT_TAG}-builder:${EXTRA_TAG}"
fi

# ---------------------------------------------------------------------------
# 5. 导出产物：把镜像里 /app/bin 的内容落到宿主机（文件属主 = 当前用户）
# ---------------------------------------------------------------------------
step "exporting artifacts to ${OUTPUT_DIR}"
mkdir -p "$OUTPUT_DIR"
docker run --rm "${PROJECT_TAG}-builder:go${GO_VERSION}" sh -c 'cd /app/bin && tar -c .' \
    | tar -x -C "$OUTPUT_DIR"


step "done in $((SECONDS - _T0))s"
ls -lh "$OUTPUT_DIR" | sed 's/^/    /'
