#!/usr/bin/env bash
# 应用中心注册表版本同步(fnos#201)——把 appcenter 库里本应用的版本改成目标版本。
#
# 为什么需要(fnos#201 实录,2026-11-10 真机 10.10.30.253):
#   原地换装换的是**磁盘上的文件**(target/{www,bin,ui} + cmd/ + manifest),
#   而应用中心**面板显示的版本**来自 appcenter 注册表(数据库里的 app 表)
#   => 换完盘、版本自证全绿,**面板仍显示旧版**(4.8.6)而实际跑的是 5.7.0
#   => 「面板显示版本 != 实际运行代码」。
#
# !! 注册表在**宿主 PostgreSQL 15 的 appcenter 库**里,
#    **不在**应用自己起的 pg18 容器里(容器里那份是业务库,不是应用中心注册表)
#    => 必须在宿主上改,且别去动容器里的库。
#
# 宿主侧访问方式(真机实录):
#   sudo su postgres -c "psql -d appcenter -c \"UPDATE app SET version='X' WHERE app_name='pigeonbox';\""
#   (pg_hba 是 local all postgres peer map=trim_root => peer 认证,不认密码)
#
# 行为约定:
#   · 无 PostgreSQL / 非 fnOS 环境 => **明确提示并跳过**(不静默跳过、不假绿)
#   · 找不到 appcenter 库或 app 表 => 明确提示并跳过
#   · 改完回读校验 => 版本对不上 => 非 0 退出
#
# 用法:
#   bash scripts/sync-appcenter-version.sh --version 5.7.0 [--app-name pigeonbox]
#   bash scripts/sync-appcenter-version.sh --version 5.7.0 --dry-run
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── shellkit v1.0.0 公共库（编译/部署/CI 侧管道：日志/退出码/参数解析/清理）──
# third_party/shellkit 是**上游镜像**（由 hub 侧 scripts/vendor-shellkit.sh 物化）⇒ 一个字节都不许手改；
# 完整性由 hub 侧 scripts/check-shellkit-vendor.sh 逐文件 sha256 对账。
# ⚠️ 不给 shellcheck 指路：third_party/ 是上游镜像，不进 shellcheck 射程。
# ⚠️ 落点是 third_party/ 而不是 vendor/：Go ≥1.14 见到**模块根**下有 vendor/ 就默认切
#    vendor 模式 ⇒ 缺 vendor/modules.txt ⇒ go build 报 "inconsistent vendoring"（实测现红）。
. "${REPO_ROOT}/third_party/shellkit/lib/bootstrap.sh"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}" # 库内消息走中文，与生态输出一致

# shellcheck source=scripts/fnos-env.sh
. "${SCRIPT_DIR}/fnos-env.sh"

VERSION=""
APP_NAME="pigeonbox"
DRY_RUN=0

# -h/--help：沿用原来的用法输出 ⇒ 在 cli_opts 之前先截住。
#   取法从固定行号 '2,30p' 改成「第 2 行起的注释块」——文件头插了公共库引导块后
#   固定行号会漂到代码行上（原来就已经漂到 set 行上了）。
for arg in "$@"; do
  case "$arg" in
    -h | --help)
      sed -n '2,/^[^#]/p' "$0" | sed '$d'
      exit 0
      ;;
    # 原实现只认「--version 5.7.0」这种写法；'--version=5.7.0' 一律当未知参数(exit 2)
    # ⇒ 这里显式保持同一口径（cli_opts 本身是接受 '=' 写法的）。
    --*=*)
      echo "✗ 未知参数：$arg" >&2
      exit 2
      ;;
  esac
done

# 参数解析：手写 case 循环 ⇒ shellkit 的 cli_opt/cli_opts
#   · 未知选项 / 缺值 ⇒ cli_opts 返回 2（= 原来的「未知参数」退出码，逐字一致）
#   · 顺带修掉一个挂死：原实现里 '--version' 后面没跟值时 shift 2 失败且**不推进**
#     ⇒ while 循环原地打转（永远出不来）⇒ 现在由 cli_opts 直接判「缺值」并退出 2。
cli_opt_init
cli_opt VERSION --version "" 1
cli_opt APP_NAME --app-name "" 1
cli_opt DRY_RUN --dry-run "" 0
cli_opts "$@" || exit 2

