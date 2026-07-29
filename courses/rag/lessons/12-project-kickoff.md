# 第 12 章 项目导览：需求、架构与工程初始化

> 一句话总结：读懂个人笔记助手的需求与架构决策，搭好四表数据模型和可运行的全栈骨架，前后端联通。

## 我们要做什么

模块三只有一件事：把前十一章学到的东西，变成一个真能跑的产品。先把它当真实项目对待——从需求开始。

**产品：个人笔记助手。** 你手里有一堆 Markdown 笔记、PDF 资料、TXT 摘录，想不起某条知识记在哪了，只能挨个文件翻。这个产品让你把文档灌进去，然后用自然语言提问，系统基于你自己的文档回答，还告诉你答案出自哪里。

核心功能四个，一个不多：

| 功能 | 描述 | 验收标准 |
| --- | --- | --- |
| F1 多格式文档导入 | 上传 Markdown / PDF / TXT，单文件 ≤ 10MB，自动进入处理流水线 | 三种格式各传一份，状态变为「就绪」 |
| F2 文档管理 | 文档列表（名称、格式、状态、时间）、删除（级联清理分块向量） | 删除后检索不再命中该文档 |
| F3 语义检索问答 | 提问 → 检索 → 流式回答，答案标注引用编号，可点击看原文 | 事实性问题答得对，流式逐字出现，引用能定位原文 |
| F4 对话历史管理 | 多会话列表、历史持久化、多轮追问（指代消解）、库外问题拒答 | 刷新页面历史还在；「那它呢」类追问正确 |

同样重要的是**不做什么**：不做多用户和登录（单用户本地应用）、不做笔记在线编辑（它是只读知识库加问答，不是笔记软件）、不做移动端适配（桌面 Web 优先）、不做混合检索和重排（第 16 章评估后再决定加不加——这是第 10 章的纪律，不是偷懒）。

范围刻意收敛，因为教学目标是在五章内交付**完整闭环**而不是功能大全。每一行代码你都要写、都要懂。

## 先走一遍完整旅程

动手之前，看看终点长什么样。五章之后，你将能在浏览器里走完这条路：

```mermaid
flowchart LR
  U["拖一份 PDF 进文档库"] --> S["状态标签：处理中 → 就绪"]
  S --> Q["对话页提问：<br/>「这份资料的核心结论是什么」"]
  Q --> A["答案逐字流出<br/>句末带 [1] [2] 角标"]
  A --> C["点击 [1]<br/>弹出原文片段与出处"]
  Q2["追问「那它建议怎么做呢」"] --> A2["系统理解「它」指什么<br/>继续带引用回答"]
```

每一步都对应前面章节的一项技术：状态流转是第 13 章的异步流水线，「逐字流出」是第 9 章的 SSE，角标是第 4 章埋的元数据加第 9 章的引用机制，指代消解是第 6 章的查询改写。这个项目没有一处是魔法。

## 架构总览与选型决策

```mermaid
flowchart LR
  subgraph FE["前端 Vue 3（浏览器）"]
    UI["文档库页 / 对话页"]
  end
  subgraph BE["后端 Express（Node.js）"]
    RT["routes<br/>HTTP 接口层"]
    SV["services<br/>业务逻辑（导入流水线、问答链路）"]
    RP["repositories<br/>数据访问"]
  end
  DB[("PostgreSQL 16<br/>+ pgvector")]
  LLM["LLM / Embedding 供应商<br/>（智谱 / OpenAI / 本地 Ollama）"]
  UI -- "HTTP / SSE" --> RT
  RT --> SV --> RP --> DB
  SV --> LLM
```

四个关键决策，每个都有明确理由：

**后端 Express + TypeScript。** 和前十一章示例同一语言，你的实验代码（分块器、BM25、改写器）可以直接搬进项目，零翻译成本。Express 是最广为熟悉的 Node Web 框架，中间件模型直观，教程资料遍地都是；Fastify、Hono 是同类替代，学会一个换谁都不难。版本基线：Express 5.2.1（2026-07-29 实测）。

**数据库 PostgreSQL + pgvector。** 第 5 章已经论证过：文档、块、会话、消息这些业务数据和向量放同一个库，删文档级联删向量是一个外键的事，元数据过滤就是普通 WHERE。个人量级（十万块以内）性能完全够。

