# Android 设备 MCP 12306 预约次票 — 实现方案

> 日期：2026-07-30
> 分类：plan
> 状态：待实施

## 1. 目标

让 xiaozhi 语音链路能调用 12306「预约次票」：用户说"帮我预约下周二次票"→ LLM `tools/call phone.reserve_ticket` → 自动完成预约 → 结果回 TTS 播报。

**关键前提（已与用户确认）**：

- 预约次票的**提交步骤不要验证码**，全程可全自动。
- **只有登录**要人机验证（验证码），且登录态可持久化，几天才重登一次。
- 因此**日常预约无需人介入**，只有 cookie 过期时需要人去远程浏览器登一次。

此特性使方案比"提交时卡验证码"的场景（device-mcp-photo-vision 方案）轻得多：远程浏览器只是偶尔的"登录维护站"，不是每次预约都要用。

## 2. 核心结论

采用**方式1（单一浏览器 + CDP）**：

- 一个 Chromium 实例（linuxserver/chromium 容器）常驻腾讯云，登录态存持久卷。
- noVNC（端口 3000）只在登录维护时用，几天一次。
- Playwright 通过 **CDP（`--remote-debugging-port=9222`）连接同一个 Chromium** 做自动化，复用同一份 cookie，无双开冲突。
- 预约流程 headless 自动跑（`connectOverCDP` 后驱动已登录的浏览器），无人机交互。

```text
日常预约（全自动）：
  语音 → LLM tools/call phone.reserve_ticket
  → Android HTTP 转发服务端 /reserve
  → Playwright connectOverCDP 驱动已登录 chromium
  → 打开预约次票页 → 填表 → 提交（无验证码）→ 结果
  → MCP tool result → LLM → TTS

登录维护（偶尔，要人）：
  cookie 过期 / 被踢回登录页
  → 服务回 isError="登录过期，请重登"
  → 用户开 noVNC 登一次 → cookie 写回卷 → 恢复全自动
```

## 3. 现状

### 3.1 已就绪（验证通过）

- 腾讯云 `119.91.206.195`（Ubuntu 24.04 + Docker）。
- `chromium-12306` 容器已部署：`linuxserver/chromium`，端口 3000，持久卷 `chromium-12306-config`。
- `--ignore-certificate-errors` 已加入 `/usr/bin/wrapped-chromium`，绕过 12306 CFCA 证书的 CT 校验问题（否则 Chromium 报"不是私密连接"且登录 XHR 被拦）。
- 腾讯云安全组已放行 3000。
- **用户已通过 noVNC 成功登录 12306**，登录态已写入持久卷；机房 IP 未被拒登录（风控初步通过）。
- 外网访问 3000 通过 SSH 隧道（`ssh -L 3000:localhost:3000 ubuntu@119.91.206.195` → `http://localhost:3000`）满足 Selkies 的安全上下文要求；公网直连 HTTP 会被 Selkies 拒。

### 3.2 待补

- Chromium 未开 `--remote-debugging-port=9222`，Playwright 无法连。
- 无 Playwright 自动化服务。
- Android 侧无 `phone.reserve_ticket` 工具。
- 12306「预约次票」页面的精确选择器（URL/按钮/字段）未录制，需先抓流程。

## 4. 架构

```text
腾讯云 119.91.206.195
├─ chromium-12306 容器（已在跑，需加 CDP 端口）
│   ├─ Chromium (--ignore-certificate-errors + --remote-debugging-port=9222)
│   ├─ Selkies noVNC :3000          ← 登录维护站（几天一次）
│   ├─ CDP :9222（仅内部网络，不公开）
│   └─ 持久卷 chromium-12306-config（登录态/cookie）
│
└─ playwright-booking 服务（新加，Node 小容器，同 docker 网络）
    ├─ connectOverCDP('http://chromium-12306:9222')
    ├─ POST /reserve   → 驱动 chromium 跑预约流程
    ├─ GET  /login-status → 探测是否已登录
    └─ 鉴权：X-Booking-Token 头

Android app
└─ phone.reserve_ticket（MCP 工具，新加）
    └─ HTTP 调 playwright-booking 服务（带 token）

xiaozhi 链路（无改动）
└─ 上游 LLM tools/call 经 Worker/WS 下发到 Android（现有 MCP 路径）
```

