# 08｜内部 API、用户界面交互与开发落地契约

> 无网页端与服务端 API。本章描述 Flutter 应用模块之间的本地类型化接口和事件，供代码实现时冻结。所有命令均通过本机服务层执行，不能把以下内容当作已实现代码。

## 8.1 Dart 业务接口（建议）

```dart
abstract interface class ExperimentCommands {
  Future<RunId> createRun(CreateRunCommand command);
  Future<StepEventId> startStep(StartStepCommand command);
  Future<StepEventId> completeStep(CompleteStepCommand command);
  Future<MeasurementId> recordMeasurement(RecordMeasurementCommand command);
  Future<RunId> closeRun(CloseRunCommand command);
}

abstract interface class LocalAssetRepository {
  Future<AssetId> importFile(ImportAssetCommand command);
  Future<OpenAssetResult> openAsset(OpenAssetCommand command);
  Future<IntegrityResult> fullVerify(AssetId assetId);
  Future<DeletionImpact> previewDelete(DeleteAssetCommand command);
  Future<DeletionId> trashAsset(DeleteAssetCommand command);
  Future<DeletionId> purgeAfterConfirmation(DeleteAssetCommand command);
  Future<ExplorerPage> listFiles(ExplorerQuery query);
}

abstract interface class CalculationService {
  Future<CalculationJobId> start(RunCalculationCommand command);
  Future<CalculationTrace> getRawCalculation(CalculationId id);
  Future<CalculationId> recalculate(CalculationId id);
}

abstract interface class PackRegistry {
  Future<PackDraft> generateFromText(String text, SkillRef skill);
  Future<ValidationReport> validate(VersionedPack draft);
  Future<GoldenTestReport> testPack(VersionedPack draft);
  Future<InstalledPack> approveAndInstall(VersionedPack draft);
}

abstract interface class SyncBackup {
  Future<SyncPlan> previewSync(SyncSelection selection);
  Future<SyncResult> syncNow(RemoteTargetId target);
  Future<BackupId> createSnapshot(BackupRequest request);
  Future<RestoreReport> testRestore(BackupId id);
}
```

### 8.1.1 所有写命令的共通字段

`command_id` 用于本地幂等；`base_revision` 防并发覆盖；`device_id`/`utc_time` 用于事件生成；`actor=local_user` 无需多用户账户；`source_ref` 可指明原始文件和测量来源；`approval_ref` 指向危险操作用户批准。

## 8.2 关键内部事件

`RunCreated`, `ProtocolVersionApproved`, `StepStarted`, `StepCompleted`, `MeasurementConfirmed`, `AssetImported`, `AssetIntegrityFailed`, `AssetTrashed`, `AssetPurged`, `CalculationCompleted`, `ImageRoiApproved`, `PackInstalled`, `ReminderDue`, `TodoChanged`, `SyncConflictDetected`, `BackupVerified`。

每个事件写入 SQLite 同一个事务中的 mutation/outbox；订阅处理需要幂等，不依赖 UI 是否打开。对于 Cloud Sync、Graph、Webhook 失败不能回滚既有实验步骤，而要可见的重试状态。

## 8.3 Error Codes 与用户提示

| Error Code | 应用行为 | 是否重试 |
|---|---|---|
| `ASSET_SHA_MISMATCH` | 标记受损，阻止新计算，提供从版本备份恢复 | 不自动覆盖哈希 |
| `ASSET_FAST_CHECK_ONLY` | 非错误，但提示不具备本次完整验证 | 用户可手动全验 |
| `ASSET_REFERENCED_DELETE_REVIEW` | 显示所有下游引用和预估回收空间 | 需用户确认 |
| `ASSET_REMOTE_MISSING` | 本机无对象且远端不可下载 | 云恢复后重试 |
| `PROTOCOL_DAG_CYCLE` | 不允许批准 Pack，指出节点路径 | 编辑流程 |
| `PROTOCOL_DURATION_UNVERIFIED` | 缺失时长保留 unknown，不自动计时 | 用户补全 |
| `CALC_PRIMITIVE_MISSING` | 阻断生成/安装，展示所需新原语 | 更新能力或选工具 |
| `CALC_UNIT_INCOMPATIBLE` | 拒绝计算，展示输入及期望单位 | 修正数据 |
| `CALC_TRACE_MISSING` | 阻止将结果标记为科研已审核结果 | 修复工具/补录来源 |
| `AI_VISION_UNSUPPORTED` | 图片相关功能不可用，不假装有模型输出 | 更换支持视觉的模型 |
| `AI_UPLOAD_CONSENT_REQUIRED` | 显示外发说明 | 用户决定 |
| `IMAGE_ROI_REVIEW_REQUIRED` | 显示 ROI 候选叠层供确认 | 用户决定 |
| `SYNC_CONFLICT_REVIEW_REQUIRED` | 展示本地/远端两版本，保留原有值 | 用户解决 |
| `REMOTE_KEY_MISSING` | 无法解密选定远端备份 | 使用恢复密钥或未加密版本 |
| `BACKUP_NOT_RESTORE_TESTED` | 状态为快照成功但尚未实际恢复演练 | 提议试恢复 |

## 8.4 最小页面导航 / User Flows

