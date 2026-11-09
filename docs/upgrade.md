# fnOS 升级指南（原地换装）

> 面向 fnOS（飞牛）用户与运维。升级流程的**生态级**说明见
> [pigeonbox/docs/UPGRADE.md](https://github.com/pigeonbox/pigeonbox/blob/master/docs/UPGRADE.md)；
> 本文只讲 **fnOS 平台特有的**两件事：启停方式与应用中心注册表。

## 为什么不能用应用中心直接升级

fnOS 应用中心**装不了原生第三方包**，且 `install-fpk` 对已装应用是 no-op
（"is installed" 直接退出）⇒ 升级一律走**原地换装脚本**：

```bash
sudo bash scripts/upgrade-inplace.sh <pigeonbox.fpk>
```

⚠️ **动手前必须先备份**：应用中心的 `install-local` 是「卸载→安装」语义，
会连 `@appdata`（含业务 DB）与**注册表行**一起删掉。

## 两条硬规矩（2026-11-10 真机实录补）

### 一、升级后的启停**必须走框架托管**

```bash
sudo appcenter-cli stop pigeonbox
sudo appcenter-cli start pigeonbox
```

**为什么**：`TRIM_APPDEST` / `TRIM_APPNAME` / `TRIM_API_TOKEN` 这些变量是
**fnOS 框架在拉起生命周期脚本时注入**的 ⇒ 只有**框架托管**的启动路径才有它们。

若绕过框架手工拉进程（本仓脚本此前就是 `nohup ... env TRIM_PKGVAR=... cmd/main start`，
只注入了 `TRIM_PKGVAR`、**没有 `TRIM_APPDEST`**）：

* adapter 判不出「原生应用环境」⇒ `/api/fnos/capabilities` 回报
  `gateway=false` / `sso=false`
* ⇒ 面板「**统一网关免登录**」**静默失效**（点桌面图标进不去、SSO 走不通）
* 而升级脚本**退出码 0**、`/version` 自证全绿 ⇒ 典型的**静默半升级**

真机实录（10.10.30.253，4.8.6→5.7.0）：脚本跑完 capabilities = `{gateway:false, sso:false}`；
改用 `appcenter-cli stop && appcenter-cli start` 后恢复 `{gateway:true, sso:true}`。

> 现在 `scripts/upgrade-inplace.sh` **默认就走框架托管启停**，并在收尾做断言：
> capabilities 的 `gateway`/`sso` 必须是 `true`，否则**非 0 退出**并打印补救命令。
> 降级路径（机器上没有 `appcenter-cli`）会**明确告警**，不会假装成功。

### 二、应用中心注册表的版本**在宿主 PostgreSQL 里，不在容器里**

面板显示的版本来自**应用中心注册表**（`appcenter` 库的 `app` 表），
**不在**应用自己起的 pg18 容器里（容器里那份是业务库）。

原地换装只换磁盘上的文件 ⇒ 不同步注册表就是
「**面板显示 4.8.6、实际跑 5.7.0**」（面板显示版本 ≠ 实际运行代码）。

同步（换装脚本会自动调；也可单独跑）：

```bash
sudo bash scripts/sync-appcenter-version.sh --version 5.7.0
```

宿主侧直连改表（等价手工动作）：

```bash
sudo su postgres -c "psql -d appcenter -c "UPDATE app SET version='5.7.0' WHERE app_name='pigeonbox';""
```

（pg_hba 是 `local all postgres peer map=trim_root` ⇒ peer 认证，不认密码。）

> 无 PostgreSQL / 非 fnOS 主机上，该脚本会**明确提示并跳过**（不静默跳过、不假绿）；
> 换装脚本收尾的断言 B 会把「面板版本 != 目标版本」判红。

## 换装脚本收尾的两条断言

| 断言 | 判据 | 不满足时 |
|---|---|---|
| A 网关能力 | `GET /api/fnos/capabilities` 的 `gateway` **且** `sso` 为 `true` | 非 0 退出 + 打印 `appcenter-cli stop/start` 补救命令 |
| B 注册表版本 | `appcenter-cli list` 里本应用的条目**包含**目标版本 | 非 0 退出 + 打印 `sync-appcenter-version.sh` 补救命令 |

* 「本机被网关纳管」的判据：`appcenter-cli` 存在**且** `appcenter-cli list` 里有本应用条目。
  拿不到这两个事实 ⇒ **跳过并说明原因**（非 fnOS 宿主本就不该有统一网关），绝不静默放过。
* **沙箱模式**（`PB_UPGRADE_SANDBOX=1`，离线门禁用）：两条断言都**跳过并说明原因**、退出码 0
  —— 沙箱里没有真机进程、没有应用中心、没有宿主 PostgreSQL，断言必然假红。

## 相关脚本

| 脚本 | 作用 |
|---|---|
| `scripts/upgrade-inplace.sh` | 原地换装主体：备份 → 停 → 解包 → 换 `cmd/`+manifest → 启 → 同步注册表 → 断言 |
| `scripts/sync-appcenter-version.sh` | 应用中心注册表版本同步（宿主 PostgreSQL） |
| `scripts/verify-upgrade-result.sh` | 升级后两条断言（网关能力 + 注册表版本） |
| `scripts/check-upgrade-inplace-framework-start.sh` | 离线门禁：断言有牙齿 + 沙箱跳过 + 负对照 |
| `scripts/lib/fnos-env.sh` | 公共小函数（manifest 字段 / 进程 environ / appcenter-cli 定位） |
