#!/usr/bin/env bash
# 门禁：fnos 原地换装脚本必须**同时替换生命周期脚本 cmd/ 与 manifest**。
#
# 缺陷实录（2026-11-04 真机，4.1.2→4.8.5 升级）：scripts/upgrade-inplace.sh
# 此前**只换 target/{www,bin,ui}**，**从不换 /var/apps/pigeonbox/cmd/** ⇒
#   · 4.8.5 新增的 cmd/prewire_beam_box 缺席；
#   · cmd/main 停在旧版 ⇒ 不给 p2pcweb 传 --config-file ⇒ p2pcweb 的配置
#     回退到 os.UserConfigDir()（包用户跑时 HOME 继承自 root ⇒ 写不了）
#     ⇒ Beam「文件柜」配置存不住 —— 正是 4.8.5 要修的缺陷。
# ⇒ 升级脚本漏换生命周期脚本 ⇒ **装了新二进制却跑着旧生命周期 = 静默半升级**。
#
# 本门禁**离线**跑真实脚本（假 fpk + 假应用根 + PB_UPGRADE_SANDBOX=1），
# 断言：
#   C1 cmd/main 被换成 fpk 里的新版；
#   C2 fpk 根**新增**的 cmd 文件（模拟 prewire_beam_box）在位 ⇒ 版本新增的生命周期
#      脚本不会在升级里缺席；
#   C3 manifest 被换成 fpk 里的新版；
#   C4 target/www 被解包替换（原有行为不能被改坏）；
#   C5 **负对照**：把脚本里的 cmd 替换段变异掉 ⇒ C1/C2 必须变红
#      ⇒ 证明门禁有区分力、不是空转。
#
# 用法: bash scripts/check-upgrade-inplace-cmd-sync.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/upgrade-inplace.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+  [$2]}"; }

[ -f "$SCRIPT" ] || { echo "找不到 $SCRIPT"; exit 1; }

WORK="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$WORK"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

