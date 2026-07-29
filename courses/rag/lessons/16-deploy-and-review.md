# 第 16 章 联调、测试、部署与复盘

> 一句话总结：走完端到端联调与测试策略，用 Docker Compose 一键部署，然后复盘全部技术决策与扩展方向，为全课画上句号。

## 端到端联调：把四条旅程当验收单

功能都「实现」了，但联调要回答的是另一个问题：**缝对上了吗**。联调的方法论是把需求翻成四条完整旅程，每条从头走到尾，任何一步断掉都算不过。

联调之前先备好环境，别让「顺手测测」污染开发数据：用一个独立的浏览器隐私窗口（干净的 localStorage）、一份专门的测试文档集（三份不同格式的小文件，内容你烂熟于心，只有你知道正确答案，才能判断系统答得对不对）、一个独立的测试数据库（`DATABASE_URL` 指向 notesmind_test，联调数据不污染开发库）。

| 旅程 | 路径 | 通过标准 |
| --- | --- | --- |
| J1 文档导入 | 上传 MD/PDF/TXT 各一 → 状态流转 → 查库 | 三份全 ready，chunks 带 heading 与 1024 维向量 |
| J2 文档管理 | 列表查看 → 删除其中一份 → 再检索 | 列表正确；被删文档的块不再出现在检索里 |
| J3 语义问答 | 提问 → 流式答案 → 点引用 → 追问指代 → 问库外问题 | 答案忠实、角标可看原文、指代正确、库外拒答 |
| J4 对话历史 | 多轮对话 → 刷新页面 → 继续追问 | 历史完整，会话按活跃排序 |

第 15 章你用 Playwright 走过 J1+J3+J4 的自动化版本。手工把四条也走一遍——自动化覆盖的是「机器能断言的」，你的眼睛负责「看起来对不对」。每走完一条就在清单上打勾并记录实际观察，联调记录是复盘时的第一手材料。

## 联调排错：四个真实的翻车现场

联调期最高频的四类问题，每个都给出症状、病根和解法。

**现场一：本地好好的，上代理后答案不出来。** 症状：curl 直连后端流式正常，经过 nginx 后 token 攒十几秒一批到达。病根：nginx 默认开响应缓冲，SSE 的增量被攒在缓冲区里。解法：`location /api/` 里加 `proxy_buffering off;`，本章部署配置里已经带了这一行，它就是从这种事故里长出来的。

排查 SSE 问题有两个趁手的观察工具，联调期会反复用到。命令行用 `curl -N`：`-N` 关闭输出缓冲，事件一到就打印，「事件是一个个蹦还是一批批涌」一眼可辨——先裸连后端端口看流式是否正常，把「后端问题」和「中间层问题」切开。浏览器用 DevTools 的 Network 面板：点开 chat 请求，切到 EventStream 标签，每个 SSE 事件的时间和内容列得清清楚楚，前端解析对不对、后端发没发，两边各看各的。

**现场二：前端能开页面，调接口全 404。** 症状：页面正常，接口全挂。病根两种：开发期是 Vite 代理没配或后端没起；生产期是 nginx 的 `location /api/` 规则写错（注意 `proxy_pass http://backend:8000;` 不带尾斜杠时的路径转发规则，写错会把 `/api/chat` 转发成 `/chat` 导致后端 404）。排查顺序：先裸连后端确认服务本身，再查代理层。

**现场三：向量写入报 `expected 1024 dimensions, not 2048`。** 病根：换了 Embedding 模型或改了 `EMBEDDING_DIM`，和建表时的维度对不上。第 12 章的启动校验就是拦这个的，看到它启动即炸是防线在干活，不是故障。正确处理：统一维度后重建 chunks 表（存量向量作废，第 3 章的纪律）。

**现场四：PDF 能传但检索质量奇差。** 病根按概率排：扫描件没文本层（提取为空或极少）；提取文本带大量版式噪声（页眉页脚、多栏交错、Unicode 兼容字符）；表格被拆成无意义碎行。排查动作固定：把解析结果打印出来看（第 4 章的「先查块」纪律），文本烂就先修解析，别动检索参数。