**供应商可插拔。** 所有模型调用走 OpenAI 兼容协议，配置三件套（BASE_URL + API_KEY + MODEL）决定供应商——第 2 章的环境变量设计原样搬进项目。智谱是默认（国内直连、有免费档），换 OpenAI 或本地 Ollama 只改 `.env`。

**不用 LangChain 等编排框架。** 这是刻意决策。框架三行代码能拼出 RAG 链，但每个部件都被封装起来，你就只剩「会调」没有「懂」。本课的每个部件（分块、检索、改写、组装）都是你亲手写的——写完这个项目，框架对你来说将只是「可选的便利」，而不是「必需的黑箱」。

## 分层约定：每一层只管自己的事

后端代码按职责分五层，目录即架构：

```text
backend/src/
├── core/           # 基础设施：config（环境变量）、db（连接池）、llm（模型客户端）
├── models/         # 数据模型：Drizzle schema（四张表）
├── repositories/   # 数据访问：CRUD + 向量检索 SQL，只跟数据库打交道
├── services/       # 业务逻辑：ingest（导入流水线）、chat（问答链路），不直接碰 SQL
├── parsers/        # 文档解析器：md / pdf / txt 三个实现 + 统一接口
└── routes/         # HTTP 接口层：参数校验、调 service、返回响应
```

分层不是仪式感，它管的是**依赖方向**：routes 可以调 services，services 可以调 repositories，反过来一律不行。两条具体纪律：service 里不允许出现 SQL（数据访问全走 repository）；route 里不允许出现业务判断（它只负责 HTTP 世界的翻译）。这样做的好处第 13 章会切身感受到：解析器、分块器这些纯逻辑可以脱离 HTTP 单独测试，换数据库时业务代码一行不动。

## 数据模型：四张表

先看关系，再看代码：

```mermaid
erDiagram
  documents ||--o{ chunks : "级联删除"
  conversations ||--o{ messages : "级联删除"
  documents {
    bigint id PK
    text filename
    text format
    text status
    text error_msg
  }
  chunks {
    bigint id PK
    int document_id FK
    int seq
    text heading
    text content
    vector embedding
  }
  conversations {
    bigint id PK
    text title
  }
  messages {
    bigint id PK
    int conversation_id FK
    text role
    text content
    jsonb citations
  }
```

设计要点四个。`documents.status` 是状态机：`pending → processing → ready / failed`，上传即返回、后台慢慢处理，第 13 章的主角。`chunks` 挂 `document_id` 外键并带 `onDelete: cascade`，删文档时块和向量跟着消失——F2 的「级联清理」在数据库层面就解决了。`messages.citations` 用 `jsonb` 存引用的 chunk id 列表，结构灵活（以后想加 snippet 快照也不用改表）。`chunks.embedding` 是 `vector(1024)`，维度必须和你的 Embedding 模型一致。

完整 schema（`backend/src/models/schema.ts`），逐字段对照上面的图读：

```ts
import { pgTable, bigserial, text, integer, vector, timestamp, jsonb, pgEnum } from "drizzle-orm/pg-core";

// 文档处理状态机：pending → processing → ready / failed
export const docStatus = pgEnum("doc_status", ["pending", "processing", "ready", "failed"]);

export const documents = pgTable("documents", {
  id: bigserial("id", { mode: "number" }).primaryKey(),
  filename: text("filename").notNull(),
  format: text("format").notNull(),          // md | pdf | txt
  sizeBytes: integer("size_bytes").notNull(),
  status: docStatus("status").notNull().default("pending"),
  errorMsg: text("error_msg"),
  createdAt: timestamp("created_at").notNull().defaultNow(),
  updatedAt: timestamp("updated_at").notNull().defaultNow(),
});

export const chunks = pgTable("chunks", {
  id: bigserial("id", { mode: "number" }).primaryKey(),
  // 级联删除：删文档时它的块跟着消失，这是把向量和业务数据放同库的红利
  documentId: integer("document_id").notNull().references(() => documents.id, { onDelete: "cascade" }),
  seq: integer("seq").notNull(),              // 第几块（顺序）
  heading: text("heading"),                   // 所属标题（结构化切分记下）
  content: text("content").notNull(),
  tokenCount: integer("token_count").notNull().default(0),
  embedding: vector("embedding", { dimensions: 1024 }), // 维度必须和 EMBEDDING_DIM 一致
});

export const conversations = pgTable("conversations", {
  id: bigserial("id", { mode: "number" }).primaryKey(),
  title: text("title").notNull().default("新对话"),
  createdAt: timestamp("created_at").notNull().defaultNow(),
  updatedAt: timestamp("updated_at").notNull().defaultNow(),
});

export const messages = pgTable("messages", {
  id: bigserial("id", { mode: "number" }).primaryKey(),
  conversationId: integer("conversation_id").notNull().references(() => conversations.id, { onDelete: "cascade" }),
  role: text("role").notNull(),               // user | assistant
  content: text("content").notNull(),
  citations: jsonb("citations"),              // 引用的 chunk id 列表
  createdAt: timestamp("created_at").notNull().defaultNow(),
});
```

