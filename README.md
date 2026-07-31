# ip_ntfy_agent

常驻 Dart 后端：同步本机 IP / Jenkins 在线状态到 Appwrite，并通过 ntfy 代理 HTTP 请求。

## 功能

1. 启动时按 `tag=test`（可配置）查询 Appwrite 文档一次（字段：`url` / `userName` / `password` / `active` / `tag` / `online`）
2. 启动及每隔 5 秒获取本机 IP；只替换文档 `url` 的 host，保留端口与路径
3. 每隔 1 分钟用文档里的 `url` + `userName` + `password` 检测 Jenkins；与 `online` 不一致则更新（`active=false` 时置为离线）
4. 订阅 ntfy topic（例如 IP `10.10.48.63` → `topic_10_10_48_63`）
5. 收到请求消息后在本机发起 HTTP，再把响应推回同一 topic
6. 收到 `action=uploadZip` 时：从 Jenkins workspace 下载热更 zip → 上传到 Appwrite Storage（上传中约每 5 秒推送 `type=progress`）→ 写入资源表（`tag` / `fileId` / `buildId`）→ 回传下载 URL
7. 收到 `action=deleteZip` 时：按 `tag` + `buildId` 删除资源表记录及对应 Storage 文件
8. 收到 `action=uploadApk` 时：按调用方提供的本地路径或 HTTP(S) URL 取 apk → 上传到 Appwrite Storage → 回传下载 URL
9. 收到 `action=deleteApk` 时：按 `tag` + `apk:{buildId}` 删除资源表记录及对应 Storage 文件
10. 配置 `FEISHU_WEBHOOK_URL` 后：仅在 Jenkins 在线状态变化时推送；IP 变化且 Jenkins 离线时推送最新 `http://IP:8080`

## 配置

复制 `.env.example` 为 `.env`，填入 `APPWRITE_API_KEY` 等参数：

```bash
cp .env.example .env
```

全局安装后，默认从**当前工作目录**的 `.env` 读取配置；也可把路径作为第一个参数传入。
启动时会校验 `.env` 是否存在，并一次性检查所有必填项是否已填写（占位符如 `your_api_key_here` 视为未配置）。

必填变量：

| Key | 说明 |
| --- | --- |
| `APPWRITE_ENDPOINT` | Appwrite API 地址 |
| `APPWRITE_PROJECT_ID` | Project ID |
| `APPWRITE_API_KEY` | Server API Key |
| `APPWRITE_DATABASE_ID` | Database ID |
| `APPWRITE_COLLECTION_ID` | 打包机 host 文档 collection |
| `APPWRITE_BUCKET_ID` | 热更 zip 存储桶 ID |
| `APPWRITE_RESOURCE_COLLECTION_ID` | 资源元数据表 ID（字段 `tag` / `fileId` / `buildId`） |
| `APPWRITE_TAG_VALUE` | 打包机 tag（如 `test` / `release`） |
| `NTFY_BASE_URL` | ntfy 服务地址 |

可选变量：

| Key | 说明 |
| --- | --- |
| `NTFY_AUTH` | ntfy 鉴权头（如 `Bearer <token>`） |
| `FEISHU_WEBHOOK_URL` | 飞书自定义机器人 Webhook |
| `JENKINS_CHECK_INTERVAL_SECONDS` | Jenkins 在线检测间隔（默认 60） |
| `IP_CHECK_INTERVAL_SECONDS` | IP 检测间隔（默认 5） |

Jenkins 的 `url` / `userName` / `password` / `active` 从 Appwrite 文档读取，不在 `.env` 配置。

## 安装（dart pub）

在本机用全局激活安装命令行工具：

```bash
# 从本地路径安装
dart pub global activate --source path /path/to/ip_ntfy_agent

# 或从 Git 仓库安装（有远程仓库时）
# dart pub global activate --source git <repo-url>
```

确保 `~/.pub-cache/bin`（或 `$HOME/.pub-cache/bin`）已加入 `PATH`，然后可直接运行：

```bash
ip_ntfy_agent
# 或指定 env 路径
ip_ntfy_agent /path/to/.env
```

更新本地安装：

