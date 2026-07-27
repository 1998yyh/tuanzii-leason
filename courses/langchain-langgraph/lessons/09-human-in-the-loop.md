# 第 9 章 人在回路：中断、审批与流式输出

> 一句话总结：用 interrupt/resume 让图在危险操作前暂停等人，掌握静态断点与动态中断的差异，以及 values/updates/messages 三种粒度的流式输出。

## 本章要解决的问题

第 4 章埋过一个雷：Agent 决定「删除该用户的全部数据」，你敢让它直接执行吗？当时没有答案。现在有了——第 8 章的持久化让「暂停」成为可能（状态存得住，才停得下），本章学习按下暂停键的两种方式，以及暂停期间用户看到的流式过程。

人在回路（Human-in-the-loop，HITL）是 Agent 从玩具变成产品的分水岭：**自主性越高的事让 Agent 干，风险越高的决定留给人。**

## interrupt：在节点里按下暂停键

`interrupt` 是 LangGraph 提供的函数，在节点内部调用。它做三件事：把当前执行冻结（靠 checkpointer 存好状态）、把你给的信息抛给调用方、等调用方带着答案回来，从冻结点继续。

```ts
import { StateGraph, Annotation, START, END, MemorySaver, interrupt, Command } from "@langchain/langgraph";

const State = Annotation.Root({
  action: Annotation<string>({ reducer: (_c, u) => u, default: () => "" }),
  approved: Annotation<boolean>({ reducer: (_c, u) => u, default: () => false }),
});

const graph = new StateGraph(State)
  .addNode("propose", () => ({ action: "删除全部测试数据" }))
  .addNode("approve", (state) => {
    // 执行到这里就冻结，把审批请求抛出去
    const answer = interrupt({ question: `批准执行「${state.action}」吗？` });
    // 下面这行要等调用方 resume 之后才会执行
    return { approved: answer === true };
  })
  .addEdge(START, "propose")
  .addEdge("propose", "approve")
  .addEdge("approve", END)
  .compile({ checkpointer: new MemorySaver() });

const config = { configurable: { thread_id: "approval-1" } };

// 第一次调用：跑到 interrupt 冻结，返回值里带着中断信息
const first = await graph.invoke({ action: "", approved: false }, config);
console.log(first.__interrupt__);
// [ { value: { question: "批准执行「删除全部测试数据」吗？" }, ... } ]
console.log(first.approved); // false——approve 节点还没走完

// 人看过之后给出答案，用 Command 带回去
const resumed = await graph.invoke(new Command({ resume: true }), config);
console.log(resumed.approved); // true——节点从冻结处继续跑完了
```

拆开看这个往返。**暂停时**：`invoke` 正常返回，但返回值里多了 `__interrupt__`，里面是你传给 `interrupt` 的 payload——这就是给前端/调用方的「审批卡片」数据。此刻 approve 节点只执行了一半，State 里是 `approved: false`。**恢复时**：`Command({ resume: 值 })` 作为输入再次调用，框架找到冻结的检查点，让 `interrupt(...)` 这个表达式「返回」你给的值，节点从那一行继续往下跑。

注意两个前提。一是**必须挂 checkpointer**，没有持久化就没有冻结点，`interrupt` 会直接报错。二是**恢复靠的是 thread_id**——必须是同一条 thread，框架才知道从哪个存档续命。这也解释了为什么本章排在第 8 章后面。

### interrupt 的正确使用姿势

`interrupt` 调用会重放它所在的节点：恢复时节点从头执行，跑到 `interrupt` 那一行直接拿到 resume 值。这意味着 `interrupt` 之前的代码会跑两遍。所以节点写法有讲究：**把有副作用的操作（写库、发请求）放在 interrupt 之后**，interrupt 之前只做无副作用的准备。上面的例子里，「提议」在 propose 节点，「审批」在 approve 节点，「真正执行删除」应该再拆一个节点放在 approve 之后——副作用节点只在审批通过后才进入，天然安全。

## 静态断点：interruptBefore

动态 `interrupt` 是「跑到这行代码才决定停」，还有一种静态的：编译时就声明「某某节点执行前必停」：

```ts
.compile({
  checkpointer: new MemorySaver(),
  interruptBefore: ["danger"],   // danger 节点每次执行前都暂停
});
```