Drizzle 的写法基本就是「TypeScript 版的 SQL DDL」：`pgTable` 对 CREATE TABLE，`references` 对外键，`defaultNow()` 对 DEFAULT now()。它给你类型安全（`documents.id` 是 number，写错类型编译期就炸），又不遮挡 SQL 本身的样子——这是选它而不是更重 ORM 的原因。

## 工程初始化实操

理论讲完，开搭。先建仓库结构：

```bash
mkdir -p notesmind/backend/src/{core,models,repositories,services,parsers,routes}
mkdir -p notesmind/frontend
cd notesmind/backend
npm init -y
```

把 `package.json` 里加 `"type": "module"`，然后装依赖。这里记一下本课核验过的版本（2026-07-29 实测安装），新版本大概率兼容，遇到诡异报错先对版本：

```bash
# 运行时依赖：express 5.2.1、pg 8.22.0、drizzle-orm 0.45.2
npm install express pg drizzle-orm dotenv
# 开发依赖：drizzle-kit 0.31.10
npm install -D tsx typescript drizzle-kit @types/express @types/pg
```

四个运行时依赖的分工：`express` 是 Web 框架；`pg` 是 PostgreSQL 官方 Node 驱动（第 5 章见过）；`drizzle-orm` 是 ORM；`dotenv` 读 `.env`。`drizzle-kit` 是迁移工具，只活在开发期。

配置 `.env`（键名和第 2 章完全同源，加了一个数据库地址）：

```bash
DATABASE_URL=postgres://postgres:rag123@localhost:5432/notesmind
LLM_BASE_URL=https://open.bigmodel.cn/api/paas/v4
LLM_API_KEY=填你的Key
LLM_MODEL=glm-4.7-flash
EMBEDDING_BASE_URL=https://open.bigmodel.cn/api/paas/v4
EMBEDDING_API_KEY=填你的Key
EMBEDDING_MODEL=embedding-3
EMBEDDING_DIM=1024
```

数据库还是第 5 章那个 Docker 容器（没起的话 `docker start rag-pg`），新建一个项目专用库：

```bash
docker exec -i rag-pg psql -U postgres -c "CREATE DATABASE notesmind;"
```

然后是 core 层的两个文件。`src/core/config.ts` 集中读取环境变量，缺了立刻炸——配置错误要在启动时暴露，不要拖到第一个请求：

```ts
import "dotenv/config";

// 启动时集中读取并校验环境变量，缺了立刻报错，不让请求期才发现
function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`缺少环境变量 ${name}，请检查 .env`);
  return value;
}

export const config = {
  port: Number(process.env.PORT ?? 8000),
  databaseUrl: required("DATABASE_URL"),
  llm: {
    baseUrl: required("LLM_BASE_URL"),
    apiKey: required("LLM_API_KEY"),
    model: required("LLM_MODEL"),
  },
  embedding: {
    baseUrl: required("EMBEDDING_BASE_URL"),
    apiKey: required("EMBEDDING_API_KEY"),
    model: required("EMBEDDING_MODEL"),
    dim: Number(required("EMBEDDING_DIM")),
  },
} as const;
```

`src/core/db.ts` 建全局唯一的连接池（复习第 5 章：连接是贵重资源，池化复用）：

