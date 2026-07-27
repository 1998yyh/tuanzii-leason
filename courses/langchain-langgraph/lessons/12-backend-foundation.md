# 第 12 章 后端地基：数据模型、鉴权与核心 API

> 一句话总结：用 better-sqlite3 建业务库，用 Express 中间件实现鉴权与校验，交付工单提交、列表、详情三个核心 API，并用 curl 完成验收。

## 本章任务：先把「不用 AI 也能转」做出来

第 13 章的 AI 内核要寄生在一套正常的业务系统上：工单得有地方存，接口得有权限拦，输入得有人校验。本章把这些地基打完。验收标准（里程碑 M1）：用 curl 能走通「提交工单 → 看我的工单列表 → 看单个工单详情」，并且无 token 被拒、垃圾输入被挡。

这个「先做骨架后装智能」的顺序是刻意为之：AI 部分天然不确定（模型输出有随机性），把它和不稳定的基建搅在一起调试，出了问题你都不知道怪谁。**地基先稳，内核后上。**

## 数据建模：一张 tickets 表够用吗

先想清楚存什么。回看需求：工单有标题、描述、分类、状态、提交人、提交时间。审批呢？审批状态直接体现在工单状态里（`pending_approval`），审批结果决定状态流转，不需要单独的审批表——这是砍需求时定下的简化，真实系统里审批该有独立流水表。

```sql
CREATE TABLE IF NOT EXISTS tickets (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  title       TEXT NOT NULL,
  description TEXT NOT NULL,
  category    TEXT,                                  -- classify 节点回填，初始为 NULL
  status      TEXT NOT NULL DEFAULT 'processing',    -- processing / pending_approval / done
  created_by  TEXT NOT NULL,
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
```

几个字段决策值得说。`id` 用自增整数而不是 UUID：内部系统、单机库，自增简单可读，URL 里 `#1024` 比一串乱码友好。`category` 允许 NULL：工单创建时还没分类，NULL 就是「尚未分类」的语义。`status` 用字符串枚举而不是数字：读库、看日志时 `pending_approval` 比 `3` 友好得多，存储成本可以忽略。

### 对话消息存哪？不存业务库

你可能想问：工单下的对话消息要不要建 messages 表？**不要。** 对话轨迹由 checkpointer 完整保存（第 8 章），详情页展示消息时，直接从图的 State 里读（第 13 章实现）。在业务库再存一份，就是同一份数据两个真相来源——两边写着写着就对不上了。这个「单一真相来源」原则，比省一次查询重要。

## db.ts：连接、建表与预编译语句

`server/src/db.ts`：

```ts
import Database from "better-sqlite3";

// 单文件数据库，随应用启动自动创建
export const db = new Database("tickets.sqlite");

// 建表用 IF NOT EXISTS：应用每次启动执行一遍，已有表则不动
// 这是极简的"迁移"策略——表结构变更在本项目靠删库重来（开发期），生产才需要正式迁移工具
db.exec(`
  CREATE TABLE IF NOT EXISTS tickets (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    title       TEXT NOT NULL,
    description TEXT NOT NULL,
    category    TEXT,
    status      TEXT NOT NULL DEFAULT 'processing',
    created_by  TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
  )
`);

// 预编译语句：SQL 写一次、编译一次，之后带参数反复执行
export const insertTicket = db.prepare(
  "INSERT INTO tickets (title, description, created_by) VALUES (?, ?, ?)"
);
export const listTicketsByUser = db.prepare(
  "SELECT * FROM tickets WHERE created_by = ? ORDER BY id DESC"
);
export const getTicketById = db.prepare("SELECT * FROM tickets WHERE id = ?");
export const updateTicketStatus = db.prepare(
  "UPDATE tickets SET category = ?, status = ? WHERE id = ?"
);
```

两个 better-sqlite3 的特性要懂。一是**同步 API**：`prepare` 返回的语句对象，`.run(...)` 写、`.get(...)` 读一行、`.all(...)` 读多行，全是同步调用，没有 await。SQLite 操作是微秒级的本地文件读写，同步不会阻塞事件循环，代码因此清爽很多——这是它教学友好的原因，也是它和「必须异步」的 Postgres 驱动最大的体感差异。

