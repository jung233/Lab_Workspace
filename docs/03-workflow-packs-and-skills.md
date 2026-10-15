# 03｜AI 生成 Protocol / Calculation Pack 与 Skill 开发生态

## 3.1 从“写硬编码实验”升级为“配置一个可审核的工作流 Pack”

平台应维护稳定的通用原语，而不是每种实验写对应专用组件。Pack 安装以后由 Runtime 动态加载，UI 根据 schema 自动生成表单、表格和向导。满足已有原语的实验（BCA、稀释、WB 上样、标准曲线等）不需要源码重构，也不需要更新 APP。

三类包严格分层：

| 包 | 承载内容 | 运行行为 | 审核 |
|---|---|---|---|
| Protocol Pack | SOP 步骤、时长、DAG、数据采集表、样本与组别映射 | 通用执行引擎解释 | AI 生成后人工批准 |
| Calculation Pack | 数值算子、数据输入表、计算 DAG、单位、质量控制、输出和 golden tests | 内置 Python 解释器执行**已有批准算子** | schema + 测试 + 人工批准 |
| Skill | 何时如何生成/检查上述 Pack、AI 工具调用规范 | AI 加载指令，不会自动变成原生代码 | Tool Registry / Policy Engine 授权 |

计算 Pack 的一个 `op` 必须来自内置 `PrimitiveRegistry`，且有版本、输入/输出 Schema、数值容差与 Trace 语义。**严禁把模型输出的 Python 源码默认当作安全声明式 Pack 执行**。

## 3.2 用户自然语言创建 BCA 工具的流程

**用户**：“新增 BCA 工具，输入酶标仪 Excel/CSV、标准品浓度和稀释倍数；按我的配置拟合标准曲线，计算浓度并把结果交给 WB 上样。”

1. AI 检查现有工具 Registry/PrimitiveRegistry（如 CSV 导入、空白扣除、线性拟合、样本重复孔统计、结果映射）。
2. 若所需原语均已存在，生成 `CalculationPackDraft`（manifest + pipeline + input form + quality gates + 示例样本 + 预期 golden outputs）。
3. 若缺少具体算法原语（如设备专用非线性拟合），明确返回 `unsupported_operations` 并提示改用已验证算子或创建新插件；**不得悄悄降级成不正确的公式**。
4. Schema、类型和量纲校验 → 运行内置合成测试 → 向用户展示样例中间值与误差 → 人工审核 → 安装为新的版本化计算 Pack。
5. Protocol 编辑器即可把新计算 Pack 关联至任意步骤，无需更新核心源代码。
6. 用户运行时填写数据，生成 CalculationRun + 完整 CalculationTrace，输出可引用到后续实验。旧实验绑定旧版本，不受新增 Pack 影响。

Pack 结构（示例）：

```text
packs/bca-standard-curve/1.0.0/
├── manifest.json                  # ID、版本、权限、文件哈希、兼容性
├── protocol.json                  # 可选：相关实验步骤，引用calc pack
├── pipeline.json                  # 输入字段、ops DAG、输出映射、质量检查
├── forms.json                     # 可视化配置表单与字段标签
├── fixtures/
│   ├── sample-input.json          # 合成数据
│   └── expected-output.json       # golden 结果
└── README.md                      # 算法适用范围、局限与审核记录
```

### 3.2.1 必须明确的功能边界

“AI 自然语言新增任意新实验/计算”在工程上分为两种：

- **声明式能力组合**：已有数学/文件/统计原语充分，AI 生成配置即可安装，跨端无需重新编译。这是 MVP 必须支持的目标。
- **新增算法代码**：平台没有原语。Windows 可让用户审核独立 Python 插件并指定 Conda 等外部执行器；该环境具有 Windows 当前用户权限，**不是真正安全沙盒**。移动端的任意下载/安装 Python 原生代码受操作系统和分发政策限制，不能承诺同样的热安装；需将扩展迁移到已打包可信运行时或更新 APP。即便在 Windows，科研数值算法也必须有黄金样例与版本化测试。

## 3.3 Pipeline 原语注册表（初始建设）