## 5. 腾讯云侧要做什么

### 5.1 改 chromium-12306 容器：加 CDP 端口

1. 编辑容器内 `/usr/bin/wrapped-chromium`，在 `${BIN} \` 调用块加两行：
   ```bash
   --remote-debugging-port=9222 \
   --remote-debugging-address=0.0.0.0 \
   ```
   - `--remote-debugging-address=0.0.0.0` **必加**：Chromium 默认 CDP 只监听 127.0.0.1，同一 docker 网络里的 playwright 容器连不上（不同容器 ≠ 同一 localhost）。绑 0.0.0.0 后，只要 9222 **不映射到宿主公网**（见下），就只在 docker 内网可达，安全。
2. **重建容器**绑定 9222 到内部网络而非公网：
   ```bash
   docker rm -f chromium-12306
   docker network create booking-net 2>/dev/null
   docker run -d --name chromium-12306 --network booking-net \
     --shm-size 1g --memory=2g \
     -e CUSTOM_USER=xz -e PASSWORD=xz-booking-7290 \
     -p 3000:3000 \
     -v chromium-12306-config:/config \
     --restart unless-stopped \
     lscr.io/linuxserver/chromium:latest
   ```
   - 9222 不映射到宿主公网，只在 `booking-net` 内部可达（`http://chromium-12306:9222`）。
   - 卷 `chromium-12306-config` 复用，登录态不丢。
   - `--restart unless-stopped`：验证期后转为常驻（日常预约要 chromium 在线供 CDP 连）。
3. 重新写入带 `--ignore-certificate-errors` 和 `--remote-debugging-port=9222` 的 `/usr/bin/wrapped-chromium`（容器重建会丢之前的 in-place 修改，要么重建后重写，要么用自定义镜像/entrypoint 固化）。
   - **建议**：把修改后的 `wrapped-chromium` 用 `docker cp` 或挂载方式固化，避免每次重建丢失。后续可做自定义镜像。

### 5.2 新建 playwright-booking 服务

- **镜像**：`node:20-alpine` + `npm i playwright-core`（只用 `connectOverCDP`，不下载浏览器二进制，体积小）。
- **部署**：docker，加入 `booking-net`，连 `http://chromium-12306:9222`。
- **对外端口**：映射一个宿主端口（如 `8800`）到公网，供 Android 调用；腾讯云安全组放行 `8800`。
- **鉴权**：请求头 `X-Booking-Token: <token>`，token 写死常量（同 Android 侧）。

#### 接口

```http
POST /reserve
X-Booking-Token: <token>
Content-Type: application/json

{
  "from": "深圳",
  "to": "北京",
  "date": "2026-08-05",
  "train_no": "G80",          // 可选，不传则取余票最多的车次
  "passenger": "詹韦",        // 可选，默认用账号默认乘客
  "seat_type": "二等座"       // 可选
}
```

响应：

```json
{ "ok": true, "text": "已为你预约 8月5日 G80 深圳→北京二等座，待出票。" }
```

或失败：

```json
{ "ok": false, "error": "not_logged_in", "message": "登录已过期，请到远程浏览器重新登录 12306" }
```

```http
GET /login-status
→ { "logged_in": true }
```

#### 预约流程（Playwright，待录制选择器后填实）

伪流程：

```text
connectOverCDP('http://chromium-12306:9222')
拿到已登录的 page（或新开 tab）
goto 预约次票入口
探测是否被踢回登录页 → 是则返回 not_logged_in
填 起站/到站/日期/车次/乘客/席别
点 提交预约
等待结果提示
抓结果文本 → 返回
```

具体选择器与 URL 在「实施步骤 2」录制。

### 5.3 资源评估

- chromium-12306 常驻 ~600M 内存 / 24% CPU（实测）。
- playwright-booking 服务 ~100M。
- 服务器可用 2.3G + swap 1.2G，**够常驻**。

## 6. Android 侧要改什么

### 6.1 配置常量

`lib/providers/config_provider.dart`，仿 `VISION_*` 加：

```dart
// 12306 预约服务（腾讯云 playwright-booking）
static const String BOOKING_API_BASE = 'http://119.91.206.195:8800';
static const String BOOKING_API_TOKEN = '<token>';  // 与服务端一致
```

