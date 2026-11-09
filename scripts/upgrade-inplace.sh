#!/usr/bin/env bash
# fnOS 原地换装(官方姿势固化,2026-10-12):
#   appcenter-cli install-fpk 对已装应用是 no-op("is installed" 直接退出),
#   升级一律走本脚本。干净换装=先清 www/bin 再解包——根除历代产物残留
#   (五代 chunk 曾累积 423 个 js,旧版本戳制造「页脚版本陈旧」幽灵伪差异)。
#
# ⚠️ 2026-11-04 真机实录(4.1.2→4.8.5)补的一条:**生命周期脚本必须一起换**。
#   本脚本此前**只换 target/{www,bin,ui}**,**从不换 /var/apps/pigeonbox/cmd/**
#   ⇒ 4.8.5 新增的 cmd/prewire_beam_box 缺席、cmd/main 停在旧版(不给 p2pcweb
#   传 --config-file)⇒ p2pcweb 配置回退到 os.UserConfigDir()(包用户跑时 HOME
#   继承自 root ⇒ 写不了)⇒ Beam 的「文件柜」配置存不住 —— 正是 4.8.5 要修的缺陷。
#   ⇒ 装了新二进制却跑着旧生命周期 = **静默半升级**。
#   ⇒ 现在本脚本同时换 **cmd/ + manifest + wizard/**(面板 config/ 保留)。
#   守卫: scripts/check-upgrade-inplace-cmd-sync.sh(离线假 fpk + 负对照)。
#
# ⚠️ 2026-11-04 另一条真机坑:fnOS 应用中心**装不了原生第三方包** ⇒ 升级走本脚本;
#   但**动手前必须先备份**(应用中心的 install-local 是「卸载→安装」语义,
#   会连 @appdata(含 DB) 与注册表行一起删掉)。
#
# ⚠️ 2026-11-10 真机实录(10.10.30.253,4.8.6→5.7.0)补的两条(fnOS#200 / fnOS#201):
#
#   ① **启停必须走框架托管**(appcenter-cli stop/start),不能自己 nohup 拉进程。
#      本脚本此前最后一步是:
#        nohup sudo -u <pkguser> env TRIM_PKGVAR="$PKGVAR" bash "$APP_ROOT/cmd/main" start &
#      只注入了 TRIM_PKGVAR,**没有 TRIM_APPDEST**。而 TRIM_APPDEST /
#      TRIM_APPNAME / TRIM_API_TOKEN 这些变量是**框架在拉起生命周期脚本时注入**
#      的 ⇒ 手工拉起的进程里压根没有 ⇒ adapter 判不出「原生应用环境」
#      ⇒ /api/fnos/capabilities 回报 gateway=false / sso=false
#      ⇒ 面板「统一网关免登录」**静默失效**;而脚本退出码 0、/version 自证全绿
#      ⇒ 典型的**静默半升级**(真机实录:改用 appcenter-cli stop/start 后
#      恢复 {gateway:true, sso:true})。
#
#      **为什么选「框架托管」而不是「手工补 TRIM_APPDEST」**:
#        · TRIM_APPDEST 的**真值由框架掌握**(应用安装目录),人工推导容易错;
#        · 更要命的是 adapter 判网关只看「TRIM_APPDEST 非空」就置 gateway=true
#          ⇒ 手工塞一个**猜错**的 TRIM_APPDEST ⇒ capabilities 照样报 true,
#            但 app.sock 落在网关找不到的地方 ⇒ **假绿**,比原来的假红更坏;
#        · 框架托管还顺带把 TRIM_API_TOKEN(官方后端 API)等一并注入。
#        ⇒ 结论:启停**一律**走 appcenter-cli;appcenter-cli 不存在时明确降级
#          并由尾部断言把「网关能力失效」喊出来(不静默)。
#
#   ② **应用中心注册表的版本要同步**(fnOS#201):本脚本换的是磁盘上的文件,
#      而**面板显示的版本**来自应用中心注册表(宿主 PostgreSQL 15 的
#      appcenter 库里的 app 表,**不在**应用自己起的 pg18 容器里)
#      ⇒ 不同步就是「面板显示 4.8.6、实际跑 5.7.0」。
#      同步由 scripts/sync-appcenter-version.sh 做,尾部断言负责对账。
#
#   尾部两条**有牙齿**的断言(不满足 ⇒ 非 0 退出 + 打印补救命令):
#     A. /api/fnos/capabilities 的 gateway/sso 必须为 true
#     B. appcenter-cli list 里的版本必须 == 目标版本
#     两者都跑在 scripts/verify-upgrade-result.sh 里;沙箱模式(PB_UPGRADE_SANDBOX=1)
#     **跳过并说明原因**(离线门禁不得被真机断言打断)。
#
# 用法: sudo bash upgrade-inplace.sh <pigeonbox.fpk>
# 升级后验真: curl -s http://127.0.0.1:12345/version.txt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/fnos-env.sh
. "${SCRIPT_DIR}/fnos-env.sh"

