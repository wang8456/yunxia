# 对话功能（默认关闭）

开源版**默认不带对话**：`chat.enabled` 是 `false`，网页和 App 里连「对话」入口都不会出现。
想用就自己在配置里填一个 OpenAI 兼容服务的地址、模型和 Key —— 云匣只是转发，不存你的 Key 之外的任何东西，也不预置任何厂商。

支持：DeepSeek、OpenAI、Moonshot、硅基流动、Ollama / vLLM / LM Studio（本地）、任何实现了
`POST {base}/chat/completions` + `stream: true` 的服务。

---

## 一、打开对话

编辑 `server/config.json`：

```jsonc
"chat": {
  "enabled": true,
  "base": "https://api.deepseek.com/v1",   // 到 /v1 为止，不要带 /chat/completions
  "api_key": "sk-你的Key",
  "model": "deepseek-chat",
  "system": "你是一个简洁、直接的中文助手。",
  "max_turns": 12,                          // 每次带给上游的历史轮数
  "timeout": 120
}
```

重启服务端。然后：

```bash
curl -s http://<IP>:8686/api/v1/meta/sources | grep -o '"chat":{[^}]*}'   # 期望 "enabled":true
```

刷新网页 / 重开 App，「对话」页就出现了。

### 几个常见服务怎么填

| 服务 | base | model 示例 |
|---|---|---|
| DeepSeek | `https://api.deepseek.com/v1` | `deepseek-chat`（推理模型用 `deepseek-reasoner`） |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| 硅基流动 | `https://api.siliconflow.cn/v1` | `deepseek-ai/DeepSeek-V3` |
| Ollama（本地） | `http://127.0.0.1:11434/v1` | `qwen2.5:7b`（Key 随便填一个非空字符串） |
| LM Studio | `http://127.0.0.1:1234/v1` | 你加载的模型名 |
| vLLM | `http://127.0.0.1:8000/v1` | 你起的模型 |

> Ollama 要确认开了 OpenAI 兼容接口（新版默认开了），`curl http://127.0.0.1:11434/v1/models` 能列出模型即可。

---

## 二、它是怎么工作的（方便你排查）

```
客户端 ──POST /hermes/api/chat──▶ 云匣服务端 ──POST {base}/chat/completions──▶ 上游
        ◀── SSE: response.output_text.delta ◀── SSE: choices[].delta.content ──
```

- **上下文**存在服务端的 `conv` 表里：客户端只发最新一条消息 + 上一轮的 `previous_response_id`，
  服务端顺着 id 往上爬，拼出历史再发给上游。所以换设备继续聊也是同一条线。
- **中断**：客户端点发送键旁边那个按钮（或在网页里直接按回车再发一条）会调 `/hermes/api/cancel`，
  服务端把上游连接关掉。**只中断前端不算数**，一定要看到 cancel 真的返回 `{"cancelled":true}`。
- **多端记录**：`/hermes/api/log` 是那本共享的账。网页 / App 都从它取历史，
  所以手机上发的消息，电脑上刷新就能看到。
- **附件**：上传到服务端 `data/media/<日期>/`，路径写进消息正文给模型看。
  取回走 `/hermes/api/dl`（带 Basic 口令），缩略图走 `/hermes/api/thumb`。

## 三、安全

- 对话接口认两样东西：**Basic 口令**（用户名随意，密码必须是 `auth.password`）和 **Bearer 令牌**。
  所以先把 `auth.password` 设好，否则同网段谁都能拿你的 Key 烧额度。
- `api_key` 明文存在 `config.json` 里：`chmod 600 config.json`，别提交到 git。
- 本地模型（Ollama）配合 `base` 写 `127.0.0.1` 时，服务端和 Ollama 必须在同一台机器（或容器能互访）。

## 四、不想要了

把 `"enabled"` 改回 `false` 重启即可：入口消失，接口一律 503，历史记录还在数据库里
（想彻底清掉：`POST /hermes/api/log/clear`，或直接删 `data/yunxia.db` 里的 `conv`/`msg`/`op` 表）。
