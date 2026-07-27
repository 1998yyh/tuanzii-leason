# 第 4 章 工具调用与 Agent：LangChain 的天花板在哪里

> 一句话总结：给模型装上「手和脚」，手写一遍 Agent 循环看清机制，再用 createAgent 收口，最后认清线性链的边界和 LangGraph 存在的理由。

## 本章要解决的问题

前三章的模型能聊、能答、能查资料，但本质上是个「缸中之脑」：你说什么它接什么，它无法主动做任何事。它不知道现在几点，查不了实时汇率，更没法帮你在数据库里改一行数据。

本章给模型接上工具，让它能「做」事。更重要的是，我们会先**手写**一遍 Agent 的核心循环，把这个被传得很玄的机制拆到骨头里，然后再看框架怎么把它封装成一行调用。最后回答那个贯穿模块一的问题：LangChain 和 LangGraph 到底怎么分工。

## 工具：一个带说明书的三件套

对模型来说，工具（Tool）就是你写的一个普通函数，外加一份写给模型看的说明书。用 `tool()` 定义：

```ts
import { tool } from "@langchain/core/tools";
import { z } from "zod";

const add = tool(
  async ({ a, b }) => String(a + b),   // ① 执行体：真正干活的函数
  {
    name: "add",                        // ② 名字：模型点名用它
    description: "计算两个整数的和。任何加法需求都使用本工具，不要口算。", // ③ 说明书
    schema: z.object({                  // ④ 参数结构：zod 声明
      a: z.number().describe("第一个加数"),
      b: z.number().describe("第二个加数"),
    }),
  }
);
```

四个部分各司其职，其中 **description 和 schema 里的 describe 是写给模型读的**，不是注释。模型靠它们判断「该不该用这个工具、参数填什么」。说明书含糊，模型就会乱用或不用；说明书清楚，比如明确写上「不要口算」，行为就稳定得多。这是工具开发里最值得花心思的地方，比函数本身重要。

工具本身可以直接调用，跟普通函数没两样：

```ts
console.log(await add.invoke({ a: 1, b: 2 })); // "3"
```

### 工具设计的三个原则

写工具容易，写好工具是手艺。三条原则都是踩坑踩出来的：

1. **单一职责**。一个工具干一件事。「查询并计算汇率换算」不如拆成「查汇率」和「算乘法」——工具越原子，模型的规划空间越大，出错的环节也越好定位。
2. **参数尽量受约束**。能用枚举就不用自由字符串，能用数字就不用文本。schema 里的每个约束，都是在帮模型缩小犯错的范围。
3. **返回简洁的文本**。工具返回会原样进模型的上下文，又臭又长的 JSON 既烧 token 又干扰模型。只返回回答这个问题需要的信息，格式成一行能读完的文本。

## Tool Calling：模型不动手，它只下指令

一个必须建立的认知：**模型从来不直接执行工具**。真实流程是一来一回的协议：

1. 你把「工具清单（名字 + 说明书 + 参数结构）」随问题一起发给模型；
2. 模型判断后，返回一个结构化的**调用请求**：「请用 add，参数 {a: 19, b: 23}」；
3. 你的程序真正执行函数，把结果包装成一条消息回灌给模型；
4. 模型拿着结果，生成给用户的最终回答。

模型全程只产出文本（结构化的文本），执行发生在你的进程里。这个分工意味着：工具执行的权限、超时、错误处理都由你控制，这是安全边界，也是工程责任。

把工具「挂」到模型上，用 `bindTools`：

```ts
import { ChatOpenAI } from "@langchain/openai";

const model = new ChatOpenAI({
  model: "deepseek-v4-flash",
  apiKey: process.env.DEEPSEEK_API_KEY,
  configuration: { baseURL: "https://api.deepseek.com" },
});

const modelWithTools = model.bindTools([add]);
const ai = await modelWithTools.invoke("19 加 23 等于多少？");

console.log(ai.tool_calls);
// [ { name: "add", args: { a: 19, b: 23 }, id: "call_xxx", type: "tool_call" } ]
```