### 6.2 新增 MCP 工具 `phone.reserve_ticket`

`lib/services/device_mcp_tools.dart`，新增 `ReserveTicketTool`（仿 `TakePhotoTool`，但不需 `MethodChannel`，纯 HTTP）：

```dart
class ReserveTicketTool extends McpTool {
  ReserveTicketTool();  // 无原生调用，不依赖 channel

  @override
  String get name => 'phone.reserve_ticket';

  @override
  String get description =>
      '预约 12306 高铁次票（定期票/计次票预约）。'
      '参数 from=出发站、to=到达站、date=日期(YYYY-MM-DD)、'
      '可选 train_no=车次(如G80)、passenger=乘客名、seat_type=席别。'
      '用于"帮我预约下周二次票 / 预约周五G80"等场景。'
      '预约提交无验证码；若登录过期会返回需重登提示。';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'from': {'type': 'string', 'description': '出发站，如 深圳'},
      'to': {'type': 'string', 'description': '到达站，如 北京'},
      'date': {'type': 'string', 'description': '日期 YYYY-MM-DD'},
      'train_no': {'type': 'string', 'description': '车次，可选，如 G80'},
      'passenger': {'type': 'string', 'description': '乘客名，可选'},
      'seat_type': {'type': 'string', 'description': '席别，可选，如 二等座'},
    },
    'required': ['from', 'to', 'date'],
  };

  @override
  Future<McpToolResult> call(Map<String, dynamic> arguments) async {
    try {
      final response = await http.post(
        Uri.parse('${ConfigProvider.BOOKING_API_BASE}/reserve'),
        headers: {
          'Content-Type': 'application/json',
          'X-Booking-Token': ConfigProvider.BOOKING_API_TOKEN,
        },
        body: jsonEncode({
          'from': arguments['from'],
          'to': arguments['to'],
          'date': arguments['date'],
          if (arguments['train_no'] != null) 'train_no': arguments['train_no'],
          if (arguments['passenger'] != null) 'passenger': arguments['passenger'],
          if (arguments['seat_type'] != null) 'seat_type': arguments['seat_type'],
        }),
      ).timeout(const Duration(seconds: 60));
      // 解析 {ok, text/message/error}
      ...
      return McpToolResult(ok, text);
    } on TimeoutException {
      return McpToolResult(false, '预约服务超时，请稍后再试');
    } catch (e) {
      return McpToolResult(false, '预约失败：$e');
    }
  }
}
```

### 6.3 注册工具

`DeviceMcpTools` 构造里注册：

```dart
DeviceMcpTools() {
  _register(TakePhotoTool(channel));
  _register(SetAlarmTool(channel));
  _register(ReserveTicketTool());   // 新增
}
```

`xiaozhi_service.dart` 的 `tools/call` 派发与 `tools/list` **零改动**（现有注册表自动带上新工具，`self.*` 别名逻辑不变）。

### 6.4 说明

- MCP `tools/call` 由上游 LLM 经 Worker/WS 下发到 Android，这条路径**不变**。
- 工具执行时 Android 直接 HTTP 调腾讯云 `playwright-booking` 服务（带 token）。
- 预约服务返回的文本直接作为 MCP tool result，上游 LLM 续写后 TTS 播报。

## 7. Cloudflare Workers 侧要做什么

**不需要做任何改动。**

理由：

- MCP `tools/call` 的下发仍走现有 xiaozhi WebSocket（Worker/WS 中继），这条链路不变。
- 工具**执行**时 Android 直接 HTTP 调腾讯云 `playwright-booking`，不经过 Worker。
- Worker 仍是 OTA + WS 中继角色，预约功能不新增 Worker 路由。

**可选替代方案（若日后想统一鉴权/入口）**：在 Worker 加 `/booking/reserve` 代理 → 转发到腾讯云 `playwright-booking`。好处：Android 只认 Worker 一个域名，token 集中在 Worker。代价：Worker 多一个路由 + Cloudflare→腾讯云网络一跳。当前阶段**不采用**，直接 Android→腾讯云更简单。

## 8. 数据流