二是**预编译语句（prepared statement）**。`VALUES (?, ?, ?)` 里的问号是参数占位符，执行时传值。为什么坚持参数化？一是防 SQL 注入——用户输入永远作为「数据」而不是「SQL 文本」参与执行，`'); DROP TABLE tickets; --` 这样的祖传攻击在参数化面前就是个普通字符串；二是性能，SQL 只编译一次。字符串拼接 SQL 是新手最容易留下的安全窟窿，从第一天就别看它。

### 给查询结果一个类型

`@types/better-sqlite3` 里 `.get()` 默认返回 `unknown`——这是类型系统在提醒你：数据库里读出来什么形状，TS 不知道，得你告诉它。tsx 运行时不做类型检查，问题会藏到生产构建（`tsc --strict`，第 15 章）才炸。做法是在语句定义处一次性收窄：

```ts
export interface TicketRow {
  id: number;
  title: string;
  description: string;
  category: string | null;
  status: string;
  created_by: string;
  created_at: string;
}

// 在 getTicketById 定义处加类型断言
export const getTicketById = db.prepare("SELECT * FROM tickets WHERE id = ?") as {
  get: (id: number) => TicketRow | undefined;
};
export const listTicketsByUser = db.prepare(
  "SELECT * FROM tickets WHERE created_by = ? ORDER BY id DESC"
) as { all: (userId: string) => TicketRow[] };
```

之后 `ticket.created_by` 这样的属性访问才有类型、有补全，`ticket.titel` 拼错编译期就拦下。断言的依据是上面的建表 SQL——**类型和表结构是同一份事实的两种写法**，改表结构时记得同步改它。

## 鉴权中间件：Express 的请求管道

本项目用最简鉴权：请求头带 `x-token`，服务端认两个硬编码 token。实现之前先懂 Express 的核心概念——**中间件（middleware）**。

Express 处理一个请求像流水线：请求进来，依次经过一串函数，每个函数可以「看一眼、改一改、放行或掐断」。`app.use(fn)` 就是把 fn 挂上流水线。鉴权天然是中间件：每个 API 请求都得先过身份这道闸。

```ts
// server/src/auth.ts
import type { Request, Response, NextFunction } from "express";

export interface AuthedRequest extends Request {
  user?: { id: string; role: "employee" | "admin" };
}

const TOKENS: Record<string, { id: string; role: "employee" | "admin" }> = {
  "emp-token":   { id: "u-employee", role: "employee" },
  "admin-token": { id: "u-admin",    role: "admin" },
};

export function auth(req: AuthedRequest, res: Response, next: NextFunction) {
  const token = req.headers["x-token"];
  const user = typeof token === "string" ? TOKENS[token] : undefined;
  if (!user) {
    res.status(401).json({ error: "未登录或 token 无效" });
    return;                        // 掐断：不调 next，后面的处理函数不会执行
  }
  req.user = user;                 // 放行前把用户信息挂在请求对象上，下游直接用
  next();                          // 放行：交给下一个中间件/路由处理
}
```

用法是在路由前挂上：`app.use("/api", auth)`——所有 `/api` 开头的请求先过鉴权。`next()` 是放行的信号，不调它请求就死在当前环节。401 的语义是「没身份」，403 是「有身份但权限不够」（后面审批接口会用到）。

坦诚说明：硬编码 token 是教学简化，只防君子。真实系统用 JWT 签名令牌或 Session，思路相通——都是「请求带凭证 → 中间件解析 → 用户信息随请求流转」。

## 输入校验：zod 在 API 边界再就业

第 2 章用 zod 约束模型输出，这里用它约束用户输入——同一个思路：在系统边界上，不信任任何外部数据。