| Primitive ID | 输入与输出 | 执行与追溯 |
|---|---|---|
| `csv.parse_table@1` | 字节资产、分隔符、列映射 → typed rows | 记录来源 Asset SHA、解析告警 |
| `table.select@1` | rows、选择配置 → rows | 记录筛选条件和行数 |
| `table.group_by@1` | rows、group keys → groups | 记录分组键和样本映射 |
| `math.unit_convert@1` | 数值与单位 → 转换后数值 | 记录单位分解与换算因子 |
| `stats.mean@1` | 数组 → 均值 | 保存 n、sum、mean |
| `stats.sd@1` | 数组 → SD | 保存公式与中间量 |
| `stats.linear_regression@1` | x/y 对 → 斜率、截距、R² | 保存 xbar、ybar、Sxx、Sxy、残差 |
| `bca.blank_adjust@1` | 吸光度与空白值 → 净吸光度 | 明确是否扣空白及顺序 |
| `math.linear_inverse@1` | slope/intercept/y → x | 记录反算公式、异常检查 |
| `math.multiply@1` | 数值 × 稀释系数 → 结果 | 记录代入值与精度 |
| `math.divide@1` | 质量÷浓度→体积 | 单位相容性检查、除零保护 |
| `data.qc_limits@1` | 值和配置的标准范围 → warnings | 不隐式删除异常值 |
| `data.export_table@1` | typed rows → 新 CSV/JSON Asset | 保存输出 SHA 与计算来源 |

**插拔要求**：算子的实现应该先有黄金测试、错误码、输入 Schema、结果类型、跨端可用性声明。对小数据量采用 Decimal 或受控浮点策略。模型自动创造 `bca.standard_curve` 如果该 op 不存在属于错误，必须先解释为已有 `stats.linear_regression` + `math.linear_inverse` 等组件。

## 3.4 动态表单生成与用户交互

由 `forms.json` 定义：字段名称、说明、类型（decimal、int、choice、file_ref、sample_ref）、单位、范围、是否必填、示例值、依赖字段显示条件、默认审核状态。Flutter FormRenderer 读取后显示，无需逐个硬编码 BCA 页面。对于板式实验，可有固定的通用 Plate Mapping Widget（96/384 孔布局）作为可复用原语，不应由 AI 每次重新写 UI。

**AI 产生的参数不是测量结果**。在生成阶段 `example_values` 仅用于演示；实际运行时默认空值，必须与 Sample ID、数据来源和时间关联。

## 3.5 Pack 发布、安装与版本

状态：`draft → validated → tested → user_approved → installed → disabled/archived`。安装时检查：文件清单哈希、schema 版本、运行时兼容、缺失原语、声明权限、测试通过、人工批准。更新必须安装为新版本，不就地修改旧包；历史 CalculationRun 与 ExperimentRun 引用旧版本及文件 SHA。

安装“声明式 Pack”不执行任意 shell、Python 源代码、网络请求或文件删除。计算 Pipeline 引用允许列表中的原语和明确参数；Tool Registry 在运行时拒绝未授权 op。

可添加本地 Pack 导入/导出（zip），未来社区包需要来源签名、可信级别、恶意包扫描及权限摘要；不能仅凭 ZIP 有 SKILL.md 就赋予系统权限。

## 3.6 Skill 目录与职责

```text
skills/
  lab-workspace-protocol-author/
    SKILL.md
    agents/openai.yaml
    references/protocol-v2.schema.json
    references/protocol-example.json
    scripts/validate_protocol.py
  lab-workspace-workflow-author/
    SKILL.md
    agents/openai.yaml
    references/calculation-pack-v2.schema.json
    references/bca-pipeline-example.json
    scripts/validate_workflow.py
  lab-workspace-image-orchestrator/
    SKILL.md
    agents/openai.yaml
    references/image-tool-catalog.json
    references/image-review-example.json
    scripts/validate_image_job.py
```

- **Protocol Author**：生成任何类型 SOP 及其定时、样本参数、步骤 DAG、溯源，审查时长缺失。
- **Workflow Author**：在不修改核心源码的前提下，用已有 PrimitiveRegistry 原语生成新的 CalculationPack / 测试样例，报告缺少算子。
- **Image Orchestrator**：多模态视觉理解、ROI 建议、图片编辑工具调用及科学数据原件保护，输出受审核的图像操作计划。

**重要**：这些 Skill 可以作为 AI 操作规范安装到 APP SkillRegistry；在 ChatGPT 中加载 Skill 并不会自动拥有 Lab Workspace 的本地文件访问和计算工具。实际执行只能经 APP 提供的受控工具接口。技能 ZIP 按 Skill Creator 格式分别打包，不能把三个 SKILL.md 当成单个 Skill 上传。

## 3.7 Skill 自定义导入与更新

APP 用户可导入新的 SKILL.md 包来扩展 AI 生成/审核行为，但应采取四层权限：

1. Skill 文本/提示词：仅作为模型指令，绝不自动获得本地文件系统权限；
2. 声明式 Protocol/Calculation Pack：经过 Schema + 测试 + 用户批准后运行；
3. Tool Registry 受控工具：由 APP 固定实现，调用前验证参数与权限；
4. Windows 用户提供的 Python 扩展：明确危险授权、可取消、限制输出目录、记录环境和 hash。移动端不允许任意下载和执行新原生 Python 模块。

Skill 生成器必须能处理无法解析的未知步骤/试剂条件，输出 `requires_user_input`，不能为了让 JSON 通过校验就捏造设备参数和实验温度。