# ── 造一个**两段结构**的假 fpk（根含 cmd/ + manifest + app.tgz，载荷含 bin/www/…）──
build_fake_fpk() {
  local out="$1" src="$WORK/fpkroot"
  mkdir -p "$src/cmd" "$src/wizard" "$src/config" \
           "$src/payload/bin" "$src/payload/www" "$src/payload/ui" \
           "$src/payload/config" "$src/payload/configs"
  printf '#!/bin/bash\n# NEW MAIN\n'            > "$src/cmd/main"
  printf '#!/bin/bash\n# NEW PREWIRE\n'        > "$src/cmd/prewire_beam_box"
  printf '#!/bin/bash\n# NEW CONFIG_CALLBACK\n' > "$src/cmd/config_callback"
  chmod 755 "$src/cmd"/*
  printf 'version               = 9.9.9\n'      > "$src/manifest"
  printf 'wizard\n'                            > "$src/wizard/config"
  printf 'priv\n'                              > "$src/config/privilege"
  printf 'res\n'                               > "$src/config/resource"
  printf 'newbin\n'                            > "$src/payload/bin/pigeonbox-linux-amd64"
  printf '<html>new</html>\n'                  > "$src/payload/www/index.html"
  printf 'ui\n'                                > "$src/payload/ui/config"
  printf 'priv\n'                              > "$src/payload/config/privilege"
  printf 'res\n'                               > "$src/payload/config/resource"
  printf 'yaml\n'                              > "$src/payload/configs/config.yaml"
  tar czf "$WORK/app.tgz" -C "$src/payload" .
  cp "$WORK/app.tgz" "$src/app.tgz"
  tar czf "$out" -C "$src" .
}

# ── 造一个「旧版本」的假应用根 ──
build_fake_app() {
  local app="$1"
  mkdir -p "$app/cmd" "$app/config" "$app/wizard" \
           "$app/target/config" "$app/target/configs" \
           "$app/target/www" "$app/target/bin" "$app/target/ui"
  printf '#!/bin/bash\n# OLD MAIN\n'            > "$app/cmd/main"
  printf '#!/bin/bash\n# OLD CONFIG_CALLBACK\n' > "$app/cmd/config_callback"
  chmod 755 "$app/cmd"/*
  printf 'version               = 1.1.1\n' > "$app/manifest"
  printf 'keep\n'               > "$app/target/config/app.conf"
  printf 'keep\n'               > "$app/target/configs/config.yaml"
  printf 'OLD HTML\n'           > "$app/target/www/index.html"
  printf 'oldbin\n'             > "$app/target/bin/pigeonbox-linux-amd64"
  printf 'panelpriv\n'          > "$app/config/privilege"
}

# 沙箱跑真实升级脚本（不碰真机：不停应用/不杀进程/不启动）
run_sandbox() { # <脚本> <应用根> ; 打印 "<退出码>|<输出>"
  local script="$1" app="$2" out rc
  out="$(PB_APP_ROOT="$app" PB_UPGRADE_TARGET="$app/target" \
        PB_UPGRADE_SANDBOX=1 PB_UPGRADE_UNPACK="$WORK/unpack" \
        PB_PKG_USER="$(id -un)" PB_PKG_GROUP="$(id -gn)" \
        bash "$script" "$WORK/pigeonbox.fpk" 2>&1)"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

echo "── 造假 fpk（两段结构）+ 假应用根"
build_fake_fpk "$WORK/pigeonbox.fpk"
build_fake_app "$WORK/app"

echo "── 沙箱跑真实升级脚本"
RES="$(run_sandbox "$SCRIPT" "$WORK/app")"
RC="${RES%%|*}"; OUT="${RES#*|}"
printf '%s\n' "$OUT" | sed 's/^/    /'
if [ "$RC" != "0" ]; then
  bad "沙箱跑升级脚本失败" "退出码=$RC"
else
  ok "沙箱跑升级脚本成功（退出码 0）"
fi

echo "── C1 cmd/main 必须被换成 fpk 里的新版"
if grep -q 'NEW MAIN' "$WORK/app/cmd/main" 2>/dev/null; then
  ok "C1 cmd/main 已被换成新版"
else
  bad "C1 cmd/main 没换（仍是旧的）" "⇒ 升级脚本漏换生命周期脚本 = 静默半升级"
fi

echo "── C2 fpk 根新增的 cmd 文件必须到位"
if [ -f "$WORK/app/cmd/prewire_beam_box" ] && grep -q 'NEW PREWIRE' "$WORK/app/cmd/prewire_beam_box" 2>/dev/null; then
  ok "C2 新增的 cmd 文件（prewire_beam_box）在位"
else
  bad "C2 新增的 cmd 文件没在位" "⇒ 版本新增的生命周期脚本会在升级里缺席"
fi

echo "── C3 manifest 必须被换成 fpk 里的新版"
if grep -q '9.9.9' "$WORK/app/manifest" 2>/dev/null; then
  ok "C3 manifest 已被换成新版"
else
  bad "C3 manifest 没换" "-"
fi

echo "── C4 target/www 必须被解包替换（原有行为不能被改坏）"
if grep -q 'new' "$WORK/app/target/www/index.html" 2>/dev/null; then
  ok "C4 target/www 被解包替换"
else
  bad "C4 target/www 没被替换" "-"
fi

echo "── C5 负对照：把 cmd/ 替换段变异掉 ⇒ 必须判红"
MUT="$WORK/upgrade-inplace.mutated.sh"
# shellcheck disable=SC2016  # 单引号是故意的：sed 模式里 $UNPACK 必须保持字面量
sed 's|if \[ -d "$UNPACK/cmd" \]; then|if [ -d "$UNPACK/cmd_DISABLED" ]; then|' "$SCRIPT" > "$MUT"
if diff -q "$SCRIPT" "$MUT" >/dev/null 2>&1; then
  bad "C5 变异未生效" "没能在脚本里定位 cmd/ 替换段（脚本结构变了？）"
else
  build_fake_app "$WORK/app2"
  RES2="$(run_sandbox "$MUT" "$WORK/app2")"
  RC2="${RES2%%|*}"
  if grep -q 'NEW MAIN' "$WORK/app2/cmd/main" 2>/dev/null; then
    bad "C5 变异后 cmd/main 竟然还是新版" "⇒ 变异没复现原缺陷，门禁空转"
  else
    ok "C5 变异体确实没换 cmd/（脚本退出码=${RC2}）⇒ 门禁能抓住原缺陷"
  fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✓ fnos 原地换装「生命周期脚本同步」守卫通过（cmd/ + manifest 会随版本换）"
OK=1
