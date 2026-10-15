# Lab Workspace V2.0 — Engineering Specification Package

> **完整开发文档、数据契约、示例计算、参考 SQLite 模型、三份可单独安装的 AI Skills。不是已编译好的 Windows/Android/iOS 应用。**

**发布日期基线**：2026-10-15。目标：Windows Desktop + Android + iOS，单用户，本地优先，无 Web 前端/无必选后端。所有旧称 “BioLab Workspace” 在本版正式统一为 **Lab Workspace**。

## 首先阅读

- `Lab_Workspace_V2.0_Complete_Development_Document.md` — 所有章节合并成完整开发文档，可独立交给开发者/AI Coding Agent。
- `AGENTS.md` — 适用于 AI Coding Agent 的架构约束与研发规则。

## 分章节工程文档

| 路径 | 内容 |
|---|---|
| `docs/00-scope-decisions.md` | 产品范围、技术决策、非目标 |
| `docs/01-architecture-and-directory.md` | Native 架构、Monorepo 与本地 Vault 物理路径 |
| `docs/02-domain-and-protocol.md` | Domain、Protocol DSL、Run/Step 状态机、计时提醒 |
| `docs/03-workflow-packs-and-skills.md` | 自然语言生成 Protocol/Calculation Pack、PrimitiveRegistry、Skill 扩展 |
| `docs/04-asset-explorer-integrity.md` | 原始文件 Explorer、2GiB 阈值、SHA 分级、删除/GC |
| `docs/05-sync-backup-optional-encryption.md` | 选择性 OneDrive/S3 同步、独立备份、可选远端加密 |
| `docs/06-python-ai-image-trace.md` | 内置 Python、OpenAI SDK、模型图片工具、展示原始计算 |
| `docs/07-security-release-tests.md` | 安全、隐私、开发里程碑和验收测试 |
| `docs/08-implementation-contracts.md` | Dart 接口、错误码、设置、Explorer 交互、GC 伪代码 |
| `docs/09-verified-technology-references.md` | 官方技术参考及尚需真机验证的边界 |

## 数据结构与可执行验证

- `contracts/` — 9 个 JSON Schema，包括 Protocol、CalculationPack、Pack Manifest、CalculationTrace、Asset、SyncEvent、远端加密、图片工具计划与动态 Forms。
- `db/001_init.sql` — **37 张** SQLite 参考表（正式应用应接入 Drift 迁移流程）。
- `examples/bca/pipeline.json` — AI 组合现有数学原语即可得到的 BCA 声明式计算 Pack 示例。
- `examples/installed_packs/bca-standard-curve/1.0.0/` — 真实 manifest + SHA 文件清单 + UI 表单 + 合成 golden fixture。
- `python/pack_runtime_demo.py` — 使用标准库 Decimal 和白名单算子解释执行 JSON Pipeline；输出逐步 CalculationTrace。
- `python/integrity_policy_demo.py` — 小文件每次完整 SHA、大文件快速元数据检查的真实代码示例。**快检不能证明内容完整性**。
- `tests/test_reference_contracts.py` — 无联网测试（schema、Pack、原语运行、SHA 阈值、用户审核、SQLite）。

## 三个可独立安装的 Skills

- `skills/lab-workspace-protocol-author`：AI 从自然语言/SOP 生成 Protocol 草稿。
- `skills/lab-workspace-workflow-author`：自然语言生成新的声明式 Calculation Pack，例如 BCA 标准曲线计算（无需重编主程序）。
- `skills/lab-workspace-image-orchestrator`：多模态图片分析与工具调用规范，保护原件、保留人工 ROI 与计算透明度。

`dist/` 中包含每个 Skill 独立的 `skill.zip`，不可把包含三个不同 `SKILL.md` 的整个 DevKit ZIP 当成一个 Skill 导入。

## 无联网校验

```bash
python -m pip install jsonschema
python tooling/validate_contracts.py
python tooling/manifest_tool.py
python -m unittest discover -s tests -v
python skills/lab-workspace-protocol-author/scripts/validate_protocol.py examples/protocol/bca-to-wb.json
python skills/lab-workspace-workflow-author/scripts/validate_workflow.py examples/bca/pipeline.json
python skills/lab-workspace-image-orchestrator/scripts/validate_image_job.py examples/storage/image-review-plan.json
```

上述参考代码只说明契约可运行、示例能复算；**不声称**云同步、加密备份、平台通知或移动端 Native 应用已经实现。正式开发还需 UI、Flutter/Native 桥接、生产算法验证、同步/恢复实现、加密安全审计与真机测试。
