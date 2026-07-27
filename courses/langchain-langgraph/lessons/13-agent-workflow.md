# 第 13 章 后端 AI 内核：LangGraph Agent 工作流落地

> 一句话总结：把工单需求翻译成 State/Node/Edge，实现分类、RAG 应答、审批中断三条路径，接上 SqliteSaver 持久化，并通过 SSE 把 Agent 过程实时推给前端。

## 本章任务：让工单真正被 AI 处理

第 12 章的提交接口只是个占位的壳：工单入库，状态 `processing`，然后就没有然后了。本章把 LangGraph 工作流接进来，实现第 11 章设计的三条路径。验收标准（里程碑 M2）：咨询类工单得到基于知识库的回复；退款工单停在待审批，管理员批准后执行；追问时前端能收到流式过程。

这是全课最重要的一章——前十章的每一块积木，都会在本章找到它在真实系统里的位置。

## State 定义：混合形态的实战

`server/src/agent/state.ts`，第 10 章预告过的混合 State 落地：

```ts
import { Annotation, addMessages } from "@langchain/langgraph";
import type { BaseMessage } from "@langchain/core/messages";

export const TicketState = Annotation.Root({
  // 业务字段：流程的骨架
  ticketId: Annotation<number>({ reducer: (_c, u) => u, default: () => 0 }),
  category: Annotation<string>({ reducer: (_c, u) => u, default: () => "" }),
  // 消息字段：与模型交互的轨迹，追加语义
  messages: Annotation<BaseMessage[]>({ reducer: addMessages, default: () => [] }),
});

export type TicketStateType = typeof TicketState.State;
```

回看第 10 章的原则：classify 之后条件边读 `category`，所以它是业务字段；对话历史喂给模型，所以进 `messages` 用追加 reducer。thread 维度的多轮对话意味着 `messages` 会随每次追问不断累积——这正是 checkpointer 要存的东西。

## classify 节点：结构化输出的第二战场

分类是流程的咽喉：分错类，后面全错。用第 2 章的 `withStructuredOutput` 拿受约束的输出，别让自由文本进条件边：

```ts
// server/src/agent/nodes.ts
import { ChatOpenAI } from "@langchain/openai";
import { z } from "zod";
import type { TicketStateType } from "./state.js";

const model = new ChatOpenAI({
  model: "deepseek-v4-flash",
  apiKey: process.env.DEEPSEEK_API_KEY,
  configuration: { baseURL: "https://api.deepseek.com" },
  temperature: 0,
});

const CategorySchema = z.object({
  category: z.enum(["consult", "refund", "other"]).describe(
    "consult=制度/使用咨询，可用知识库回答；refund=涉及退钱；other=其他一切"
  ),
});

const classifier = model.withStructuredOutput(CategorySchema);

export async function classify(state: TicketStateType) {
  const last = state.messages.at(-1);
  const result = await classifier.invoke([
    { role: "system", content: "你是工单分类器，只输出分类结果。涉及退款、退钱、退费一律 refund；询问制度、流程、使用方法一律 consult；其余 other。" },
    { role: "user", content: String(last?.content ?? "") },
  ]);
  return { category: result.category };
}
```

两个工程细节。一是 enum 的取值和条件边的路由标签严格同名，schema 的 describe 就是给模型的分类说明书——第 4 章「说明书质量决定行为稳定性」在这里同样适用。二是追问也会过 classify：员工在退款工单下追问「进展如何」，分类器可能判成 consult——这是合理的，追问本来就该重新判断该谁来答。图的每一轮都是独立完整的一次执行，状态靠 thread 延续，判断不缓存。

## consult 节点：知识库加载与 RAG

知识库在启动时建索引，常驻内存。`server/src/agent/knowledge.ts`：

```ts
import { readdir, readFile } from "node:fs/promises";
import { Document } from "@langchain/core/documents";
import { RecursiveCharacterTextSplitter } from "@langchain/textsplitters";
import { OpenAIEmbeddings } from "@langchain/openai";
import { MemoryVectorStore } from "@langchain/classic/vectorstores/memory";

export async function buildRetriever() {
  const files = await readdir("knowledge");
  const docs: Document[] = [];
  for (const f of files.filter((f) => f.endsWith(".md"))) {
    const text = await readFile(`knowledge/${f}`, "utf8");
    docs.push(new Document({ pageContent: text, metadata: { source: f } }));
  }

  const splitter = new RecursiveCharacterTextSplitter({ chunkSize: 300, chunkOverlap: 50 });
  const chunks = await splitter.splitDocuments(docs);

  const embeddings = new OpenAIEmbeddings({
    model: "text-embedding-3-small",
    apiKey: process.env.OPENAI_API_KEY,
  });
  const store = await MemoryVectorStore.fromDocuments(chunks, embeddings);
  return store.asRetriever(3);
}
```

