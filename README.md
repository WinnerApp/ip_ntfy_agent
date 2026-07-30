# ip_ntfy_agent

常驻 Dart 后端：同步本机 IP / Jenkins 在线状态到 Appwrite，并通过 ntfy 代理 HTTP 请求。

## 功能

1. 启动时按 `tag=test`（可配置）查询 Appwrite 文档一次（字段：`url` / `userName` / `password` / `active` / `tag` / `online`）
2. 启动及每隔 5 秒获取本机 IP；只替换文档 `url` 的 host，保留端口与路径
3. 每隔 1 分钟用文档里的 `url` + `userName` + `password` 检测 Jenkins；与 `online` 不一致则更新（`active=false` 时置为离线）
4. 订阅 ntfy topic（例如 IP `10.10.48.63` → `topic_10_10_48_63`）
5. 收到请求消息后在本机发起 HTTP，再把响应推回同一 topic
6. 收到 `action=uploadZip` 时：从 Jenkins workspace 下载热更 zip → 上传到 Appwrite Storage → 写入资源表（`tag` / `fileId` / `buildId`）→ 回传下载 URL
7. 收到 `action=deleteZip` 时：按 `tag` + `buildId` 删除资源表记录及对应 Storage 文件
8. 配置 `FEISHU_WEBHOOK_URL` 后：启动时推送当前 Jenkins 在线/离线状态；IP 变化且 Jenkins 离线时推送最新 `http://IP:8080`；之后仅在 Jenkins 在线状态变化时再推送

## 配置

复制 `.env.example` 为 `.env`，填入 `APPWRITE_API_KEY` 等参数：

```bash
cp .env.example .env
```

全局安装后，默认从**当前工作目录**的 `.env` 读取配置；也可把路径作为第一个参数传入。
主要变量：

| Key | 说明 |
| --- | --- |
| `APPWRITE_ENDPOINT` | Appwrite API 地址 |
| `APPWRITE_PROJECT_ID` | Project ID |
| `APPWRITE_API_KEY` | Server API Key |
| `APPWRITE_DATABASE_ID` | Database ID |
| `APPWRITE_COLLECTION_ID` | 打包机 host 文档 collection |
| `APPWRITE_BUCKET_ID` | 热更 zip 存储桶 ID |
| `APPWRITE_RESOURCE_COLLECTION_ID` | 资源元数据表 ID（字段 `tag` / `fileId` / `buildId`） |
| `NTFY_BASE_URL` | ntfy 服务地址 |
| `FEISHU_WEBHOOK_URL` | 飞书自定义机器人 Webhook（可选） |
| `JENKINS_CHECK_INTERVAL_SECONDS` | Jenkins 在线检测间隔（默认 60） |

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

后台常驻示例：

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

Agent 会忽略带 `response` / `agent-response` tag 或 `"type":"response"` 的消息，避免回环。

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
