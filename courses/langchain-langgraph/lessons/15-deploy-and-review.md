# 第 15 章 联调、测试、部署与复盘

> 一句话总结：用联调清单和旅程测试把系统钉死，完成生产构建与同域部署，复盘全项目的技术决策，收束整门课程。

## 本章任务：从「能跑」到「敢交」

前四章的验收都是单点的：后端 curl 通、前端页面通。本章把它们变成一套可重复验证的整体，然后部署成别人能访问的服务，最后停下来复盘——做过的每个决策，哪些是对的，哪些下次会换做法。里程碑 M4：旅程测试脚本全绿，生产构建在本机以生产形态跑通。

## 联调清单：前后端对齐的七个核对点

前后端分开验收过 ≠ 合起来没问题。联调期的问题几乎全是「约定不一致」，按这份清单逐条核对，比瞎试高效得多：

1. **路径一致**：前端 `api.ts` 写的每个路径，后端都有对应路由（`/api/tickets`、`/api/tickets/:id/messages`、`/api/approvals/:ticketId/decide`）。一个字母的出入就是 404。
2. **字段一致**：后端返回的 `reply`、`status`，前端解构的名字相同；SSE 事件的结构（`{ 节点名: { 字段 } }`）前后端理解一致。
3. **token 一致**：前端 localStorage 里的 token 值，是后端硬编码表里的 key。「401 满天飞」多半是这边存了个旧值。
4. **状态码语义一致**：前端把非 2xx 都当错误处理了吗？后端的 400/401/403 消息格式统一吗？
5. **SSE 头三件套**：`text/event-stream`、`no-cache`、`keep-alive`，缺一个都可能在某一层被缓冲。
6. **代理生效**：`vite.config.ts` 改了要重启 dev server；浏览器 Network 面板里请求应发往 5173（Vite）而不是 3000。
7. **时间基准**：created_at 是后端生成的，前端别自己造——两处时间源必有不一致。

这份清单值得存进项目 README。下次联调任何前后端项目，它都通用。

## 排错实战：三个真问题

### 问题一：SSE 本地好好的，上服务器就不流了

症状：本地开发流式完美，部署到服务器后，前端收不到逐条事件，最后一次性全到。

排查路径：本地 Vite 代理不缓冲 → 服务器上多了 nginx 反向代理 → **nginx 默认会缓冲上游响应**，攒够一批才发给客户端，SSE 的「实时」就此阵亡。

修复：nginx 对该路径关闭缓冲并放行长连接：

```nginx
location /api/ {
  proxy_pass http://127.0.0.1:3000;
  proxy_http_version 1.1;
  proxy_set_header Connection "";
  proxy_buffering off;        # 关键：不缓冲，收到就转发
  proxy_read_timeout 3600s;   # 长连接别被默认超时掐断
}
```

教训提炼：**凡是「本地好、线上坏」的网络行为差异，先怀疑中间层**（代理、网关、CDN），而不是自己的代码。SSE、文件下载、WebSocket 都是中间层敏感型。

### 问题二：生产环境的 CORS 又回来了

开发期靠 Vite 代理，前端不知道后端的存在。生产构建后没有 Vite 了，如果前端部署在 A 域、后端在 B 域，同源策略立刻回归。本项目的方案是**同域部署**：后端 Express 直接托管前端构建产物，页面和 API 同一个来源，CORS 问题从根上消失（下一节落地）。

如果业务上必须分域（比如 API 要给多个客户端用），那就后端显式配置 CORS 头：放行指定来源、允许的头部（`x-token` 要在允许列表里）。原则收紧不放宽：`Access-Control-Allow-Origin: *` 配 token 鉴权等于把门钥匙挂门上。

### 问题三：重启之后，待审批的工单去哪了

这是验收持久化的关键实验，也是最容易被漏测的：提交一个退款工单（进入待审批）→ 重启后端 → 审批员批准 → 员工看到结果吗？

应该看到。拆解为什么：工单在业务库（tickets.sqlite，文件）；冻结的流程在 checkpoints.sqlite（文件）；重启后 `buildGraph()` 重建内存索引和图结构，checkpointer 从文件读回冻结点；`decide` 用同样的 thread_id 把 resume 送回去。整条链没有一环依赖进程内存——这就是第 8 章「数据不依赖进程」的设计在买单。