看到没有，模型没有回答「42」，它返回的是 `tool_calls`——一张待执行的工单。执行并回灌：

```ts
import { ToolMessage } from "@langchain/core/messages";

const result = await add.invoke(ai.tool_calls[0].args);          // 你的程序真正执行
const toolMsg = new ToolMessage({
  content: String(result),
  tool_call_id: ai.tool_calls[0].id,   // 用 id 把结果和工单对上号
});

const final = await modelWithTools.invoke([
  { role: "user", content: "19 加 23 等于多少？" },
  ai,        // 模型的工单消息也要回传，保持上下文完整
  toolMsg,   // 工具执行结果
]);
console.log(final.content); // "19 + 23 = 42"
```

`tool_call_id` 是对号入座的凭据：一次可能有多个工单，结果必须标明自己在回答哪张单。漏传 `ai` 那条消息是新手高频错误——模型会收到一个「不明所以的工具结果」，行为立刻变得古怪。

## 手写 Agent 循环：三遍看清机制

上面的流程只走了一轮。真实任务可能要连续调多个工具：查汇率 → 算金额 → 查库存。把「调用 → 看有没有工单 → 执行 → 回灌 → 再调用」写成循环，就是 Agent：

```ts
async function runAgent(question: string) {
  const tools = { add };                       // 工单上点名 → 实际函数
  const modelWithTools = model.bindTools([add]);
  const messages = [{ role: "user", content: question }];

  for (let step = 0; step < 8; step++) {       // 最大步数是保险丝
    const ai = await modelWithTools.invoke(messages);
    messages.push(ai);

    if (!ai.tool_calls || ai.tool_calls.length === 0) {
      return ai.content;                       // 没有工单了，循环结束
    }
    for (const call of ai.tool_calls) {
      const result = await tools[call.name].invoke(call.args);
      messages.push(new ToolMessage({
        content: String(result),
        tool_call_id: call.id,
      }));
    }
  }
  throw new Error("超过最大步数，Agent 可能陷入了死循环");
}

console.log(await runAgent("先算 19 加 23，再加上 100，是多少？"));
```

读三遍这段代码，它值得你读三遍。

第一遍看结构：整个 Agent 就是一个 for 循环加一个判断。没有魔法。

第二遍看状态：`messages` 数组是唯一状态，每一轮都把模型的工单和工具结果追加进去，下一轮模型能看到全部历史。Agent 的「思考过程」就是这条越来越长的消息轨迹。

第三遍看两个保护：最大步数是保险丝，防止模型陷入「一直调工具」的死循环烧光 token；循环退出条件由模型决定（不再下工单），这就是「模型自己决定下一步做什么」的确切含义——第 1 章那个 Agent 定义，在这里落了地。

这个「思考 → 调工具 → 观察结果 → 再思考」的循环有个学名，叫 **ReAct（Reasoning + Acting）**。现在市面上各种 Agent 框架，核心循环几乎都是它的变体。

## createAgent：把循环收口成一行

手写的循环有边界情况要处理：并行工单、工具报错、流式输出、循环保护。生产代码不该维护这些。v1 的 `createAgent` 把整套机制封装好：

```ts
import { createAgent } from "langchain";

const agent = createAgent({
  model,                 // ChatModel，不用自己 bindTools
  tools: [add],
  systemPrompt: "你是计算助手。需要计算时必须用工具，不要口算。",
});

const result = await agent.invoke({
  messages: [{ role: "user", content: "先算 19 加 23，再加上 100，是多少？" }],
});

const last = result.messages[result.messages.length - 1];
console.log(last.content); // "42 + 100 = 142，最终结果是 142。"
```

对照手写版：`createAgent` 内部就是我们刚写的那个循环（它建立在 LangGraph 之上，第 5 章会揭晓这意味着什么），但把循环控制、消息管理、错误处理都接管了。返回值里的 `messages` 是完整轨迹——每一轮思考、每张工单、每个工具结果都在里面，这对手写版要自己维护的东西，现在是免费的。