```text
主页面
  ├─ 今日实验 / 并行计时 / To-Do
  ├─ 实验管理
  │   ├─ 新建实验（自由记录 / 选择Protocol / AI导入）
  │   ├─ 执行页面（步骤、实时数据、材料、计时、上传）
  │   └─ 实验历史与派生链
  ├─ Protocol
  │   ├─ 模板与Pack库
  │   ├─ AI自然语言生成
  │   ├─ 表单/变量/步骤/DAG编辑
  │   └─ 校验/测试/审核/版本
  ├─ 工具箱
  │   ├─ AI新增计算工具
  │   ├─ BCA、WB、稀释等已安装Pack
  │   └─ 计算结果 → [展示原始计算]
  ├─ 原始文件 Explorer
  │   ├─ 全部 / 项目 / 样本 / 原始 / 派生 / 大文件 / 未关联
  │   ├─ 元数据 / SHA / 派生链 / 打开系统查看器
  │   ├─ 重命名显示名 / 导出副本 / 关联 / 解除引用
  │   └─ 回收站 / 永久删除 / 空间优化 / 扫描校验
  └─ 设置
      ├─ 数据路径与迁移
      ├─ SHA完整性策略（默认2GiB）
      ├─ Python执行器（内置/Conda）
      ├─ AI供应商/API模式/秘钥/模型能力
      ├─ Skills/Workflow Packs
      ├─ 云同步（OneDrive/S3）
      ├─ 备份（目标/加密/保留/恢复密钥）
      ├─ Microsoft To Do/Webhook
      └─ 数据恢复/诊断日志
```

## 8.5 设置模型（推荐）

```json
{
  "schema_version": "2.0",
  "local_vault": {"storage_mode": "managed", "integrity_threshold_bytes": 2147483648,
                  "small_read_check": "full_sha256", "large_read_check": "metadata_quick",
                  "large_idle_full_verify": "manual_or_offpeak", "trash_retention_days": 30},
  "python": {"default": "builtin", "external_profiles": []},
  "ai": {"provider_profiles": [], "auto_upload_sensitive_assets": false},
  "sync": {"enabled": false, "metadata_default": true, "large_file_default": "manual"},
  "backup": {"enabled": false, "remote_encryption": "ask_per_target", "keep_snapshot_history": true}
}
```

## 8.6 文件访问最短路径（严格与宽松）

- `AssetGateway.open(asset_id)` 先查询 Blob.size 和当前阈值。
- `size <= threshold`：必须完整哈希验证本次读入的原件，再把字节流/临时只读句柄交给下游工具；不能校验文件 A 却读取被外部替换后的 B（Windows 要有文件句柄锁/共享策略，必要时单次 staging 读取）。
- `size > threshold`：检查 size、mtime、FileId 等，返回数据和 `validation_level=quick_checked`；如果用户设置了严格，则同样全量校验。
- 原始图像交给 AI 工具时仍标记该次访问的 validation_level，最终计算 Trace 保存该状态；若需要最高强度科研证明，用户可以在正式发表/最终归档前对大文件主动做完整哈希核验。
- 无论大小，编辑的派生文件必须写入 staging 并为新文件计算一次 SHA。

## 8.7 文件删除与 Storage GC 伪代码

```text
function previewDelete(assetId):
  links = active_links(assetId)
  blob = asset.blob_sha256
  other_assets = active_assets_with_blob(blob) excluding assetId
  snapshots = retained_backup_snapshots_referencing(blob)
  replicas = remote_replica_states(blob)
  reclaimable_now = not links and not other_assets and no_pending_jobs
  return {links, other_assets, snapshots, replicas, reclaimable_now,
          logical_bytes=asset.size, reclaimable_physical_bytes=...}

function confirmedDelete(assetId, mode):
  require_confirmation(previewDelete(assetId))
  in_transaction:
    soft_delete(assetId) / mark_forced_missing(assetId)
    append_tombstone_event()
    update_file_explorer_index()
  if mode == purge:
    schedule_gc_after_grace_and_device_ack()

function gc():
  for blob in orphan_blobs():
    check active Assets, trash age, syncing devices, leases and backups
    if eligible: unlink CAS blob and record purge event
```

**避免“强制删除文件”变成业务记录丢失**：既有计算 Trace、样本关系和历史 SHA 仍保留，但文件状态变为 Missing，UI 可引导从版本备份恢复。

## 8.8 Graph To Do 的单用户双设备避免重复

没有中心服务器时，同一个 Microsoft 帐户若同时由手机和 Windows 创建同一 Task，可能产生重复任务。默认让用户选择一个 `integration_primary_device` 对 Graph 执行写同步；其他设备通过 Vault 同步获得映射关系，只显示本地待同步状态。若主设备不可用，必须经过用户显式接管和重新同步检查才允许新的主设备写入，不能假设 Graph 原生请求幂等键能解决跨设备竞态。

## 8.9 完整开发的 Definition of Done

某一模块完成必须同时满足：接口/Schema 文档、单元测试、异常恢复测试、脱敏日志、真实输入文件边界测试、移动端与 Windows 跨端用例（如适用）、数据迁移测试和用户可理解的错误提示。**“模型生成了一段 JSON 并成功解析”不等于正式 Protocol/计算工具已科学验证**。
