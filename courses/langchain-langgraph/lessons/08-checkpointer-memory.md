# 第 8 章 记忆与持久化：Checkpointer 让图记住一切

> 一句话总结：给图装上 Checkpointer，实现跨调用的多轮记忆、重启不丢的会话、可回放的历史快照，理解 Thread 隔离语义与长短期记忆分层。

## 从一个很痛的现状开始

第 7 章的图版 Agent 有个隐形的残疾，你可能已经察觉了：每次 `invoke` 都是一张白纸。用户说「我叫小王」，下一轮问「我叫什么」，Agent 一脸茫然——除非你像第 2 章那样手动维护消息数组，把全部历史塞给下一次调用。

手动维护能解决「多轮」，但解决不了「持久」：服务重启、容器漂移、 deploy 一次，内存里的会话全灭。对真实产品来说，「关掉进程就失忆」是致命伤。

本章的解法叫 **Checkpointer（检查点器）**。它的承诺一句话：**图的每一步执行完，框架自动把完整 State 存下来；下次带上同一个会话标识来调用，自动从上次的状态接着跑。** 多轮记忆、重启恢复、历史回放，都是这一个机制的衍生品。

## 术语地基：Checkpoint 与 Thread

**Checkpoint（检查点）**：图执行过程中某个时刻的完整状态快照——State 的全部字段、执行到了哪个节点、接下来该去哪。每推进一步，框架存一个。游戏里存档的概念，一模一样。

**Thread（线程/会话）**：一串检查点属于同一次连续对话或任务，这条线就叫 Thread，用 **Thread ID** 标识。同一时刻系统里可以有成千上万个 Thread：用户 A 的会话是一条，用户 B 的是另一条，工单 #1024 的处理流程也可以是一条。**Thread 是隔离单位**：A 的状态 B 永远看不到。

这两个概念一组合，持久化的全貌就出来了：调用时给 `thread_id`，框架就知道去哪个存档序列里取最新状态，执行完再把新检查点追加进去。

## 最小改造：两行代码获得记忆

拿第 7 章的消息图来改。改动只有两处：编译时挂 checkpointer，调用时给 thread_id：

```ts
import { StateGraph, MessagesAnnotation, START, END, MemorySaver } from "@langchain/langgraph";
import { AIMessage } from "@langchain/core/messages";

const graph = new StateGraph(MessagesAnnotation)
  .addNode("reply", async (state) => {
    // 节点逻辑一字不改——历史消息自动出现在 state.messages 里
    const ai = await model.invoke(state.messages);
    return { messages: [ai] };
  })
  .addEdge(START, "reply")
  .addEdge("reply", END)
  .compile({ checkpointer: new MemorySaver() });   // ① 挂上检查点器

// ② 调用时给会话标识
const config = { configurable: { thread_id: "user-42" } };

await graph.invoke({ messages: [{ role: "user", content: "我叫小王" }] }, config);
const out = await graph.invoke({ messages: [{ role: "user", content: "我叫什么？" }] }, config);
console.log(out.messages.at(-1).content); // "你叫小王。"
```

第二轮调用只传了新消息，但节点看到的 `state.messages` 里躺着完整历史——第一轮的消息被 checkpointer 存下，第二轮自动恢复并追加。节点代码一行没改，记忆是框架在图的边界上做的。

`MemorySaver` 把检查点存在内存里，适合开发和测试。它的价值是让机制透明可练，但进程一死照样失忆——别把它带上生产。

## SqliteSaver：重启也不丢的会话

生产入门级的选择是 `SqliteSaver`：检查点落进一个 SQLite 文件，进程重启、服务重部署都不丢。SQLite 是嵌进应用的文件数据库，不用装任何服务，一个文件就是全部数据。

```bash
npm install @langchain/langgraph-checkpoint-sqlite
```

```ts
import { SqliteSaver } from "@langchain/langgraph-checkpoint-sqlite";

const checkpointer = SqliteSaver.fromConnString("./checkpoints.sqlite");

const graph = new StateGraph(MessagesAnnotation)
  // ...节点和边不变
  .compile({ checkpointer });
```

验证持久化的方法很粗暴：跑一轮对话，**把进程杀掉，重启**，用同一个 thread_id 再聊——历史还在。这正是 checkpointer 设计的杀伤力所在：你的服务可以随时重启、可以水平扩到多个实例，会话状态不依赖任何单个进程的内存。