FPK="${1:?用法: sudo bash upgrade-inplace.sh <pigeonbox.fpk>}"
# 应用目录(默认生产路径;可覆盖 ⇒ 门禁脚本能离线自检而不碰真机)
APP_ROOT="${PB_APP_ROOT:-/var/apps/pigeonbox}"
T="${PB_UPGRADE_TARGET:-$APP_ROOT/target}"
# 沙箱模式:离线门禁用 ⇒ 只做「解包 + 替换」,绝不碰真机的 stop/pkill/start/chown。
PB_UPGRADE_SANDBOX="${PB_UPGRADE_SANDBOX:-0}"
# 包用户(沙箱里换成本机用户 ⇒ 门禁也能真跑 chown 这一步)
PB_PKG_USER="${PB_PKG_USER:-pigeonbox}"
PB_PKG_GROUP="${PB_PKG_GROUP:-pigeonbox}"
[ -f "$FPK" ] || { echo "✗ 找不到 $FPK"; exit 1; }

echo "[1/6] 备份机器配置(config/configs,解包会覆盖)"
BK=/tmp/pigeonbox-cfg-backup-$(date +%s)
mkdir -p "$BK"
cp -a "$T/config" "$BK/config"
cp -a "$T/configs" "$BK/configs"

# cmd/main 全程依赖框架注入的 TRIM_PKGVAR(数据根/.env/.admin_reset/日志路径),
# 手工调用必须显式注入——否则数据根漂到包目录、重置标记不消费(2026-10-13 实锤)。
# 优先从运行中进程 environ 取(多卷场景),否则默认 vol1。
#
# ⚠️ 2026-10-26 审计 P1:原实现是**一条含命令替换的赋值**:
#   PKGVAR=$(tr "\0" "\n" < /proc/$(pgrep -f "target/bin/pigeonbox" | head -1)/environ \
#            2>/dev/null | grep "^TRIM_PKGVAR=" | cut -d= -f2)
# 在 `set -e` + `pipefail` 下,**赋值语句的退出码取自命令替换** ⇒
#   · 进程不存在   ⇒ 重定向失败 ⇒ 管道返回 1;
#   · 进程在但 environ 无该变量 ⇒ grep 返回 1 ⇒ pipefail 传导 ⇒ 同样返回 1;
# ⇒ set -e 立刻终止脚本 ⇒ 脚本**死在读 PKGVAR 这步**(连 "[2/6] 停应用"都到不了),
#   错误信息还被 2>/dev/null 吞掉 ⇒ 用户只看到一条无上下文的退出。
#   而这恰恰是「应用已停/已崩/上一轮升级中途失败 ⇒ 正需要重试」的场景;
#   任何非 fnOS 框架方式启动的实例首次升级也必然失败。
# ⇒ 修法:取值与赋值**拆开**,逐段显式兜底(取不到就当「没取到」,绝不因此终止脚本)。
PBGVAR_PID="$(pgrep -f 'target/bin/pigeonbox' 2>/dev/null | head -1 || true)"
PBGVAR_RAW=""
if [ -n "$PBGVAR_PID" ] && [ -r "/proc/$PBGVAR_PID/environ" ]; then
  PBGVAR_RAW="$(tr '\0' '\n' < "/proc/$PBGVAR_PID/environ" 2>/dev/null | grep '^TRIM_PKGVAR=' | cut -d= -f2 || true)"
fi
PKGVAR="${PBGVAR_RAW:-/vol1/@appdata/pigeonbox}"

