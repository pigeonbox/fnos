#!/usr/bin/env bash
# 管理员口令重置「原地生效」门禁（fnos#182）。
#
# 为什么要有这道门禁：向导的「重置管理员口令」此前是**平台层删 admin 行**
# （DELETE FROM users）+ core 按 env 重建 ⇒ admin 的 user id 变化
# ⇒ 名下 88 份分享 + 3 把 API Key 全部成孤儿（真机实录）。
# 这类缺陷「不报错、只留孤儿」⇒ 没有任何告警 ⇒ 必须有**能判红**的机械判据。
#
# 本门禁跑**真脚本**（真 sqlite 库 + 真 users 行 + 真 .env）：
#   ① 向导重置流程跑完后，**admin 行必须还在**（旧实现会删掉它 ⇒ 红）；
#   ② 平台层必须把新口令**一次性投递给 core**（文件 + 路径导出）；
#   ③ 消费标记后**不得清空 .env 里的明文口令**
#      （清空 ⇒ prewire 的「每次启动校验有效性、自愈重建」只剩第一次）；
#   ④ 向导「留空=不改动」：提交空口令不得覆盖 .env 里已有的口令；
#   ⑤ 负对照：把旧行为（删 admin 行）注入回去 ⇒ 判据 ① 必须红（有牙齿）。
#
# 用法: bash scripts/check-admin-reset-inplace.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD_MAIN="$SCRIPT_DIR/../fnos/cmd/main"
CONFIG_CB="$SCRIPT_DIR/../fnos/cmd/config_callback"
INSTALL_CB="$SCRIPT_DIR/../fnos/cmd/install_callback"

fails=0
note_fail() { echo "  ✗ $1"; fails=$((fails + 1)); }
note_ok() { echo "  ✓ $1"; }

TMP="$(mktemp -d)"
# ⚠️ EXIT trap 必须**保留退出码**（hub 门禁 check-shell-trap-exit-code.sh）：
#   macOS bash 3.2 下未定义变量失败时 trap 入口的 $? 可能是 0 ⇒ 失败被报成 exit 0
#   ⇒ 门禁形同虚设。正确形态=成功哨兵：结尾置 OK=1，trap 里 rc≠0 原样返回。
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit "$rc"; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

# 取 cmd/main 的函数定义（去掉末尾的 case 分发），以便单点驱动 reset 流程。
# ⚠️ eval 后 BASH_SOURCE 指向本脚本 ⇒ APP_ROOT 必须在 eval 之后**显式**覆盖。
load_main_functions() {
    local src="$1"
    # shellcheck disable=SC2016  # 单引号里的 $1 是**要匹配的字面量**，不可展开
    eval "$(sed -n '1,/^case "\$1" in$/p' "$src" | sed '$d')"
    # shellcheck disable=SC2034  # APP_ROOT 由被 eval 的 cmd/main 函数使用（静态看不见）
    APP_ROOT="$(cd "$SCRIPT_DIR/../fnos" && pwd)"
}

file_mode() {
    stat -c%a "$1" 2>/dev/null || stat -f%Lp "$1" 2>/dev/null || echo "?"
}

cat > "$TMP/q.py" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
print(con.execute("SELECT COUNT(*) FROM users WHERE username = 'admin'").fetchone()[0])
PYEOF

cat > "$TMP/delete_admin.py" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("DELETE FROM users WHERE username = 'admin'")
con.commit()
PYEOF

# 旧实现里「消费标记后清空 .env 明文口令」那一步（用 python 写,跨平台可复现;
# 原实现用的是 sed -i,在 macOS 上语义不同 ⇒ 负对照必须跨平台可判红)。
cat > "$TMP/clear_env_password.py" <<'PYEOF'
import re, sys
path = sys.argv[1]
try:
    lines = open(path).read().splitlines(True)
except FileNotFoundError:
    sys.exit(0)
with open(path, "w") as f:
    for line in lines:
        f.write(re.sub(r'^PB_ADMIN_PASSWORD=.*$', 'PB_ADMIN_PASSWORD=""', line))
PYEOF