**现场五：迁移报 `Failed query: CREATE TABLE "chunks" ... vector(1024)`。** 第 12 章那个坑的部署版回响：迁移文件里 `CREATE EXTENSION vector` 的顺序被改乱了，或者部署环境的数据库压根没装 pgvector 扩展（比如换了不带 pgvector 的 PostgreSQL 镜像）。解法：确认镜像（`pgvector/pgvector:pg16`）和迁移文件首行。

**现场六：重启后有一批文档永远「处理中」。** 第 13 章说过崩溃恢复，但前提是 `recoverStuckDocs` 真的在启动路径上被调用了。联调时故意在文档处理中重启一次服务，验证恢复逻辑真的活着：卡住的文档应被退回「待处理」。这个「故意制造崩溃」的动作叫故障演练，比读十遍代码更能确认恢复逻辑的存在。

## 测试策略：三层各有分工

个人项目也要测试，但要花对地方。先想清楚每层防什么：

| 层 | 防什么 | 成本 | 本项目配多少 |
| --- | --- | --- | --- |
| 纯逻辑单测 | 核心算法被改坏（分块、解析、融合） | 低 | 每个纯函数 2–4 例 |
| 接口测试 | API 契约被破坏（状态码、字段、错误文案） | 中 | 每个路由 1–2 例 |
| 端到端旅程 | 层与层接缝处的错（如响应式 bug） | 高 | 3–5 条核心旅程 |

三层分工：

**纯逻辑单测**（投入产出比最高）：分块器、解析器、RRF、组装器这些纯函数，脱离数据库和网络就能测。用 vitest：

```bash
npm install -D vitest
```

```ts
// tests/chunking.test.ts
import { describe, it, expect } from "vitest";
import { recursiveSplit, chunkSections } from "../src/chunking.js";

describe("recursiveSplit", () => {
  it("超长段落降级到句子切分", () => {
    const text = "甲".repeat(200) + "。" + "乙".repeat(200) + "。";
    const chunks = recursiveSplit(text, 120, 0);
    expect(chunks.every((c) => c.length <= 130)).toBe(true);
  });

  it("overlap 让下一块带上上一块结尾", () => {
    const text = "甲".repeat(100) + "\n\n" + "乙".repeat(100);
    const chunks = recursiveSplit(text, 120, 30);
    expect(chunks[1].startsWith(chunks[0].slice(-30))).toBe(true);
  });

  it("空文本不产生垃圾块", () => {
    expect(recursiveSplit("", 100, 0)).toEqual([""]);
  });
});
```

注意这三个用例的来历：第一个是分块器的核心承诺，第二个是第 13 章实测过的 overlap 行为，第三个是第 4 章修过的那个真实 bug。**每个修过的 bug 都应该留下一个测试**，这是回归的保险丝。

**接口测试**：起真实服务（连测试数据库），用 fetch 打接口。覆盖上传校验、文档 CRUD、会话 CRUD 这些确定性行为。问答接口的 LLM 依赖用第 14 章的 mock 思路换掉，测试的是链路的 plumbing，不是模型的智商。一个上传接口的用例长这样：

```ts
// tests/documents.api.test.ts（服务已在测试端口启动）
import { describe, it, expect } from "vitest";

const BASE = "http://localhost:8001";

describe("POST /api/documents", () => {
  it("拒绝不支持的格式并说明原因", async () => {
    const form = new FormData();
    form.append("file", new File(["x"], "evil.exe"));
    const resp = await fetch(`${BASE}/api/documents`, { method: "POST", body: form });
    expect(resp.status).toBe(400);
    expect((await resp.json()).error).toContain("不支持的格式");
  });

  it("上传 md 返回 pending 记录", async () => {
    const form = new FormData();
    form.append("file", new File(["# 标题\n\n正文内容"], "note.md"));
    const resp = await fetch(`${BASE}/api/documents`, { method: "POST", body: form });
    expect(resp.status).toBe(201);
    const doc = await resp.json();
    expect(doc.status).toBe("pending");
    expect(doc.format).toBe("md");
  });
});
```

注意接口测试断言的是**契约**（状态码、字段、错误文案），不是实现。契约不变，里面怎么重构测试都不动——这就是它护住的东西。

一个务实的投入顺序：先写纯逻辑单测（半天），再留一条 E2E 主旅程（一小时），接口测试按接口改动的频率补。