这就是第 3 章的完整链路搬到服务端，只有一个新观念：**索引的构建时机是应用启动**，不是每次请求。Embedding 要花钱要耗时，启动时建一次、常驻内存复用，查询时只做检索——第 3 章「索引期与查询期分离」在服务端的落地形态。

consult 节点本身：

```ts
import { ChatPromptTemplate } from "@langchain/core/prompts";
import { StringOutputParser } from "@langchain/core/output_parsers";
import { AIMessage } from "@langchain/core/messages";

const answerPrompt = ChatPromptTemplate.fromMessages([
  ["system", `你是服务台助手。只根据【资料】回答，资料里没有就说"知识库暂无相关规定，已为您转人工"。
【资料】
{context}`],
  ["human", "{question}"],
]);

export function makeConsultNode(retriever: ReturnType<typeof buildRetriever> extends Promise<infer R> ? R : never) {
  return async function consult(state: TicketStateType) {
    const question = String(state.messages.at(-1)?.content ?? "");
    const docs = await retriever.invoke(question);
    const context = docs.map((d) => `【${d.metadata.source}】${d.pageContent}`).join("\n\n");

    const chain = answerPrompt.pipe(model).pipe(new StringOutputParser());
    const answer = await chain.invoke({ context, question });
    return { messages: [new AIMessage(`根据知识库回答：\n${answer}\n\n（来源：${docs.map((d) => d.metadata.source).join("、")}）`)] };
  };
}
```

注意回复里带了来源文件——第 3 章「让回答带上出处」在产品里的样子。`makeConsultNode` 是个工厂函数：retriever 是启动时才建好的异步资源，节点函数需要它，用工厂把资源注进去。那个长类型注解看着唬人，意思就是「retriever 是 buildRetriever 的返回类型」；也可以简单写成 `(retriever: any)`，但 TS 项目里类型就是文档，值得。

## refundFlow 节点：interrupt 的正式上岗

```ts
import { interrupt } from "@langchain/langgraph";

export async function refundFlow(state: TicketStateType) {
  const question = String(state.messages.at(-1)?.content ?? "");

  // 第一步：AI 整理处理方案（无副作用，可安全重放）
  const plan = await model.invoke([
    { role: "system", content: "你是退款处理专员。根据用户描述，整理一份退款处理方案：涉及金额、原因、建议操作。简明列出。" },
    { role: "user", content: question },
  ]);

  // 第二步：中断，等人工审批。interrupt 之前的代码会在恢复时重放——所以这里只做"无副作用"的方案整理
  const approved = interrupt({
    type: "refund_approval",
    ticketId: state.ticketId,
    plan: String(plan.content),
  });

  // 第三步：审批结果决定走向（副作用发生在这里，只有通过才执行）
  if (approved === true) {
    // 真实系统：调用财务接口执行退款
    return { messages: [new AIMessage(`✅ 审批已通过，退款已执行。\n处理方案：${plan.content}`)] };
  }
  return { messages: [new AIMessage("❌ 审批未通过，退款申请已被驳回。如有疑问请联系服务台。")] };
}
```

第 9 章的纪律在这里全部用上了：`interrupt` 之前只做无副作用的方案整理（重放安全）；payload（方案内容）是给审批员的决策依据；真正的「执行」在审批通过之后才发生。审批员在审批中心看到的就是 payload 里的方案——AI 出方案，人做决策，机器执行。

## handoff 节点与图的总装

转人工最简单，登记并告知：

```ts
export async function handoff(_state: TicketStateType) {
  // 真实系统：写入人工队列、通知值班同事
  return { messages: [new AIMessage("已为您转接人工服务台，预计 2 小时内响应。工单进度可在本页面随时查看。")] };
}
```

`server/src/agent/graph.ts` 总装：

```ts
import { StateGraph, START, END } from "@langchain/langgraph";
import { SqliteSaver } from "@langchain/langgraph-checkpoint-sqlite";
import { TicketState } from "./state.js";
import { classify, makeConsultNode, refundFlow, handoff } from "./nodes.js";
import { buildRetriever } from "./knowledge.js";

export async function buildGraph() {
  const retriever = await buildRetriever();
  const checkpointer = SqliteSaver.fromConnString("checkpoints.sqlite");

  return new StateGraph(TicketState)
    .addNode("classify", classify)
    .addNode("consult", makeConsultNode(retriever))
    .addNode("refundFlow", refundFlow)
    .addNode("handoff", handoff)
    .addEdge(START, "classify")
    .addConditionalEdges("classify", (s) => s.category, {
      consult: "consult",
      refund: "refundFlow",
      other: "handoff",
    })
    .addEdge("consult", END)
    .addEdge("refundFlow", END)
    .addEdge("handoff", END)
    .compile({ checkpointer });
}
```