```bash
dart pub global activate --source path /path/to/ip_ntfy_agent
```

卸载：

```bash
dart pub global deactivate ip_ntfy_agent
```

## 运行（开发模式）

未全局安装时，可在仓库内直接跑：

```bash
cd ip_ntfy_agent
dart pub get
dart run
# 或指定 env 路径
dart run bin/ip_ntfy_agent.dart /path/to/.env
```

后台常驻（推荐，SSH 断开也不停）：

```bash
./scripts/agent.sh start          # 后台启动（默认读仓库根目录 .env）
./scripts/agent.sh status         # 查看是否在跑
./scripts/agent.sh logs -f        # 跟踪日志
./scripts/agent.sh stop           # 停止
./scripts/agent.sh restart        # 重启
```

也可用手工 `nohup`：

```bash
# 全局安装后
nohup ip_ntfy_agent >> agent.log 2>&1 &

# 或开发模式
nohup dart run >> agent.log 2>&1 &
```

## ntfy 请求消息格式

向当前 IP 对应 topic 发送 JSON（message body）：

```json
{
  "requestId": "optional-id",
  "method": "GET",
  "url": "http://127.0.0.1:8080/api/json",
  "headers": {
    "Authorization": "Basic xxx"
  },
  "params": {
    "tree": "jobs[name]"
  },
  "body": null
}
```

Agent 会忽略带 `response` / `agent-response` tag 或 `"type":"response"` / `"type":"progress"` 的消息，避免回环。

响应示例：

```json
{
  "type": "response",
  "requestId": "optional-id",
  "ok": true,
  "statusCode": 200,
  "body": {},
  "request": {
    "method": "GET",
    "url": "http://127.0.0.1:8080/api/json?tree=jobs%5Bname%5D"
  }
}
```

代理到**文件**（二进制/`Content-Disposition: attachment` 等）或响应过大（超过 ntfy 文本消息上限）时，**不回传 body**，只返回文件名 / 文件夹名等元数据，避免触发 ntfy `attachments not allowed`。实际下载请走 `uploadApk` / `uploadZip` 等其它通道：

```json
{
  "type": "response",
  "requestId": "optional-id",
  "ok": true,
  "statusCode": 200,
  "body": null,
  "bodyOmitted": true,
  "omitReason": "file",
  "fileName": "app.apk",
  "folderName": "Builds",
  "contentType": "application/vnd.android.package-archive",
  "contentLength": 12345678,
  "request": {
    "method": "GET",
    "url": "http://127.0.0.1:8080/job/.../ws/Builds/app.apk"
  }
}
```

代理 Jenkins workspace **目录**（如 `/job/.../ws/`）时，自动改走 `*plain*` 文本列表，只返回文件名 / 文件夹名：

```json
{
  "type": "response",
  "requestId": "optional-id",
  "ok": true,
  "statusCode": 200,
  "body": {
    "files": ["app.apk", "notes.txt"],
    "folders": ["Builds", "HotUpdate"],
    "folderName": "ws"
  },
  "request": {
    "method": "GET",
    "url": "http://127.0.0.1:8080/job/build_unity_cache/ws/"
  }
}
```

## 上传热更 zip（Appwrite Storage）

Agent 按与旧发布工具相同的路径，从本机 Jenkins workspace 拉取 zip，再上传到 Appwrite：

```
{jenkinsUrl}/job/build_unity_hot_asset/ws/HotUpdate/{buildId}/{PLATFORM}/UploadAssets/*zip*/UploadAssets.zip
```

`PLATFORM`：`iOS`/`Android` → `IOS`/`ANDROID`；`HarmonyOS`/`ohos` → `Harmony`。Jenkins 地址与账号取自 Appwrite 打包机文档。

向当前 IP 对应 topic 发送：

```json
{
  "action": "uploadZip",
  "requestId": "build-123",
  "buildId": "123",
  "platform": "iOS",
  "tag": "test"
}
```

