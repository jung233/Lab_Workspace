# 06｜跨端 Python、全计算透明性、OpenAI SDK、图片 AI 工具

## 6.1 CalculationEngine：所有端使用相同任务协议

`CalculationExecutor` Interface：`probe()` 返回 Python 版本/包/支持算子；`execute(job)` 执行受批准的模块并生成 CalculationTrace；`requestCancel(job_id)`；`getLogs(job_id)`。业务 UI 不能直接导入 chaquopy、CPython 原生桥接、Conda 命令。

| 平台 | 默认执行器 | 外部执行器 | 可信范围 |
|---|---|---|---|
| Windows | 随 APP 分发的 CPython 子进程，stdio JSON-RPC | 用户指定 `python.exe`、venv、Conda 环境目录 | 可信内置 Pack；用户明确授权外部脚本 |
| Android | Kotlin 嵌入 CPython/Chaquopy 或等价桥接 | 不承诺任意 Python 安装 | 随 APP 签名交付的可信原语 + 动态声明式 Pack |
| iOS | Swift/CPython Embedded Framework | 不允许任意外部 Python 进程 | 打包可信原语 + 声明式 Pack；注意分发政策 |

**移动端 Python 可计算小数据，但“能在手机上执行 CPython”不等于自动支持所有 PyPI 二进制库**。初期将常用算子控制在标准库、Decimal 与经过真机测试的可选 NumPy/SciPy 依赖范围；手机不同运行时使用同样的 CalculationPack 输入输出 Schema 和 golden cases。

Windows 外部执行器在设置中选择环境目录或 python.exe、探测 `sys.version`, `sys.executable`, 包版本、工具能力、是否缺失依赖。不要自动 `conda install` 或修改用户环境；不可通过 shell 拼接执行路径。外部 Python 对当前 Windows 用户文件可能有访问权限，不能当作严格沙盒。APP 发给外部执行器的实验输入应是受限临时文件/JSON，不包含存储凭据。

## 6.2 计算任务生命周期

`queued → preparing → running → completed/failed/cancelled/interrupted`。输入快照、配置、Pack 版本先写入 SQLite，Python 工具仅将输出写向任务隔离目录并返回 JSON。由 App 验证 Schema、输出 SHA、单位及范围后提交 Measurement/CalculationTrace/Asset。APP 崩溃导致 interrupted 的任务不能自动标成 completed。所有新数值仅创建新结果版本，旧 Run 不被无痕更改。

## 6.3 “展示原始计算”是强制系统级约束

**每个可显示的衍生科研数值**旁必须存在按钮 `展示原始计算`，从 Measurement → CalculationRun → CalculationTrace → 直接上游 inputs/Assets 全链追溯。禁用/隐藏按钮为 QA blocker。没有 Trace 的“AI 建议值”只能以 `suggestion` 显示，不能被确认为有定量依据的科研结果。

计算追踪必须包含：

1. 业务对象：Sample/Group/Step、原始文件 Asset ID + SHA；
2. 原始输入：值、单位、采集方法、时间、使用的稀释倍数；
3. 计算定义：Pack ID+version、原语 ID+version、代码哈希或原语构建版本、参数快照；
4. 每步算术：原式、代入式、单位、完整中间值、精度/舍入规则；
5. 质控：标准曲线 R²、样本是否外推、复孔离散度、饱和/异常提示（适用时）；
6. 执行环境：设备平台、Python 版本、依赖版本、执行器、UTC 时间；
7. 输出：数值与文件、结果 JSON、SHA、是否审核；
8. 可复制/导出：JSON、CSV、Markdown 计算报告；可从快照**重新运行**并生成新结果版本；
9. AI 参与：模型提取的值、置信标签、用户核对动作、相关工具调用 ID；
10. 结果修订版本差异：谁（此产品单用户仅表示本机操作者）、什么时间、为什么修改。

> 透明性界限：显示**真正执行的源公式、程序/运算节点、变量、中间值与工具记录**；不是展示或伪造多模态模型的隐藏推理过程。不能把模型解释文本冒充实际执行 Trace。

示例：WB 目标 20 µg、样本蛋白浓度 2 µg/µL → 样本用量 10 µL，Trace 必须保存 `20 / 2 = 10`、单位推导、所引用 BCA 浓度版本与来源原件。

## 6.4 BCA 工作流的计算与审查

数据输入优先仪器导出 CSV/Excel，而不是培养板颜色照片。若仅有报告截图，由多模态模型提取标准孔/样本孔/吸光度文本，展示叠层位置和置信标签，人工逐项确认后才提交测量数据。

Pipeline 建议：CSV 表格与样本映射 → 空白校正（用户按 SOP 选择具体方式）→ 线性或经过支持/验证的拟合方法 → 样本浓度计算 → 稀释倍数换算 → 复孔统计/范围质控 → output.bind sample.protein_concentration → WB 上样工具自动引用。**输入截图不等于用颜色进行可靠绝对蛋白定量**。不同 BCA 试剂和仪器是否适合线性拟合由用户 SOP 决定。