```ts
import { z } from "zod";

const CreateTicketSchema = z.object({
  title: z.string().trim().min(1, "标题不能为空").max(100, "标题太长了"),
  description: z.string().trim().min(1, "描述不能为空").max(5000),
});

// 在路由里：
const parsed = CreateTicketSchema.safeParse(req.body);
if (!parsed.success) {
  res.status(400).json({ error: parsed.error.issues[0].message });
  return;
}
const { title, description } = parsed.data;  // 校验通过的数据，类型精确
```

`safeParse` 不抛异常，返回成功/失败结果，适合在边界手动处理。校验不通过返回 400（请求本身有问题）和统一格式的错误消息。三个状态码的分工顺手记住：400 你发的东西不对，401 你是谁，403 你不配。

## 路由实现：三个核心接口

`server/src/routes/tickets.ts`：

```ts
import { Router } from "express";
import { z } from "zod";
import { insertTicket, listTicketsByUser, getTicketById } from "../db.js";
import type { AuthedRequest } from "../auth.js";

export const ticketsRouter = Router();

const CreateTicketSchema = z.object({
  title: z.string().trim().min(1, "标题不能为空").max(100, "标题太长了"),
  description: z.string().trim().min(1, "描述不能为空").max(5000),
});

// 提交工单（本章先占位：状态 processing，第 13 章接入 AI 工作流）
ticketsRouter.post("/", (req: AuthedRequest, res) => {
  const parsed = CreateTicketSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.issues[0].message });
    return;
  }
  const info = insertTicket.run(parsed.data.title, parsed.data.description, req.user!.id);
  res.status(201).json({ id: Number(info.lastInsertRowid), status: "processing" });
});

// 我的工单列表
ticketsRouter.get("/", (req: AuthedRequest, res) => {
  res.json(listTicketsByUser.all(req.user!.id));
});

// 工单详情（只能看自己的；审批员角色可查看全部，用于审批）
ticketsRouter.get("/:id", (req: AuthedRequest, res) => {
  const ticket = getTicketById.get(Number(req.params.id));
  if (!ticket) {
    res.status(404).json({ error: "工单不存在" });
    return;
  }
  if (ticket.created_by !== req.user!.id && req.user!.role !== "admin") {
    res.status(403).json({ error: "无权查看他人的工单" });
    return;
  }
  res.json(ticket);
});
```

最后一道判断必须存在，而且必须查库之后做：**工单 1 是员工 A 的，员工 B 把 URL 里的 id 改成 1 就能看吗？** 没有这行判断就能——这类漏洞叫 IDOR（不安全的直接对象引用），是越权漏洞里最低级也最常见的一种。防线只有一条规则：凡是按 id 取资源的接口，取出后必须校验「这个资源属不属于当前用户」。注意校验在 404 之后——先确认存在，再确认归属，避免通过 403/404 的差异探测别人的工单 id 是否存在。

`Router()` 是路由模块：把一类接口写在自己文件里，最后在入口 `app.use("/api/tickets", ticketsRouter)` 挂上。`req.user!.id` 的 `!` 是 TS 的非空断言——auth 中间件已经保证放行必有 user，编译器不知道，我们替它知道。`201` 表示「创建成功」，比一律 200 更精确。

入口文件更新为：

```ts
import express from "express";
import { auth } from "./auth.js";
import { ticketsRouter } from "./routes/tickets.js";

const app = express();
app.use(express.json());              // 解析 JSON 请求体，req.body 才有值

app.get("/api/health", (_req, res) => res.json({ ok: true }));
app.use("/api", auth);                // health 之外的 /api 全要登录
app.use("/api/tickets", ticketsRouter);

app.listen(3000, () => console.log("server on http://localhost:3000"));
```

注意挂载顺序：`express.json()` 在最前（body 解析是所有路由的前提），health 在 auth 之前（健康检查不该要登录，监控探针可没有 token）。**中间件的顺序就是安全的顺序**，挂错位置等于给保险箱装了门却忘了锁。

## 错误处理：给意外兜底

路由里抛异常会怎样？Express 默认返回一坨 HTML 错误页，前端 JSON 解析直接炸。统一兜底：

