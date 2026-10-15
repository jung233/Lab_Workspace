# 05｜OneDrive/S3 按需同步、独立备份与可选远端加密

## 5.1 三个概念必须分开

**存储**：每台设备的 Vault SQLite + 文件仓库。  
**同步**：把设备 A 的事件和选定资产交换到设备 B，保留每端独立状态。  
**备份**：某时刻可独立恢复的历史快照，不能因另一设备的误删除就自动销毁。

没有云账号、不设置服务器、不运行 Docker，APP 核心功能仍能正常使用。OneDrive 和 S3 是可选的远端交换与备份地点，不运行云端常驻应用业务逻辑。

## 5.2 远端加密从“强制”改为“可选”

### 5.2.1 UI 配置和默认行为

路径：设置 → 同步与备份 → 远端目标 → 安全与加密。**每个 OneDrive 或 S3 目标独立配置**；同步与备份可使用不同目标、不同密钥或不同加密设置。

提供至少以下选项：

| 模式 | 元数据事件/清单 | 小文件 | 大文件（>阈值） | 适用目标 |
|---|---|---|---|---|
| `none` | 明文 | 明文 | 明文 | 极简恢复/用户明确允许外部服务读取内容 |
| `encrypt_metadata` | 客户端 AEAD 加密 | 可独立选 | 可独立选 | 希望隐藏实验名称/结构但直接取回原始大文件 |
| `encrypt_all` | 客户端 AEAD 加密 | 客户端 AEAD 加密 | 客户端 AEAD 加密 | 敏感数据/需要端到端隐私 |
| `custom` | 分类别选择 | 分类别选择 | 分类别选择 | 针对大文件成本/恢复诉求定制 |

**默认建议**：首次配置必须让用户明确选择，不把加密强制设为前置条件；若用户希望最高可恢复性，可以设置 `none` 并保存普通开放格式的备份清单。对人体相关、未公开敏感科研文件则显著推荐客户端加密且备份恢复密钥。禁用客户端加密仍可能由云供应商在服务器端加密；这与用户拥有私有密钥的端到端加密不是一回事。

### 5.2.2 加密与非加密对象如何共存

每个远端对象保存：`object_id`, `remote_key`, `content_sha256`, `transfer_checksum`, `encryption_mode`, `key_id`, `format_version`, `source_asset_id`, `size`, `verification_level`。对象写入后不可原地改写。某目标的加密策略改变时，生成**新 epoch** 或新远端对象及 manifest，不能在原 Key 上用新加密参数覆盖旧备份；迁移成功并验证可恢复以后，用户再决定是否删除旧 epoch。

加密模式采用成熟的分片/流式 AEAD 方案，nonce 唯一，认证标签验证必需；不得自行发明密码算法。大文件可采用带认证的 chunk envelope + 清单，便于断点续传。真正加密需要密钥并可能带来 CPU、存储、恢复步骤成本；如果未加密，下载只需云授权和 manifest，不会因为“忘记 Vault 加密密码”而失去内容，但仍可能受云账号/权限/服务故障影响。

**本地 Vault 可默认不额外进行应用级文件加密**，依赖操作系统磁盘加密/设备保护；是否加入可选本地加密可作为后续独立特性，不与远端设置强绑定。

### 5.2.3 恢复优先设计

- 非加密备份：附可读 `README`、JSON manifest、可导出的 SQLite 快照及目录化对象，保证无 APP 也能用标准工具找到原始字节（可提供一键按原文件名重建目录脚本）。
- 加密备份：用户能导出脱离 APP 的恢复说明、明文密钥 ID、独立保存的 recovery key；**不把实际密钥直接打包在同一份远端备份中**；忘记密钥无法强行恢复。
- 混合备份：敏感元数据可加密、原始大文件可保持明文；清单明确列出哪些资源无法独立解密，否则 UI 不允许显示“完整无需密钥可恢复”。
- 备份设置页面实时显示“最后一次经实际恢复演练的版本”，不能用“上传完成”代替“恢复可用”。

## 5.3 同步协议（无中心业务服务器）

每台设备：`vault_id` 相同、各自唯一 `device_id`；本地每笔写事务附加只增 MutationEvent：`mutation_id`, `device_id`, `seq`, `lamport`, `entity_type`, `entity_id`, `base_revision`, `payload`, `asset_sha_refs`。

远端采用 append-only：

```text
lab-workspace/v2/<vault-id>/<storage-epoch>/
  header.json                       # 公共版本信息，不放敏感具体实验数据
  devices/<device-id>/events/00000000001-<uuid>.bin
  snapshots/<snapshot-id>/manifest.bin
  objects/<opaque-key>              # 根据加密/明文模式选择命名
  backup/<backup-id>/manifest.bin
```

**加密已关闭**时 manifest 可存明文原始 SHA（涉及存在性泄露），对象可由 digest 派生路径；**启用加密**时推荐不将明文 SHA 直接用于公开远端路径，采用受密钥保护的对象标识或随机 ID。Manifest 保存可验证的源 SHA 与密文传输校验信息。