**端到端旅程测试**最后说，因为它的价值已经用事故证明过了。第 15 章那个 Playwright 脚本（上传 → 就绪 → 流式答案 → 多轮追问）就是你的第一条旅程，建议原样收进项目 `e2e/` 目录，大改动前跑一遍。跑法：起好前后端，`node e2e/journeys.mjs`，全绿才算改完。它断言的不是代码，是「用户真的能用」——这是任何单测都给不了的信心。

## Docker Compose 一键部署

开发是「两个终端各起一个服务」，部署要收敛成一条命令。三个容器：数据库、后端、前端（nginx 托管静态文件并反代后端）。

```yaml
# docker-compose.yml
services:
  postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_PASSWORD: rag123
      POSTGRES_DB: notesmind
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      retries: 10

  backend:
    build: ./backend
    depends_on:
      postgres:
        condition: service_healthy   # 等数据库能连再启动
    environment:
      DATABASE_URL: postgres://postgres:rag123@postgres:5432/notesmind
      LLM_BASE_URL: ${LLM_BASE_URL}   # 从项目根目录 .env 读取，密钥不进镜像
      LLM_API_KEY: ${LLM_API_KEY}
      LLM_MODEL: ${LLM_MODEL}
      EMBEDDING_BASE_URL: ${EMBEDDING_BASE_URL}
      EMBEDDING_API_KEY: ${EMBEDDING_API_KEY}
      EMBEDDING_MODEL: ${EMBEDDING_MODEL}
      EMBEDDING_DIM: 1024

  frontend:
    build: ./frontend
    depends_on:
      - backend
    ports:
      - "8080:80"

volumes:
  pgdata:   # 数据卷：容器删了数据还在
```

三个编排细节：`healthcheck` + `condition: service_healthy` 解决启动顺序（后端先于数据库就绪启动会崩）；密钥走宿主机 `.env` 注入，不进镜像不进仓库；`pgdata` 数据卷让 `docker compose down` 之后数据还活着。

后端 Dockerfile（多阶段可以省，单阶段先跑迁移再起服务）：

```dockerfile
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm install tsx
COPY drizzle.config.ts ./
COPY drizzle ./drizzle
COPY src ./src
EXPOSE 8000
# 启动先跑迁移再起服务（单容器内顺序执行）
CMD ["sh", "-c", "npx drizzle-kit migrate && npx tsx src/index.ts"]
```

前端是两阶段构建：Node 里 `vite build` 出静态文件，换 nginx 镜像托管，最终镜像里没有 node_modules，几十 MB 而已。

```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npx vite build

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
```

nginx 配置（`frontend/nginx.conf`），两个知识点都在这：

```nginx
server {
  listen 80;

  location / {
    root /usr/share/nginx/html;
    try_files $uri /index.html;   # SPA 路由兜底：/chat/3 这种前端路由交给 Vue Router
  }

  location /api/ {
    proxy_pass http://backend:8000;
    proxy_buffering off;          # SSE 必须关缓冲，否则 token 攒批到达
    proxy_set_header Connection "";
    proxy_http_version 1.1;
  }
}
```

`try_files $uri /index.html` 是单页应用部署的经典配置：用户直接访问 `/chat/3` 时，服务器上没有这个文件，nginx 回退到 index.html，Vue Router 接管路由。没有它，刷新对话页就是 404。

在项目根目录放好 `.env`（真实密钥），一条命令：

```bash
docker compose up -d --build
```

第一次构建要几分钟（拉镜像、装依赖）。起来之后 `curl http://localhost:8080/api/health` 应该返回 ok。8080 是 nginx，它把 `/api` 反代给 backend 容器。打开 `http://localhost:8080` 就是完整应用。这套配置已经过完整构建实测（compose 配置校验 + 三容器构建启动 + 健康检查通过，记录在学习档案）。

## 部署后的日常三件事

部署不是终点，是运维的起点。三件很快会碰到的事：

**更新代码**：改完代码重新 `docker compose up -d --build`，compose 只重建有变化的镜像（层缓存生效时几十秒）。数据库迁移在 backend 启动命令里自动跑——schema 演进和代码发布永远同步，这是把 `migrate` 放进启动命令的红利。