# 应用名(应用中心注册表里的 app_name):从已装 manifest 取,取不到用默认。
APP_NAME="$(fnos_manifest_field "$APP_ROOT/manifest" appname 2>/dev/null || true)"
APP_NAME="${APP_NAME:-pigeonbox}"

# 启停方式:**框架托管优先**(appcenter-cli)—— 理由见文件头 2026-11-10 那段。
# 找不到 CLI 时不静默:明确降级,并由尾部断言把「网关能力失效」喊出来。
APPCENTER_CLI="$(fnos_appcenter_cli 2>/dev/null || true)"

# 框架注入的 TRIM_APPDEST / TRIM_APPNAME 只有框架知道真值 ⇒ 只能从**停之前的**
# 运行中进程 environ 里问出来(框架托管拉起时才有)。拿不到就留空(不猜):
# 猜错 ⇒ adapter 照样报 gateway=true 但 app.sock 落在网关找不到的地方 ⇒ 假绿。
APPDEST="$(fnos_proc_env_value "$PBGVAR_PID" TRIM_APPDEST 2>/dev/null || true)"
APPNAME="$(fnos_proc_env_value "$PBGVAR_PID" TRIM_APPNAME 2>/dev/null || true)"

echo "[2/6] 停应用(TRIM_PKGVAR=$PKGVAR)"
# 干跑:解析出 PKGVAR 后立刻退出,不做任何变更。
# 用途:门禁脚本要能验证「取不到 PKGVAR 时脚本仍能走到 [2/6]」(见同目录
# check-upgrade-inplace-pkgvar.sh)。
if [ "${PB_UPGRADE_DRYRUN:-0}" = "1" ]; then
  echo "[dryrun] 已解析 PKGVAR=$PKGVAR —— 不停应用/不解包"
  exit 0
fi
# 沙箱模式:离线门禁只验「替换」,不碰真机进程。
if [ "$PB_UPGRADE_SANDBOX" != "1" ]; then
  if [ -n "$APPCENTER_CLI" ]; then
    # 框架托管停机:框架知道应用已停 ⇒ 不会在我们换文件的窗口里把它拉起来。
    echo "  · 框架托管停机: $APPCENTER_CLI stop $APP_NAME"
    "$APPCENTER_CLI" stop "$APP_NAME" || true
    sleep 2
  else
    echo "  · 未找到 appcenter-cli ⇒ 只能直接停生命周期脚本"
  fi
  # 兜底:直接停生命周期脚本 + pkill(与框架托管并存,幂等)。
  TRIM_PKGVAR="$PKGVAR" bash "$APP_ROOT/cmd/main" stop 2>/dev/null || true
  sleep 2
  pkill -f "target/bin/pigeonbox" 2>/dev/null || true
  sleep 1
else
  echo "[sandbox] 跳过停应用(不碰真机进程)"
fi

echo "[3/6] 干净解包(rm -rf www bin ui → 解包,杜绝旧产物残留)"
UNPACK="${PB_UPGRADE_UNPACK:-/tmp/fpk-unpack}"
rm -rf "$UNPACK" && mkdir -p "$UNPACK"
tar xzf "$FPK" -C "$UNPACK"
[ -f "$UNPACK/app.tgz" ] || { echo "✗ fpk 无 app.tgz"; exit 1; }
rm -rf "${T:?}/www" "${T:?}/bin" "${T:?}/ui"
tar xzf "$UNPACK/app.tgz" -C "$T"

