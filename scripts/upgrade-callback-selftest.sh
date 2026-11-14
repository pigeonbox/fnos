#!/usr/bin/env bash
# fnos/cmd/upgrade_callback（升级前业务库快照）的自测 + 变异负对照（fnos#211）。
#
# 为什么需要：这个回调干两件「错了也不会有人喊」的事——
#   ① 快照失败：此前 `cp … 2>/dev/null || exit 0` **零日志静默跳过** ⇒ 卷满/
#      权限变化时既没有回滚点也零痕迹（不可逆迁移最需要回滚点的正是这种时刻）；
#   ② 轮转按 mtime（ls -t）排序 ⇒ 时钟回拨/备份还原后可能淘汰错对象（丢掉最新
#      回滚点），与 qnap package_routines「按文件名轮转」的三端口径相悖。
# ⇒ 两类都必须有**能判红的**机械化判据。
#
# 本自测跑**真的回调**（临时数据目录 + 假 cp/假 logger 注入 PATH）：
#   C1 正常：生成 1 份快照、命名形态 <db>.bak-YYYYMMDD-HHMMSS、退出 0、成功日志
#   C2 按文件名轮转：构造 mtime 错序 ⇒ 仍淘汰**文件名最旧**那份（不丢最新回滚点）
#   C3 快照失败：stderr 有告警 + syslog(logger) 收到告警 + 退出 0（不中止升级）
#
# --selfcheck 另跑 2 组变异负对照（改坏回调的某一处，对应判据必须转红）：
#   M1 去掉失败告警（echo 静默）⇒ C3 必红 · M2 轮转改回 ls -t（mtime）⇒ C2 必红
#
# 用法: bash scripts/upgrade-callback-selftest.sh [--selfcheck]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CB="$SCRIPT_DIR/../fnos/cmd/upgrade_callback"

[ -f "$CB" ] || { echo "✗ 找不到被测回调: $CB"; exit 1; }

fails=0
QUIET=""
CB_UNDER_TEST="$CB"
LAST_FAILS=0
ok() { [ -n "$QUIET" ] || echo "  ✓ $1"; }
bad() { [ -n "$QUIET" ] || echo "  ✗ $1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

LOGGER_OUT="$TMP/logger.out"

# ── 夹具 ────────────────────────────────────────────────────────────────
# 假 logger：把收到的参数留档（验证 syslog 通道真的收到了告警）
SHIM_LOG="$TMP/shim-log"
mkdir -p "$SHIM_LOG"
cat > "$SHIM_LOG/logger" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$LOGGER_OUT"
EOF
# 假 cp：恒失败（复刻卷满/权限变化时快照拷不动的场景）
SHIM_FAIL="$TMP/shim-fail"
mkdir -p "$SHIM_FAIL"
cp "$SHIM_LOG/logger" "$SHIM_FAIL/logger"
printf '#!/bin/sh\nexit 1\n' > "$SHIM_FAIL/cp"
chmod +x "$SHIM_LOG/logger" "$SHIM_FAIL/logger" "$SHIM_FAIL/cp"

make_data() { # make_data <name> → 打印数据根目录（内含 data/fileCodeBox.db）
	local d="$TMP/$1"
	mkdir -p "$d/data"
	echo "SQLite format 3 payload" > "$d/data/fileCodeBox.db"
	printf '%s\n' "$d"
}

run_cb() { # run_cb <数据根目录> <PATH 前缀> ⇒ CB_RC / CB_STDOUT / CB_STDERR
	CB_STDERR="$TMP/stderr.out"
	TRIM_PKGVAR="$1" PATH="$2:$PATH" \
		bash "$CB_UNDER_TEST" >"$TMP/stdout.out" 2>"$CB_STDERR"
	CB_RC=$?
	CB_STDOUT=$(cat "$TMP/stdout.out")
}

backups() { # backups <db 路径> → 每行一个存在的快照
	local f
	for f in "$1".bak-*; do
		[ -f "$f" ] || continue
		printf '%s\n' "$f"
	done | sort
}
count_backups() { backups "$1" | wc -l | tr -d ' '; }

# ── C1 正常路径 ─────────────────────────────────────────────────────────
c1() {
	local d db n bak
	d=$(make_data c1)
	: > "$LOGGER_OUT"
	run_cb "$d" "$SHIM_LOG"
	db="$d/data/fileCodeBox.db"
	n=$(count_backups "$db")
	[ "$CB_RC" -eq 0 ] && ok "C1 退出码 0" || bad "C1 退出码 $CB_RC,应为 0"
	[ "$n" -eq 1 ] && ok "C1 生成 1 份快照" || bad "C1 生成 $n 份快照,应为 1"
	bak=$(backups "$db" | head -1)
	case "$bak" in
	"$db".bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
		ok "C1 命名形态 <db>.bak-YYYYMMDD-HHMMSS" ;;
	*) bad "C1 命名形态不对: $bak" ;;
	esac
	if [ -n "$bak" ] && cmp -s "$db" "$bak"; then
		ok "C1 快照与源库逐字节一致"
	else
		bad "C1 快照缺失或内容不一致"
	fi
	case "$CB_STDOUT" in
	*"db backup saved"*) ok "C1 成功日志在案" ;;
	*) bad "C1 缺成功日志" ;;
	esac
}

