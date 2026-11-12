#!/usr/bin/env bash
# =============================================================================
# goenv.sh —— 编译环境镜像的版本管理（改版本、重建镜像、查看现状）
#
# 版本清单由同目录的 versions.conf 声明，这里是唯一的操作入口。
#
# 用法:
#   ./goenv.sh status            # 看清单 vs 镜像现状，是否需要重建
#   ./goenv.sh apply             # 按清单重建镜像（无差异则跳过）
#   ./goenv.sh build             # 只构建缺失的镜像并输出镜像名（gocross-build.sh 首次调用）
#   ./goenv.sh apply --force     # 强制重建（比如改了 Dockerfile）
#   ./goenv.sh apply --no-cache  # 完全不用缓存
#   ./goenv.sh add <版本>        # 加一个版本：写进 versions.conf 并立即 apply
#   ./goenv.sh use <版本>        # 指定某个版本为默认版本并立即 apply
#   ./goenv.sh list              # 只列清单里的版本
#   ./goenv.sh projects          # 列出各项目 go.mod 声明的 go 版本，核对覆盖情况
#   ./goenv.sh clean             # 清理用不上的旧镜像（基础镜像 + 派生的项目镜像）
# =============================================================================
set -euo pipefail

# 打印本文件开头那段注释作为帮助（第 1 行是 shebang，跳过）
show_help() { awk 'NR==1 {next} /^#[^=]/ {sub(/^# ?/,""); print; next} /^#=/ {next} /^#/ {print ""; next} {exit}' "$0"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${HERE}/versions.conf"
CODE_DIR="$(cd "${HERE}/../.." && pwd)"   # /home/zhang/code

_T0=$SECONDS
step()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
die()   { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$CONF" ] || die "missing $CONF"
# shellcheck disable=SC1090
. "$CONF"

GO_VERSIONS="${GO_VERSIONS:-}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:18.04}"
[ -n "$GO_VERSIONS" ] || die "$CONF 里 GO_VERSIONS 不能为空"

# 镜像名包含版本清单：版本一变，镜像名就变，不会误用旧镜像
tag_go() { echo "$GO_VERSIONS" | tr ' ' '-'; }
target_image() { echo "gocross/build-env:$(echo "$BASE_IMAGE" | tr ':/' '--')-go$(tag_go)"; }

# 当前生效的镜像（.build-env-image 记录的实际构建结果）
current_image() {
    [ -f "${HERE}/.build-env-image" ] && cat "${HERE}/.build-env-image" || true
}

image_go_versions() {
    local img="$1"
    docker run --rm "$img" sh -c 'for d in /opt/go/*; do basename "$d" | sed "s/^go//"; done' 2>/dev/null | sort -V | tr '\n' ' ' | sed 's/ *$//'
}

image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# status：清单 vs 镜像
# ---------------------------------------------------------------------------
do_status() {
    local want cur cur_ver default_ver
    want="$(echo "$GO_VERSIONS" | tr ' ' '\n' | sort -V | tr '\n' ' ' | sed 's/ *$//')"
    cur="$(current_image)"
    default_ver="$(echo "$GO_VERSIONS" | awk '{print $1}')"

    step "版本清单（versions.conf）"
    info "需要的版本 : $want"
    info "默认版本   : $default_ver  （项目没指定 GO_VERSION 时用）"
    info "目标镜像   : $(target_image)"

    step "当前镜像"
    if [ -z "$cur" ]; then
        warn "还没有构建过（.build-env-image 不存在）"
        info "运行： ./goenv.sh apply"
        return 0
    fi
    info "当前镜像   : $cur"
    if ! image_exists "$cur"; then
        warn "该镜像已被删除，需要重建"
        info "运行： ./goenv.sh apply"
        return 0
    fi
    cur_ver="$(image_go_versions "$cur")"
    info "已装版本   : $cur_ver"

    if [ "$cur" = "$(target_image)" ]; then
        ok "已是最新，无需重建"
    else
        warn "镜像名与清单不一致，需要重建"
        info "运行： ./goenv.sh apply"
    fi
}

# ---------------------------------------------------------------------------
# build：供 gocross-build.sh 调用。镜像不存在才构建，最后一行输出镜像名
# ---------------------------------------------------------------------------
do_build() {
    local target; target="$(target_image)"
    if [ "$(current_image)" = "$target" ] && image_exists "$target"; then
        echo "$target"; return 0
    fi
    do_apply quiet >&2    # 进度打到 stderr，stdout 只留给镜像名
    cat "${HERE}/.build-env-image"
}

# ---------------------------------------------------------------------------
# apply：按清单重建。带 quiet 参数时不输出收尾提示（供 do_build 调用）
# ---------------------------------------------------------------------------
do_apply() {
    local cur default_ver missing
    default_ver="$(echo "$GO_VERSIONS" | awk '{print $1}')"
    local target; target="$(target_image)"
    cur="$(current_image)"

    if [ -z "${FORCE:-0}" ] && [ "$cur" = "$target" ] && image_exists "$target"; then
        step "镜像已是最新： $target"
        info "已装版本： $(image_go_versions "$target")"
        info "如需强制重建： ./goenv.sh apply --force"
        return 0
    fi

    # 删版本前检查：还有项目在用的话先提醒（不阻塞，用户可自行决定）
    if [ -n "$cur" ] && image_exists "$cur"; then
        local old new gone v
        old="$(image_go_versions "$cur")"
        new="$(echo "$GO_VERSIONS" | tr ' ' '\n' | sort -V | tr '\n' ' ' | sed 's/ *$//')"
        gone="$(comm -23 <(echo "$old" | tr ' ' '\n' | sort -V) <(echo "$new" | tr ' ' '\n' | sort -V) | tr '\n' ' ')"
        if [ -n "${gone// /}" ]; then
            warn "以下版本将从镜像中移除： $gone"
            info "对应项目请确认不再使用： ./goenv.sh projects"
        fi
    fi

    step "构建镜像 $target"
    info "版本： $GO_VERSIONS   默认： $default_ver"
    step "（首次会下载 Go，约 3~5 分钟；只加版本时通常 1~2 分钟）"

    docker build \
        -f "${HERE}/Dockerfile" \
        ${NO_CACHE:-} \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
        --build-arg "GO_VERSIONS=${GO_VERSIONS}" \
        --build-arg "GO_DEFAULT=${default_ver}" \
        --build-arg "GO_DIST_MIRRORS=${GO_DIST_MIRRORS:-}" \
        -t "$target" \
        "$HERE"

    echo "$target" > "${HERE}/.build-env-image"

    step "完成（用时 $((SECONDS - _T0))s）"
    docker run --rm "$target" sh -c 'for d in /opt/go/*; do "$d/bin/go" version; done' | sed 's/^/    /'
    # 由 build 子命令调用时（gocross-build.sh 首次构建），不重复提示
    if [ "${1:-}" != "quiet" ]; then
        info ""
        info "派生出的项目镜像下次编译会自动重建，无需手动处理。"
    fi
}

# ---------------------------------------------------------------------------
# 修改清单
# ---------------------------------------------------------------------------
conf_set_versions() {
    local v="$1"
    sed -i "s|^GO_VERSIONS=.*|GO_VERSIONS=\"${v}\"|" "$CONF"
    GO_VERSIONS="$v"
}

# 排序：默认版本（第一个）保留在最前，其余按版本号升序
sort_versions() {
    local default_ver rest
    default_ver="$(echo "$GO_VERSIONS" | awk '{print $1}')"
    rest="$(echo "$GO_VERSIONS" | tr ' ' '\n' | grep -vx "$default_ver" | sort -V | tr '\n' ' ' | sed 's/ *$//')"
    echo "${default_ver} ${rest}" | sed 's/ *$//'
}

do_add() {
    local v="${1:-}"
    [ -n "$v" ] || die "用法： ./goenv.sh add <完整版本，如 x.y.z>"
    echo "$v" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || die "版本格式不对：$v（应为 x.y 或 x.y.z）"
    echo "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || warn "$v 没有补丁号，镜像里建议装完整版本"

    local default_ver list
    default_ver="$(echo "$GO_VERSIONS" | awk '{print $1}')"
    list="$(echo "$GO_VERSIONS" | tr ' ' '\n')"

    if echo "$list" | grep -qx "$v"; then
        ok "$v 已在清单里"
        FORCE=0 do_apply
        return 0
    fi

    GO_VERSIONS="$(printf '%s %s' "$GO_VERSIONS" "$v")"
    conf_set_versions "$(sort_versions)"
    ok "已写入 versions.conf: GO_VERSIONS=\"${GO_VERSIONS}\""
    FORCE=0 do_apply
}

do_use() {
    local v="${1:-}"
    [ -n "$v" ] || die "用法： ./goenv.sh use <版本>（先 list 看有哪些）"
    if ! echo "$GO_VERSIONS" | tr ' ' '\n' | grep -qx "$v"; then
        die "$v 不在清单里，先执行： ./goenv.sh add $v"
    fi
    local list
    list="$v $(echo "$GO_VERSIONS" | tr ' ' '\n' | grep -vx "$v" | tr '\n' ' ' | sed 's/ *$//')"
    conf_set_versions "$list"
    ok "默认版本已设为 $v: GO_VERSIONS=\"$list\""
    FORCE=0 do_apply
}

do_list() {
    step "versions.conf 中的 Go 版本"
    for v in $(echo "$GO_VERSIONS" | tr ' ' '\n' | sort -V); do
        if [ "$v" = "$(echo "$GO_VERSIONS" | awk '{print $1}')" ]; then
            printf '    %-10s  (默认)\n' "$v"
        else
            printf '    %-10s\n' "$v"
        fi
    done
}

# ---------------------------------------------------------------------------
# projects：扫描各项目 go.mod，看清单是否覆盖
# ---------------------------------------------------------------------------
do_projects() {
    step "扫描 $CODE_DIR 下各项目 go.mod 的 go 版本"
    # 按 go.mod 里写的版本分组统计，再列出缺的版本对应的项目
    local f v
    declare -A ok_proj miss_proj
    local ok_cnt=0 miss_cnt=0
    for f in "$CODE_DIR"/*/go.mod; do
        [ -f "$f" ] || continue
        v="$(sed -n 's/^go[[:space:]]\+\([0-9][0-9.]*\).*/\1/p' "$f" | head -1)"
        [ -n "$v" ] || continue
        if echo " $GO_VERSIONS " | grep -q " $v "; then
            ok_proj[$v]="${ok_proj[$v]:-} $(basename "$(dirname "$f")")"
            ok_cnt=$((ok_cnt + 1))
        else
            miss_proj[$v]="${miss_proj[$v]:-} $(basename "$(dirname "$f")")"
            miss_cnt=$((miss_cnt + 1))
        fi
    done

    info "镜像里有： $GO_VERSIONS"
    echo
    if [ "$ok_cnt" -gt 0 ]; then
        printf '    \033[1;32m✓ 对得上（%d 个项目）\033[0m\n' "$ok_cnt"
        for v in $(printf '%s\n' "${!ok_proj[@]}" | sort -V); do
            printf '      %-10s %s\n' "$v" "${ok_proj[$v]}"
        done
        echo
    fi
    if [ "$miss_cnt" -gt 0 ]; then
        printf '    \033[1;33m✗ 缺版本（%d 个项目）\033[0m\n' "$miss_cnt"
        for v in $(printf '%s\n' "${!miss_proj[@]}" | sort -V); do
            printf '      %-10s %s\n' "$v" "${miss_proj[$v]}"
            printf '      %-10s 加： ./goenv.sh add %s\n' "" "$v"
        done
    else
        ok "全部对得上"
    fi
}

# ---------------------------------------------------------------------------
# clean：删除不再使用的旧镜像
# ---------------------------------------------------------------------------
do_clean() {
    local target; target="$(target_image)"
    step "清理旧镜像（保留当前的 $target）"
    local list
    list="$(
        docker images --format '{{.Repository}}:{{.Tag}}' \
            | grep -E '^gocross/build-env:' | grep -vx "$target" || true
        docker images --format '{{.Repository}}:{{.Tag}}' \
            | grep -E -- '-buildenv:' || true
    )"   # 派生镜像（<项目>-buildenv:goX）全部可删，下次编译会自动按当前基础镜像重建

    if [ -z "${list//\n/}" ]; then
        ok "没有需要清理的旧镜像"
        return 0
    fi
    local n=0
    while IFS= read -r img; do
        [ -n "$img" ] || continue
        [ "$img" = "$target" ] && continue
        if docker rmi "$img" >/dev/null 2>&1; then
            info "删除 $img"; n=$((n + 1))
        else
            warn "跳过（可能仍被容器使用）： $img"
        fi
    done <<< "$list"
    docker image prune -f >/dev/null 2>&1 || true
    ok "已删除 ${n} 个旧镜像"
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
# 第一个参数是子命令；-h/--help 也允许出现在这个位置
case "${1:-}" in
    -h|--help|help) show_help; exit 0 ;;
esac
CMD="${1:-status}"
shift || true

FORCE=0
NO_CACHE=""
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --force|-f) FORCE=1 ;;
        --no-cache) NO_CACHE="--no-cache" ;;
        -h|--help) show_help; exit 0 ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done

command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "docker daemon not running"

case "$CMD" in
    status)    do_status ;;
    apply)     do_apply ;;
    build)     do_build ;;
    add)       do_add "${POSITIONAL[0]:-}" ;;
    use)       do_use "${POSITIONAL[0]:-}" ;;
    list)      do_list ;;
    projects)  do_projects ;;
    clean)     do_clean ;;
    *)         die "未知命令：$CMD（可用：status/apply/build/add/use/list/projects/clean）" ;;
esac