```ts
import pg from "pg";
import { drizzle } from "drizzle-orm/node-postgres";
import { config } from "./config.js";

// 全局共享一个连接池：连接是贵重资源，池化复用是后端标配
export const pool = new pg.Pool({ connectionString: config.databaseUrl });
export const db = drizzle(pool);
```

## 数据库迁移：以及一个必须最先创建的扩展

schema 写好了，让 drizzle-kit 把它变成迁移 SQL：

```bash
npx drizzle-kit generate
```

它读 `drizzle.config.ts`（下面给出）和 schema，在 `drizzle/` 目录生成一份 SQL 文件：

```ts
import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "postgresql",
  schema: "./src/models/schema.ts",
  out: "./drizzle",
  dbCredentials: { url: process.env.DATABASE_URL! },
});
```

打开生成的 SQL，四张表和一个 enum 都在，但**少了两样 pgvector 特有的东西**：`CREATE EXTENSION vector` 和 HNSW 索引——ORM 不管数据库扩展和索引，这是常态，得手写。编辑生成的 SQL 文件，**在文件最开头**加扩展，在**最末尾**加索引：

```sql
-- 文件最开头（必须在所有 CREATE TABLE 之前）：
CREATE EXTENSION IF NOT EXISTS vector;
--> statement-breakpoint

-- ……（drizzle 生成的建表语句）……

-- 文件最末尾追加：
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS chunks_embedding_hnsw ON chunks USING hnsw (embedding vector_cosine_ops);
```

为什么反复强调「最开头」？因为这个顺序是实测踩出来的：`CREATE EXTENSION` 写在文件末尾时，迁移执行到 `CREATE TABLE chunks（含 vector(1024) 列）`直接报错——`vector` 类型还不存在。扩展是类型的来源，必须先于任何使用它的地方。这个坑你大概率也会踩，踩了回来对这句报错：`Failed query: CREATE TABLE "chunks" ... "embedding" vector(1024)`。

执行迁移：

```bash
npx drizzle-kit migrate
```

验证（应该看到四张表和两个索引）：

```bash
docker exec -i rag-pg psql -U postgres -d notesmind -c "\dt"
docker exec -i rag-pg psql -U postgres -d notesmind -c "SELECT indexname FROM pg_indexes WHERE tablename='chunks';"
```

```text
 chunks | conversations | documents | messages   ← 四张表
 chunks_pkey
 chunks_embedding_hnsw                          ← HNSW 索引就位
```

## 后端最小启动与健康检查

写最小的路由和入口，让服务活起来。`src/routes/health.ts`：

```ts
import { Router } from "express";

export const healthRouter = Router();

healthRouter.get("/health", (_req, res) => {
  res.json({ ok: true, service: "notesmind", time: new Date().toISOString() });
});
```

`src/index.ts` 装配应用：

```ts
import express from "express";
import { config } from "./core/config.js";
import { healthRouter } from "./routes/health.js";

const app = express();
app.use(express.json());

app.use("/api", healthRouter);

app.listen(config.port, () => {
  console.log(`notesmind backend 已启动: http://localhost:${config.port}`);
});
```

启动并验证（真实输出）：

```bash
npx tsx src/index.ts
```

```text
notesmind backend 已启动: http://localhost:8000
```

```bash
curl http://localhost:8000/api/health
```

```json
{"ok":true,"service":"notesmind","time":"2026-07-29T03:42:47.439Z"}
```

后端活了。麻雀虽小，分层是全的：route（health）→ core（config、db）→ 数据库（连接池在第一次查询时才会真正建连）。

## 前端空壳与代理联通

后端能说话了，让前端也出生。`frontend/` 目录下：

```bash
npm init -y
npm install vue vue-router pinia
npm install -D vite @vitejs/plugin-vue typescript
```

版本基线：Vue 3.5.40、Vite 8.1.5（2026-07-29 实测）。四个文件撑起空壳。`vite.config.ts`（代理是重点，马上讲）：

```ts
import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

export default defineConfig({
  plugins: [vue()],
  server: {
    proxy: {
      // 开发期把 /api 代理到后端，前端代码里不用写死后端地址
      "/api": "http://localhost:8000",
    },
  },
});
```

`index.html` 和 `src/main.ts` 是 Vite + Vue 的标准出生证：

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>个人笔记助手</title></head>
<body><div id="app"></div><script type="module" src="/src/main.ts"></script></body>
</html>
```

