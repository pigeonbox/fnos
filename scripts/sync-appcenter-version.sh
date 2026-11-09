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
# shellcheck source=scripts/fnos-env.sh
. "${SCRIPT_DIR}/fnos-env.sh"

VERSION=""
APP_NAME="pigeonbox"
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --app-name)
      APP_NAME="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      OK=1
      exit 0
      ;;
    *)
      echo "✗ 未知参数：$1"
      exit 2
      ;;
  esac
done

# 临时 SQL 文件(权限 644 => 切到 postgres 用户后仍可读)。
SQLFILE="$(mktemp)"
chmod 644 "${SQLFILE}"
# ⚠️ EXIT trap 必须**保留退出码**(hub 门禁 check-shell-trap-exit-code.sh):
#   macOS bash 3.2 下未定义变量失败时 trap 入口的 $? 是 0 => 失败被报成 exit 0
#   => 门禁形同虚设。正确形态=成功哨兵:结尾置 OK=1,trap 里 rc≠0 原样返回。
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -f "${SQLFILE}"; if [ "${rc}" -ne 0 ]; then exit "${rc}"; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

if [ -z "${VERSION}" ]; then
  echo "✗ 缺 --version(目标版本)——用法：bash $0 --version <ver> [--app-name pigeonbox]"
  exit 2
fi
if [ "${PB_UPGRADE_SANDBOX:-0}" = "1" ]; then
  echo "[sandbox] 跳过应用中心注册表版本同步：沙箱模式不碰宿主 PostgreSQL"
  OK=1
  exit 0
fi

# ── 前置事实:宿主 PostgreSQL 客户端在不在 ──────────────────────────────────
PSQL_BIN="$(command -v psql 2>/dev/null || true)"
if [ -z "${PSQL_BIN}" ]; then
  echo "⊘ 跳过应用中心注册表版本同步：本机没有 psql 客户端 => 不是 fnOS 宿主(或未装 PostgreSQL)"
  echo "  (说明：应用中心注册表在宿主 PostgreSQL 里；非 fnOS 主机没有这张表，同步无从谈起)"
  OK=1
  exit 0
fi

# SQL 走临时文件 => 不必在一堆引号里嵌套 SQL(引号地狱是这类脚本最常见的坏法)。
run_pg() { # <sql> ; 打印结果行(失败返回非 0)
  local sql="$1"
  printf '%s\n' "${sql}" > "${SQLFILE}"
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
  echo "⊘ 跳过应用中心注册表版本同步：宿主 PostgreSQL 上没有可用的 appcenter 库/app 表"
  echo "  (说明：注册表在**宿主** PostgreSQL 15 的 appcenter 库里，不在容器里的 pg18；"
  echo "        若本机确实装了应用中心却查不到这张表，请核对该机 pg_hba/库名)"
  OK=1
  exit 0
fi

CURRENT="$(run_pg "SELECT version FROM app WHERE app_name='${APP_NAME}'" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
if [ -z "${CURRENT}" ]; then
  echo "⊘ 跳过应用中心注册表版本同步：appcenter.app 里没有 app_name='${APP_NAME}' 的行"
  echo "  (说明：本应用未在应用中心注册，面板本来就不显示它，无需同步)"
  OK=1
  exit 0
fi

echo "── 应用中心注册表当前版本：${CURRENT} => 目标版本：${VERSION}"
if [ "${CURRENT}" = "${VERSION}" ]; then
  echo "✓ 注册表版本已是 ${VERSION}，无需改动"
  OK=1
  exit 0
fi

if [ "${DRY_RUN}" = "1" ]; then
  echo "[dry-run] 将执行：UPDATE app SET version='${VERSION}' WHERE app_name='${APP_NAME}';"
  OK=1
  exit 0
fi

SQL="UPDATE app SET version='${VERSION}' WHERE app_name='${APP_NAME}';"
if ! run_pg "${SQL}" >/dev/null 2>&1; then
  echo "✗ 应用中心注册表版本同步失败（UPDATE 未成功）"
  echo "  手工补救： sudo su postgres -c \"psql -d appcenter -c \\\"UPDATE app SET version='${VERSION}' WHERE app_name='${APP_NAME}';\\\"\""
  exit 1
fi

AFTER="$(run_pg "SELECT version FROM app WHERE app_name='${APP_NAME}'" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
if [ "${AFTER}" != "${VERSION}" ]; then
  echo "✗ 注册表版本同步后回读为 '${AFTER}'，与目标 ${VERSION} 不符"
  echo "  手工补救： sudo su postgres -c \"psql -d appcenter -c \\\"UPDATE app SET version='${VERSION}' WHERE app_name='${APP_NAME}';\\\"\""
  exit 1
fi
echo "✓ 应用中心注册表版本已同步：${CURRENT} => ${AFTER}"
OK=1
exit 0
