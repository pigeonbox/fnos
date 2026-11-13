#!/usr/bin/env bash
# 门禁：钉版对账——DEPS.env 的 CORE_PIN/FRONTEND_CORE_PIN 必须与 go.mod、web 侧
# 实际钉版一致（漂移即红，且点名文件与两侧取值）。
#
# 缺陷实录（U2b 批疑虑 1 / PREP-D，Refs pigeonbox/pigeonbox#327）：fnos 此前是
# 三平台仓里**唯一没有任何 CORE_PIN 校验点**的——
#   · qnap 的断言内嵌在 .github/workflows/release.yml ⇒ 只有打 tag 才跑
#     ⇒ 「PR 全绿 ≠ 守卫全绿」（平台仓钉版的既有教训）；
#   · openwrt 有完整 scripts/check-build-pin.sh（含构建产物核验）；
#   · fnos 两个都没有 ⇒ go.mod 与 DEPS.env 的 CORE_PIN 漂移无人抓。
# 而 DEPS.env 正是**第二份钉版真相源**（hub release/train.yaml → trainctl bump 写入，
# 与 go.mod 平行）：列车 bump 漏改 go.mod（或反之）⇒ fnos 发出的二进制实际编译的
# core ≠ DEPS.env 声称的版本 ⇒ 「版本幽灵」（qnap 2.1.0 列车实录）。
# 另：FRONTEND_CORE_PIN 此前在**全生态零对账**（web/package.json 与 package-lock.json
# 的 tgz URL 没人核）——而「改 URL 后 npm install 不会自动更新 lock 的 version 字段」
# 是已知老坑（漏同步 ⇒ 两份 contracts / EINTEGRITY）。
#
# 本门禁正判据（对 <仓根> 的四条断言）：
#   P1 DEPS.env 存在且有非空 CORE_PIN、FRONTEND_CORE_PIN；
#   P2 go.mod 里 github.com/pigeonbox/core 的**直接 require**（require 块内、非
#      // indirect 行）== CORE_PIN；
#   P3 web/package.json 的 frontend-core tgz URL 钉版 == FRONTEND_CORE_PIN
#      （同一文件里出现多个不同钉版也判红=改 URL 没改全）；
#   P4 web/package-lock.json 的 resolved URL 钉版 == FRONTEND_CORE_PIN（同上）。
#
# 负对照自测（--selfcheck，CI 里跑）：把四份文件拷进临时目录，
#   ① 基线原样 ⇒ 必须绿（证明不是「本来就红」）；
#   ② 逐条制造漂移（CORE_PIN 改错 / CORE_PIN 行删掉 / go.mod core 改错 /
#      package.json URL 改错 / lock URL 改错）⇒ 必须**逐条判红且点名**；
#   ③ 每轮变异后复位再跑（证明上面的红不是恒红）。任一条无区分力 ⇒ 本门禁自己红。
#
# 用法:
#   bash scripts/check-build-pin.sh             # 正判据（对当前仓）
#   bash scripts/check-build-pin.sh --selfcheck # 负对照自测
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SELFCHECK=0
for arg in "$@"; do
  case "$arg" in
    --selfcheck) SELFCHECK=1 ;;
    *)
      echo "用法: $0 [--selfcheck]"
      exit 2
      ;;
  esac
done

PIN_ERRS=0
p_ok()  { echo "  ✓ $1"; }
p_bad() { echo "  ✗ $1${2:+  [$2]}"; PIN_ERRS=$((PIN_ERRS + 1)); }

# go.mod 里 core 的**直接 require**版本。
# 口径：只认 require 块（或单行 require）里、且**不带 // indirect** 的那行——
#   // indirect 行是 MVS 抬上来的传递依赖，不是本仓声明的钉版；replace 块的行也不算。
gomod_core_pin() { # <go.mod 路径>
  awk '
    $1 == "require" && $2 == "github.com/pigeonbox/core" { print $3; exit }
    /^require[[:blank:]]*\(/ { inreq = 1; next }
    inreq && /^[[:blank:]]*\)/ { inreq = 0; next }
    inreq && $1 == "github.com/pigeonbox/core" && $0 !~ /\/\/[[:blank:]]*indirect/ { print $2; exit }
  ' "$1" 2>/dev/null
}

# web 侧 frontend-core tgz URL 里的钉版（去重输出，一行一个取值）
web_core_pins() { # <package.json|package-lock.json>
  grep -oE 'frontend-core/releases/download/v[0-9][0-9A-Za-z.+-]*' "$1" 2>/dev/null \
    | sed 's|.*/download/||' \
    | sort -u
}