### 看一眼轨迹，调试 Agent 的基本功

Agent 行为不对劲时，第一件事是把轨迹打出来读：

```ts
for (const m of result.messages) {
  // getType() 返回消息的角色类型："human" / "ai" / "tool"，比 instanceof 判断写法省心
  const type = m.getType();
  const calls = m.tool_calls?.map((c) => `${c.name}(${JSON.stringify(c.args)})`);
  console.log(`[${type}]`, calls ?? m.content);
}
```

（一个 TypeScript 提示：`m.tool_calls` 只在 AI 消息上存在，上面用 `?.` 做了空值保护；如果你写严格的类型判断分支，用 `m.getType() === "ai"` 收窄后再取，编译器就不会抱怨。手写循环里的 `tools[call.name]` 动态索引同理——工具表是「名字到函数」的映射，TS 严格模式下可以声明成 `Record<string, typeof add>` 消除索引告警。）

输出大概是这样：

```text
[human] 先算 19 加 23，再加上 100，是多少？
[ai] ['add({"a":19,"b":23})']
[tool] 42
[ai] ['add({"a":42,"b":100})']
[tool] 142
[ai] 42 + 100 = 142，最终结果是 142。
```

模型分了两轮：先算 19+23，拿结果再算 +100。哪一步算错、哪一步说明书没被遵守，轨迹里一目了然。第 10 章的 LangSmith 就是把这件事做成了可视化平台，但 `console.log` 永远是你的第一工具。

## 多工具实战：汇率换算助手

单工具不过瘾，来个真实点的场景：用户问「100 美元现在值多少人民币」。这需要两个工具配合——查汇率、做乘法：

```ts
const getExchangeRate = tool(
  async ({ from, to }) => {
    // 教学示例：真实项目里这里调汇率 API（如 exchangerate.host）
    if (from === "USD" && to === "CNY") return "7.16";
    throw new Error(`不支持的币种对：${from}/${to}`);
  },
  {
    name: "get_exchange_rate",
    description: "查询两种货币之间的实时汇率。返回 1 单位 from 货币可兑换的 to 货币数量。",
    schema: z.object({
      from: z.string().describe("源币种，三位字母代码，如 USD"),
      to: z.string().describe("目标币种，三位字母代码，如 CNY"),
    }),
  }
);

const multiply = tool(async ({ a, b }) => String(a * b), {
  name: "multiply",
  description: "计算两个数的乘积",
  schema: z.object({ a: z.number(), b: z.number() }),
});

const agent = createAgent({
  model,
  tools: [getExchangeRate, multiply],
  systemPrompt: "你是货币换算助手。汇率必须调用工具查询，金额计算必须用工具，不要凭记忆估算。",
});

const r = await agent.invoke({
  messages: [{ role: "user", content: "100 美元现在值多少人民币？" }],
});
```

模型会自己规划出「先查汇率、再做乘法」的两步。注意 systemPrompt 里那句「不要凭记忆估算」——模型是见过汇率的，它会偷懒用训练数据里的旧数字，必须用指令明确禁止。工具型 Agent 的可靠性，一半在工具质量，一半在这类指令。

## 工具出错时，Agent 怎么办

上面的汇率工具里藏了一个 `throw new Error("不支持的币种对")`。如果用户问「100 火星币值多少人民币」，工具必然报错。接下来发生什么，直接决定你的 Agent 是「稳健」还是「崩溃」。

`createAgent` 默认会接住工具抛出的异常，把错误信息作为 `ToolMessage` 的内容回灌给模型。模型读到「不支持的币种对：MARS/CNY」后，通常能做出合理反应：告诉用户这个币种查不了，或者问用户是不是输错了。**错误信息因此有了双重身份：既是程序的异常，也是模型的输入。** 这带来一条实践准则：工具的错误信息要写得让模型能看懂——「不支持的币种对：MARS/CNY，目前仅支持主流法币」就比干巴巴的 `Error: invalid` 有用得多，模型能拿着它向用户解释，甚至自我修正参数重试。