```ts
// 放在所有路由挂载之后、listen 之前
app.use((err: Error, _req, res, _next) => {
  console.error("未捕获异常:", err);
  res.status(500).json({ error: "服务器开小差了，请稍后再试" });
});
```

四个参数的错误处理中间件（Express 靠参数个数认它）：任何环节抛错或被 `next(err)` 传递，都会落到这。对前端永远返回统一 JSON，内部细节只进服务端日志——和「错误信息的双重身份」同理，堆栈不该出门。

## 验收：curl 走一遍

M1 验收清单，逐条跑：

```bash
# ① 无 token，应 401
curl -i http://localhost:3000/api/tickets

# ② 提交工单，应 201 并返回 id
curl -X POST http://localhost:3000/api/tickets \
  -H "Content-Type: application/json" -H "x-token: emp-token" \
  -d '{"title":"VPN 连不上","description":"从今早开始 VPN 一直转圈"}'

# ③ 空标题，应 400 且提示「标题不能为空」
curl -X POST http://localhost:3000/api/tickets \
  -H "Content-Type: application/json" -H "x-token: emp-token" \
  -d '{"title":"","description":"x"}'

# ④ 我的列表，应看到刚提交的工单
curl http://localhost:3000/api/tickets -H "x-token: emp-token"

# ⑤ 详情，应看到完整记录；换个不存在的 id 应 404
curl http://localhost:3000/api/tickets/1 -H "x-token: emp-token"

# ⑥ admin 的列表应该是空的（它没提交过）——验证数据按用户隔离
curl http://localhost:3000/api/tickets -H "x-token: admin-token"

# ⑦ 用 admin 之外的身份访问别人的工单 id，应 403（IDOR 防线验证）
curl -i http://localhost:3000/api/tickets/1 -H "x-token: emp-token"   # 自己的，应 200
# 另起一个 token 模拟第二个员工访问 id=1，应 403
```

六条全过，M1 达成。顺手看一眼 `server/tickets.sqlite` 文件已经生成了——你的数据就在那儿，可以用任意 SQLite 工具打开围观。

## 常见坑位预告

这章的代码不长，坑都在细节上：

- **body 是 undefined**：十有八九是 `express.json()` 没挂或挂在路由后面，或者请求忘了带 `Content-Type: application/json` 头。
- **改了 db.ts 不生效**：tsx 不会自动重启，开发期建议 `npx tsx watch`（改动自动重跑）。注意 watch 重启会丢内存数据——但我们的数据在 SQLite 文件里，重启安然无恙，这就是「数据不依赖进程内存」的好处。
- **Number(req.params.id)**：路径参数永远是字符串，`"1"` 和 `1` 在 SQL 里行为不同，转换别省。

## 小结

本章交付了不依赖 AI 的完整业务地基：tickets 表与「单一真相来源」的数据归属决策、better-sqlite3 的同步 API 与参数化语句、中间件管道上的鉴权、zod 边界校验、三个核心 API、统一错误兜底，以及一份可复跑的 curl 验收清单。

下一章是本模块的重心：LangGraph 工作流接入——分类、RAG、审批中断全部上线，工单提交从「占位 processing」变成真正的 AI 处理，SSE 把处理过程推到前端。

## 自测

1. 为什么对话消息不建表存业务库？详情页的消息从哪来？
2. 预编译语句解决了哪两个问题？字符串拼 SQL 的风险是什么？
3. `app.use("/api", auth)` 放在 health 路由之前会造成什么后果？
4. 400、401、403 三个状态码分别对应什么场景？

参考答案：1. 对话轨迹由 checkpointer 持久保存，业务库再存即双真相来源；详情页从图的 State 读取。2. 防 SQL 注入与重复编译开销；拼接会让用户输入成为 SQL 文本被执行。3. 健康检查也会被要求登录，监控探针无法访问，失去健康检查的意义。4. 400 请求数据不合法，401 未提供有效身份凭证，403 已认证但权限不足。