# 对账主判据：<目录> 四条全过=0；任一漂移=1（打印逐条 ✓/✗，点名文件与两侧取值）
pin_check() {
  local dir="$1"
  local core_pin fe_pin gomod_pin pins

  PIN_ERRS=0
  [ -f "$dir/DEPS.env" ] || { p_bad "缺 $dir/DEPS.env" "第二份钉版真相源（trainctl bump 写入）"; return 1; }
  [ -f "$dir/go.mod" ] || { p_bad "缺 $dir/go.mod" "-"; return 1; }

  # P1 钉版声明本身要在
  core_pin="$(sed -n 's/^CORE_PIN=//p' "$dir/DEPS.env" | tr -d ' \r' | head -1)"
  fe_pin="$(sed -n 's/^FRONTEND_CORE_PIN=//p' "$dir/DEPS.env" | tr -d ' \r' | head -1)"
  if [ -n "$core_pin" ]; then
    p_ok "P1 DEPS.env CORE_PIN = ${core_pin}"
  else
    p_bad "P1 DEPS.env 无 CORE_PIN" "发车走 hub 列车 bump，勿手改 DEPS.env"
  fi
  if [ -n "$fe_pin" ]; then
    p_ok "P1 DEPS.env FRONTEND_CORE_PIN = ${fe_pin}"
  else
    p_bad "P1 DEPS.env 无 FRONTEND_CORE_PIN" "发车走 hub 列车 bump，勿手改 DEPS.env"
  fi

  # P2 go.mod 直接 require == CORE_PIN
  gomod_pin="$(gomod_core_pin "$dir/go.mod")"
  if [ -z "$gomod_pin" ]; then
    p_bad "P2 go.mod 找不到 github.com/pigeonbox/core 的直接 require（只有 // indirect 或没有）" \
      "fnos 直接 import core ⇒ 缺直接 require 说明 go.mod 被改坏"
  elif [ -n "$core_pin" ] && [ "$gomod_pin" = "$core_pin" ]; then
    p_ok "P2 go.mod 直接 require core = ${gomod_pin} == CORE_PIN"
  else
    p_bad "P2 go.mod 直接 require core = ${gomod_pin:-无} ≠ DEPS.env CORE_PIN=${core_pin:-无}" \
      "版本幽灵:DEPS.env 声称的 core 与二进制实际编译的不一致（改 go.mod 或跑列车 bump,二选一对齐）"
  fi

  # P3 web/package.json 的 tgz URL 钉版
  pins="$(web_core_pins "$dir/web/package.json")"
  if [ -z "$pins" ]; then
    p_bad "P3 web/package.json 找不到 frontend-core tgz URL" "钉版形如 .../releases/download/vX.Y.Z/..."
  elif [ -z "$fe_pin" ]; then
    p_bad "P3 无从对账（DEPS.env 缺 FRONTEND_CORE_PIN）" "-"
  elif [ "$(printf '%s\n' "$pins" | wc -l | tr -d ' ')" -gt 1 ]; then
    p_bad "P3 web/package.json 有多个 frontend-core 钉版: $(printf '%s' "$pins" | tr '\n' ' ')" \
      "改 URL 没改全 ⇒ 装出两份 frontend-core"
  elif [ "$pins" = "$fe_pin" ]; then
    p_ok "P3 web/package.json tgz 钉版 = ${pins} == FRONTEND_CORE_PIN"
  else
    p_bad "P3 web/package.json tgz 钉版 = ${pins} ≠ DEPS.env FRONTEND_CORE_PIN=${fe_pin}" \
      "改一处没改另一处 ⇒ web 装的 core ≠ 声称的钉版"
  fi

  # P4 package-lock.json 的 resolved URL 钉版（漏同步 lock ⇒ npm ci EINTEGRITY/两份 contracts）
  pins="$(web_core_pins "$dir/web/package-lock.json")"
  if [ -z "$pins" ]; then
    p_bad "P4 web/package-lock.json 找不到 frontend-core tgz URL" "lock 漏了钉版改动"
  elif [ -z "$fe_pin" ]; then
    p_bad "P4 无从对账（DEPS.env 缺 FRONTEND_CORE_PIN）" "-"
  elif [ "$(printf '%s\n' "$pins" | wc -l | tr -d ' ')" -gt 1 ]; then
    p_bad "P4 web/package-lock.json 有多个 frontend-core 钉版: $(printf '%s' "$pins" | tr '\n' ' ')" \
      "lock 内部不一致 ⇒ npm ci 装出来的版本不可预期"
  elif [ "$pins" = "$fe_pin" ]; then
    p_ok "P4 web/package-lock.json tgz 钉版 = ${pins} == FRONTEND_CORE_PIN"
  else
    p_bad "P4 web/package-lock.json tgz 钉版 = ${pins} ≠ DEPS.env FRONTEND_CORE_PIN=${fe_pin}" \
      "改 URL 后 npm install 不会更新 lock ⇒ 必须手改 version+integrity 同步"
  fi

  [ "$PIN_ERRS" -eq 0 ]
}