这条准则反过来也成立：不该让模型知道的细节（堆栈、内部路径、数据库报错原文）不要塞进工具返回。该过滤的在工具内部过滤掉，这和你写 API 错误响应是同一个道理。

手写循环版要自己去实现这个兜底：把 `tools[call.name].invoke(...)` 包进 try-catch，出错时回灌错误文本而不是让循环崩掉。这正是「生产代码该用 createAgent」的原因之一——这些边界情况框架都替你处理了。

## 链还是 Agent：一个选择标准

学完 `createAgent`，容易产生一种冲动：什么都交给 Agent，让它自己规划。冷静点。链和 Agent 的取舍，本质是**确定性和灵活性的交换**：

- 步骤是死的、流程可预测（检索 → 总结 → 格式化），用链。每一步都在你掌控中，可测试、可调试、token 消耗稳定。
- 步骤取决于中间结果、路径事先写不出来（「根据用户问题决定查哪个系统」），用 Agent。你为灵活性付出的代价是：行为有随机性、轨迹可能绕路、token 消耗不可预测。

还有一条常被忽视：能用一个工具解决的，不要上 Agent。一个「查汇率」接口，直接函数调用就完了，套一层 Agent 只是让模型多一次犯错机会。Agent 的价值从「需要模型在多个工具间做选择、做多步规划」开始算起。

真实系统里两者是混着的：外层是确定的业务流程（链或图），其中某个环节内部是一个小 Agent。模块三的实战项目就是这种嵌套结构。

## Agent 的成本与延迟意识

用 Agent 还有一个账要会算。回头看手写循环：每一轮都是一次完整的模型调用，而且 `messages` 数组在每一轮里全量重发。一个走了 4 轮的 Agent 任务，消耗的 token 不是单次调用的 4 倍，而是 1+2+3+4 轮的累积——消息历史越滚越长，每轮都带着前面所有的工单和结果。

三个实操建议：

- **盯着 usage_metadata 看**。把每轮的 `input_tokens` 打出来，亲眼看看累积曲线，比任何说教都直观。
- **工具返回要瘦身**。前面说「返回简洁的文本」，成本维度再看一遍：工具返回的每个字，之后每一轮都会被重发。一个返回 2000 字 JSON 的工具，在多轮循环里会被反复计费。
- **步数上限是预算也是保险**。`createAgent` 建在 LangGraph 之上，可以在 `invoke` 时用第二个参数限制图的最大执行步数：`agent.invoke(input, { recursionLimit: 10 })`（2026-07-27 在 v1.5.4 上实测可用）。教学示例可以不设，上线代码必须设。失控的循环烧的是真金白银。

延迟同理：每一轮都是一次网络往返，4 轮就是 4 次串行等待。对延迟敏感的交互场景，要么减少规划步数，要么用流式把中间过程先吐给用户（第 9 章细讲）。

## LangChain 的天花板：线性链说不清的四种场景

到这里做个盘点。LCEL 链是直线（最多加并行分支），Agent 循环让模型有了自主性，看起来很圆满。但把需求再往前推一步，问题就来了：

**场景一：流程有确定的分支规则。** 比如客服系统：简单问题走 RAG 直接答，投诉必须转人工，涉及退款要走审批。这些分支条件是业务规则，不该由模型自由发挥。链能写条件分支，但「分支后各自又是多步流程、还可能合流」的表达就开始扭曲了。

**场景二：状态要跨轮持久。** 用户今天聊一半，明天接着说；服务重启，对话不能丢。手写版的消息数组活在内存里，进程一没全完。`createAgent` 也没替你做持久化。

**场景三：危险操作要人批。** Agent 决定「删除该用户的全部数据」——你敢让它直接执行吗？真实系统需要在特定节点暂停，等人确认再继续。线性循环里塞「暂停等人」非常别扭。

