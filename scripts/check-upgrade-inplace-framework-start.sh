#!/usr/bin/env bash
# 门禁：原地换装脚本必须**走框架托管启停**并**带两条有牙齿的断言**
#        (fnOS#200 统一网关免登录静默失效 / fnOS#201 面板版本 != 实际运行代码)。
#
# 缺陷实录（2026-11-10 真机 10.10.30.253，4.8.6→5.7.0）：
#   scripts/upgrade-inplace.sh 的最后一步此前是
#     nohup sudo -u <pkguser> env TRIM_PKGVAR="$PKGVAR" bash "$APP_ROOT/cmd/main" start &
#   只注入了 TRIM_PKGVAR，**没有 TRIM_APPDEST** —— 而 TRIM_APPDEST /
#   TRIM_APPNAME / TRIM_API_TOKEN 是**框架在拉起生命周期脚本时注入**的
#   ⇒ 手工拉起的进程没有它们 ⇒ adapter 判不出「原生应用环境」
#   ⇒ /api/fnos/capabilities 回报 gateway=false / sso=false
#   ⇒ 面板「统一网关免登录」**静默失效**；而脚本退出码 0、/version 自证全绿
#   ⇒ 典型的**静默半升级**。
#   真机实录：改用 appcenter-cli stop/start（框架托管）后恢复 {true, true}。
#
# 同轮另一条（fnOS#201）：换装只换磁盘文件，而**面板显示的版本**来自应用中心
#   注册表（宿主 PostgreSQL 15 的 appcenter 库，**不在**容器里的 pg18）
#   ⇒ 不同步就是「面板 4.8.6 / 实跑 5.7.0」。
#
# 本门禁**离线**跑（假 fpk + 假应用根 + PB_UPGRADE_SANDBOX=1 + 假 appcenter-cli
# + 假 curl），断言：
#   C1 启停必须走 appcenter-cli（**不得**自己 nohup 拉进程当默认路径）；
#   C2 脚本尾部必须调 verify-upgrade-result.sh（两条断言的载体）；
#   C3 脚本尾部必须调 sync-appcenter-version.sh（注册表版本同步）；
#   C4 沙箱模式下两条断言都**跳过并说明原因**、退出码 0
#      （离线门禁不得被真机断言打断 —— 这一条是本门禁存在的理由）；
#   C5 verify 脚本在「capabilities 报 gateway=false」时必须**非 0 退出**
#      且打印补救命令（断言有牙齿：不是走过场）；
#   C6 verify 脚本在「注册表版本 != 目标版本」时必须**非 0 退出**
#      且打印补救命令；正对照（版本一致）必须退 0（不误报红）；
#   C7 **负对照**：把 upgrade-inplace.sh 里的 appcenter-cli 启停变异掉
#      ⇒ C1 必须变红 ⇒ 证明门禁有区分力、不是空转。
#
# 用法: bash scripts/check-upgrade-inplace-framework-start.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/upgrade-inplace.sh"
VERIFY="$ROOT/scripts/verify-upgrade-result.sh"
SYNC="$ROOT/scripts/sync-appcenter-version.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+  [$2]}"; }

[ -f "$SCRIPT" ] || { echo "找不到 $SCRIPT"; exit 1; }
[ -f "$VERIFY" ] || { echo "找不到 $VERIFY"; exit 1; }
[ -f "$SYNC" ] || { echo "找不到 $SYNC"; exit 1; }

WORK="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$WORK"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