**备份数据**：个人笔记数据全在 pgdata 卷里，定期 `docker exec notesmind-postgres-1 pg_dump -U postgres notesmind > backup-$(date +%F).sql` 就够。恢复是反向的 `psql < backup.sql`。uploads/ 目录里的原文如果在容器内，记得把它也挂成卷（部署配置留给你的一个练习）。

**看日志**：`docker compose logs -f backend` 跟踪后端，`docker compose logs --tail 100 postgres` 看数据库。容器化之后没有「登录服务器翻文件」这回事，日志都走 stdout，compose 统一收集。

常用的 compose 命令收一张速查表，运维期会天天打交道：

| 命令 | 用途 |
| --- | --- |
| `docker compose up -d --build` | 构建并后台启动全部服务 |
| `docker compose ps` | 看各容器状态 |
| `docker compose logs -f backend` | 跟踪后端日志 |
| `docker compose restart backend` | 只重启后端（改配置后） |
| `docker compose down` | 停止并删除容器（数据卷保留） |
| `docker compose down -v` | 连数据卷一起删（慎用，数据全没） |

## 复盘：这套架构哪里会先到极限

项目做完了，更重要的问题来了：它会在哪里先撑不住？把关键决策逐个翻出来过堂，顺便把模块二埋的扩展点全部回收。

**pgvector 什么时候不够？** 现在的量级（几千块）毫无压力。需要重新评估的信号：块数上百万、检索 QPS 过百、或者需要向量库层面的高级特性（量化压缩、多副本）。到时候迁移路径是清晰的：检索逻辑集中在 repository 一处，换专用向量库只动这层——分层的红利在迁移时才真正兑现。

**setImmediate 什么时候换 BullMQ？** 信号：一次传几十份文档（任务堆积）、处理耗时上到分钟级（崩溃概率变高）、或者想要失败自动重试。BullMQ + Redis 给任务持久化和重试，`ingestDocument` 的函数签名不用变，只是触发方式从 setImmediate 换成入队。

**什么时候加混合检索（第 7 章）？** 信号来自评估集：「精确标识符类」问题（型号、错误码、人名）的召回率明显拖后腿。接入点也清楚：`searchChunks` 旁边加一路 BM25（PostgreSQL tsvector 或第 7 章的手写实现），RRF 融合后替换现有单一排名。

**什么时候加重排（第 8 章）？** 信号：Recall@20 高但 Top3 命中率低，召回里有答案但排不进去。接入点：检索 K 从 5 放大到 30–50，过一道 reranker 再截 Top5。注意这会增加每次问答几百毫秒，阈值拒答可以顺势从「相似度距离」换成「重排分数」，判据更准。

重排的接入代码长什么样？在现有架构里，它只改 `chat` 服务的一个环节，其余一概不动，这就是当初把检索封装成独立函数的红利：

```ts
// services/chat.ts 的 ③④ 环节，从「Top5 + 距离阈值」升级为「Top30 → 重排 → Top5 + 重排阈值」
const hits = await searchChunks(qVector, 30);              // 候选放大到 30
const reranked = await rerank(rewritten, hits.map((h) => h.content)); // 第 8 章的本地 reranker
const top = reranked
  .map((score, i) => ({ ...hits[i], score }))
  .sort((a, b) => b.score - a.score)
  .slice(0, 5);
const relevant = top.filter((h) => h.score >= 0.3);        // 重排分数阈值，语义比距离清晰
```

混合检索的接法同构：`searchChunks` 旁边加一路 BM25 查询，RRF 融合两路排名后代替单一 `hits`，下游代码同样无感。好的架构不是预测了未来，而是给未来的改动留的是小切口。

**什么时候上 GraphRAG / Agentic（第 11 章）？** 个人笔记场景大概率永远不需要——答案集中在少数块、查询以自然语言为主。除非你的笔记库变成企业级知识中台，且全局性、多跳问题占比显著上升。

这张「信号 → 扩展点」对照表，就是第 10 章评估体系的存在意义：**没有信号，一个都别加**。

## 技术决策总账

最后把全课的七个关键决策放在一张表里过一遍——当时的理由是什么，现在的评价是什么：