# ── [3.5/6] 生命周期脚本 + manifest 必须一起换(2026-11-04 真机实录) ──
#   只换 target/{www,bin,ui} ⇒ **新生命周期脚本缺席** ⇒ 装了新二进制却跑旧
#   生命周期 = 静默半升级(见文件头)。cmd/ 干净替换(先 rm -rf 再 cp -a)。
if [ -d "$UNPACK/cmd" ]; then
  rm -rf "${APP_ROOT:?}/cmd"
  mkdir -p "${APP_ROOT:?}/cmd"
  cp -a "$UNPACK/cmd/." "${APP_ROOT:?}/cmd/"
  chmod 755 "${APP_ROOT:?}/cmd"/*
  echo "✓ cmd/ 已换($(find "${APP_ROOT}/cmd" -maxdepth 1 -type f | wc -l) 个文件)"
else
  echo "✗ fpk 根无 cmd/ —— 原生 fpk 必须带 cmd/(fnpack native 约定)"
  exit 1
fi
# manifest:桌面入口/服务端口等元信息随版本走。
if [ -f "$UNPACK/manifest" ]; then
  cp -a "$UNPACK/manifest" "${APP_ROOT:?}/manifest"
  echo "✓ manifest 已换(version=$(grep -E '^version' "${APP_ROOT}/manifest" | tr -s ' ' | cut -d' ' -f3))"
fi
# wizard/:fnOS 面板的向导文案(随版本走;不含机器状态,换是安全的)。
if [ -d "$UNPACK/wizard" ]; then
  rm -rf "${APP_ROOT:?}/wizard"
  mkdir -p "${APP_ROOT:?}/wizard"
  cp -a "$UNPACK/wizard/." "${APP_ROOT:?}/wizard/"
fi
# config/(privilege+resource)是 **fnOS 面板配置** ⇒ 保留;与包内不一致时告警。
if [ -d "$UNPACK/config" ] && [ -d "${APP_ROOT:?}/config" ]; then
  if ! diff -r "$UNPACK/config" "${APP_ROOT}/config" >/dev/null 2>&1; then
    echo "⚠ 面板 config/ 与包内不一致 —— 保留面板现状(fnOS 面板配置优先)"
  fi
fi

echo "[4/6] 还原机器配置"
cp -a "$BK/config/." "$T/config/"
cp -a "$BK/configs/." "$T/configs/"

echo "[5/6] 属主归位"
chown -R "${PB_PKG_USER}:${PB_PKG_GROUP}" "$T"

echo "[5.5/6] 数据目录属主归位(root 实例曾写花 app.log→框架起不来,2.1.0 真机实锤)"
chown -R "${PB_PKG_USER}:${PB_PKG_GROUP}" "$PKGVAR" 2>/dev/null || true

echo "[6/6] 启应用(TRIM_PKGVAR=$PKGVAR,看门狗后台,勿占管道)"
# 沙箱模式:离线门禁不启真机(**也不做尾部断言**,见 [6.8/6])。
if [ "$PB_UPGRADE_SANDBOX" = "1" ]; then
  echo "[sandbox] 跳过启动(不碰真机进程)"
else
  if [ -n "$APPCENTER_CLI" ]; then
    # ✅ 框架托管启动(fnOS#200 的正解):框架在拉起生命周期脚本时注入
    #    TRIM_APPDEST / TRIM_APPNAME / TRIM_API_TOKEN ⇒ adapter 判得出
    #    「原生应用环境」⇒ 统一网关 + SSO 免登录可用。
    #    手工 nohup 起进程拿不到这些变量 ⇒ capabilities 回报
    #    gateway=false/sso=false ⇒ 面板「统一网关免登录」静默失效。
    echo "  · 框架托管启动: $APPCENTER_CLI start $APP_NAME"
    "$APPCENTER_CLI" start "$APP_NAME" || true
  else
    # ⚠️ 降级路径:本机没有应用中心 CLI ⇒ 只能手工拉起。
    #    此时**显式补**框架注入的 TRIM_APPDEST / TRIM_APPNAME —— 取值只认
    #    「停之前那个运行中进程的 environ」(框架自己的真值);
    #    猜路径(如 /var/apps/<pkg> 与 /var/apps/<pkg>/target 哪个对)是不行的:
    #    猜错 ⇒ adapter 照样报 gateway=true,但 app.sock 落在网关找不到的地方
    #    ⇒ **假绿**(比原来的假红更坏)。
    #    两者都拿不到 ⇒ 只能裸启动 ⇒ 网关能力必然是关的 ⇒ 由 [6.8/6] 断言喊出来。
    echo "  · 未找到 appcenter-cli ⇒ 降级为手工拉起"
    if [ -n "$APPDEST" ]; then
      echo "    · 注入 TRIM_APPDEST=$APPDEST(取自停之前的运行中进程)"
    else
      echo "    ⚠ 拿不到 TRIM_APPDEST(无运行中进程可问)⇒ 统一网关能力必然失效"
      echo "      补救: 装好应用中心后执行 $APPCENTER_CLI start $APP_NAME"
    fi
    # 必须以应用用户启动:sudo 跑本脚本时直接 start 会拉起 root 实例,占端口+写花
    # 数据目录,fnOS 框架随后「端口被占用」拒启(2026-10-19 真机实锤;对齐框架
    # appcenter-cli start 的应用用户语义)。
    if [ -n "$APPDEST" ] && [ -n "$APPNAME" ]; then
      nohup sudo -u "${PB_PKG_USER}" env TRIM_PKGVAR="$PKGVAR" \
        TRIM_APPDEST="$APPDEST" TRIM_APPNAME="$APPNAME" \
        bash "$APP_ROOT/cmd/main" start >/dev/null 2>&1 &
    else
      nohup sudo -u "${PB_PKG_USER}" env TRIM_PKGVAR="$PKGVAR" \
        bash "$APP_ROOT/cmd/main" start >/dev/null 2>&1 &
    fi
  fi
  for _i in $(seq 1 30); do pgrep -f "target/bin/pigeonbox" >/dev/null && break; sleep 1; done
  if pgrep -f "target/bin/pigeonbox" >/dev/null; then
    echo "✓ 进程已起"
  else
    echo "✗ 启动失败"
    exit 1
  fi
fi

# 目标版本 = 刚装上去的那份 manifest 的版本(面板该显示的就是它)。
TARGET_VERSION="$(fnos_manifest_field "$APP_ROOT/manifest" version 2>/dev/null || true)"
TARGET_VERSION="${TARGET_VERSION:-$(fnos_manifest_field "$UNPACK/manifest" version 2>/dev/null || true)}"

echo "[6.5/6] 应用中心注册表版本同步(fnos#201)"
# 注册表在**宿主 PostgreSQL 15 的 appcenter 库**里,不在应用自己起的 pg18
# 容器里 ⇒ 换完盘不更新它,面板显示的就是旧版(4.8.6)而实际跑的是新版。
# 无 PostgreSQL / 非 fnOS 环境 ⇒ 该脚本明确提示并跳过(不静默跳过)。
if [ "$PB_UPGRADE_SANDBOX" = "1" ]; then
  echo "[sandbox] 跳过注册表版本同步(不碰宿主 PostgreSQL)"
elif [ -z "$TARGET_VERSION" ]; then
  echo "⚠ 读不到目标版本(manifest 里没有 version 字段)⇒ 跳过注册表版本同步"
else
  bash "$SCRIPT_DIR/sync-appcenter-version.sh" --version "$TARGET_VERSION" --app-name "$APP_NAME" \
    || echo "⚠ 注册表版本同步未成功(见上面的补救命令)—— [6.8/6] 的断言会判红"
fi

echo "[6.8/6] 升级后断言(网关能力 + 注册表版本)"
# 两条**有牙齿**的断言,不满足 ⇒ 非 0 退出 + 打印补救命令:
#   A. /api/fnos/capabilities 的 gateway/sso 必须为 true
#   B. appcenter-cli list 里的版本必须 == 目标版本
# 沙箱模式 ⇒ 跳过并说明原因(离线门禁不得被真机断言打断)。
if [ "$PB_UPGRADE_SANDBOX" = "1" ]; then
  echo "[sandbox] 跳过升级后断言(沙箱无真机进程/无应用中心/无宿主 PostgreSQL)"
elif [ -z "$TARGET_VERSION" ]; then
  echo "⚠ 读不到目标版本 ⇒ 跳过注册表版本对账(网关能力断言仍会跑)"
  PB_TARGET_VERSION="" PB_APP_ROOT="$APP_ROOT" PB_PKGVAR="$PKGVAR" \
    PB_APP_NAME="$APP_NAME" PB_UPGRADE_SANDBOX="$PB_UPGRADE_SANDBOX" \
    bash "$SCRIPT_DIR/verify-upgrade-result.sh" || exit 1
else
  PB_TARGET_VERSION="$TARGET_VERSION" PB_APP_ROOT="$APP_ROOT" PB_PKGVAR="$PKGVAR" \
    PB_APP_NAME="$APP_NAME" PB_UPGRADE_SANDBOX="$PB_UPGRADE_SANDBOX" \
    bash "$SCRIPT_DIR/verify-upgrade-result.sh" || exit 1
fi
echo "── 验真: curl -s http://127.0.0.1:12345/version.txt"