条件边用了映射表写法（第 7 章）：路由返回 enum 值，映射到节点名。checkpointer 和业务库并列的两个 `.sqlite` 文件，就是第 11 章架构图里「两个数据库」的物理形态。

## 提交接口改造：触发工作流

图的调用时机是「工单创建时」和「每次追问时」。改 `POST /api/tickets`：

```ts
ticketsRouter.post("/", async (req: AuthedRequest, res) => {
  const parsed = CreateTicketSchema.safeParse(req.body);
  if (!parsed.success) { /* 同第 12 章，略 */ return; }

  const info = insertTicket.run(parsed.data.title, parsed.data.description, req.user!.id);
  const ticketId = Number(info.lastInsertRowid);

  // thread_id 绑定工单：这个工单一生的对话与流程都在这条 thread 上
  const config = { configurable: { thread_id: `ticket-${ticketId}` } };
  const out = await graph.invoke(
    {
      ticketId,
      category: "",
      messages: [{ role: "user", content: parsed.data.description }],
    },
    config
  );

  if (out.__interrupt__) {
    // 中断即待审批：同步业务状态，返回给前端
    updateTicketStatus.run("refund", "pending_approval", ticketId);
    res.status(201).json({ id: ticketId, status: "pending_approval" });
    return;
  }
  updateTicketStatus.run(out.category, "done", ticketId);
  res.status(201).json({ id: ticketId, status: "done", reply: String(out.messages.at(-1).content) });
});
```

注意两个数据库在这一刻的协作：**LangGraph 管流程走到哪（checkpointer 自动存），业务代码管工单对外呈现什么状态（业务库手动更新）**。`__interrupt__` 是两边状态的同步点——检测到中断，就把业务状态刷成 `pending_approval`，审批中心的列表查的就是业务库。

`graph` 是启动时 `await buildGraph()` 建好、挂在模块级变量上的，全应用共享一份（retriever 和 checkpointer 都该单例，每请求新建等于每次重启对话还重复建索引）。

## 追问接口：SSE 把过程推出去

追问用 POST（带消息体），但要把过程流式推给前端——这就是 SSE 登场的时刻。

**SSE（Server-Sent Events）协议**一句话：HTTP 响应不结束，`Content-Type: text/event-stream`，服务端持续按 `data: <内容>\n\n` 的格式写数据块，前端持续收。它是纯文本协议，没有握手没有帧，就是「不关门的 HTTP 响应」。

```ts
ticketsRouter.post("/:id/messages", async (req: AuthedRequest, res) => {
  const ticket = getTicketById.get(Number(req.params.id));
  if (!ticket) { res.status(404).json({ error: "工单不存在" }); return; }
  // 第 12 章的 IDOR 防线在这里同样适用：只能追问自己的工单
  if (ticket.created_by !== req.user!.id && req.user!.role !== "admin") {
    res.status(403).json({ error: "无权操作他人的工单" });
    return;
  }
  const content = String(req.body?.content ?? "").trim();
  if (!content) { res.status(400).json({ error: "消息不能为空" }); return; }

  // SSE 三件套响应头
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",     // 禁止任何中间层缓存这个响应
    Connection: "keep-alive",
  });

  const config = {
    configurable: { thread_id: `ticket-${ticket.id}` },
    streamMode: "updates" as const,   // 第 9 章：updates 模式推节点增量
  };

  try {
    for await (const chunk of await graph.stream(
      { messages: [{ role: "user", content }] },
      config
    )) {
      res.write(`data: ${JSON.stringify(chunk)}\n\n`);   // 每个节点增量就是一个事件
    }
  } catch (e) {
    res.write(`data: ${JSON.stringify({ error: "处理出错，请重试" })}\n\n`);
  }
  res.write("data: [DONE]\n\n");   // 约定的结束信号，前端据此收尾
  res.end();
});
```

和第 9 章 `for await` 消费流的区别只在出口：那里打印到控制台，这里 `res.write` 推给浏览器。updates 模式的 chunk 形如 `{ classify: { category: "consult" } }`、`{ consult: { messages: [...] } }`——前端据此渲染「⚙️ 分类完成 → ⚙️ 知识库回复完成」的过程提示和最终答复。