| 决策 | 当时的理由 | 复盘评价 |
| --- | --- | --- |
| 手写全部 RAG 部件，不用框架 | 学习优先，拒绝黑箱 | 教学上完全正确；生产新项目可以重新评估框架，但你已懂得怎么选 |
| Express 而非更重的框架 | 熟悉度、中间件直观 | 个人项目恰好；团队大项目值得再评估 NestJS 的约束性 |
| pgvector 单库 | 级联一致、SQL 复用 | 本量级最优解；百万块以上再谈分家 |
| Drizzle + 原生 SQL 混用 | 类型安全 + 向量操作符直写 | 被验证最舒服的组合：CRUD 用 ORM，向量检索手写 SQL |
| setImmediate 进程内任务 | 零依赖讲清异步 | 教学目的达成；信号出现时按扩展表升级 BullMQ |
| 供应商可插拔配置 | 不绑定厂商 | 全课最有远见的决策之一——模型换代时只改 .env |
| 不实现混合检索与重排 | 评估先行，拒绝过度设计 | 纪律的样板：留好接入点，等评估集发信号 |

复盘的终极目的不是给项目打分，是让你看到：**每个决策都是当时约束下的合理选择，而不是永恒真理**。约束变了就重新决策——这比你背下任何「最佳实践」都重要。

## 全课收束：从三大硬伤到一个真项目

回到第 1 章。三个翻车现场——编造的 API、过期的新闻、答不出的报销制度——现在你有了一整套回答：RAG 用「检索 + 生成」把模型的知识边界从参数扩展到资料库，幻觉被引用溯源和拒答锁住，时效性被增量索引解决，私域知识被分块向量化收编。

十六个章节，你亲手写了 Embedding 实验、递归分块器、BM25、RRF、pgvector 索引、改写器、组装器，最后把它们熔进一个五章交付的完整应用。这套东西里最值钱的不是任何一段代码，而是两条工作方式：**每个部件都搞懂再用**（框架从此是你的工具而不是你的天花板），**每个优化都有评估撑腰**（badcase 指到哪，手术动到哪）。

RAG 这个领域还在快速演化，新变体每季度都有。但索引期/查询期的基本结构、检索与生成的分工、评估驱动迭代的方法，变化远比名词慢。你已经有了看懂任何新论文的底架。

## 你现在应该能做到的事

结课之前，拿这张清单做一次自评。每一条都对应课程的一个里程碑，打不出勾的地方就是该回头复习的章节：

- 向外行讲清 RAG 解决什么问题，以及它和微调、提示词工程的分工（第 1 章）
- 徒手画出索引期/查询期两条流水线并说清每个部件（第 2 章）
- 解释向量为什么能表示语义，余弦相似度在算什么（第 3 章）
- 为一种新文档类型设计分块策略并说出权衡（第 4 章）
- 用 pgvector 完成建表、相似度查询、HNSW 索引与 EXPLAIN 验证（第 5 章）
- 为一个检索 badcase 判断该用改写、扩展、HyDE 还是分解（第 6 章）
- 说明混合检索解决什么、RRF 为什么比加权融合稳（第 7 章）
- 说清两阶段检索的分工，知道重排救不了召回（第 8 章）
- 写出带引用、能拒答的 RAG Prompt，并分配 Token 预算（第 9 章）
- 给一个 RAG 系统设计评估集，用指标证明一次优化有效（第 10 章）
- 面对业务场景选出合适的 RAG 形态并算清成本账（第 11 章）
- 从零交付一个可部署的 RAG 应用并讲清每个决策（第 12–16 章）

课程配套的术语表放在课程首页的「参考资料」里，面试前翻一遍，比临时抱佛脚管用。

## 里程碑 4 验收清单

- [ ] 四条旅程手工全通
- [ ] `npx vitest run` 纯逻辑测试全绿
- [ ] `docker compose up -d --build` 一键起三容器，`localhost:8080/api/health` 返回 ok
- [ ] 8080 端口走完 J1–J4，SSE 经 nginx 流式正常
- [ ] 能向同事讲清「信号 → 扩展点」对照表的每一行

## 结课语

课程到这里就结束了。你的个人笔记助手可能还有毛边——UI 不够精致、没有重排、标题是截断的——但它是你从一个空目录开始，一个部件一个部件理解着搭出来的。让它陪你记录和学习，让它在你的真实笔记上暴露问题，然后用第 10 章的方法一个 badcase 一个 badcase 地收拾它们。那才是这门课真正的第 17 章，而且它没有句号。
