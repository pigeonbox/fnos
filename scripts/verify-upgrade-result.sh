#!/usr/bin/env bash
# 升级后断言(fnos#200 / fnos#201)——**有牙齿**的两条:
#
#   A. /api/fnos/capabilities 的 gateway/sso 必须是 true
#      (前提:本机被 fnOS 应用中心纳管)
#   B. 应用中心注册表里的版本必须 == 目标版本
#      (面板显示的版本必须等于实际运行的代码)
#
# 为什么必须有这两条(fnos#200/201 实录,2026-11-10 真机 10.10.30.253):
#   ① 原地换装脚本此前**自己拉起进程**(nohup + env TRIM_PKGVAR=...)
#      ⇒ 只注入了 TRIM_PKGVAR,**没有 TRIM_APPDEST**
#      ⇒ TRIM_APPDEST 是**框架在拉起生命周期脚本时注入**的,手工拉起就没有
#      ⇒ adapter 判不出「原生应用环境」⇒ /api/fnos/capabilities 回报
#         gateway=false / sso=false ⇒ 面板「统一网关免登录」**静默失效**
#      而脚本退出码 0、/version 自证全绿 ⇒ 典型的**静默半升级**。
#      (真机实录:改用 appcenter-cli stop/start 框架托管启停 ⇒ 恢复 true/true。)
#   ② 注册表里的版本没同步 ⇒ 面板显示 4.8.6、实际跑 5.7.0
#      ⇒ 面板显示版本 != 实际运行代码。
#
# 「本机被网关纳管」的判据(拿不到就跳过并说明,绝不静默放过):
#   appcenter-cli 存在 **且** appcenter-cli list 里有本应用的条目。
#   非 fnOS 宿主 / 应用未在应用中心注册 ⇒ 本就不该有统一网关 ⇒ 跳过。
#
# 沙箱(PB_UPGRADE_SANDBOX=1):**跳过并说明原因**,退出码 0
#   —— 离线门禁不得被真机断言打断(沙箱里没有真机进程、没有应用中心、
#   没有宿主 PostgreSQL,断言必然假红)。
#
# 用法:
#   PB_TARGET_VERSION=5.7.0 bash scripts/verify-upgrade-result.sh
# 环境变量:
#   PB_TARGET_VERSION  目标版本(必填)
#   PB_APP_ROOT        应用目录(默认 /var/apps/pigeonbox)
#   PB_PKGVAR          数据目录(默认 /vol1/@appdata/pigeonbox)
#   PB_APP_NAME        应用名(默认 pigeonbox)
#   PB_UPGRADE_SANDBOX 1=沙箱(跳过断言)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/fnos-env.sh
. "${SCRIPT_DIR}/fnos-env.sh"

TARGET_VERSION="${PB_TARGET_VERSION:-}"
APP_ROOT="${PB_APP_ROOT:-/var/apps/pigeonbox}"
PKGVAR="${PB_PKGVAR:-/vol1/@appdata/pigeonbox}"
APP_NAME="${PB_APP_NAME:-pigeonbox}"
SANDBOX="${PB_UPGRADE_SANDBOX:-0}"

FAILURES=0
ok()   { printf '  ✓ %s\n' "$1"; }
bad()  { printf '  ✗ %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
skip() { printf '  ⊘ 跳过：%s\n' "$1"; }

# 目标版本为空 ⇒ **只跳过断言 B**(版本对账),断言 A(网关能力)照跑。
# (读不到目标版本说明 manifest 形态变了,那是另一件事,不该把网关能力也放跑。)

if [ "${SANDBOX}" = "1" ]; then
  echo "[sandbox] 跳过升级后断言：沙箱模式不启真机进程、不连应用中心、不碰宿主 PostgreSQL"
  echo "          (fnos#200/#201 的断言只对真机有意义,对沙箱断言必然假红)"
  exit 0
fi

# ── 端口口径:运行时端口(.env) > manifest service_port > 12345 ─────────────
# cmd/main 的优先级是「框架注入 > .env > 12345」,而 .env 是向导写的
# ⇒ 真机端口先看 .env,再看 manifest(面板端口),最后兜底默认。
detect_port() {
  local p=""
  if [ -r "${PKGVAR}/.env" ]; then
    p="$(sed -n 's/^[[:space:]]*PB_SERVER_PORT[[:space:]]*=[[:space:]]*//p' "${PKGVAR}/.env" 2>/dev/null \
      | head -1 | tr -d '"' | tr -d '[:space:]')"
  fi
  if [ -z "${p}" ]; then
    p="$(fnos_manifest_field "${APP_ROOT}/manifest" service_port 2>/dev/null || true)"
  fi
  case "${p}" in
    ''|*[!0-9]*) p=12345 ;;
  esac
  printf '%s\n' "${p}"
}

PORT="$(detect_port)"
CAPS_URL="http://127.0.0.1:${PORT}/api/fnos/capabilities"

# ── 前置:应用中心 CLI + 注册表条目 ─────────────────────────────────────────
APPCENTER="$(fnos_appcenter_cli 2>/dev/null || true)"
if [ -z "${APPCENTER}" ]; then
  skip "未找到 appcenter-cli ⇒ 本机不是 fnOS 应用中心纳管环境(无应用中心即无统一网关前端)"
  echo "  (说明：统一网关免登录与面板版本对账都只在应用中心纳管的主机上成立)"
  exit 0
fi