**为什么不用 EventSource**：浏览器原生 EventSource 只支持 GET，我们的追问必须 POST 带消息体。所以前端用 `fetch + ReadableStream` 手动解析 SSE（第 14 章实现）。这是 SSE 实践里最高频的坑，先记住结论：GET 流式用 EventSource，POST 流式用 fetch 手动解析。

## 审批接口：resume 的 HTTP 形态

审批员的两个接口：看待审批列表（查业务库），做审批决定（resume 流程）：

```ts
// approvals.ts
import { Router } from "express";
export const approvalsRouter = Router();

// 待审批列表：只有审批员能看
const listPending = db.prepare("SELECT * FROM tickets WHERE status = 'pending_approval' ORDER BY id");
approvalsRouter.get("/", (req: AuthedRequest, res) => {
  if (req.user!.role !== "admin") { res.status(403).json({ error: "需要审批员角色" }); return; }
  res.json(listPending.all());
});

// 审批决定
approvalsRouter.post("/:ticketId/decide", async (req: AuthedRequest, res) => {
  if (req.user!.role !== "admin") { res.status(403).json({ error: "需要审批员角色" }); return; }
  const ticketId = Number(req.params.ticketId);
  const approved = req.body?.approved === true;

  const config = { configurable: { thread_id: `ticket-${ticketId}` } };
  const out = await graph.invoke(new Command({ resume: approved }), config);

  updateTicketStatus.run("refund", "done", ticketId);
  res.json({ id: ticketId, status: "done", reply: String(out.messages.at(-1).content) });
});
```

第 9 章的 `Command({ resume })` 在这里找到了它的 HTTP 形态：审批员的点击变成一次 API 调用，API 调用把答案送回冻结的流程。thread_id 从 URL 参数重建——**thread_id 的业务含义设计（ticket-{id}）在此刻显出价值**：谁审批哪个工单，URL 说了算。

## 验收：M2 全流程

后端起好，按剧本走：

```bash
# ① 咨询类：reply 里应有知识库内容与来源文件
curl -X POST localhost:3000/api/tickets -H "Content-Type: application/json" -H "x-token: emp-token" \
  -d '{"title":"报销额度","description":"差旅住宿报销额度是多少？"}'

# ② 退款类：应返回 pending_approval
curl -X POST localhost:3000/api/tickets -H "Content-Type: application/json" -H "x-token: emp-token" \
  -d '{"title":"申请退款","description":"上月多扣了我 800 元团建费，申请退回"}'

# ③ 员工尝试审批，应 403
curl -X POST localhost:3000/api/approvals/2/decide -H "Content-Type: application/json" -H "x-token: emp-token" -d '{"approved":true}'

# ④ 管理员批准：reply 应显示已执行
curl -X POST localhost:3000/api/approvals/2/decide -H "Content-Type: application/json" -H "x-token: admin-token" -d '{"approved":true}'

# ⑤ 追问（SSE）：应看到逐条 data: 事件流出
curl -N -X POST localhost:3000/api/tickets/1/messages -H "Content-Type: application/json" -H "x-token: emp-token" -d '{"content":"那审批流程呢？"}'

# ⑥ 重启服务后再追问：历史还在（checkpointer 落盘验证）
```

`-N` 是 curl 关闭输出缓冲，看 SSE 必须加。六条全过，M2 达成——这个后端已经有了完整的 AI 处理闭环。

## 小结

本章是前十章的总装：混合 State、结构化输出分类、启动时建索引的 RAG、interrupt 审批（副作用在审批后）、SqliteSaver 绑定 ticket thread、SSE 推 updates 流、resume 的 HTTP 化。两个数据库的协作模式——框架管流程、业务管呈现，`__interrupt__` 做同步点——是本章最值钱的架构认知。

下一章前端：三个页面加 SSE 手动解析，让用户在浏览器里看到 Agent 的每一步。

## 自测

1. 为什么知识库索引在应用启动时构建而不是每次请求时？
2. refundFlow 里方案整理放在 interrupt 之前、退款执行放在之后，分别依据什么原则？
3. 业务库的 status 和 checkpointer 的流程状态为什么会不一致？在哪两个时刻同步？
4. 追问接口为什么必须 POST？这给前端带来了什么影响？

参考答案：1. Embedding 构建耗时费钱，属索引期工作；启动建一次常驻内存，查询期只做检索。2. interrupt 恢复时节点重放，之前的代码跑两遍，故只放无副作用操作；执行属副作用，必须在审批通过后才发生。3. 流程状态由框架自动维护，业务状态由业务代码手动更新，两者天然可能脱节；同步点是检测到 `__interrupt__` 时和审批 decide 完成时。4. 追问要携带消息体；POST 不能用 EventSource，前端需用 fetch + ReadableStream 手动解析 SSE。
