# 07｜安全、实施计划、验收测试、发布与维护

## 7.1 用户故事与系统级验收

| ID | 验收项 | 判定方式 |
|---|---|---|
| AC01 | 断网首次运行无 Protocol 可新建实验、步骤、附件、计时与计算 | Windows + Android 真机 |
| AC02 | PDF/SOP 生成 Protocol Draft，缺失时长标 unknown，用户批准才能发布 | mock 模型/Schema/DAG |
| AC03 | “新建 BCA 工具”通过自然语言生成 CalculationPack，无需修改 APP 源码即可安装 | 真实 BCA 合成数据 golden test |
| AC04 | 无可用计算原语时明确报错，不私自生成不安全 Python | unsupported op 测试 |
| AC05 | 所有衍生数值“展示原始计算”包含输入、来源、代入式、中间值、公式、单位、版本 | UI E2E+Trace Schema |
| AC06 | Windows 内置 Python、Conda 自选环境计算，互不污染 | 跨环境比较与异常恢复 |
| AC07 | Android/iOS 内置 Python 能运行批准的基础计算包 | 真机 golden test |
| AC08 | 多模态模型提出 ROI，人工确认，像素定量从未修改原图产生 | 模型工具 Stub+原件哈希比较 |
| AC09 | SHA 阈值默认为 2 GiB，用户可修改；小文件每次逻辑打开全文 SHA；大文件不反复全量计算 | 监听哈希调用计数与 IO 基准 |
| AC10 | 大文件首次导入流式 SHA、后续快检准确标注“非全量验证” | 完整性标志测试 |
| AC11 | 内置 Explorer 可打开原件、查看引用和派生链、批量软删、永久删除与空间回收 | UI/SQLite/GC 验收 |
| AC12 | 删除被引用的原件需要风险确认，保留 tombstone，历史实验显示“文件已缺失” | 断引用与恢复测试 |
| AC13 | OneDrive/S3 远端加密可关、可开，均可恢复对应备份 | 两套独立恢复演练 |
| AC14 | 远端不加密备份不依赖未知加密密钥，清单可读，数据可重新导入 | 退出账号后模拟离线恢复包 |
| AC15 | 加密备份无恢复密钥则明确告警，不能虚假宣称可恢复 | 错密钥/损坏认证标签测试 |
| AC16 | 设备 A/B 离线修改同一浓度，重新同步后产生显式冲突，不 LWW 覆盖 | 双 SQLite + 假云存储 |
| AC17 | 备份与同步分离，删除同步不销毁历史独立备份 | 恢复旧 Snapshot |
| AC18 | 2 GB 级以及更大文件导入、打开、部分云同步时内存不随大小线性增长 | 资源仪表/断点续传测试 |
| AC19 | 未经用户授权不上传图片至 AI，模型不能调用文件删除/系统 shell | 拒绝工具调用与数据外发测试 |
| AC20 | Windows 无 Python/Conda 额外安装仍可计算；离线核心功能正常 | 干净环境安装 |
| AC21 | APP 崩溃、上传中断、OS 休眠后恢复有一致的 Pending/Interrupted 状态 | 故障注入 |
| AC22 | 额外复制生成的“展示用图片”不会进入科研定量数据流 | Asset provenance 策略测试 |

## 7.2 关键单元与集成测试矩阵

**资产完整性**：导入 sha256；相同内容去重；改源文件不影响 CAS；小文件每次打开重新校验；大文件每次打开只快检；手动全验会发现同尺寸篡改；恢复后校验策略；`missing` 与 `mismatch` 不可静默重算现有哈希覆盖原记录。

**File Explorer**：取消引用但仍有其他 AssetLink，不可回收 Blob；唯一 Asset 软删可恢复；永久删除即使下游 CalculationRun 仍存在也不得悬空报错崩溃；回收站和云墓碑延迟正确；缓存清理不损失原始数据；已导出的可编辑文件重导入生成新 Asset。

**AI/Workflow**：有依赖循环的 Protocol 拒绝；AI 伪造 `op` 拒绝；未知变量/不兼容单位拒绝；不批准的 Pack 不能运行；公式除零、样本值超标准范围、结果追踪中间步骤缺失均显示错误；AI 提供的 ROI 坐标越界与未人工批准拒绝。

**Sync/Backup**：云离线、错误凭据、部分上传、重复事件、顺序乱序、跨设备冲突、加密配置切换生成新 Epoch、远端明文恢复、新旧快照恢复、损坏 metadata manifest、lost key、快照恢复后使用新 device_id。

**平台**：Windows 安装/升级/卸载保留 Vault、Android 文件权限与电量限制、iOS 代码签名与嵌入 CPython、系统通知权限变化、系统休眠/重启恢复。

## 7.3 威胁模型与权限隔离

