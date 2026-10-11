# OpenCode Desktop Pet

一只运行在 Windows 桌面上的 2D 桌宠。它通过 OpenCode 插件事件感知会话活动，能在思考、执行工具、完成和报错时切换动画，也支持桌宠库、聊天气泡、鼠标互动和自定义 spritesheet。

桌面窗口由 PowerShell 5.1 和 WPF 实现；插件及本机 HTTP 服务使用 Node.js。运行时不需要额外 Node.js 依赖。

## 功能

- OpenCode 会话联动：区分模型思考与工具执行，识别空闲和错误状态。
- 透明置顶桌面窗：自动走动、睡眠、拖动、点击反馈与可配置动画。
- 每个动画可设独立帧率，支持专用左向帧行 `leftRow`。
- 桌宠库：从设置页面导入、保存、切换和删除桌宠。
- 桌宠聊天：从桌宠右键菜单打开聊天窗口，消息发送到最近活跃的 OpenCode 会话。
- 注视鼠标或 OpenCode 桌面窗口的对话区域。
- 本机 HTTP API 与 SSE 状态流。

## 要求

- Windows 10/11
- OpenCode 桌面端或 CLI
- Node.js 18 或更高版本
- PowerShell 5.1（Windows 自带）

## 安装

1. 将仓库放到一个不会移动的目录，例如 `E:\\tools\\opencode-desktop-pet`。
2. 在 OpenCode 配置 `~/.config/opencode/opencode.json` 中添加插件路径：

   ```json
   {
     "plugin": [
       "E:/tools/opencode-desktop-pet/index.mjs"
     ]
   }
   ```

   若原配置已有 `plugin` 项，请把路径追加到数组中，不要覆盖其他插件。

3. 重启 OpenCode。插件默认依据用户配置中的 `autoStart: true` 自动启动桌宠。
4. 也可运行仓库中的 `start-pet.bat` 手动召唤。启动器只连接本项目固定端口，不会复用 Copilot 桌宠实例。

桌宠配置与资源位于 `%APPDATA%\\opencode-desktop-pet\\`。桌宠窗口和设置页面会读取此处的 `pet.json`。

## 配置

可从 `pet.example.json` 开始编辑。把配置保存为：

```text
%APPDATA%\opencode-desktop-pet\pet.json
```

贴图文件也放在该目录，或者放在插件目录。配置示例：

```json
{
  "name": "我的桌宠",
  "autoStart": true,
  "sprite": "spritesheet.png",
  "frameWidth": 32,
  "frameHeight": 32,
  "scale": 4,
  "fps": 8,
  "defaultAnimation": "idle",
  "animations": {
    "idle": { "row": 0, "frames": 4 },
    "walk": { "row": 1, "frames": 4, "leftRow": 2 },
    "thinking": { "row": 3, "frames": 4, "fps": 6 },
    "work": { "row": 4, "frames": 4 },
    "review": { "row": 9, "frames": 4 }
  },
  "behavior": {
    "autoWander": true,
    "walkSpeedPxPerSec": 40,
    "wanderIntervalSec": [3, 8],
    "sleepAfterIdleSec": 45,
    "lookAtMouse": false,
    "lookAtOpenCode": false
  },
  "speech": {
    "phrases": ["嗯，我在。", "戳我干嘛？"],
    "fontSize": 13
  }
}
```

### Spritesheet 和动画

- 图片按规则网格切分，每格大小为 `frameWidth × frameHeight`；每一行对应一个动画。
- `row` 是动画所在的从零开始的行号，`frames` 是该行的帧数。
- 顶层 `fps` 是默认帧率；动画中的 `fps` 可单独覆盖。
- `leftRow` 可指定专用左向帧行。未设置时，桌宠会水平镜像当前动画行。
- `scale` 支持小数，例如 `0.65` 表示以原始帧尺寸的 65% 显示。
- 单帧贴图没有逐帧动画；桌宠仍可走动，待机时使用轻微呼吸起伏。

可用动画名包括 `idle`、`walk`、`sleep`、`thinking`、`work`、`chat`、`look`、`drag`、`poke`、`review`、`aborted` 和 `error`。配置了别名动画时，插件会自动选择对应动画。

## 操作

- 左键拖动桌宠；单击桌宠触发跳动并显示随机台词。
- 右键打开菜单，可进入设置、聊天、切换动画、控制自动走动和注视目标，或退出桌宠。
- 设置页面可从桌宠右键菜单打开，也可以访问 `http://127.0.0.1:12030/`。
- 设置页中的桌宠库支持保存当前桌宠、导入 JSON 配置与图片、切换和删除。
- 导入图片支持 PNG、GIF 和 WebP，文件大小上限为 12 MiB。

桌宠库保存在 `%APPDATA%\opencode-desktop-pet\pets\`。当前选择记录在 `pets\active.json`，配置工作副本为 `pet.json`。

## 本机 API

服务只绑定回环地址 `127.0.0.1:12030`。若该端口被其他程序占用，插件不会自动改用随机端口，以免误连其他桌宠。服务身份字段为 `opencode-desktop-pet`。

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/api/state` | 当前动画、会话活动、桌宠运行状态 |
| `GET` | `/api/events` | SSE 状态流 |
| `GET` | `/api/sessions` | 已观察到的会话 |
| `GET` | `/api/pets` | 桌宠库列表及当前 ID |
| `POST` | `/api/pet/show`、`/api/pet/hide`、`/api/pet/toggle` | 显示或隐藏桌宠 |
| `POST` | `/api/pets/save` | 保存当前桌宠到桌宠库 |
| `POST` | `/api/pets/import` | 导入配置和贴图 |
| `POST` | `/api/pets/activate`、`/api/pets/delete` | 切换或删除桌宠 |
| `POST` | `/api/say` | 显示气泡文字 |
| `POST` | `/api/animation` | 指定动画；传 `auto` 恢复自动行为 |
| `POST` | `/api/chat` | 向最近活跃的 OpenCode 会话发送聊天消息 |
| `POST` | `/api/look_at_mouse`、`/api/look_at_opencode` | 切换注视目标 |
| `POST` | `/api/reload` | 重读用户配置 |

注册文件位于 `%TEMP%\opencode-desktop-pet\`，文件名包含 PID 和随机实例 ID。启动器不会通过扫描这些文件连接其他桌宠服务。

### 可选外部活动事件

在 `pet.json` 中配置 `externalEvents.enabled: true` 后，可使用 `POST /api/working`、`/api/idle` 或 `/api/activity` 推送活动状态。建议设置 token，并通过 `X-Pet-Token` 请求头发送。

## 开发与测试

```powershell
npm test
```

测试使用 Node.js 内置测试运行器，无需安装依赖。

## 素材

仓库包含的 `octocat.png` 基于 GitHub Octocat 素材，仅作为单帧演示桌宠。请遵守原素材的许可与品牌使用要求；代码许可与素材许可不同。