```text
用户语音"帮我预约下周二次票"
  ↓
xiaozhi 上游 LLM
  ↓ tools/call: phone.reserve_ticket {from,to,date,train_no?...}
Android ReserveTicketTool.call()
  ↓ HTTP POST http://119.91.206.195:8800/reserve  (X-Booking-Token)
playwright-booking 服务
  ↓ connectOverCDP('http://chromium-12306:9222')
  ↓ 驱动已登录 chromium
  ↓ 打开预约次票页 → 填表 → 提交（无验证码）
  ↓ 抓结果文本
  ↑ {ok:true, text:"已预约..."}
Android McpToolResult(true, text)
  ↓ MCP tools/call response → 上游
上游 LLM 续写回复 → TTS 播报
```

## 9. 登录维护

```text
预约时 Playwright 探测到被跳转回 12306 登录页
  → 返回 {ok:false, error:"not_logged_in"}
  → Android 回 McpToolResult(false, "登录已过期，请到远程浏览器重新登录 12306 后再说一次")
  → TTS 提示用户
用户：
  ssh -L 3000:localhost:3000 ubuntu@119.91.206.195
  浏览器开 http://localhost:3000  → 输 xz / <密码> → 进远程 chromium
  → 12306 登录（过验证码）→ cookie 写回 chromium-12306-config 卷
  → 再说一次"帮我预约..." → 恢复全自动
```

后续可优化：服务端定时探测登录态，过期主动推送（当前先被动触发）。

## 10. 错误处理

| 场景 | 服务端行为 | Android 回 TTS |
|---|---|---|
| 登录过期 | 探测跳登录页 → `not_logged_in` | "登录已过期，请到远程浏览器重新登录" |
| 余票不足/无票 | 抓 12306 提示文本 | 原样回 |
| 已有重复预约 | 抓 12306 提示 | 原样回 |
| 参数错（站点/日期非法） | 提交前校验或抓 12306 报错 | 原样回 |
| CDP 连不上（chromium 挂/未起） | 服务回 `service_unavailable` | "预约服务暂不可用，稍后再试" |
| 超时 60s | 服务回 `timeout` | "预约超时，请稍后再试" |

## 11. 实施步骤

1. **chromium 加 CDP 端口**
   - 改 `/usr/bin/wrapped-chromium` 加 `--remote-debugging-port=9222`（固化，避免重建丢失）。
   - 重建容器入 `booking-net`，9222 仅内部可达。
   - 重写 ignore-cert + cdp 两项到 wrapper，重启。
2. **录制预约次票流程**
   - 用户在 noVNC 里手动走一遍预约次票（进页面→填→提交），用 CDP 录 URL/选择器。
   - 或服务端用 Playwright `codegen` 连 CDP 会话录制，产出脚本骨架。
3. **写 playwright-booking 服务**
   - `node:20-alpine` + `playwright-core`，`/reserve` + `/login-status`。
   - 入 `booking-net`，映射 8800 到公网，安全组放行 8800。
4. **Android 加 `phone.reserve_ticket`**
   - config 常量 + `ReserveTicketTool` + 注册。
   - `flutter analyze` + build apk + 装机。
5. **端到端实测**
   - 语音触发"帮我预约..."，验证 LLM→tools/call→服务→预约→TTS 全链路。

## 12. 待确认

1. 12306「预约次票」具体是哪个产品入口（计次票/定期票/候补？）及其页面 URL、字段、提交按钮选择器——实施步骤 2 录制后确定。
2. 登录验证码类型（滑动拼图 / 文字点选 / 图形选物）——影响"登录维护站"UX，点选类在远程桌面不好操作。
3. 预约参数默认值：不传 `train_no` 时取什么策略（余票最多？最早？）；不传 `passenger` 时用账号默认乘客还是报错。
4. `playwright-booking` 的 token 值（生成一个常量写死两端）。
5. chromium wrapper 的修改是否要固化为自定义镜像（重建不丢）——当前先 `docker cp` 临时固化，稳定后再做镜像。

## 13. 安全提醒

- `BOOKING_API_TOKEN` 与 noVNC 口令写死源码/常量，仅自用；分发需改回服务端代理 + 鉴权。
- CDP 9222 **绝不**对公网开放，只在 docker 内网或绑 127.0.0.1。
- 12306 账号 cookie 存服务器持久卷，属敏感凭据；服务器注意访问控制。