如果看不到结果，按序排查：checkpoints.sqlite 文件是否生成（启动时创建）；thread_id 拼接是否一致（`ticket-2` vs `2` 是两个世界）；decide 的 resume 值类型（`req.body.approved === true` 的严格比较，前端传 `"true"` 字符串会翻车）。

## 旅程测试：把验收剧本变成代码

前面每章的 curl 验收，本质是手动测试。手动的东西不会被执行第二次——把它写成脚本，以后每次改代码跑一遍，30 秒确认主干无恙。`server/scripts/journey.mts`：

```ts
const BASE = "http://localhost:3000";
const emp = { "Content-Type": "application/json", "x-token": "emp-token" };
const admin = { "Content-Type": "application/json", "x-token": "admin-token" };

let passed = 0, failed = 0;
async function check(name: string, fn: () => Promise<void>) {
  try { await fn(); passed++; console.log("✓", name); }
  catch (e) { failed++; console.error("✗", name, (e as Error).message); }
}
const api = (path: string, opts?: RequestInit) => fetch(BASE + path, opts);

// 旅程 1：咨询工单全周期
await check("咨询工单得到知识库回答", async () => {
  const r = await api("/api/tickets", {
    method: "POST", headers: emp,
    body: JSON.stringify({ title: "住宿额度", description: "一线城市住宿报销额度是多少" }),
  });
  const j = await r.json();
  if (j.status !== "done" || !j.reply?.length) throw new Error("未办结或无回复");
});

// 旅程 2：退款审批往返
let refundId = 0;
await check("退款工单进入待审批", async () => {
  const r = await api("/api/tickets", {
    method: "POST", headers: emp,
    body: JSON.stringify({ title: "退款", description: "申请退回多扣的 800 元" }),
  });
  const j = await r.json();
  if (j.status !== "pending_approval") throw new Error("未进入待审批: " + j.status);
  refundId = j.id;
});
await check("员工无权审批(403)", async () => {
  const r = await api(`/api/approvals/${refundId}/decide`, { method: "POST", headers: emp, body: "{}" });
  if (r.status !== 403) throw new Error("越权成功: " + r.status);
});
await check("管理员批准后执行", async () => {
  const r = await api(`/api/approvals/${refundId}/decide`, {
    method: "POST", headers: admin, body: JSON.stringify({ approved: true }),
  });
  const j = await r.json();
  if (!j.reply?.includes("已执行")) throw new Error("未执行: " + j.reply);
});

// 旅程 3：追问 SSE
await check("追问收到 SSE 流", async () => {
  const r = await api("/api/tickets/1/messages", {
    method: "POST", headers: emp, body: JSON.stringify({ content: "审批流程呢" }),
  });
  const text = await r.text();
  if (!text.includes("data:") || !text.includes("[DONE]")) throw new Error("SSE 格式异常");
});

console.log(`\n${passed} 通过, ${failed} 失败`);
process.exit(failed ? 1 : 0);
```

这叫**旅程测试（journey test）**：不测单个函数，测「一类用户的一次完整操作旅程」。它和单元测试不冲突，是不同层级的网——单测抓逻辑细节，旅程抓「系统拼起来是不是真的能用」。`npx tsx scripts/journey.mts`，全绿才敢说你没把主干改坏。

## 生产构建与同域部署

**前端构建**：`cd web && npm run build`，产物是 `dist/` 下的一堆静态文件（HTML/JS/CSS）。Vite 会把 TS 编译、打包、压缩一次做完。

**后端托管静态文件**：让 Express 把 `dist` 目录服务出去，并处理 SPA 路由回退：

```ts
import path from "node:path";

const dist = path.resolve("../web/dist");
app.use(express.static(dist));

// SPA 回退：非 /api 的 GET 都返回 index.html，前端路由接管
// （Vue Router 的 history 模式下，/tickets/3 这样的地址刷新时需要它）
app.get(/^\/(?!api\/).*/, (_req, res) => {
  res.sendFile(path.join(dist, "index.html"));
});
```

SPA 回退值得解释一句：Vue Router 的 history 模式让 URL 长得像普通页面（`/tickets/3`），但这路由只存在于浏览器里。用户在这个地址上刷新，请求直接打到服务器，服务器没有对应的文件——所以约定「凡是GET 且不是 /api 的，都返回 index.html」，让前端路由从首页重新导航过去。不配它，一切正常，一刷新 404。

