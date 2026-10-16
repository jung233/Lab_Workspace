# 09｜官方技术参考与需要真机验证的部分

本章记录于 2026-10-15 查阅的官方文档和工程使用理由；功能清单和具体 SDK 版本必须在发布前再次核查。

1. **Flutter 原生 Windows / Android / iOS**：<https://docs.flutter.dev/reference/supported-platforms>。本项目选用共享 Dart UI + Platform Channel/FFI，但并未自动得到成熟跨端文件和后台能力，需实际开发适配层。
2. **Android CPython 嵌入**：<https://docs.python.org/3.15/using/android.html>。解释器随 App 分发，不能假设手机自动继承桌面 pip 生态。
3. **iOS CPython 嵌入**：<https://docs.python.org/3.14/using/ios.html>。依赖 App 打包、原生 Framework 和代码签名，动态原生扩展存在分发限制。
4. **Apple App Review 2.5.2**：<https://developer.apple.com/app-store/review/guidelines/>。可下载/执行改变 App 功能的代码受限制，因此手机端以声明式 Packs（现有原语）为主，不直接执行新下载的任意 Python 原生代码。
5. **OpenAI 官方 Python SDK**：<https://github.com/openai/openai-python>。支持 Responses、Chat Completions；第三方兼容服务必须对多模态/函数工具/Schema 能力独立测试。
6. **SQLite Online Backup API**：<https://www.sqlite.org/backup.html>。在线生成一致性数据库快照，不直接同步正在运行的 SQLite + WAL 文件。
7. **Microsoft Graph OneDrive uploadSession**：<https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0>。支持分块大文件上传与断点续传；实施要遵守官方分片规则。
8. **S3 Conditional Writes**：<https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html>。AWS S3 可借助条件写避免覆盖，S3 兼容实现差异要能力探测；不能把 ETag 当成通用 SHA-256。
9. **Microsoft Graph To Do task delta**：<https://learn.microsoft.com/en-us/graph/api/todotask-delta?view=graph-rest-1.0> 与 <https://learn.microsoft.com/graph/delta-query-overview>。每页必须原样保存并复用完整 `@odata.nextLink` / `@odata.deltaLink`；todoTask delta 支持 `$select`、`$top`、`$expand`。通用 delta 文档要求不依赖响应顺序、允许同一实体重复出现，并要求在 410 / `syncStateNotFound` 后进行全量同步。
10. **Microsoft Graph open extensions**：<https://learn.microsoft.com/en-us/graph/api/opentypeextension-get?view=graph-rest-1.0> 与 <https://learn.microsoft.com/en-us/graph/api/opentypeextension-post-opentypeextension?view=graph-rest-1.0>。To Do task 支持扩展，用于将本地 Task ID 作为远端相关性标记；扩展仅用于重试关联，不携带凭据。

**审查与上线前未验证内容**：iOS 真机 Python 第三方包兼容性、不同 S3 供应商加密/分块与条件写能力、OneDrive 账户及文件夹限制、Windows 关闭 APP 后原生通知的精确性、移动端跨多设备事件合并的复杂性、远端加密/恢复的实际实现及安全审计。这些不是通过文档或单元测试就能宣称“已支持”的能力。