## 6.5 多模态图片：模型负责理解与编排，工具负责精确变换/数值

**禁止**在 APP 本地打包自动目标检测、图像分割、荧光细胞识别模型。APP 可以解码/展示原图、读取元数据、按模型/用户显式给定的 ROI 裁剪、绘制标注、按确定性公式统计原始 ROI 内的像素。后者是被批准的“像素算术工具”，不是 CV 自动识别。

图像任务模式：

- `image_documentation`：模型理解/标注/整理说明；新派生文件，不影响原始。
- `report_extraction`：模型从 BCA 仪器报告图片提取文本/数字，用户核对后作为输入。
- `scientific_quantification`：模型建议 WB/IF ROI、泳道和背景区域，用户确认，工具在未修改的原始像素计算并生成 Trace；模型无法直接宣称定量值。
- `presentation_edit`：允许模型调用图片编辑/生成工具创建展示用图，但强制标注派生类型 `illustrative`，禁止后续作为可信定量原始图使用。

### 6.5.1 图片工具白名单

`inspect_metadata`, `create_model_preview`, `suggest_rois`, `render_overlay`, `crop_derived`, `compute_roi_pixels`, `save_derived_asset`, `export_image_report`。Skill 加载与工具授权分开；模型传入任意本地路径/远程 URL 必须拒绝，必须先通过 APP AssetId 受控句柄与明确授权。

示例图片流程：导入原始 TIFF/SHA → 创建缩放预览并保存变换矩阵 → 用户授权外发给 vision model → 模型返回原图坐标候选框、解释与警告 → APP 显示 ROI 叠层 → 用户调整确认 → 图像工具从原始 TIFF 像素进行积分与背景校正 → 逐步 CalculationTrace → 新派生标注图（有新 SHA）和分析结果关联样本与泳道。原件不覆盖、不美颜、不 AI 生成像素。

### 6.5.2 不能假装免费离线 AI

用户未配置可用视觉模型或当前离线时，可手动 ROI、保存原件并执行既有确定性数值原语；自动视觉解释任务保存 `waiting_for_model` 状态，不伪造模型输出。若用户自行连接一个支持视觉与函数工具调用的本地 OpenAI 兼容模型，也走 `AiProvider`；本产品不会附带“大型本地视觉分割模型”。

## 6.6 OpenAI 官方 SDK 和 API 兼容层

推荐 Python 侧 `OpenAI(api_key=..., base_url=...)` 配置适配 `client.responses.create` 和 `client.chat.completions.create` 两个 API。**供应商所谓“OpenAI compatible”通常不是所有多模态、工具调用与结构化 Schema 能力均等价**，ProviderProfile 必须保存并测试 `responses`, `chat_completions`, `vision`, `function_tools`, `json_schema`, `image_edit`, `streaming` 等能力。

`ProviderProfile = {name, base_url, api_mode, model_id, secret_ref, capabilities, budgets, timeout, data_policy}`。默认不上传真实科研文件做模型能力探测；使用合成最小样例单独测试 function call / image support。

### 6.6.1 两套 function calling 循环

**Responses**：查看 response.output 中 `function_call` → 验证 name/arguments/schema → PolicyEngine 审批 → ToolRegistry 执行 → 追加对应 `function_call_output`（匹配 call_id）→ 再发请求直到最终文本或回合数上限。

**Chat Completions**：查看 choices[0].message.tool_calls → 验证与执行 → 以 `role=tool` + `tool_call_id` 写工具结果 → 下一轮；不能将 Responses item 直接填入 Chat Completions history。

两个 adapter 共用内部事件 `{assistant_text, tool_request, tool_result, final, error, usage}`。不支持 tool calling 的兼容端只能用于普通文本建议，不允许工具执行与自动量化。图片编辑还须检查实际 image edit 能力，不能把普通文本模型包装成图像编辑 API。

### 6.6.2 安全与数据外发

- `api_key` 存 Windows DPAPI / Android Keystore / iOS Keychain；不要写 SQLite/Pack/日志/云备份。
- 上传前明确展示目标供应商、文件数、预计大小、是否原始敏感文件、费用提醒、同意范围。模型视图只发用户批准内容。
- HTTPS 强制为远端服务，loopback 可特殊配置；用户 SOP 文本是**不可信输入**，不能指挥 APP 暗中删除原件或读取密钥。
- 模型调用限时、限工具轮数/费用；工具先被本地 allowlist 校验并记录输入输出哈希、用户确认。
- `store=false` 等选项是否可用依赖供应商适配，不能因此断言所有第三方不存储用户数据。

## 6.7 OpenAI SDK 与移动端技术边界

Windows 默认可直接通过内置 Python 执行官方 SDK。Android/iOS 如果实际 Python 官方 SDK 及其依赖无法稳定打包，可在对应 Native Adapter 中使用等价 HTTPS 协议实现网络请求，业务层仍只接触统一 `AiProvider` 接口；不得为了形式上“所有端必须直接跑 SDK”而牺牲稳定性。移动端 Python 负责计算原语，云 AI 请求可以由 native 网络实现，但需与 Python SDK 的行为契约做集成测试。
