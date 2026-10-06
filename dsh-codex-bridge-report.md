# Codex ↔ DeepSeek Harness 调用集成报告

> 用途：交给 Codex 阅读，用于讨论"如何更好地调用 DSH"。
> 所有标 ✅ 的结论都在本机实测过；标 ⚠️ 的是推断或来自文档；标 ❓ 的是待商量的开放问题。
> 生成日期：2026-09-22

---

## 0. 结论先行

1. **官方已有一条可用通道，且已实测跑通**：`dsh --profile headless "<任务>"`。不需要装任何插件。
2. **Codex 要"原生"调用 DSH，缺一块官方拼图**：DSH 只发布了 MCP **客户端**（让 DSH 去调别人），**没有发布 MCP 服务端**（让别人调 DSH）。Codex 的原生扩展机制恰好是 MCP，所以这个缺口是真实的。
3. **已落地**：`~/.codex/AGENTS.md`（用户级，所有项目生效）写入了委派约定。
4. **最重要的未公开约束**：headless 的沙箱根 = **调用方的 cwd**，且**无人应答审批时 fail-closed**。这直接决定了 Codex 该怎么调用它（见 §4）。

---

## 1. 环境事实

| 项 | 值 | 来源 |
|---|---|---|
| DSH 版本 | `0.1.5-rc.1` | ✅ `dsh --version` |
| DSH 可执行文件 | `/Users/magi/.npm-global/bin/dsh` | ✅ |
| Codex CLI 版本 | `0.155.0-alpha.9.2` | ✅ `codex --version` |
| Codex 可执行文件 | `/Users/magi/.local/bin/codex`（另有 ChatGPT.app 内置副本） | ✅ |
| Codex 家目录 | `/Users/magi/.codex` | ✅ |
| 已有 profile | `web` / `headless` / `dsh-tui` | ✅ |
| DSH 默认模型 | `deepseek-official` / `deepseek-flash`，`reasoningEffort: high` | ✅ `~/.dsh/settings.yaml` |
| 技能根目录 | `/Users/magi/.agents/skills/`（11 个技能） | ✅ |

### Codex 当前已注册的 MCP 服务器

```toml
[mcp_servers.node_repl]      # ChatGPT.app 内置 node REPL
[mcp_servers.computer-use]   # enabled = false
```

即 **Codex 已经是 MCP 客户端**，加一个 DSH 的 MCP 服务端在机制上没有任何障碍。

---

## 2. 调用契约（硬事实，均为实测）

```sh
dsh --profile headless "<任务描述>"
```

| 通道 | 内容 |
|---|---|
| **stdout** | 最终答案 |
| **stderr** | 模型推理过程，逐段以 `dsh: reasoning:` 开头 |
| **退出码 0** | 任务完成 |
| **退出码 1** | 中止或出错；出错时 stderr 另有一行 `dsh: <code>: <message>` |

### 实测记录

```sh
$ dsh --profile headless "回答 1+1 等于几，只输出数字" 2>/dev/null
2                      # exit 0

$ dsh --profile headless "回答 1+1 等于几，只输出数字" 2>/dev/null   # 沙箱外的对照
（空）                  # exit 1，stderr: dsh: ... 
```

### 两个反直觉点

- ⚠️ **成功运行 stderr 可能完全为空**。没有推理内容的成功运行不输出任何 stderr（官方文档明确说明）。所以**不能**用"stderr 没输出"判断它没干活。
- ⚠️ **它只回推理和最终答案**，中间的工具调用过程不打印。因此长任务期间没有任何进度信号——首个 token 之前 stderr 全静默。

### 固定开销

✅ 实测冷启动（进程启动 + 一次模型往返）**约 1.2–1.3 秒**：

```
run1: 1.32s   run2: 1.17s   run3: 1.25s
```

这是"值不值得委派"的下限成本。真实任务耗时随任务规模增长。

---

## 3. DSH 有什么是 Codex 没有的