**场景四：多个 Agent 协作。** 一个查资料、一个写报告、一个审校，各司其职还要交接。循环套循环，状态在谁手里？怎么交接？手写很快失控。

这四个场景的共性是：**流程的拓扑结构本身变复杂了**——有分支、有循环、有暂停点、有多个执行者。直线管道天然表达不了拓扑。这正是 LangGraph 要解决的：把流程画成一张图（节点是步骤，边是流转规则），状态由图统一管理，暂停和恢复是图的原生能力。

## LangChain 与 LangGraph：一次说清异同

模块一收官，把两门框架的分工钉死。这张表值得收藏：

| 维度 | LangChain | LangGraph |
| --- | --- | --- |
| 定位 | LLM 应用的部件库 + 链式组合 | Agent 工作流的图编排引擎 |
| 核心抽象 | Runnable（水管）、pipe（连接） | State（状态）、Node（节点）、Edge（边） |
| 流程形态 | 直线为主，可并行分叉 | 任意拓扑：分支、循环、并行、合流 |
| 状态管理 | 随调用产生，随调用结束 | 一等公民：可持久化、可回放、可断点续跑 |
| 人工介入 | 需自行实现 | 原生 interrupt/resume |
| 关系 | `createAgent` 内部就构建在 LangGraph 上 | 节点内部大量使用 LangChain 部件 |

一句话：**LangChain 管「零件好不好用」，LangGraph 管「流程怎么流转」**。小应用单用 LangChain 足够；流程出现上面四种场景之一，就该上图了。两者不竞争，是上下层。

## 动手练习

1. 给汇率助手加第三个工具 `get_current_time`（返回当前时间），问它「两小时后的时间加 100 美元换算」，观察模型怎么规划三步。判据：打印轨迹，应看到 `get_current_time`、`get_exchange_rate`、`multiply` 三张工单按合理顺序出现。
2. 故意把 `multiply` 的 description 改成含糊的「处理数字」，重跑换算，观察模型行为怎么退化。判据：轨迹中 `multiply` 工单消失或参数明显错误，模型开始口算——体会说明书的价值。
3. 在手写循环里加一个「工具执行超时」保护（超过 5 秒视为失败并回灌错误消息），想想真实系统为什么需要它。判据：人为让某个工具 sleep 10 秒后，循环不崩溃，且模型收到超时说明并能向用户解释。

## 小结

本章拆穿了 Agent 的全部神秘性：工具是「函数 + 说明书」，Tool Calling 是「模型下单、程序执行」的协议，Agent 是「调用 → 判单 → 执行 → 回灌」的循环。手写一遍之后，`createAgent` 不再是黑盒。最后我们认清了线性链的边界：分支流程、持久状态、人工审批、多 Agent 协作，四种场景指向同一个答案——图。

模块一到此结束。你手里已经有了部件（三件套）、组合（LCEL）、知识（RAG）和行动（工具与 Agent）。模块二，我们进 LangGraph 的世界。

## 自测

1. 模型调用工具时，真正执行函数的是谁？这个分工的安全意义是什么？
2. `ToolMessage` 里的 `tool_call_id` 起什么作用？漏了会怎样？
3. 手写 Agent 循环的退出条件和保险丝分别是什么？为什么退出条件要交给模型？
4. 「LangGraph 会取代 LangChain」这个说法对吗？用两者的分工说明。

参考答案：1. 你的程序；模型只产出结构化调用请求，执行权限、超时、错误处理都在应用侧可控。2. 把执行结果和具体调用请求对号；漏了或多工单场景下模型无法对应结果与请求，行为错乱。3. 退出条件是模型不再返回 tool_calls；保险丝是最大步数。任务需要几步由模型根据中间结果判断，写死步数就失去了自主性。4. 不对；LangChain 提供部件与链式组合，LangGraph 提供图编排，`createAgent` 本身就构建在 LangGraph 上，节点内部也用 LangChain 部件，两者是上下层关系。