暂停后用 `getState` 能看到 `next` 里躺着 `"danger"`——它在等你放行。放行方式是 `invoke(null, config)`：输入 null 表示「不喂新数据，从断点继续」。

两种中断怎么选：**审批逻辑是数据驱动的（只有高风险操作才要批）用动态 interrupt；流程规则是硬性的（这个节点永远要人过目）用静态断点。** 静态断点还能挂在别人的图上——你拿到一个现成 Agent，想在它的工具节点前加审批，不用改它的代码，`interruptBefore: ["tools"]` 就行。对应的还有 `interruptAfter`（节点执行后暂停），用法相同，需要「看结果再决定放不放行」的场景用它。

## 时间旅行：从历史的某个点重新来过

第 8 章的历史快照在这里派上用场。场景：审批人觉得 Agent 的提议不对，不是简单否决，而是想「回到提议之前，换个条件让它重新提议」。

做法是从 `getStateHistory` 里找到目标检查点，用它的 config 直接调用。先改一处 propose 节点：让它尊重输入里已有的 action，而不是无条件覆盖——否则分叉时喂进去的新方案会被节点自己的硬编码顶掉（这是时间旅行最容易踩的坑）：

```ts
const graph = new StateGraph(State)
  // state.action 已有值就沿用（分叉输入从这里生效），否则给默认方案
  .addNode("propose", (state) => ({ action: state.action || "删除全部测试数据" }))
  // ...其余同前
```

然后找到「propose 执行前」的那个检查点，从那一刻分叉：

```ts
for await (const snap of graph.getStateHistory(config)) {
  if (snap.next.includes("propose")) {
    // 从那一刻分叉：新输入的 action 会被 propose 沿用，审批问题随之改变
    await graph.invoke({ action: "只清理过期缓存", approved: false }, snap.config);
    break;
  }
}
```

这不是篡改历史——旧检查点都在，而是从旧点长出一个新分支。审计场景里这个性质很关键：你永远能回答「当时到底发生了什么」，同时允许「如果当时换个决定会怎样」。

## 流式输出：三种粒度各管什么

审批卡片、Agent 思考过程，最终都要呈现在用户面前。干等 `invoke` 返回的体验很糟，流式（streaming）让过程可见。图的 `stream` 支持三种模式，粒度从粗到细：

**values**：每推进一步，吐一次完整 State。适合「状态面板」式 UI——你能看到每个字段随执行变化：

```ts
for await (const state of await graph.stream(input, { ...config, streamMode: "values" })) {
  console.log("当前消息数:", state.messages.length);
}
```

**updates**：每个节点执行完，只吐这个节点造成的增量（哪个节点、更新了什么）。适合「进度条」式 UI——「正在检索」「正在调用工具」的逐步提示：

```ts
for await (const update of await graph.stream(input, { ...config, streamMode: "updates" })) {
  console.log(update); // { model: { messages: [...] } } 这样的节点增量
}
```

**messages**：最细，吐 LLM 的 token 流。打字机效果靠它，每条是「消息片段 + 元数据（来自哪个节点）」：

```ts
for await (const [chunk, meta] of await graph.stream(input, { ...config, streamMode: "messages" })) {
  process.stdout.write(chunk.content); // 模型逐 token 的输出
}
```

三种模式可以组合着传数组（`streamMode: ["updates", "messages"]`），各取所需。选择标准一句话：**给人看思考过程用 updates，给人看回答正文用 messages，给程序做状态同步用 values。** 模块三的工单前端会同时用到前两种。

## 完整实战：带审批的退款 Agent

把本章零件组装成一个像样的东西。需求：客服 Agent 处理退款请求，金额超过 500 元必须人工审批，审批通过才执行。

