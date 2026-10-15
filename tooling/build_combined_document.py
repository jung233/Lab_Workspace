#!/usr/bin/env python3
"""Build the standalone complete Markdown engineering document from chapters."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
parts=[
 '00-scope-decisions.md','01-architecture-and-directory.md','02-domain-and-protocol.md',
 '03-workflow-packs-and-skills.md','04-asset-explorer-integrity.md',
 '05-sync-backup-optional-encryption.md','06-python-ai-image-trace.md',
 '07-security-release-tests.md','08-implementation-contracts.md',
 '09-verified-technology-references.md'
]
header='''# Lab Workspace — 完整系统架构与开发文档 V2.0

**冻结日期：2026-10-15｜交付类型：工程设计文档 + 可验证契约**  
**客户端：Windows、Android、iOS｜单用户｜离线优先｜无网页端与必选服务器**

> 本文覆盖需求背景、架构、程序与 Vault 目录、数据库、协议与计算包、AI/Skills、文件 Explorer、SHA、可选远端加密、OneDrive/S3、Python、OpenAI SDK、测试与迭代规划。文中示例实现并非完整可运行的 APP。

## 阅读目录

00. 产品定位、范围与冻结决策
01. 系统架构、模块边界与完整目录约定
02. 领域模型、Protocol、执行引擎和时间管理
03. AI 生成 Protocol / Calculation Pack 与 Skill 开发生态
04. 原始文件 Explorer、存储回收与分级 SHA-256
05. OneDrive/S3 按需同步、独立备份与可选远端加密
06. 跨端 Python、全计算透明性、OpenAI SDK、图片 AI 工具
07. 安全、实施计划、验收测试、发布与维护
08. 内部 API、用户界面交互与开发落地契约
09. 官方技术参考与需要真机验证的部分

---
'''
sections=[]
for name in parts:
    text=(ROOT/'docs'/name).read_text(encoding='utf8')
    sections.append(text.rstrip())
output=ROOT/'Lab_Workspace_V2.0_Complete_Development_Document.md'
output.write_text(header+'\n\n---\n\n'.join(sections)+'\n',encoding='utf8')
print(output,output.stat().st_size,'bytes',len(output.read_text().splitlines()),'lines')