再往上是 `PostgresSaver`（包名 `@langchain/langgraph-checkpoint-postgres`，2026-07-27 核验 v1.0.x），面向多实例并发的生产环境；首次使用需按其文档执行建表。三者接口完全一致，切换只改构造那一行。选型口诀：开发用 Memory，单机上线用 SQLite，多实例用 Postgres。

## 检查点里到底存了什么

对一条聊了两轮的 thread（单节点图）拉一次 `getStateHistory`，实测（v1.4.8）会拿到 6 条快照，倒序返回、最新在前：

```text
#0  next=[]           messages=4 条   step=4   ← 第二轮 reply 执行完，流程走完
#1  next=["reply"]    messages=3 条   step=3   ← 第二轮的输入已写入，reply 待执行
#2  next=["__start__"] messages=2 条  step=2   ← 第二次 invoke 的输入写入点
#3  next=[]           messages=2 条   step=1   ← 第一轮 reply 执行完
#4  next=["reply"]    messages=1 条   step=0   ← 第一轮的输入已写入，reply 待执行
#5  next=["__start__"] messages=0 条   step=-1  ← 第一次 invoke 的输入写入点
```

读法：每次 `invoke` 先产生一个「输入写入」检查点（`next=["__start__"]`），然后流程每推进一步再产生一个——START 到 reply 是一步，reply 到 END 是一步。所以这张单节点图每轮对话攒 3 个检查点（1 输入 + 2 执行），两轮正好 6 条。`next` 告诉你「那一刻流程停在哪个节点前面」，`next=[]` 表示这轮已经走完。

## 历史快照：会话是可以回放的录像带

每个检查点都在，历史就能翻出来看：

```ts
const history = [];
for await (const snap of graph.getStateHistory(config)) {
  history.push(snap);
}
console.log(`这条 thread 有 ${history.length} 个检查点`);
console.log("最早的状态里有", history.at(-1).values.messages.length, "条消息");
```

每个快照（`snap`）里有三样东西值得认识：`values`（那一刻的完整 State）、`next`（那一刻接下来要执行的节点）、`config`（定位这个检查点的标识，含 checkpoint_id）。

能看历史，就能做两件大事：

**复盘调试**：用户投诉「Agent 第三步答非所问」，把那条 thread 的历史拉出来，逐个检查点看 State 演化，问题出在哪一步一目了然。这是日志之外的第二条调查通道，而且信息是结构化的。

**时间旅行**：从历史检查点分叉，让流程「从那一刻重新走」。比如审批被拒后不是从头再来，而是回到提交前那一刻换个方案继续。第 9 章讲完中断后，这个能力会派上真实用场。

## 崩溃恢复：持久化的另一张底牌

多轮记忆只是 Checkpointer 的一半价值，另一半是**故障恢复**。想象一个十步的工单处理流程，跑到第八步服务器崩了。没有 checkpointer，前七步的成果灰飞烟灭，用户只能重提工单从头再来；有了 checkpointer，流程停在第七个检查点上，服务恢复后从那里接着跑。

恢复的方式就是「带同一个 thread_id 再次调用」：

```ts
try {
  await graph.invoke(input, config);
} catch (e) {
  console.log("流程中断：", e.message);
  // 排查修复后，从最后一个检查点续跑——已完成的节点不会重跑
  await graph.invoke(null, config);
}
```

`invoke(null, config)` 的意思是「不喂新输入，从存档点继续」（第 9 章的静态断点恢复用的是同一个机制）。框架只执行「还没执行」的部分。这个性质有个学名叫**幂等恢复**，它成立的前提又回到那条老纪律：节点返回增量、框架合并——每一步的结果都被独立存档，重放哪一步、跳过哪一步才有据可依。

对长流程（批量处理、调研 Agent、代码审查），崩溃恢复不是锦上添花，是能不能上线的分水岭。一个跑 20 分钟的流程，你不会想因为它在第 19 分钟OOM 了就全部重来。

## 查看与修改当前状态

除了历史，当前状态也能直接读写：

```ts
// 读：当前状态 + 接下来要去哪
const state = await graph.getState(config);
console.log(state.values.messages.length, state.next);

// 写：手动修正状态（比如人工编辑了某条消息内容）
await graph.updateState(config, { messages: [new AIMessage("（人工修正后的回复）")] });
```

`updateState` 会在历史里追加一个新检查点，而不是篡改旧的——所有状态变化都留痕。这个「只追加、不篡改」的原则，是让回放和审计成立的关键设计。

## 短期与长期：记忆的两层

到这里你手里的是**短期记忆**：一条 thread 内的上下文。它跟着会话走，会话结束（或开新 thread）就归零。