# 临时 SQL 文件(权限 644 => 切到 postgres 用户后仍可读)。
SQLFILE="$(mktemp)"
chmod 644 "${SQLFILE}"
# ⚠️ EXIT trap 必须**保留退出码**(hub 门禁 check-shell-trap-exit-code.sh):
#   macOS bash 3.2 下未定义变量失败时 trap 入口的 $? 是 0 => 失败被报成 exit 0
#   => 门禁形同虚设。
#   ⇒ 现在由 shellkit 的 trap_push + trap_install 承担：清理动作进栈，退出时取 $?
#     并原样 exit（不再依赖「成功哨兵」那套手写形态）。
#   ⇒ 原「成功哨兵 OK=1」在本脚本里是冗余：本脚本**没有 set -e**，但每条失败路径都
#     显式 exit 1、每条跳过路径都显式 exit 0 ⇒ 哨兵永远不会把 0 变成 1。
trap_push 'rm -f "${SQLFILE}"'
trap_install

[ -z "${VERSION}" ] && die 2 "✗ 缺 --version(目标版本)——用法：bash $0 --version <ver> [--app-name pigeonbox]"
if [ "${PB_UPGRADE_SANDBOX:-0}" = "1" ]; then
  log_info "[sandbox] 跳过应用中心注册表版本同步：沙箱模式不碰宿主 PostgreSQL"
  exit 0
fi

# ── 前置事实:宿主 PostgreSQL 客户端在不在 ──────────────────────────────────
PSQL_BIN="$(command -v psql 2>/dev/null || true)"
if [ -z "${PSQL_BIN}" ]; then
  log_info "⊘ 跳过应用中心注册表版本同步：本机没有 psql 客户端 => 不是 fnOS 宿主(或未装 PostgreSQL)"
  log_info "  (说明：应用中心注册表在宿主 PostgreSQL 里；非 fnOS 主机没有这张表，同步无从谈起)"
  exit 0
fi

# SQL 走临时文件 => 不必在一堆引号里嵌套 SQL(引号地狱是这类脚本最常见的坏法)。
run_pg() { # <sql> ; 打印结果行(失败返回非 0)
  local sql="$1"
  printf '%s\n' "${sql}" >"${SQLFILE}"
  if command -v su >/dev/null 2>&1 && id postgres >/dev/null 2>&1; then
    su postgres -c "${PSQL_BIN} -d appcenter -tA -f ${SQLFILE}" 2>/dev/null && return 0
  fi
  if command -v sudo >/dev/null 2>&1 && id postgres >/dev/null 2>&1; then
    sudo -u postgres "${PSQL_BIN}" -d appcenter -tA -f "${SQLFILE}" 2>/dev/null && return 0
  fi
  return 1
}

# ── 前置事实:appcenter 库与 app 表在不在 ──────────────────────────────────
if ! run_pg "SELECT 1 FROM app LIMIT 1" >/dev/null 2>&1; then
  log_info "⊘ 跳过应用中心注册表版本同步：宿主 PostgreSQL 上没有可用的 appcenter 库/app 表"
  log_info "  (说明：注册表在**宿主** PostgreSQL 15 的 appcenter 库里，不在容器里的 pg18；"
  log_info "        若本机确实装了应用中心却查不到这张表，请核对该机 pg_hba/库名)"
  exit 0
fi

CURRENT="$(run_pg "SELECT version FROM app WHERE app_name='${APP_NAME}'" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
if [ -z "${CURRENT}" ]; then
  log_info "⊘ 跳过应用中心注册表版本同步：appcenter.app 里没有 app_name='${APP_NAME}' 的行"
  log_info "  (说明：本应用未在应用中心注册，面板本来就不显示它，无需同步)"
  exit 0
fi

log_info "── 应用中心注册表当前版本：${CURRENT} => 目标版本：${VERSION}"
if [ "${CURRENT}" = "${VERSION}" ]; then
  log_ok "✓ 注册表版本已是 ${VERSION}，无需改动"
  exit 0
fi

if [ "${DRY_RUN}" = "1" ]; then
  log_info "[dry-run] 将执行：UPDATE app SET version='${VERSION}' WHERE app_name='${APP_NAME}';"
  exit 0
fi

SQL="UPDATE app SET version='${VERSION}' WHERE app_name='${APP_NAME}';"
if ! run_pg "${SQL}" >/dev/null 2>&1; then
  die 1 "✗ 应用中心注册表版本同步失败（UPDATE 未成功）
  手工补救： sudo su postgres -c \"psql -d appcenter -c \\\"UPDATE app SET version='${VERSION}' WHERE app_name='${APP_NAME}';\\\"\""
fi

AFTER="$(run_pg "SELECT version FROM app WHERE app_name='${APP_NAME}'" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
if [ "${AFTER}" != "${VERSION}" ]; then
  die 1 "✗ 注册表版本同步后回读为 '${AFTER}'，与目标 ${VERSION} 不符
  手工补救： sudo su postgres -c \"psql -d appcenter -c \\\"UPDATE app SET version='${VERSION}' WHERE app_name='${APP_NAME}';\\\"\""
fi
log_ok "✓ 应用中心注册表版本已同步：${CURRENT} => ${AFTER}"
exit 0