LIST_OUT="$("${APPCENTER}" list 2>&1 || true)"
ROW="$(printf '%s\n' "${LIST_OUT}" | grep -i -- "${APP_NAME}" | head -1 || true)"
if [ -z "${ROW}" ]; then
  skip "appcenter-cli list 里没有 ${APP_NAME} 的条目 ⇒ 本应用未在应用中心注册,不做断言"
  echo "  (appcenter-cli list 原始输出：)"
  printf '%s\n' "${LIST_OUT}" | sed 's/^/    /' | head -20
  exit 0
fi

echo "── 断言 A：/api/fnos/capabilities 的 gateway/sso 必须为 true"
# 刚启完的应用可能还在起 ⇒ 最多等 20s 让探测端点可答。
CAPS=""
for _i in $(seq 1 20); do
  CAPS="$(curl -s -m 3 "${CAPS_URL}" 2>/dev/null || true)"
  if [ -n "${CAPS}" ]; then break; fi
  sleep 1
done
if [ -z "${CAPS}" ]; then
  bad "探测不到 ${CAPS_URL}(应用没起来或端口不对,端口取 ${PORT})"
  echo "    补救： sudo ${APPCENTER} start ${APP_NAME}"
else
  # JSON 容错:允许 "gateway" 与冒号之间有空白(Go 的 json.Marshal 不加空白,
  # 但代理/网关重写后可能有)。
  GW="$(printf '%s' "${CAPS}" | grep -o '"gateway"[[:space:]]*:[[:space:]]*[a-z]*' | head -1 | sed 's/.*:[[:space:]]*//' || true)"
  SSO="$(printf '%s' "${CAPS}" | grep -o '"sso"[[:space:]]*:[[:space:]]*[a-z]*' | head -1 | sed 's/.*:[[:space:]]*//' || true)"
  if [ "${GW}" = "true" ] && [ "${SSO}" = "true" ]; then
    ok "gateway=true sso=true(统一网关免登录可用)"
  else
    bad "capabilities 回报 gateway=${GW:-?} sso=${SSO:-?} ⇒ 统一网关免登录已失效(fnos#200)"
    echo "    补救： sudo ${APPCENTER} stop ${APP_NAME} && sudo ${APPCENTER} start ${APP_NAME}"
    echo "          (只有**框架托管**的启停才会注入 TRIM_APPDEST ⇒ 网关能力才会打开;"
    echo "           手工 nohup 起进程没有该变量 ⇒ 面板上看着正常、实际免登录是坏的)"
  fi
fi

if [ -z "${TARGET_VERSION}" ]; then
  skip "读不到目标版本(PB_TARGET_VERSION 为空)⇒ 无法做注册表版本对账"
  echo
  if [ "${FAILURES}" -gt 0 ]; then
    echo "PASS=0 FAIL=${FAILURES}(升级**不算完成**：上面的补救命令跑完再重跑本脚本)"
    exit 1
  fi
  echo "PASS=1 FAIL=0(网关能力对账通过;版本对账因缺目标版本被跳过)"
  exit 0
fi

echo "── 断言 B：应用中心注册表版本必须 == 目标版本 ${TARGET_VERSION}"
# 注册表版本从「本应用那一行」里取。该行可能还带别的版本串(如 os_min_version)
# ⇒ 判据是「该行里**包含**目标版本」,而不是「该行的第一个版本串」。
# 行解析失败(格式变了)时退一步:用 python3 解析整段 JSON(若可用)。
REG_VERSIONS="$(printf '%s\n' "${ROW}" | grep -oE '[0-9]+(\.[0-9]+)+' | tr '\n' ' ' | tr -s ' ' || true)"
if [ -z "${REG_VERSIONS}" ] && command -v python3 >/dev/null 2>&1; then
  REG_VERSIONS="$(printf '%s' "${LIST_OUT}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
want = sys.argv[1].lower()
def walk(o):
    if isinstance(o, dict):
        name = (o.get("app_name") or o.get("appname") or o.get("name") or "").lower()
        ver = o.get("version") or ""
        # 只取**本应用**的版本(否则别的应用的版本会被误当成本应用的)。
        if name and ver and (name == want or want in name):
            print(ver)
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(data)
' "${APP_NAME}" 2>/dev/null | tr '\n' ' ' | tr -s ' ' || true)"
fi
NORMALIZED_TARGET="$(printf '%s' "${TARGET_VERSION}" | sed 's/^v//')"
MATCH=0
for v in ${REG_VERSIONS}; do
  if [ "$(printf '%s' "${v}" | sed 's/^v//')" = "${NORMALIZED_TARGET}" ]; then
    MATCH=1
    break
  fi
done
if [ "${MATCH}" = "1" ]; then
  ok "注册表版本包含 ${TARGET_VERSION}(行：${ROW})"
else
  bad "应用中心注册表里的版本(${REG_VERSIONS:-解析不出})不含目标版本 ${TARGET_VERSION}(fnos#201)"
  echo "    补救： sudo bash scripts/sync-appcenter-version.sh --version ${TARGET_VERSION}"
  echo "          (注册表在**宿主 PostgreSQL**的 appcenter 库里,不在容器里的 pg 容器;"
  echo "           直接改表： sudo su postgres -c \"psql -d appcenter -c \\\"UPDATE app SET version='${TARGET_VERSION}' WHERE app_name='${APP_NAME}';\\\"\")"
fi

echo
if [ "${FAILURES}" -gt 0 ]; then
  echo "PASS=0 FAIL=${FAILURES}(升级**不算完成**：上面的补救命令跑完再重跑本脚本)"
  exit 1
fi
echo "PASS=1 FAIL=0(网关能力与注册表版本都对账通过)"
exit 0