- `buildId` / `buildNumber`：Jenkins 构建号
- `platform`：`iOS` / `Android` / `HarmonyOS`（必填）
- `tag`：可选，默认用 `.env` 的 `APPWRITE_TAG_VALUE`（`test` / `release`）
- 同一 `tag` + `buildId` 会覆盖旧记录，并删除旧 Storage 文件
- 上传到 Appwrite Storage 期间，约每 5 秒（及开始/完成时）推送进度消息

进度消息示例：

```json
{
  "type": "progress",
  "action": "uploadZip",
  "requestId": "build-123",
  "phase": "uploading",
  "percent": 42.5,
  "sizeUploaded": 1234567,
  "chunksUploaded": 3,
  "chunksTotal": 7
}
```

成功响应示例：

```json
{
  "type": "response",
  "action": "uploadZip",
  "requestId": "build-123",
  "ok": true,
  "body": {
    "fileId": "...",
    "buildId": "123",
    "tag": "test",
    "documentId": "...",
    "downloadUrl": "https://<APPWRITE_HOST>/v1/storage/buckets/<BUCKET_ID>/files/<FILE_ID>/download?project=<PROJECT_ID>",
    "replaced": false,
    "platform": "iOS"
  }
}
```

本机用 `downloadUrl` 下载即可（若桶非公开读，需带 Appwrite 鉴权头）。

## 删除热更 zip

按 `tag` + `buildId` 删除资源元数据文档，并尽量删除对应 Storage 文件：

```json
{
  "action": "deleteZip",
  "requestId": "del-123",
  "buildId": "123",
  "tag": "test"
}
```

- `buildId` / `buildNumber`：必填
- `tag`：可选，默认用 `.env` 的 `APPWRITE_TAG_VALUE`

成功响应示例：

```json
{
  "type": "response",
  "action": "deleteZip",
  "requestId": "del-123",
  "ok": true,
  "body": {
    "buildId": "123",
    "tag": "test",
    "deleted": true,
    "documentId": "...",
    "fileId": "...",
    "fileDeleted": true
  }
}
```

记录不存在时仍返回 `ok: true`，`body.deleted` 为 `false`。

## 上传 APK（Appwrite Storage）

调用方提供打包机本地绝对路径，或可访问的 HTTP(S) 下载地址（如 Jenkins workspace URL）。Agent 取到本地 `.apk` 后上传 Appwrite，并回传远程 `downloadUrl`。

向当前 IP 对应 topic 发送：

```json
{
  "action": "uploadApk",
  "requestId": "apk-123",
  "path": "http://127.0.0.1:8080/job/build_unity_first_package/ws/Builds/app.apk",
  "buildId": "123",
  "tag": "test"
}
```

本地路径示例：

```json
{
  "action": "uploadApk",
  "requestId": "apk-123",
  "path": "/path/on/packaging/machine/app.apk",
  "buildId": "123"
}
```

- `path` / `file` / `filePath`：必填；本地绝对路径，或 `http`/`https` URL
- `buildId` / `buildNumber`：必填
- `tag`：可选，默认用 `.env` 的 `APPWRITE_TAG_VALUE`
- `fileName` / `filename`：可选；URL 下载时指定本地保存名（默认从 URL 推断，否则 `app.apk`）
- 资源表中存储的 `buildId` 为 `apk:{buildId}`，与热更 zip 互不覆盖
- 上传期间约每 5 秒推送 `type=progress`

成功响应示例：

```json
{
  "type": "response",
  "action": "uploadApk",
  "requestId": "apk-123",
  "ok": true,
  "body": {
    "fileId": "...",
    "buildId": "123",
    "tag": "test",
    "documentId": "...",
    "downloadUrl": "https://<APPWRITE_HOST>/v1/storage/buckets/<BUCKET_ID>/files/<FILE_ID>/download?project=<PROJECT_ID>",
    "replaced": false,
    "path": "...",
    "fileName": "app.apk"
  }
}
```

## 删除 APK

```json
{
  "action": "deleteApk",
  "requestId": "del-apk-123",
  "buildId": "123",
  "tag": "test"
}
```

- `buildId` / `buildNumber`：必填
- `tag`：可选，默认用 `.env` 的 `APPWRITE_TAG_VALUE`
- 记录不存在时仍返回 `ok: true`，`body.deleted` 为 `false`
