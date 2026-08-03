#!/usr/bin/env bash
#
# build.sh — 一键编译 grok (xai-grok-pager) 二进制
#
# 用法:
#   ./build.sh              # release 构建(默认,产物可直接运行)
#   ./build.sh --debug      # debug 构建(更快,带调试符号)
#   ./build.sh --check      # 只做 cargo check(快速验证,不产出二进制)
#   ./build.sh -- --offline # 透传额外 cargo 参数(-- 之后)
#   PROTOC=/path/to/protoc ./build.sh   # 指定 protoc 路径
#
# 脚本会自动检测并补齐依赖:rustup / Rust 工具链 / protoc。
# 仓库根目录的 rust-toolchain.toml 锁定了 Rust 版本,rustup 会自动安装。
# 可重复运行:已安装的依赖会跳过,已编译的产物会被 cargo 增量复用。

set -euo pipefail

# ---------------------------- 颜色输出 ----------------------------
if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_RESET=''
fi
info()  { printf '%s==>%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s!!%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
error() { printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { error "$*"; exit 1; }

# ---------------------------- 定位仓库根 ----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
[[ -f Cargo.toml ]] || die "未在脚本所在目录找到 Cargo.toml (当前: $SCRIPT_DIR)。请把本脚本放在仓库根目录。"

print_usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------------------------- 解析参数 ----------------------------
PROFILE="release"
CARGO_CMD="build"
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)   PROFILE="debug"; shift ;;
    --release) PROFILE="release"; shift ;;
    --check)   CARGO_CMD="check"; PROFILE="debug"; shift ;;
    -h|--help) print_usage ;;
    --)        shift; while [[ $# -gt 0 ]]; do EXTRA_ARGS+=("$1"); shift; done ;;
    *)         EXTRA_ARGS+=("$1"); shift ;;
  esac
done

# ---------------------------- 1. Rust / rustup ----------------------------
ensure_rust() {
  if command -v cargo >/dev/null 2>&1 && command -v rustup >/dev/null 2>&1; then
    info "Rust 已就绪: $(cargo --version 2>/dev/null || echo 'cargo')"
  else
    warn "未检测到 rustup/cargo,开始安装 Rust 工具链..."
    if command -v curl >/dev/null 2>&1; then
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    else
      die "安装 rustup 需要 curl 或 wget,请先安装其一。"
    fi
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
    info "Rust 安装完成: $(cargo --version)"
  fi

  # 触发 rust-toolchain.toml 锁定版本的安装/同步,避免在编译阶段才卡住。
  if [[ -f rust-toolchain.toml ]]; then
    info "同步仓库锁定的工具链 (rust-toolchain.toml)..."
    info "如需下载/安装工具链,请耐心等待(可能需要几分钟)..."
    rustup show active-toolchain 2>&1 || true
  fi
}
ensure_rust

# ---------------------------- 2. protoc ----------------------------
ensure_protoc() {
  # (a) 已通过环境变量指定
  if [[ -n "${PROTOC:-}" ]] && [[ -x "$PROTOC" ]]; then
    info "使用 \$PROTOC 指定的 protoc: $($PROTOC --version 2>/dev/null || echo "$PROTOC")"
    return
  fi
  # (b) PATH 上已有 protoc
  if command -v protoc >/dev/null 2>&1; then
    export PROTOC="$(command -v protoc)"
    info "使用 PATH 上的 protoc: $(protoc --version)"
    return
  fi
  # (c) 项目自带 dotslash protoc(bin/protoc 是 dotslash 清单)
  if command -v dotslash >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/bin/protoc" ]]; then
    warn "通过 dotslash 使用项目自带 bin/protoc(未设置 \$PROTOC)。"
    return
  fi
  # (d) 都没有 -> 安装系统 protoc
  warn "未检测到 protoc,尝试安装..."
  case "$(uname -s)" in
    Darwin)
      command -v brew >/dev/null 2>&1 || die "未找到 Homebrew,请先安装 (https://brew.sh) 或手动安装 protoc。"
      brew install protobuf
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y protobuf-compiler
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y protobuf-compiler
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm protobuf
      elif command -v apk >/dev/null 2>&1; then
        sudo apk add --no-cache protobuf-dev
      else
        die "未识别的 Linux 包管理器,请手动安装 protoc (protobuf-compiler)。"
      fi
      ;;
    *) die "不支持的系统: $(uname -s)" ;;
  esac
  command -v protoc >/dev/null 2>&1 || die "protoc 安装失败。"
  export PROTOC="$(command -v protoc)"
  info "protoc 安装完成: $(protoc --version)"
}
ensure_protoc

# ---------------------------- 3. 编译 ----------------------------
BIN_NAME="xai-grok-pager"
CARGO_ARGS=("$CARGO_CMD" -p xai-grok-pager-bin)
[[ "$PROFILE" == "release" ]] && CARGO_ARGS+=(--release)
# bash 3.2 (macOS 自带) 在 set -u 下展开空数组会报错,这里先判断长度。
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  CARGO_ARGS+=("${EXTRA_ARGS[@]}")
fi

info "开始编译: cargo ${CARGO_ARGS[*]}"
if [[ "$PROFILE" == "release" ]]; then
  info "release 全量编译可能需要 10-30 分钟,请耐心等待..."
fi
START=$(date +%s)
cargo "${CARGO_ARGS[@]}"
ELAPSED=$(( $(date +%s) - START ))

# ---------------------------- 4. 汇报结果 ----------------------------
if [[ "$CARGO_CMD" == "build" ]]; then
  ARTIFACT="$SCRIPT_DIR/target/$PROFILE/$BIN_NAME"
  if [[ -x "$ARTIFACT" ]]; then
    SIZE=$(du -h "$ARTIFACT" | cut -f1)
    echo
    info "编译成功 ✔  (用时 ${ELAPSED}s)"
    printf '  %s产物%s  %s\n' "$C_BLUE" "$C_RESET" "$ARTIFACT"
    printf '  %s大小%s  %s\n' "$C_BLUE" "$C_RESET" "$SIZE"
    printf '  %s版本%s  %s\n' "$C_BLUE" "$C_RESET" "$(GROK_DISABLE_AUTOUPDATER=1 "$ARTIFACT" --version 2>/dev/null || echo '(无法获取版本)')"
    echo
    echo "  用法:"
    echo "    $ARTIFACT --version"
    echo "    $ARTIFACT                      # 启动 TUI"
    echo "    $ARTIFACT -p '你好'            # headless 模式"
    echo "    $ARTIFACT -p '你好' --output-format streaming-json   # 事件流(可用于记录交互)"
    echo
    echo "  可选:建别名  alias grok=$ARTIFACT"
  else
    die "编译结束但未找到产物: $ARTIFACT"
  fi
else
  info "cargo check 通过 ✔  (用时 ${ELAPSED}s)"
fi