这些是委派的**理由**。headless profile 由 `dsh-base` + `dsh-headless` 组成，✅ 实测它能看到**全部 11 个技能**，与我当前 GUI 会话完全一致：

| 技能 | 能力 |
|---|---|
| `hyperframes` + 7 个子技能（`-animation` / `-audio` / `-cli` / `-core` / `-creative` / `-keyframes` / `-registry`） | 视频、动画、动效的全流程制作与渲染 |
| `dreamina-canvas-cli` | 图像/媒体生成与画布编辑 |
| `media-use` | BGM / 音效 / 图像 / 图标 / 配音 / 调色 |
| `autoglm-browser-agent` | 真实浏览器自动化（含登录、社媒、表单、采集） |

工具面（headless 由 `dsh-base` 提供，✅ 部分经实测、部分来自 profile 配置）：

- **编排**：`subagent`、`subagent_fork`、`workflow`、`ralph`、`goal` 系列、`jobs` 系列
- **执行**：`bash`、`read`、`write`、`edit`、`read_image`、`glob`、`grep`
- **规划**：plan mode（`exit_plan_mode`）、`todo_write`
- **联网**：`web_search`、`web_fetch`

> ⚠️ **给 Codex 的诚实提醒**：我曾让 headless 自述它的工具列表，它的自述**漏掉了 `write`**，但配置文件（`dsh-tool-fs`）明确注册了 `read`/`read_image`/`write`/`edit`。
> **结论：不要信任 agent 对自己工具面的自述，要以配置或实际调用为准。** 这条同样适用于 Codex 评估 DSH 的任何自我描述。

---

## 4. 关键约束（本节最重要）

### 4.1 沙箱根 = 调用方的 cwd

来自 `dsh-base` 的 profile 配置：

```yaml
- id: sandbox-policy
  config:
    mode: !!js process.env.DSH_PERMISSION_MODE ?? 'workspace-write'
    workspaceRoot: !!js process.cwd()
```

✅ **实测边界**（从 `magikara` 目录调用 headless）：

| 目标路径 | 结果 |
|---|---|
| 工作区内 `./.dsh-probe-inside.txt` | ✅ 成功落盘 |
| `/tmp/dsh-probe-outside.txt` | ✅ 成功（平台临时区例外） |
| `/Users/magi/dsh-probe-home.txt`（工作区外） | ❌ `[sandbox: file access denied under workspace-write mode]`，**文件未落盘** |

**推论：Codex 必须先 `cd` 到目标项目再调用**，否则 DSH 的可写范围是错的。AGENTS.md 里已写入这一条。

### 4.2 无人应答 → fail-closed

默认审批策略：

```yaml
- id: approval
  config:
    policy: !!js "(process.env.DSH_PERMISSION_MODE ?? 'workspace-write') === 'danger-full-access' ? 'never' : 'ask'"
```

headless **没有任何交互式应答者**。所以：

- 默认 `workspace-write` + `ask`：越界操作返回的升级提示**永远无人批准**，实际上等于 fail-closed。✅ 上表已证实：提示出现了，但文件确实没落盘。
- 若设 `DSH_PERMISSION_MODE=danger-full-access`：沙箱变 `danger-full-access` **且审批变 `never`** —— 完全无人监督、无限制。

> ❓ **这是一个需要和 Codex 商量的取舍**：要不要为委派场景放开权限？放开等于让 Codex 能间接获得无限制的文件系统访问。

### 4.3 没有交互能力

headless 的工具集**不包含**以下三项（它们来自 web profile）：

- `ask_user_question` —— **无法向用户提问**
- `present` —— 无法声明交付物
- `dsh_im_return_file` —— **无法通过 IM 回传文件**

**推论：DSH 只能把结果写进文件系统或 stdout，不能主动"发文件"给用户。** 需要交付物时，Codex 负责从磁盘取回。

### 4.4 一次性、无追问、无共享记忆

