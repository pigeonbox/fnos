# wizard · 安装/配置向导

已按官方规范落地(docs/core-concepts/wizard/):向导收集的字段**不带前缀**直接成为
环境变量,注入生命周期脚本(cmd/*_callback 经 `$PB_SERVER_PORT` 等直接读取)。

- `install` 安装时收集;`config` 安装后从应用设置随时改(两份字段一致)
- 字段即 env 契约(compose/adapter 直接消费,故未用 wizard_ 前缀):
  `PB_JWT_SECRET`(留空=adapter 自动生成并持久化到数据卷)、
  `PB_ADMIN_PASSWORD`(非空=admin 密码安装设定/重置:callback 置 `.admin_reset` 标记,
  cmd/main 启动前把新口令投递给 core(core **原地**改 bcrypt 哈希,admin 的 user id 不变
  ⇒ 名下分享/API Key 不成孤儿);留空=不改动——.env 里已有的口令逐字保留,
  供 Beam 出厂预接线做「Key 失效后重建」的自愈)、
  `PB_SERVER_PORT`(服务端口,默认 12345;config_callback 同步解包目录 manifest.service_port,
  cmd/main prepare_env 消费——端口 env 优先,勿在脚本内无条件覆盖)

## 已知限制

- **改端口后的桌面入口(仅端口直连场景)**:2026-10-09 起桌面入口走统一网关
  (`/app/pigeonbox` 前缀,不绑端口),改端口不影响桌面图标;仅经
  `http://NAS_IP:端口` 直连的老书签需要更新。
- **config 面板端口回显**:面板端口框为静态默认值(框架未提供动态预填机制),
  修改前请以实际监听端口为准。

## 数据备份与恢复

- 升级时 `cmd/upgrade_callback` 自动快照业务库:`data/fileCodeBox.db.bak-<时间戳>`,
  轮转保留最近 3 份。
- 手动恢复:应用设置停止应用 → 用备份覆盖 `data/fileCodeBox.db` → 启动应用。