# ── 场景跑一遍：真库 + 真 admin 行 + 真 .env + 真标记 ──────────────────
# 用法: run_reset_case <cmd_main 文件> <工作目录> → 结果写入 <工作目录>/result.env
run_reset_case() {
    local main_file="$1" work="$2"
    rm -rf "$work"
    mkdir -p "$work/pkgvar/data"

    export TRIM_PKGVAR="$work/pkgvar"
    export PB_DATA_PATH="$TRIM_PKGVAR/data"
    export PB_DATABASE_DB_NAME="$PB_DATA_PATH/fileCodeBox.db"
    export PB_ADMIN_PASSWORD="new-admin-pw"
    unset PB_ADMIN_PASSWORD_RESET_FILE

    # 真库 + 真 admin 行
    python3 - "$PB_DATABASE_DB_NAME" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, role TEXT)")
con.execute("INSERT INTO users (username, role) VALUES ('admin','admin')")
con.commit()
con.close()
PYEOF

    # .env 里已是**新口令**（向导 config_callback 刚写下的），标记 = 待重置
    printf 'PB_JWT_SECRET="sec"\nPB_ADMIN_PASSWORD="new-admin-pw"\nPB_SERVER_PORT="12345"\n' \
        > "$TRIM_PKGVAR/.env"
    : > "$TRIM_PKGVAR/.admin_reset"

    load_main_functions "$main_file"
    reset_admin_if_requested >/dev/null 2>&1

    {
        echo "admin_rows=$(python3 "$TMP/q.py" "$PB_DATABASE_DB_NAME")"
        echo "reset_file=${PB_ADMIN_PASSWORD_RESET_FILE:-}"
        echo "env_password=$(sed -n 's/^PB_ADMIN_PASSWORD="\(.*\)"$/\1/p' "$TRIM_PKGVAR/.env")"
        echo "marker_left=$([ -f "$TRIM_PKGVAR/.admin_reset" ] && echo 1 || echo 0)"
    } > "$work/result.env"
}

echo "── 判据 ①：向导重置不得删 admin 行（原地生效）"
run_reset_case "$CMD_MAIN" "$TMP/real"
# shellcheck disable=SC1090,SC1091  # 结果文件是本脚本刚生成的
source "$TMP/real/result.env"

if [ "${admin_rows:-0}" = "1" ]; then
    note_ok "admin 行仍在（重置是原地改哈希，不是删号重建）"
else
    note_fail "admin 行被删了（剩 ${admin_rows:-0} 行）⇒ 名下分享/Key 会成孤儿"
fi

# ── 判据 ②：平台层必须把新口令一次性投递给 core ──────────────────────
echo "── 判据 ②：新口令已投递给 core（一次性文件 + 路径导出）"
RESET_FILE="${reset_file:-}"
if [ -n "$RESET_FILE" ] && [ -f "$RESET_FILE" ]; then
    note_ok "重置文件已投递：$RESET_FILE"
    if [ "$(cat "$RESET_FILE")" = "new-admin-pw" ]; then
        note_ok "重置文件内容 = 提交的新口令"
    else
        note_fail "重置文件内容不是提交的新口令（实得：$(cat "$RESET_FILE")）"
    fi
    MODE="$(file_mode "$RESET_FILE")"
    if [ "$MODE" = "600" ]; then
        note_ok "重置文件权限 0600"
    else
        note_fail "重置文件权限是 ${MODE}（期望 600）"
    fi
else
    note_fail "未投递重置文件（core 拿不到新口令 ⇒ 重置根本没生效）"
fi

# ── 判据 ③：消费标记后不得清空 .env 明文口令（prewire 自愈凭据）──────
echo "── 判据 ③：.env 明文口令不得被清空（prewire 自愈需要它）"
if [ "${env_password:-}" = "new-admin-pw" ]; then
    note_ok ".env 里的口令仍在（prewire 每次启动都能自愈重建 Key）"
else
    note_fail ".env 里的口令被清空/改写（实得：${env_password:-空}）⇒ prewire 自愈只剩第一次"
fi
if [ "${marker_left:-1}" = "0" ]; then
    note_ok "重置标记已消费"
else
    note_fail "重置标记未被消费（每次启动都会重复投递）"
fi