- **文件**：恶意替换原件、删除/同步错误、备份损坏。用 CAS 只写一次、校验记录、回收站、不可变快照和恢复演练缓解。
- **AI**：SOP 内提示注入、让模型调用任意 shell、请求 API Key、创造虚构测量。用局部 AssetId、Policy Engine、Schema 验证、用户审批、合成测试和工具白名单缓解。
- **计算**：用户可指定 Windows 外部 Conda，应明确标注为可信本机环境（不是严格沙盒）；文件输入走受控目录，输出只导入新对象。移动端不允许运行任意远端新原生库。
- **云**：不加密意味着供应商和具有云账户访问权的人可能看到内容；启用加密则必须保护恢复密钥。外发人体/敏感研究数据前应先核对机构规定与伦理审批。
- **设备**：单用户免登录仍需建议设备锁/全盘加密；本机可选应用 PIN/生物识别锁，不宣称满足医疗监管合规要求。

## 7.4 发布与目录迁移

首次启用生成 VaultID/DeviceID 与本地目录，独立于 APP 安装路径。用户改变存储磁盘时，迁移向导先校验空间、创建目标、流式复制文件（默认按分级哈希）、复制 SQLite 一致性快照、核验新 Vault 后切换；原旧目录在新位置被验证前不可自动删除。

CI：`dart analyze`、Flutter unit/widget/integration tests、Python Golden Cases、Protocol/Pack/Trace JSON Schema、SQLite migration/`integrity_check`、Core sync conflict tests。使用 Windows Runner 生成原生安装包、Android Runner 生成 APK/AAB、macOS Runner 生成 iOS IPA；固定 SDK 和依赖版本，产物签名并附 SHA-256/SBOM。测试不得携带真实科研原始数据或真实用户 API Key。

## 7.5 Sprint/Epic 拆解

| 阶段 | 主要模块 | 退出门槛 |
|---|---|---|
| S0 | 工程基础/固定契约/测试数据/Flutter Shell | 全部 Schemas & SQLite 迁移通过 |
| S1 | 本地 Vault、Asset CAS、SHA 策略与 Explorer | 可导入、查看、删除、恢复，大小阈值工作 |
| S2 | Project/Run/Sample/Treatment/Protocol DAG | 未知实验不依赖预置模板完成记录 |
| S3 | Python Executor、PrimitiveRegistry、CalculationTrace UI | BCA/WB golden tests 与原始计算按钮 |
| S4 | Protocol Pack、Calculation Pack、Skill 生成与审核 | AI 生成 BCA 动态工具无须改代码 |
| S5 | 本地时间线、通知、Todo | 跨暂停/重启保持正确计划与状态 |
| S6 | OpenAI SDK 双 API、多模态图像工具 | 工具调用/用户授权/ROI 与原图保护 |
| S7 | OneDrive/S3 增量 Sync、选择性附件、可选加密 | 两端冲突可恢复、未加密备份与加密备份均可恢复 |
| S8 | Android/iOS 嵌入 Python、真机性能 | Native 两平台通过功能/资源/分发测试 |
| S9 | MS To Do、可靠性测试、安装包/发布 | 故障注入、恢复演练、生产签名 |

本表是**任务拆解而非时间估算**。优先交付 Windows + Android 的本地稳定闭环，iOS 在打包/签名与 App Store 分发审核后进入正式发布。

## 7.6 版本兼容与架构升级

- 所有 Protocol/CalculationPack/Skill/Trace 采用 SchemaVersion；新增字段向后兼容，破坏性升级需新增主版本和迁移器。
- 数据库每次迁移生成不可改写版本，迁移前备份；旧 APP 无法理解新 Schema 时必须拒绝写入，防止损坏。
- 模型 API 的兼容端可能只支持其中一套接口：系统进行真实能力检测而非仅凭自称兼容判定。
- AI 新增 Pack 的功能范围受现有 PrimitiveRegistry 与 Flutter FormRenderer 能力限制，未来新类型通用控件由 APP 更新后支持。
- 云备份 Manifest 必须包含最低可恢复 App 版本与所需 Pack 版本，可离线导出参考解码说明。

## 7.7 本版明确的技术风险

1. 把 SHA-256 读校验用于所有小文件会导致特定中等体积文件频繁重复 IO，因此阈值应可调整并提供性能监测，不应隐式牺牲用户需求。
2. 大文件不每次全验降低检测静默篡改概率，UI 必须明确“快速检查 ≠ 哈希验证”。
3. OneDrive/S3 无原生业务中心，增量事件合并、设备时钟与垃圾回收很容易造成永久性丢失，必须建立幂等、冲突队列、回收宽限期与备份。
4. 远端不加密提高独立可恢复性，但会暴露科研文件和元数据；选择权属于用户且应充分提示。
5. AI 自动生成计算包必须限制在已验证通用原语，不能为了宣传“无限扩展”就把任意模型代码直接运行。
6. iOS 下 Python 第三方 native 扩展和下载执行代码受平台分发限制，需要提前验证真实设备和商店政策。
7. 绝大多数模型不能保证精确图像 ROI/定量识别；必须让用户确认，量化基于真实原始像素和可复算公式。

## 7.8 成功的最终判定

Lab Workspace 达成目标时，用户可以在没有网络、没有后端、没有预置实验类型的前提下完成实验记录和内置计算；联网后使用 AI 自然语言导入 SOP 或生成 BCA 等计算配置；所有衍生数值可单独展示原始公式和运算；所有文件可在 Explorer 中操作并有透明的 SHA 策略；可以选择同步或备份到 OneDrive/S3，并自由决定远端是否加密、哪些大文件上传、何时删除与如何恢复。