# ── C2 轮转按文件名（mtime 错序时不得丢最新回滚点）──────────────────────
c2() {
	local d db n i
	d=$(make_data c2)
	db="$d/data/fileCodeBox.db"
	# 三份旧快照：文件名定序（0001 最旧），mtime **故意错序**
	# （0001 最新、0003 居中、0002 最旧）⇒ 按 mtime 轮转会删 0002、留 0001，
	#   按文件名轮转必删 0001、留 0002——两条判据据此区分实现。
	for i in 1 2 3; do
		echo "old snapshot $i" > "$db.bak-20200101-00000$i"
	done
	touch -t 202601011200 "$db.bak-20200101-000001"
	touch -t 202601011000 "$db.bak-20200101-000002"
	touch -t 202601011100 "$db.bak-20200101-000003"
	run_cb "$d" "$SHIM_LOG"
	n=$(count_backups "$db")
	[ "$n" -eq 3 ] && ok "C2 轮转后只剩 3 份" || bad "C2 轮转后剩 $n 份,应为 3"
	if [ ! -f "$db.bak-20200101-000001" ]; then
		ok "C2 最旧文件名那份被淘汰（按名字排序,非 mtime）"
	else
		bad "C2 最旧文件名那份仍在——轮转走了 mtime(ls -t)路径,错序时会丢最新回滚点"
	fi
	if [ -f "$db.bak-20200101-000002" ] && [ -f "$db.bak-20200101-000003" ]; then
		ok "C2 mtime 较旧但名字较新的两份被保留"
	else
		bad "C2 mtime 错序导致保留了错误对象（0002/0003 被删）"
	fi
}

# ── C3 快照失败必须留痕（stderr + syslog），且不中止升级 ─────────────────
c3() {
	local d db n
	d=$(make_data c3)
	: > "$LOGGER_OUT"
	run_cb "$d" "$SHIM_FAIL"   # 假 cp 恒失败
	db="$d/data/fileCodeBox.db"
	n=$(count_backups "$db")
	[ "$CB_RC" -eq 0 ] && ok "C3 失败仍退出 0（不中止升级）" || bad "C3 失败退出 ${CB_RC}——fnOS 框架语义未验证,不得擅自中止"
	if grep -q "快照失败" "$CB_STDERR" 2>/dev/null; then
		ok "C3 stderr 有响亮告警"
	else
		bad "C3 stderr 无告警（静默失败,fnos#211 原缺陷）"
	fi
	if grep -q "DB snapshot failed" "$LOGGER_OUT" 2>/dev/null; then
		ok "C3 syslog(logger) 收到告警"
	else
		bad "C3 syslog 未收到告警"
	fi
	[ "$n" -eq 0 ] && ok "C3 不留残缺快照" || bad "C3 失败却留下 $n 份残留"
}

run_cases() { # run_cases <脚本> <quiet|""> <判据函数...>
	CB_UNDER_TEST="$1"
	QUIET="$2"
	shift 2
	fails=0
	local c
	for c in "$@"; do "$c"; done
	LAST_FAILS=$fails
}

# ── 变异引擎（锚点未命中即失败，负对照才可信）───────────────────────────
mutate() { # mutate <name> <old> <new>
	python3 - "$CB" "$TMP/mut.$1" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
if old not in s:
    sys.exit("变异锚点未命中: " + old[:60])
open(dst, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
}

mut_expect() { # mut_expect <name> <case> <old> <new> <desc>
	echo "── 变异 $1（$5）⇒ 期望 $2 转红"
	if ! mutate "$1" "$3" "$4"; then
		echo "✗ 变异 $1 未生效（锚点没命中）⇒ 负对照无效"
		exit 1
	fi
	if ! bash -n "$TMP/mut.$1"; then
		echo "✗ 变异 $1 语法已坏 ⇒ 负对照无效"
		exit 1
	fi
	run_cases "$TMP/mut.$1" quiet "$2"
	if [ "$LAST_FAILS" -ge 1 ]; then
		echo "  ✓ $2 如期转红（判据有牙齿）"
	else
		echo "  ✗ $2 没转红 ⇒ 该判据测不出这种回归"
		exit 1
	fi
}

if [ "${1:-}" = "--selfcheck" ]; then
	echo "== 基线（真回调，全部判据必须绿）"
	run_cases "$CB" "" c1 c2 c3
	if [ "$LAST_FAILS" -ne 0 ]; then
		echo "✗ 基线就红了（$LAST_FAILS 条）⇒ 自测自身失效,先修真回调或真判据"
		exit 1
	fi
	echo "✓ 基线全绿"
	mut_expect M1 c3 \
		'  echo "pigeonbox upgrade_callback: 升级前业务库快照失败(${DB})——本次升级将没有回滚点,请检查存储空间/权限" >&2' \
		'  :' \
		'去掉 stderr 告警（退回静默失败）'
	mut_expect M2 c2 \
		'for old in "${DB}".bak-*; do
  [ -f "$old" ] || continue
  printf '"'"'%s\n'"'"' "$old"
done | sort -r | tail -n +4 | while read -r old; do
  rm -f "$old"
done' \
		'ls -t "${DB}".bak-* 2>/dev/null | tail -n +4 | while read -r old; do
  rm -f "$old"
done' \
		'轮转改回按 mtime（ls -t）'
	echo "✓ 自证：基线绿、告警可判红、按名轮转可判红 ⇒ 判据有牙齿"
	OK=1
	exit 0
fi

run_cases "$CB" "" c1 c2 c3
if [ "$LAST_FAILS" -ne 0 ]; then
	echo "✗ $LAST_FAILS 条判据失效"
	exit 1
fi
echo "✓ upgrade_callback 的判据全部有效"
OK=1
exit 0