```ts
import { StateGraph, MessagesAnnotation, START, END, MemorySaver, interrupt, Command } from "@langchain/langgraph";
import { AIMessage, ToolMessage } from "@langchain/core/messages";
import { tool } from "@langchain/core/tools";
import { z } from "zod";

const refund = tool(
  async ({ orderId, amount }) => `订单 ${orderId} 退款 ${amount} 元已到账`,
  {
    name: "refund",
    description: "为指定订单执行退款",
    schema: z.object({ orderId: z.string(), amount: z.number() }),
  }
);

// 工具节点：超过 500 先中断审批，通过才执行
const callTools = async (state) => {
  const last = state.messages.at(-1);
  const results = [];
  for (const call of last.tool_calls ?? []) {
    if (call.name === "refund" && call.args.amount > 500) {
      const ok = interrupt({
        type: "approval",
        detail: `订单 ${call.args.orderId} 退款 ${call.args.amount} 元，超过 500 需审批`,
      });
      if (ok !== true) {
        results.push(new ToolMessage({ content: "审批未通过，退款已取消", tool_call_id: call.id }));
        continue;
      }
    }
    const result = await refund.invoke(call.args);
    results.push(new ToolMessage({ content: String(result), tool_call_id: call.id }));
  }
  return { messages: results };
};

// model 节点与第 7 章相同（bindTools([refund]) 后调模型），此处省略
```

这条链的完整图就是第 7 章的 Agent 图，只换了工具节点的内部逻辑。调用方的配合：

```ts
const out = await agent.invoke(
  { messages: [{ role: "user", content: "订单 A1001 退 800 元" }] },
  config
);
if (out.__interrupt__) {
  // 把 out.__interrupt__[0].value 渲染成审批卡片给用户
  const approved = await waitForUserDecision(); // 等用户点"批准/拒绝"，返回 boolean
  const final = await agent.invoke(new Command({ resume: approved }), config);
  console.log(final.messages.at(-1).content);
}
```

一套「模型提议 → 阈值判断 → 中断审批 → 条件执行 → 结果回灌」的完整闭环。模式是通用的：发邮件、改数据、调支付，任何「危险动作」都可以套这个模板。模块三里，它就是工单审批中心的后端原型。

## 动手练习

1. **审批拒绝路径**：给上面的退款 Agent 回复 `resume: false`，观察 ToolMessage 的内容和模型的后续反应。判据：模型读到「审批未通过」后能向用户解释退款未执行，而不是谎称已退。
2. **静态断点改造**：不用动态 interrupt，改用 `interruptBefore: ["tools"]` 给第 7 章的计算 Agent 加「所有工具调用都要人放行」。判据：每次工具执行前 `getState` 的 `next` 都是 tools，`invoke(null, config)` 后继续。
3. **流式对比**：对同一次 Agent 调用分别用 updates 和 messages 模式流式，对比输出内容。判据：能说出哪种模式适合做「正在调用 xxx 工具」的界面提示，哪种适合做回答正文。

## 常见误区

**误区一：interrupt 之前放副作用代码。** 恢复时节点重放，interrupt 之前的代码跑两遍——发两封邮件、扣两次款的事故就是这么来的。副作用一律放 interrupt 之后，或拆到后续节点。

**误区二：忘了 checkpointer。** `interrupt` 报错信息不太直白，新手常对着它发懵。记住因果链：中断靠冻结，冻结靠存档，存档靠 checkpointer。

**误区三：把 interrupt 当输入框用。** 它的设计意图是「审批/澄清」这类流程控制，不是常规的逐轮问答。普通多轮对话走 thread 自然延续就行，每轮都 interrupt 是把简单事情复杂化。

## 小结

本章补上了 Agent 产品化的关键一块：interrupt 让图能在危险操作前冻结，Command(resume) 带回答案从冻结点继续；静态断点适合硬性流程规则，动态中断适合数据驱动的审批；历史分叉实现时间旅行；values/updates/messages 三种流式粒度分别服务状态同步、过程提示和正文渲染。

下一章是模块二收官：多 Agent 协作、子图封装、LangSmith 观测和部署决策，然后进实战。

## 自测

1. `interrupt` 生效的两个前提是什么？缺了分别会怎样？
2. 为什么恢复执行时 interrupt 之前的节点代码会跑两遍？这条性质引出什么写法纪律？
3. 动态 interrupt 和静态断点 `interruptBefore` 各适合什么场景？
4. values、updates、messages 三种流式模式分别适合什么界面需求？

参考答案：1. 挂 checkpointer（否则无冻结点直接报错）与使用同一 thread_id 恢复（否则找不到存档）。2. 恢复时节点从头执行、到 interrupt 行直接取 resume 值；因此副作用代码必须放在 interrupt 之后或后续节点。3. 数据驱动、条件性审批用动态；规则硬性、或要给现成图外部加卡点用静态。4. values 做状态面板/程序同步，updates 做「正在做什么」的过程提示，messages 做回答正文的打字机渲染。