- 每次调用是**全新会话**，不共享 Codex 的对话历史。
- 无法追问，一次调用只做一件事。
- ⇒ 任务描述必须**完全自包含**：背景、目标、约束、绝对路径、已排除的方案，全部写进去。

### 4.5 必须经 `dsh` 启动器运行

⚠️ 绕过启动器直接起 profile 会在启动时失败（只有启动器能请求进程退出）。

---

## 5. 三条调用路径对比

| 路径 | 状态 | 优点 | 代价 |
|---|---|---|---|
| **A. `headless` CLI** | ✅ 官方、已实测、已落地 | 零依赖、零供应链风险、立即可用 | 一次性、无会话延续、无结构化返回、无并行、Codex 需自己解析 stdout |
| **B. `sdk` profile（stdio JSON-RPC）** | ⚠️ 官方已发布（`dsh-sdk-app` + `dsh-sdk-jsonrpc-server`） | 持久会话、事件流、`session/prompt` 入队 | Codex 不说这套协议，需要写一层适配 |
| **C. MCP 服务端** | ❌ **官方没有** | Codex 原生工具调用，无需"记得" | 必须用第三方或自建 |

### 5.1 官方其他相关件（别搞混方向）

| 包 | 方向 | 说明 |
|---|---|---|
| `dsh-mcp-client` | DSH **调**别人 | MCP 客户端，把外部 MCP 工具注册进 DSH |
| `dsh-hooks-codex` | DSH 跑 Codex 的 hook | 把 Codex `hooks.json` 跑在 DSH 拦截缝上，**不是调用桥** |
| `dsh-acp` | 给 ACP 客户端 | 面向 Zed/Cursor 等；**Codex 不说 ACP** |
| `dsh-api-gateway` | Web UI 内部 | Typert RPC over `/api`，内部接口，**不适合外部 agent 依赖** |

### 5.2 社区 MCP 桥（已核查，未安装）