# ── 造假 fpk + 假应用根（结构同 check-upgrade-inplace-cmd-sync.sh）─────────
build_fake_fpk() {
  local out="$1" src="$WORK/fpkroot"
  mkdir -p "$src/cmd" "$src/wizard" "$src/config"            "$src/payload/bin" "$src/payload/www" "$src/payload/ui"            "$src/payload/config" "$src/payload/configs"
  printf '#!/bin/bash\n# NEW MAIN\n'  > "$src/cmd/main"
  printf 'appname=pigeonbox\n'        > "$src/manifest"
  printf 'version=9.9.9\n'            >> "$src/manifest"
  printf 'service_port=12345\n'       >> "$src/manifest"
  chmod 755 "$src/cmd"/*
  printf 'newbin\n'  > "$src/payload/bin/pigeonbox-linux-amd64"
  printf 'newhtml\n' > "$src/payload/www/index.html"
  printf 'ui\n'      > "$src/payload/ui/config"
  printf 'yaml\n'    > "$src/payload/configs/config.yaml"
  tar czf "$WORK/app.tgz" -C "$src/payload" .
  cp "$WORK/app.tgz" "$src/app.tgz"
  tar czf "$out" -C "$src" .
}

build_fake_app() {
  local app="$1"
  mkdir -p "$app/cmd" "$app/config" "$app/wizard"            "$app/target/config" "$app/target/configs"            "$app/target/www" "$app/target/bin" "$app/target/ui"
  printf '#!/bin/bash\n# OLD MAIN\n' > "$app/cmd/main"
  chmod 755 "$app/cmd"/*
  printf 'appname=pigeonbox\n'  > "$app/manifest"
  printf 'version=1.1.1\n'      >> "$app/manifest"
  printf 'service_port=12345\n' >> "$app/manifest"
  printf 'keep\n'   > "$app/target/config/app.conf"
  printf 'keep\n'   > "$app/target/configs/config.yaml"
  printf 'oldhtml\n' > "$app/target/www/index.html"
  printf 'oldbin\n'  > "$app/target/bin/pigeonbox-linux-amd64"
}

# ── 假 appcenter-cli：把调用记录下来（供断言查）──────────────────────────
make_fake_appcenter() {
  local dir="$1" list_out="$2"
  mkdir -p "$dir"
  # 引号 heredoc ⇒ 内容**原样**落盘。
  # list 输出与调用日志路径走**环境变量**（不用 sed -i 填坑：
  # macOS 的 BSD sed -i 会把 -e 当成备份后缀 ⇒ 直接炸）。
  cat > "$dir/appcenter-cli" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${FAKE_APPCENTER_LOG:-/dev/null}"
case "$1" in
  list) printf '%s\n' "${FAKE_APPCENTER_LIST:-}" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$dir/appcenter-cli"
  # list 输出用环境变量带给假 CLI（导出到本函数调用者的环境里）。
  export FAKE_APPCENTER_LIST="$list_out"
}

# C1 的判据：脚本里出现了「用 appcenter-cli **启动**」的调用。
# 只看 start：停机方式不影响网关能力，启动方式才决定 TRIM_APPDEST 有没有。
has_framework_start() {
  grep -qE 'APPCENTER_CLI" start' "$1"
}

echo "── 造假 fpk + 假应用根"
build_fake_fpk "$WORK/pigeonbox.fpk"
build_fake_app "$WORK/app"

echo "── C1/C2/C3 结构断言：启停走 appcenter-cli + 尾部有断言与注册表同步"
if has_framework_start "$SCRIPT"; then
  ok "C1 启停走 appcenter-cli（框架托管）"
else
  bad "C1 启停没走 appcenter-cli" "⇒ TRIM_APPDEST 拿不到 ⇒ 统一网关免登录静默失效(fnOS#200)"
fi
if grep -q 'nohup sudo -u' "$SCRIPT"; then
  if grep -q '未找到 appcenter-cli' "$SCRIPT"; then
    ok "C1b 手工 nohup 路径已降级为「找不到 appcenter-cli 时」的兜底（不是默认路径）"
  else
    bad "C1b 手工 nohup 仍是默认启停路径" "⇒ TRIM_APPDEST 缺失 ⇒ 网关能力失效(fnOS#200)"
  fi
else
  bad "C1b 没找到手工启动兜底路径" "-"
fi
if grep -q 'verify-upgrade-result.sh' "$SCRIPT"; then
  ok "C2 尾部调 verify-upgrade-result.sh（两条断言的载体）"
else
  bad "C2 尾部没调 verify-upgrade-result.sh" "⇒ 没有断言 ⇒ 静默半升级无人喊"
fi
if grep -q 'sync-appcenter-version.sh' "$SCRIPT"; then
  ok "C3 尾部调 sync-appcenter-version.sh（注册表版本同步）"
else
  bad "C3 尾部没调 sync-appcenter-version.sh" "⇒ 面板版本会停在旧版(fnOS#201)"
fi

echo "── C4 沙箱模式：两条断言都跳过并说明原因，退出码 0"
make_fake_appcenter "$WORK/bin" "pigeonbox 9.9.9 running"
SANDBOX_OUT="$(PATH="$WORK/bin:$PATH" PB_APP_ROOT="$WORK/app" PB_UPGRADE_TARGET="$WORK/app/target"   PB_UPGRADE_SANDBOX=1 PB_UPGRADE_UNPACK="$WORK/unpack"   PB_PKG_USER="$(id -un)" PB_PKG_GROUP="$(id -gn)"   bash "$SCRIPT" "$WORK/pigeonbox.fpk" 2>&1)"
SANDBOX_RC=$?
printf '%s\n' "$SANDBOX_OUT" | sed 's/^/    /'
if [ "$SANDBOX_RC" = "0" ]; then
  ok "C4a 沙箱跑升级脚本退出码 0（离线门禁不被真机断言打断）"
else
  bad "C4a 沙箱跑升级脚本失败" "退出码=${SANDBOX_RC}"
fi
if printf '%s' "$SANDBOX_OUT" | grep -q '跳过升级后断言'; then
  ok "C4b 沙箱下断言被跳过并说明了原因"
else
  bad "C4b 沙箱下没看到「跳过断言」说明" "-"
fi
if printf '%s' "$SANDBOX_OUT" | grep -q '跳过注册表版本同步'; then
  ok "C4c 沙箱下注册表同步被跳过并说明了原因"
else
  bad "C4c 沙箱下没看到「跳过注册表同步」说明" "-"
fi

echo "── C5 断言 A 有牙齿：capabilities 报 gateway=false ⇒ 必须非 0 退出"
make_fake_appcenter "$WORK/bin_false" "pigeonbox 9.9.9 running"
cat > "$WORK/bin_false/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"code":200,"data":{"gateway":false,"sso":false}}'
EOF
chmod +x "$WORK/bin_false/curl"
OUT_FALSE="$(PATH="$WORK/bin_false:$PATH" FAKE_APPCENTER_LIST="pigeonbox 9.9.9 running" PB_TARGET_VERSION=9.9.9   PB_APP_ROOT="$WORK/app" PB_PKGVAR="$WORK/pkgvar"   bash "$VERIFY" 2>&1)"
RC_FALSE=$?
printf '%s\n' "$OUT_FALSE" | sed 's/^/    /'
if [ "$RC_FALSE" != "0" ]; then
  ok "C5a gateway=false 时 verify 非 0 退出（退出码=${RC_FALSE}）"
else
  bad "C5a gateway=false 时 verify 竟然退 0" "⇒ 断言没牙齿 ⇒ 静默失效仍会被放过"
fi
if printf '%s' "$OUT_FALSE" | grep -q 'appcenter-cli stop'; then
  ok "C5b 失败时打印了补救命令（appcenter-cli stop/start）"
else
  bad "C5b 失败时没打印补救命令" "-"
fi

echo "── C6 断言 B 有牙齿：注册表版本 != 目标版本 ⇒ 必须非 0 退出"
make_fake_appcenter "$WORK/bin_old" "pigeonbox 4.8.6 running"
cat > "$WORK/bin_old/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"code":200,"data":{"gateway":true,"sso":true}}'
EOF
chmod +x "$WORK/bin_old/curl"
OUT_OLD="$(PATH="$WORK/bin_old:$PATH" FAKE_APPCENTER_LIST="pigeonbox 4.8.6 running" PB_TARGET_VERSION=9.9.9   PB_APP_ROOT="$WORK/app" PB_PKGVAR="$WORK/pkgvar"   bash "$VERIFY" 2>&1)"
RC_OLD=$?
printf '%s\n' "$OUT_OLD" | sed 's/^/    /'
if [ "$RC_OLD" != "0" ]; then
  ok "C6a 注册表版本落后时 verify 非 0 退出（退出码=${RC_OLD}）"
else
  bad "C6a 注册表版本落后时 verify 竟然退 0" "⇒ 版本断言没牙齿 ⇒ 面板旧版会被放过"
fi
if printf '%s' "$OUT_OLD" | grep -q 'sync-appcenter-version.sh'; then
  ok "C6b 失败时打印了补救命令（sync-appcenter-version.sh）"
else
  bad "C6b 失败时没打印补救命令" "-"
fi

echo "── C6c 正对照：注册表版本 == 目标版本 ⇒ 必须退 0"
make_fake_appcenter "$WORK/bin_new" "pigeonbox 9.9.9 running"
cat > "$WORK/bin_new/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"code":200,"data":{"gateway":true,"sso":true}}'
EOF
chmod +x "$WORK/bin_new/curl"
OUT_NEW="$(PATH="$WORK/bin_new:$PATH" FAKE_APPCENTER_LIST="pigeonbox 9.9.9 running" PB_TARGET_VERSION=9.9.9   PB_APP_ROOT="$WORK/app" PB_PKGVAR="$WORK/pkgvar"   bash "$VERIFY" 2>&1)"
RC_NEW=$?
printf '%s\n' "$OUT_NEW" | sed 's/^/    /'
if [ "$RC_NEW" = "0" ]; then
  ok "C6c 一切对账通过时 verify 退 0（不会误报红）"
else
  bad "C6c 一切对账通过时 verify 竟然退非 0" "退出码=${RC_NEW} ⇒ 断言误报"
fi

echo "── C7 负对照：把 appcenter-cli 启停变异掉 ⇒ C1 必须变红"
MUT="$WORK/upgrade-inplace.mutated.sh"
# shellcheck disable=SC2016  # 单引号是故意的：sed 模式里 $APPCENTER_CLI 必须保持字面量
sed 's|"$APPCENTER_CLI" start "$APP_NAME"|true|' "$SCRIPT" > "$MUT"
if diff -q "$SCRIPT" "$MUT" >/dev/null 2>&1; then
  bad "C7 变异未生效" "没能在脚本里定位 appcenter-cli 启停段（脚本结构变了？）"
else
  if has_framework_start "$MUT"; then
    bad "C7 变异后 C1 仍绿" "⇒ 变异没复现原缺陷，门禁空转"
  else
    ok "C7 变异体确实没了框架托管启停 ⇒ 门禁能抓住原缺陷"
  fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✓ fnos 原地换装「框架托管启停 + 网关/版本断言」守卫通过"
OK=1