真实产品还需要**长期记忆**：跨会话的用户偏好（「用户小王是 VIP」「他偏好简洁回答」）。LangGraph 为此提供 Store——一个独立于 thread 的键值存储，节点可以随时读写，不受会话边界限制。用法是给 compile 传入 store 实例，节点函数通过第二个参数访问。

本课不展开 Store 的细用（模块三实战会碰到再讲），但要建立分层的意识：**thread 内的用 Checkpointer，跨 thread 的用 Store，持久的业务数据用你自己的数据库**。三者不是替代关系。工单系统的工单记录永远该在业务库里，Checkpointer 管的是「处理这个工单的 Agent 流程走到哪了」。

## 成本意识：记忆不是免费的

多轮记忆爽归爽，账要算清。thread 里的消息只增不减，每一轮调用，全量历史都进模型的上下文——第 4 章算过的 token 累积账，在持久化加持下会滚得更久。一条聊了三天的 thread，第 100 轮时 input_tokens 可能已经是第一轮的几十倍。

三个控制手段，先记名字和适用时机：

- **截断**：只保留最近 N 条消息进模型，节点里自己切片。简单有效，代价是老消息被「遗忘」。
- **摘要**：定期让模型把早期历史压缩成一段摘要，替换原始消息。保留语义的压缩，成本是多一次模型调用。
- **显式开新 thread**：任务边界清楚时，新任务开新会话，物理隔离。

模块三实战里会给工单会话配上其中一种，到时候看真实选择。

## 动手练习

1. **给第 7 章的图版 Agent 接上 SqliteSaver**，跑两轮工具对话，杀进程重启，再追问一个依赖上文的问题。判据：重启后 Agent 记得第一轮的工具结果。
2. **隔离验证**：同一图、同一 checkpointer，用两个 thread_id 各聊一轮，互相问「我们刚才聊了什么」。判据：两条 thread 的答案互不串味。
3. **历史考古**：对一条聊了三轮的 thread 用 `getStateHistory` 数检查点个数，打印每个检查点的 `next`。判据：单节点图下每轮 invoke 产生 3 个检查点（1 输入写入点 + START 和 reply 两个执行点），三轮共 9 个；能在快照里指出哪个是「输入写入点」（参考「检查点里到底存了什么」一节）。

## 常见误区

**误区一：把 Checkpointer 当业务数据库。** 工单、订单、用户资料这些业务实体必须进业务库。Checkpointer 管流程状态，语义是「流程走到哪、中间数据是什么」，不是业务事实的存储。混用会在数据审计和迁移时吃苦头。

**误区二：thread_id 随便生成。** 用随机 UUID 当 thread_id 等于每次开新会话，记忆全废。thread_id 必须有业务含义：用户 ID、会话 ID、工单 ID——谁来聊、聊的是哪件事，标识就得跟着谁、哪件事。

**误区三：以为挂了 checkpointer 就有长期记忆。** 新 thread 一样是白纸。「记得这个用户上次聊过什么」是 Store 或业务库的事，不是 checkpointer 自动给的。

## 小结

本章给图装上了记忆：Checkpointer 按步存快照，thread_id 串起连续会话；MemorySaver 练手、SqliteSaver 落地、PostgresSaver 扛生产，接口统一；历史快照让会话可回放、可时间旅行；`getState`/`updateState` 提供读写通道。记忆分两层：thread 内靠 Checkpointer，跨 thread 靠 Store 和业务库。

下一章解决「危险操作要人点头」：interrupt 让图在指定位置暂停，等人审批完再从断点继续——持久化正是这一切的前提。

## 自测

1. Checkpoint 和 Thread 分别是什么？为什么说 Thread 是隔离单位？
2. MemorySaver 和 SqliteSaver 的能力差异在哪？验证后者价值的最直接实验是什么？
3. 「所有状态变化只追加、不篡改」这个原则支撑了哪两个能力？
4. 短期记忆和长期记忆分别由什么机制承担？工单系统的工单记录该放哪？

参考答案：1. Checkpoint 是某时刻的完整状态快照；Thread 是同一连续会话的检查点序列，以 thread_id 标识，不同 Thread 的状态互不可见，因而是隔离单位。2. 前者存内存、进程死即失，后者落 SQLite 文件、重启不丢；实验是聊一轮后杀进程重启，用同一 thread_id 继续，历史仍在即验证。3. 历史回放（复盘调试）和时间旅行（从历史点分叉重走）。4. thread 内短期记忆靠 Checkpointer，跨会话长期记忆靠 Store 或业务库；工单记录属于业务事实，必须放业务数据库。