| 方案 | 形态 | 工具面 | 周下载 | 备注 |
|---|---|---|---|---|
| [`dsh-sdk-mcp`](https://www.npmjs.com/package/dsh-sdk-mcp) `0.6.0-rc.2` | 独立 MCP stdio server | 8 个：`dsh_health`/`dsh_delegate`/`dsh_continue`/`dsh_status`/`dsh_parallel`/`dsh_parallel_worktree`/`dsh_worktree_review`/`dsh_integrate` | 12 | 最贴合。走官方 `sdk` profile + 官方 TS SDK；带持久会话、并行 worker、git worktree 隔离、结构化错误分类、`doctor` 自检。CHANGELOG 称已用 Codex CLI 实测 |
| [`@chushixixin/dsh-harness-mcp-server`](https://github.com/chushixixin/dsh-harness-mcp-server) `0.1.10` | DSH 插件，内部开 StreamableHTTP `:8090` | 5 个：`echo`/`harness_list_tools`/`agent_run`/`task_inbox`/`task_result` | 113 | 复用现有 DSH 配置与凭据；但 README 自述是**未鉴权的远程代码执行端点** |
| [`codex-dsh-buddy`](https://www.npmjs.com/package/codex-dsh-buddy) `0.1.0` | MCP | — | 10 | 定位对口但过早期 |

**隔离验证结果** ✅（装在 `/tmp`，跑完已删除）：`dsh-sdk-mcp doctor` 输出

```
status: needs-configuration
package: 0.6.0-rc.2      node: v24.19.0 (darwin/arm64)
mcp: @modelcontextprotocol/sdk 1.30.0 / 2025-11-25 / stdio
dsh: client=0.1.2-rc.1 protocol=0.1.2-rc.1 runtime=0.1.2-rc.1 mode=bundled-sdk
provider: deepseek-official/deepseek-v4-flash credentialConfigured=false
maxParallel: 3/8         sandbox: inconclusive
warnings: - credential is not configured for DEEPSEEK_API_KEY
```

即：本机可用，唯一阻碍是 `DEEPSEEK_API_KEY` 未配置。但它自带并锁定 `dsh@0.1.2-rc.1`，而本机是 `0.1.5-rc.1` —— **它跑的不是你现在这套 DSH 配置**。

⚠️ **供应链提示**：上述包周下载仅 10–170，均为早期个人项目。它们会把一个拥有 bash/文件/网络全权限的 agent 暴露成 Codex 的工具，**等于给 Codex 增加一条 RCE 通道**。安装前应审阅源码。

### 5.3 容易装错的反方向包

- `dsh-codex`（454/周）—— DSH 去用 ChatGPT/Codex 模型（ChatGPT OAuth、搜索、图像）
- `dsh-mcp-bridge`（171/周）—— 为 DSH 打包一批 MCP 服务端

---

## 6. ❓ 待与 Codex 商量的开放问题

1. **委派粒度**：固定开销 ~1.2s 起。多小的任务不值得委派？是否设一个"低于 N 步自己做"的阈值？
2. **上下文如何传才不失真**：DSH 没有共享记忆。是让 Codex 写一份结构化任务简报，还是约定把关键文件路径 + 目标 + 验收标准固定成模板？
3. **结果如何校验**：DSH 会返回一套自洽的说法。Codex 用什么独立证据判断它真的做对了（diff？测试输出？）？§3 那个"自述漏掉 write"的例子说明**自述不可作证据**。
4. **权限边界**：是否给 `DSH_PERMISSION_MODE=danger-full-access`？给了就等于 Codex 可间接无限制访问文件系统且无审批。
5. **是否升级到 MCP**：AGENTS.md 是**软约束**（靠 Codex 自觉）；MCP 是**硬接口**（工具在列表里，不用记）。值得为哪些能力升级？
6. **并行**：headless 一次一个。真需要并行（多模块/多方案）时怎么办 —— 多个 headless 进程，还是上 §5.2 的并行桥？
7. **失败语义**：`exit 1` + `dsh: <code>: <message>` 之外，Codex 应如何区分"任务失败"与"权限被拒"？后者目前只表现为沙箱拒绝，重试无用。
8. **中文 vs 英文任务描述**：是否影响 DSH 的输出质量或 token 成本？

---

## 7. 附录：复现与验证命令

```sh
# 基本调用
dsh --profile headless "<任务>" 2>/dev/null

# 看推理过程
dsh --profile headless "<任务>"

# 查看 profile 组合结果
dsh --dump-config --profile headless

# 查看帮助（不执行任何任务）
dsh --profile headless --help

# 确认 Codex 侧 MCP 注册
codex mcp list

# 确认已落地的约定文件
cat ~/.codex/AGENTS.md
```

### 本次生成的所有实测证据

| 结论 | 验证方式 |
|---|---|
| headless 可用 | `dsh --profile headless "..."` → exit 0 |
| stdout/stderr 契约 | 分离重定向测两次 |
| 冷启动 1.2–1.3s | 3 次计时 |
| 工作区内可写 | 实际文件落盘 |
| 工作区外不可写 | 实际文件**未**落盘 + 沙箱错误信息 |
| `/tmp` 是例外 | 实际文件落盘 |
| headless 可见 11 个技能 | 直接询问并比对技能目录 |
| `dsh-sdk-mcp` 本机可用 | `/tmp` 隔离安装后跑 `doctor` |
| 社区包下载量 | `api.npmjs.org` 查询 |

---

## 8. 当前落地状态

- ✅ `~/.codex/AGENTS.md`（3016 字节）已写入委派约定：何时委派、怎么调用、契约、约束、正反例、何时不用。
- ✅ 探测过程中产生的临时文件与隔离安装目录**均已清理**。
- ✅ 用户工作区文件未被修改。
- ⬜ MCP 桥**未安装**，等你和 Codex 商量后再决定。