```ts
import { createApp } from "vue";
import App from "./App.vue";

createApp(App).mount("#app");
```

`src/App.vue` 先只做一件事：调健康检查，把结果显示出来。

```vue
<script setup lang="ts">
import { ref, onMounted } from "vue";

const health = ref("正在连接后端……");

onMounted(async () => {
  try {
    const resp = await fetch("/api/health");
    const data = await resp.json();
    health.value = data.ok ? `后端已连接：${data.service}` : "后端异常";
  } catch {
    health.value = "连不上后端，请确认它已启动";
  }
});
</script>

<template>
  <h1>个人笔记助手</h1>
  <p>{{ health }}</p>
</template>
```

起两个服务（后端 `npx tsx src/index.ts`，前端 `npx vite`），浏览器打开 `http://localhost:5173`，看到「后端已连接：notesmind」，前后端正式联通。也可以直接用 curl 验证代理生效（实测）：

```bash
curl http://localhost:5173/api/health
# {"ok":true,"service":"notesmind",...}  ← 经 Vite 代理拿到了后端的响应
```

**为什么用代理而不是 CORS？** 浏览器有个安全规矩：页面向「别的源」（端口不同就算）发请求，默认被拦，除非后端显式配置 CORS 放行。开发期两条路：后端开 CORS，或让 Vite 把 `/api` 开头的请求转发给后端——对浏览器来说，它访问的始终是 5173 同一个源，规矩不触发。选代理的理由：前端代码里只写 `/api/...` 不写死地址，生产部署时前后端同源（nginx 托管前端并反代后端），代码一行不改，开发到生产无缝平移。CORS 不是没用——前后端真的要分域名部署时它是正解，第 16 章会再提。

## 启动时的维度校验

第 5 章埋的事故预防，现在落地：Embedding 模型换维度、表还是旧维度，写入直接炸。在 `src/index.ts` 的 listen 之前加一道静态校验：

```ts
// 启动防线：配置维度必须和 schema 维度一致（第 5 章的高频事故预防）
import { config } from "./core/config.js";

const SCHEMA_EMBEDDING_DIM = 1024; // 与 models/schema.ts 中 vector 维度保持一致
if (config.embedding.dim !== SCHEMA_EMBEDDING_DIM) {
  throw new Error(
    `EMBEDDING_DIM=${config.embedding.dim} 与数据表维度 ${SCHEMA_EMBEDDING_DIM} 不一致，` +
    `请修改 .env 或重建数据表（换维度必须重建索引，见第 3 章）`
  );
}
```

静态校验只能防「配置和表不一致」。更严格的版本会在启动时真实调一次 Embedding 接口探测实际维度，但那要求启动时 API 可用——本地开发可以接受，生产上网络抖动会让服务起不来。折中方案就是把这道静态校验放在启动路径上，把 API 探测做成一个独立的管理命令。工程里很多「严格」和「可用」的权衡都长这样。

## 里程碑 0 验收清单

对照检查，全绿才算完成本章：

- [ ] `docker exec -i rag-pg psql -U postgres -d notesmind -c "\dt"` 显示四张表
- [ ] chunks 表上有 `chunks_embedding_hnsw` 索引
- [ ] `curl http://localhost:8000/api/health` 返回 `{"ok":true,...}`
- [ ] `curl http://localhost:5173/api/health` 经代理返回同样结果
- [ ] 浏览器打开 5173 显示「后端已连接：notesmind」
- [ ] 把 `.env` 里 `EMBEDDING_DIM` 改成 512 再启动后端，看到维度不一致的明确报错（验完改回来）

## 小结与预告

本章你给项目打下了地基：需求边界（四个功能 + 四个不做）；四个架构决策（Express、pgvector 单库、可插拔供应商、不用框架）；五层分层约定与依赖方向；四表数据模型与级联设计；迁移的完整流程和「扩展最先建」的实测坑；前后端经 Vite 代理联通；启动时的维度防线。

下一章写项目的第一条大动脉：文档导入流水线。用户拖进来一个 PDF，从格式校验、三种解析器、递归分块（第 4 章的代码要兑现 overlap 承诺了）、批量 Embedding，到状态机流转和 pgvector 入库——索引期的工业化形态。