# ── 负对照自测 ──────────────────────────────────────────────────────────────
if [ "$SELFCHECK" -eq 1 ]; then
  SELF_TMP="$(mktemp -d)"
  OK=0
  # shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
  trap 'rc=$?; rm -rf "$SELF_TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

  SC_PASS=0; SC_FAIL=0
  sc_ok()  { SC_PASS=$((SC_PASS + 1)); echo "  ✓ $1"; }
  sc_bad() { SC_FAIL=$((SC_FAIL + 1)); echo "  ✗ $1${2:+  [$2]}"; }

  reset_fixtures() {
    mkdir -p "$SELF_TMP/web"
    cp "$ROOT/DEPS.env" "$ROOT/go.mod" "$SELF_TMP/"
    cp "$ROOT/web/package.json" "$ROOT/web/package-lock.json" "$SELF_TMP/web/"
  }

  # <字面量替换>：awk 按字面量换掉首个命中行（不依赖 sed -i ⇒ macOS/CI 双端一致）
  replace_first() { # <文件> <旧字面量> <新字面量>
    awk -v o="$2" -v n="$3" 'index($0, o) && !d { sub(o, n); d = 1 } { print }' "$1" >"$1.tmp" \
      && mv "$1.tmp" "$1"
  }

  drop_line() { # <文件> <行首前缀>
    awk -v p="$2" 'index($0, p) == 1 { next } { print }' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
  }

  expect_red() { # <变异名> <点名词（输出里必须出现）>
    local name="$1" needle="$2" out rc
    out="$(pin_check "$SELF_TMP" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
      # 变量一律显式花括号（${name} 形态）：变量名后紧跟全角标点会让 bash 把全角
      # 字符并进变量名 ⇒ hub 门禁 check-shell-var-boundary.sh 判红（2026-11-13 实证）。
      sc_bad "${name}：制造漂移后守卫仍绿" "断言无效"
    elif printf '%s' "$out" | grep -qF "$needle"; then
      sc_ok "${name} ⇒ 判红并点名「${needle}」"
    else
      sc_bad "${name}：判红但没点名「${needle}」" "输出=$(printf '%s' "$out" | tr '\n' ';' | tail -c 200)"
    fi
    reset_fixtures
  }

  echo "── 负对照自测（临时目录里的四份文件原样复刻）"
  reset_fixtures

  # ① 基线：原样必须绿（否则守卫在当前仓就是坏的/恒红）
  if pin_check "$SELF_TMP" >/dev/null 2>&1; then
    sc_ok "① 基线（四份文件原样）⇒ 守卫绿"
  else
    sc_bad "① 基线竟然判红 ⇒ 守卫在当前仓就是坏的" "-"
  fi
  reset_fixtures

  # ② 逐条制造漂移 ⇒ 必须红且点名
  replace_first "$SELF_TMP/DEPS.env" "CORE_PIN=" "CORE_PIN=v9.9.9-phantom"
  expect_red "② DEPS.env CORE_PIN 改错" "CORE_PIN"

  drop_line "$SELF_TMP/DEPS.env" "CORE_PIN="
  expect_red "③ DEPS.env 删掉 CORE_PIN 行" "CORE_PIN"

  replace_first "$SELF_TMP/go.mod" "github.com/pigeonbox/core v" "github.com/pigeonbox/core v9.9.8"
  expect_red "④ go.mod core 直接 require 改错" "go.mod"

  # 字面量必须带 pigeonbox/frontend-core 前缀：裸 "releases/download/v" 会先命中
  # 同文件里 contracts 的 URL（实录：首轮 ⑤⑥ 因此「变异没打中」而假绿）。
  replace_first "$SELF_TMP/web/package.json" "pigeonbox/frontend-core/releases/download/v" \
    "pigeonbox/frontend-core/releases/download/v9.9.7"
  expect_red "⑤ web/package.json tgz URL 改错" "web/package.json"

  replace_first "$SELF_TMP/web/package-lock.json" "pigeonbox/frontend-core/releases/download/v" \
    "pigeonbox/frontend-core/releases/download/v9.9.6"
  expect_red "⑥ web/package-lock.json tgz URL 改错" "package-lock.json"

  # ③ 复位后必须恢复绿（证明上面每条的红都是变异引起的，不是恒红）
  reset_fixtures
  if pin_check "$SELF_TMP" >/dev/null 2>&1; then
    sc_ok "③ 漂移复位后恢复绿"
  else
    sc_bad "③ 复位后仍红 ⇒ 守卫误报" "-"
  fi

  echo
  echo "selfcheck: PASS=$SC_PASS FAIL=$SC_FAIL"
  [ "$SC_FAIL" -eq 0 ] || exit 1
  echo "✓ 钉版对账守卫自证：基线绿、5 条漂移逐条判红点名、复位恢复绿"
  OK=1
  exit 0
fi

# ── 正判据：对当前仓 ────────────────────────────────────────────────────────
echo "── 钉版对账：DEPS.env ↔ go.mod ↔ web/package{,-lock}.json"
if pin_check "$ROOT"; then
  echo "✓ fnos 钉版对账守卫通过（CORE_PIN=$(sed -n 's/^CORE_PIN=//p' "$ROOT/DEPS.env" | tr -d ' \r')）"
  exit 0
fi
echo "✗ fnos 钉版对账失败——按上面点名的文件两侧对齐；钉版由 hub 列车 bump 写入，勿只改一边" >&2
exit 1