**后端生产运行**：开发用 tsx 图省事，生产建议编译成 JS 再跑，少一层运行时转换，启动更快、错误栈更干净。给 server 补一份 `tsconfig.json`：

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

`module: NodeNext` 表示按 Node 原生 ESM 规则处理模块——这也是本章代码里 import 一直写 `.js` 后缀的原因（`./db.js`）：TS 源码编译后路径不变，Node 按 ESM 规范要求显式后缀。然后在 package.json 里加 scripts：

```json
{
  "scripts": {
    "dev": "tsx watch --env-file=.env src/index.ts",
    "build": "tsc",
    "start": "node --env-file=.env dist/index.js",
    "journey": "tsx scripts/journey.mts"
  }
}
```

开发 `npm run dev`，上线 `npm run build && npm run start`，测试 `npm run journey`。进程守护用 pm2（`pm2 start dist/index.js --name ticket-polit`）：崩溃自动拉起、开机自启、日志集中——单机部署的标配套件。

**环境变量**：生产环境 `.env` 不进 git 的纪律不变，由部署环境注入（pm2 的 ecosystem 文件、或系统的环境变量）。模型密钥出现在任何客户端可见的地方（前端代码、构建产物、接口响应）都算事故，发布前全局搜一遍。

部署后最后一步：把「问题三」的重启实验在生产形态下再做一遍。能过，M4 达成。

## 复盘：每个决策的回头看

| 决策 | 回头看 |
| --- | --- |
| 两个数据库分离 | 正确。重启实验、业务查询都受益；代价是要记两个文件 |
| thread_id = ticket-{id} | 正确。审批、追问、恢复全靠它定位，业务含义清晰 |
| MemoryVectorStore | 现阶段正确（三份文档）。知识库上百篇就得换 pgvector 类方案 |
| 硬编码 token | 教学可接受。真实系统必须换 JWT/Session，优先级高 |
| 审批结果不存流水 | 已知妥协。真实系统需要 approvals 表做审计 |
| SSE 而非 WebSocket | 正确。单向推送场景它最简，nginx 调通后零维护 |
| messages 不进业务库 | 正确但留了作业：详情页历史对话要从 getState 读，目前只能看本次会话 |

### 可扩展方向（下一版做什么）

按价值排序：消息历史展示（详情页调 `graph.getState` 渲染完整轨迹，前后端各加十行）；对话成本控制（第 8 章的截断或摘要策略，thread 一长寿必须做）；长期记忆（Store 记用户偏好，「这个员工偏好简洁回复」）；LangSmith 接入（生产排障刚需，几个环境变量的事）；PostgresSaver（多实例部署的前提）；人工工单队列（handoff 节点目前只是回复一句话，真实系统要落库排队）。

## 全课收束

十五章走完，回到第 1 章的那张复杂度阶梯：

- L1 固定流水线，你在第 2、3 章用 LCEL 做过；
- L2 工具型 Agent，你在第 4 章手写循环、用 createAgent 收口；
- L3 有状态工作流，你在第 8、9 章加了持久化和人工介入；
- L4 多 Agent 系统，第 10 章见过组织形态；
- 然后在 Ticket Polit 里，把它们全部塞进了一个真实产品。

最后留一句方法论，比任何 API 都值得带走：**先用简单的工具把东西做出来，让真实的复杂度来敲门，再换更大的锤子。** LangChain 之于裸调 API、LangGraph 之于 for 循环、多 Agent 之于单 Agent，都是这个逻辑的重复上演。能判断「现在该不该升级工具」的你，已经比会背所有 API 的你值钱得多。

## 自测

1. 「本地好、线上坏」的 SSE 问题，第一嫌疑人是谁？为什么？
2. SPA 回退规则解决什么问题？不配会出现什么症状？
3. 重启后审批能继续，依赖链上的哪几个环节都不依赖进程内存？
4. 旅程测试和单元测试各抓什么问题？为什么说它们不冲突？

参考答案：1. 中间层代理（nginx 等）的响应缓冲；SSE 依赖边收边发，缓冲会把实时流攒成批量响应。2. history 模式的前端路由 URL 在服务器上不存在对应文件；不配时子页面刷新返回 404。3. 工单数据在业务库文件、流程冻结点在 checkpoints 文件、thread_id 由 URL 参数重建、图结构启动时重建。4. 单测抓函数级逻辑细节，旅程抓系统拼装后的端到端可用性；层级不同，互相补充。
