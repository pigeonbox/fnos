#!/usr/bin/env bash
# fnOS 运维脚本的**公共小函数**（被 source,不做任何顶层副作用）。
#
# 三个脚本共用同一套「事实读取」口径,避免各自抄一份、慢慢漂移:
#   scripts/upgrade-inplace.sh        —— 原地换装(启停 + 断言)
#   scripts/sync-appcenter-version.sh —— 应用中心注册表版本同步(fnos#201)
#   scripts/verify-upgrade-result.sh  —— 升级后断言(fnos#200/#201)
#
# ⚠️ 本文件只放**纯函数**:不得有顶层副作用、不得 exit、不得改全局变量。
# ⚠️ 变量名后不得紧跟非 ASCII 字符(全角括号/冒号/汉字)⇒ bash 会把它并进变量名
#    (hub 门禁 scripts/check-shell-var-boundary.sh)。

# fnos_manifest_field <manifest文件> <字段名> —— 读 fnOS manifest 的字段值。
#
# 为什么不用固定的 cut 位置:manifest 的字段写法有两种
#   appname=pigeonbox            (仓内 fnos/manifest)
#   version               = 5.7.0 (fnpack 打包形态)
# ⇒ 必须按「字段名 = 值」解析,两种都吃。
fnos_manifest_field() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" \
    | head -1 \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//'
}

# fnos_proc_env_value <pid> <变量名> —— 读运行中进程 environ 里的某个变量。
#
# 用途:升级脚本在**停应用之前**把框架注入的 TRIM_* 取出来(TRIM_PKGVAR /
# TRIM_APPDEST / TRIM_APPNAME)。框架注入的这些变量只有它自己知道真值,
# 我们只能「问还在跑的那个进程」,猜是猜不准的。
fnos_proc_env_value() {
  local pid="$1" key="$2"
  [ -n "$pid" ] || return 1
  [ -r "/proc/${pid}/environ" ] || return 1
  tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null \
    | grep "^${key}=" | head -1 | cut -d= -f2- || true
}

# fnos_appcenter_cli —— 定位 fnOS 应用中心 CLI(appcenter-cli)。
#
# 为什么必须用框架自己的 CLI 启停(fnos#200):
#   TRIM_APPDEST / TRIM_APPNAME / TRIM_API_TOKEN 这些变量是**框架在拉起
#   生命周期脚本时注入**的 ⇒ 只有框架托管的启动路径才有它们。
#   手工 nohup 起进程 ⇒ 没有 TRIM_APPDEST ⇒ adapter 判不出原生应用环境 ⇒
#   /api/fnos/capabilities 回报 gateway=false/sso=false ⇒ 面板「统一网关免登录」
#   静默失效(而脚本退出码 0、版本自证全绿)。
#
# 退出码:0=找到(路径打到 stdout) / 1=没找到(非 fnOS 主机或未装应用中心)。
fnos_appcenter_cli() {
  local c
  if [ -n "${PB_APPCENTER_CLI:-}" ]; then
    if [ -x "${PB_APPCENTER_CLI}" ]; then
      printf '%s\n' "${PB_APPCENTER_CLI}"
      return 0
    fi
    return 1
  fi
  c="$(command -v appcenter-cli 2>/dev/null || true)"
  if [ -n "${c}" ]; then
    printf '%s\n' "${c}"
    return 0
  fi
  for c in /usr/bin/appcenter-cli /usr/local/bin/appcenter-cli /usr/sbin/appcenter-cli \
           /usr/trim/appcenter/appcenter-cli /usr/trim/bin/appcenter-cli \
           /opt/fnos/bin/appcenter-cli; do
    if [ -x "${c}" ]; then
      printf '%s\n' "${c}"
      return 0
    fi
  done
  return 1
}