### 5.3.1 同步状态机

`LOCAL_ONLY → QUEUED → UPLOADING → UPLOADED → REMOTE_AVAILABLE → DOWNLOADING → VERIFIED/QUICK_CHECKED`；任何环节可 `PAUSED`, `FAILED`, `CONFLICT`, `MISSING`。同步不能把线上数据“看似存在”作为本地可读文件。

### 5.3.2 多端冲突

- 不同 Entity 的写操作自然合并；对 append-only 测量与新附件可并存。
- 对相同样本处理浓度、同一步骤状态、正式 Protocol 版本、同一计算输入、删除与修改冲突，记录两端原始事件，人工选定/合并并生成新 Resolution Event。
- 不采用 LWW（最后写入覆盖）作为科研数值冲突默认策略。
- 时间使用 UTC + logical clock，不能根据本地墙上时间严格推断跨端事件先后。
- 从备份在另一台设备恢复时分配新 device_id，避免“同 device_seq 重用导致事件丢失”。

### 5.3.3 选择性同步

支持“只同步元数据”“同步小文件”“指定项目/实验”“只 Wi-Fi / 充电时同步”“大文件仅手动”与**单个文件的同步开关**。默认不强制上传原始科研图片；用户可对 `>2GiB` 文件默认禁用自动同步以控制流量。手机仅下载缩略图或元数据时仍可看到文件信息并点选下载。设备远端没有副本时不能误报“备份已存在”。

### 5.3.4 云适配器

`CloudStore` 统一方法：`putImmutable`, `getRange`, `stat`, `listSince`, `delete`, `createUploadSession`, `abort`, `capabilities`。

- OneDrive 用 Microsoft Graph OAuth + PKCE，文件上传优先使用支持断点续传的 uploadSession；需处理 Graph 429/重试和 OneDrive 部分账户/目录限制。
- S3 兼容适配需能力探测：multipart、服务端 checksum、conditional put、versioning 支持程度不同；不能把 ETag 当成通用 SHA-256。
- API Token/OAuth refresh token 保存在设备操作系统安全存储，不放在同步事件、备份或源码。
- 不要求安装 OneDrive 同步客户端，也不直接在被同步的云盘文件夹中读写活动 SQLite 数据库。

## 5.4 备份服务与快照

### 5.4.1 SQLite 一致性

使用 SQLite Online Backup API 或安全的 `VACUUM INTO` 生成可恢复快照；禁止只复制活动中的 `.sqlite` 而不考虑 WAL。保存 `db_schema_version`, `vault_id`, `snapshot_id`, `asset_manifest`, `created_at`, `encryption_policy`, `checksum_policy`, `pack_versions`。

### 5.4.2 全量与增量

- 初始化快照包含数据库、全部选中的 Blob、版本化 Protocol/CalculationPack 配置；
- 后续快照可重用远端已存在的不可变 Blob，只上传数据库新快照和新的 Blob；
- 删除策略独立于 Sync 墓碑；用户可设每周全量/每日快照/保留 N 版本，但空间不足需暂停并发告警；
- 大文件默认遵照分级 SHA 策略，备份时可在传输同一遍计算 SHA 流式核验（如用户允许）或依赖导入时哈希+传输通道校验并显示验证级别；不额外强制重新读完源文件。

### 5.4.3 恢复与验收

1. 用户选目标与备份版本，展示是否需要密钥及预计大小。
2. 先恢复到全新临时 Vault，不覆盖正在运行数据库；验 manifest schema、密文 AEAD（若启用）、元数据引用完整性。
3. 每个对象按配置“严格完整核验”或“大文件快速恢复后后台全量验证”。若未全验，标记 `restored_unverified_large_blob`，避免科研结果被错误声明 100% 可信。
4. SQLite `PRAGMA integrity_check`、数据外键、Sample→Asset→CalculationTrace 引用校验。
5. 用户确认切换当前 Vault，并保留原 Vault 应急快照。提供试恢复功能与恢复报告。

## 5.5 云同步与备份错误矩阵

| 场景 | 行为 |
|---|---|
| 云离线 | 本地完整可用，发送队列等待，重试退避 |
| S3 仅支持部分 API | 降级到版本化不可变对象，显式显示能力限制 |
| OneDrive 登录过期 | 只停止云动作，不影响实验计时与计算 |
| 远端未加密 | UI 提醒可读性和隐私风险，但用户确认后允许使用 |
| 丢失加密恢复密钥 | 不能声明可从加密备份恢复；保留本地/未加密副本 |
| 大文件快检通过、未 full verify | 显示 last_verified_at 和有限的信任级别 |
| 手机和电脑冲突 | 保留双方版本和原始事件，人工解决 |
| 文件从 Explorer 删除 | 同步墓碑；保留独立历史备份，不盲目级联删远端旧版本 |