# ── 判据 ④：向导「留空=不改动」（提交空口令不得覆盖已有口令）──────────
echo "── 判据 ④：向导提交空口令 = 不改动（config/install callback）"
for cb in "$CONFIG_CB" "$INSTALL_CB"; do
    name="$(basename "$cb")"
    work="$TMP/cb-${name}"
    mkdir -p "$work"
    printf 'PB_JWT_SECRET="sec"\nPB_ADMIN_PASSWORD="keepme"\nPB_SERVER_PORT="12345"\n' > "$work/.env"
    TRIM_PKGVAR="$work" TRIM_APPDEST="$work" \
    PB_JWT_SECRET="" PB_ADMIN_PASSWORD="" PB_SERVER_PORT="12345" \
        bash "$cb" >/dev/null 2>&1
    kept="$(sed -n 's/^PB_ADMIN_PASSWORD="\(.*\)"$/\1/p' "$work/.env")"
    if [ "${kept:-}" = "keepme" ]; then
        note_ok "${name}：提交空口令 ⇒ 原口令逐字保留"
    else
        note_fail "${name}：提交空口令 ⇒ 原口令被覆盖（实得：${kept:-空}）"
    fi
    if [ -f "$work/.admin_reset" ]; then
        note_fail "${name}：提交空口令却置了重置标记（应为空=不改动）"
    else
        note_ok "${name}：提交空口令未置重置标记"
    fi
    # 反向：提交非空口令 ⇒ 必须更新（证明上面的「保留」不是「什么都不写」）
    TRIM_PKGVAR="$work" TRIM_APPDEST="$work" \
    PB_JWT_SECRET="" PB_ADMIN_PASSWORD="changed" PB_SERVER_PORT="12345" \
        bash "$cb" >/dev/null 2>&1
    changed="$(sed -n 's/^PB_ADMIN_PASSWORD="\(.*\)"$/\1/p' "$work/.env")"
    if [ "${changed:-}" = "changed" ]; then
        note_ok "${name}：提交非空口令 ⇒ 已更新"
    else
        note_fail "${name}：提交非空口令却没更新（实得：${changed:-空}）"
    fi
done

# ── 判据 ⑤：负对照——把旧行为（删 admin 行）注入回去 ⇒ 判据 ① 必须红 ──
echo "── 负对照：注入旧的「删 admin 行」行为 ⇒ 判据 ① 必须红"
MUTANT="$TMP/main-mutant"
export MUT_DIR="$TMP"
python3 - "$CMD_MAIN" "$MUTANT" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
anchor = 'stage_admin_password_reset "${PB_ADMIN_PASSWORD}"'
if anchor not in src:
    print("MUTATION_ANCHOR_MISSING")
    sys.exit(2)
old_behavior = ('    python3 "$MUT_DIR/delete_admin.py" "$PB_DATABASE_DB_NAME"\n'
                '    python3 "$MUT_DIR/clear_env_password.py" "$TRIM_PKGVAR/.env"\n')
mut = src.replace(anchor, old_behavior + anchor)
open(sys.argv[2], "w").write(mut)
PYEOF
if [ ! -f "$MUTANT" ]; then
    note_fail "负对照无法生成（cmd/main 结构变了 ⇒ 判据 ① 可能已失效）"
else
    run_reset_case "$MUTANT" "$TMP/mutant"
    # shellcheck disable=SC1090,SC1091  # 结果文件是本脚本刚生成的
    source "$TMP/mutant/result.env"
    if [ "${admin_rows:-1}" = "0" ]; then
        note_ok "坏副本确实删掉了 admin 行（判据 ① 能抓住它）"
    else
        note_fail "坏副本没删 admin 行（${admin_rows:-?} 行）⇒ 变异无效，判据 ① 无牙齿"
    fi
    if [ -z "${env_password:-}" ]; then
        note_ok "坏副本确实清空了 .env 口令（判据 ③ 能抓住它）"
    else
        note_fail "坏副本没清空 .env 口令（${env_password:-?}）⇒ 变异无效，判据 ③ 无牙齿"
    fi
fi

if [ "$fails" -gt 0 ]; then
    echo
    echo "✗ $fails 条判据失效"
    exit 1
fi
echo
echo "✓ 管理员口令重置的判据全部有效"
OK=1
exit 0
