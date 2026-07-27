# 第 6 章 第一张图：State、Node、Edge 实战

> 一句话总结：跑通最小可运行的图，掌握 State 的定义方式、Reducer 的合并语义和消息追加机制，建立「返回增量，框架合并」的肌肉记忆。

## 本章要解决的问题

第 5 章把概念讲完了：状态、节点、边。本章把它们变成代码。目标很具体：亲手建一张两个节点的图，跑通它，看清每一次状态是怎么变化的。学完你能回答一个 LangGraph 里最重要的问题：**节点的返回值是怎么进 State 的？**

## 最小闭环：两个节点一条边

先把环境补上。LangGraph 是独立的包：

```bash
npm install @langchain/langgraph
```

然后写第一张图。需求刻意简单到无聊：一个计数器，第一个节点加 1，第二个节点加 10，看结果是多少。

```ts
import { StateGraph, Annotation, START, END } from "@langchain/langgraph";

// ① 定义 State：字段、合并规则、初始值
const State = Annotation.Root({
  count: Annotation<number>({
    reducer: (current, update) => current + update,  // 合并规则：累加
    default: () => 0,                                 // 初始值
  }),
});

// ② 定义节点：输入 State，返回增量
const step1 = () => ({ count: 1 });
const step2 = (state: typeof State.State) => {
  console.log("step2 看到的 count =", state.count);
  return { count: 10 };
};

// ③ 建图、连边、编译
const graph = new StateGraph(State)
  .addNode("step1", step1)
  .addNode("step2", step2)
  .addEdge(START, "step1")
  .addEdge("step1", "step2")
  .addEdge("step2", END)
  .compile();

// ④ 执行
const result = await graph.invoke({ count: 0 });
console.log("最终 count =", result.count);
```

运行结果：

```text
step2 看到的 count = 1
最终 count = 11
```

这段代码里的每一行都是新概念，下面逐个拆。先记住整体感觉：**定义状态 → 写节点 → 连边 → 编译 → 执行**，这是所有 LangGraph 程序的五步骨架，后面五章不过是给这个骨架不断加东西。

## State：字段、合并规则、初始值

`Annotation.Root({...})` 定义 State 的结构。每个字段三件事：

- **名字**：比如 `count`。节点返回值里的键，对应的就是这些字段名。
- **reducer（合并规则）**：节点返回 `{ count: 1 }` 时，框架怎么处理？是直接覆盖，还是跟现有值合并？规则由 reducer 决定，它接收「当前值」和「节点返回的增量」，返回新值。上面的 `(current, update) => current + update` 是累加，所以两个节点分别返回 1 和 10，最终是 11。
- **default（初始值）**：执行开始时字段的默认值。

`typeof State.State` 是 State 的 TypeScript 类型，给节点参数做标注用，编辑器的类型提示全靠它。

### Reducer 是最容易被忽视的核心

把 reducer 换成覆盖语义，结果立刻不同：

```ts
const State = Annotation.Root({
  count: Annotation<number>({
    reducer: (current, update) => update,   // 覆盖：后写的赢
    default: () => 0,
  }),
});
```

同样两个节点，最终 count 变成 10——step2 的返回值覆盖了 step1 的。**字段的语义不在节点里，在 reducer 里。** 同一个节点返回值，累加还是覆盖，是 State 设计的一部分。

为什么要理解得这么细？因为 LangGraph 的节点是独立执行的，并行场景下多个节点可能同时返回同一个字段的更新（第 7 章并行分支就会遇到）。没有 reducer，框架根本不知道该怎么合并。这也是第 5 章说的「返回增量而不是直接改」的兑现方式。

## START 与 END：两个特殊节点

`START` 是执行的入口，`addEdge(START, "step1")` 表示「从入口先进 step1」。`END` 是终点，流到这里执行结束。它们不是真实节点，是图结构的标记。

`invoke` 时传入的 `{ count: 0 }` 是初始 State（不传字段就用 default）。也可以只传部分字段，其余走 default。

## compile：从图纸到可执行程序

`.compile()` 把节点和边的定义变成一张可执行的图。编译期框架会做一些结构检查（比如从 START 出发不可达的节点），把一部分结构错误暴露在运行之前。但别对它期望过高：实测 v1.4.8 中，**条件边指向一个不存在的节点名，编译期不会报错，运行时也往往静默结束而不是明确异常**。所以「节点名和路由返回值对不齐」这类错误，编译器不替你兜底——这也是下一章给条件边配映射表的价值之一：标签和节点名的对应关系写在一处，好检查。

编译产物是个 Runnable。对，第 2 章那个 Runnable。所以 `invoke`、`batch`、`stream` 全套方法都能用，图和链在调用层面完全统一：

```ts
const out = await graph.invoke({ count: 0 });        // 单次
const outs = await graph.batch([{ count: 0 }, { count: 5 }]);  // 批量
for await (const chunk of await graph.stream({ count: 0 })) {  // 流式
  console.log(chunk);
}
```

流式输出默认按节点产出：每个节点执行完，吐一次当前状态。第 9 章会细讲流式的三种粒度。

## MessagesAnnotation：消息场景的标配 State

Agent 场景的 State 长什么样？核心就是一个不断追加的消息数组。这个需求太常见，LangGraph 直接给了现成的：`MessagesAnnotation`。

```ts
import { StateGraph, MessagesAnnotation, START, END } from "@langchain/langgraph";
import { AIMessage } from "@langchain/core/messages";

const graph = new StateGraph(MessagesAnnotation)
  .addNode("reply", (state) => {
    const last = state.messages.at(-1);
    return { messages: [new AIMessage(`你刚才说：${last.content}`)] };
  })
  .addEdge(START, "reply")
  .addEdge("reply", END)
  .compile();

const out = await graph.invoke({
  messages: [{ role: "user", content: "今天天气不错" }],
});
console.log(out.messages.length); // 2：用户消息 + AI 回复
```

注意节点返回的是 `{ messages: [新消息] }`——一个只含新消息的数组。`MessagesAnnotation` 给 messages 字段预置的 reducer 叫 `addMessages`，语义是**追加而不是覆盖**：新消息接到现有数组后面。所以最终数组里是「用户消息 + AI 回复」两条。

如果 reducer 是覆盖语义，AI 回复会把用户消息顶掉，对话就没法进行了。消息追加是 Agent 的地基，第 7 章的 Agent 循环、第 8 章的多轮记忆，都建立在它上面。

### addMessages 不只是「数组拼接」

它还有两条隐藏规则，先知道，后面会救你的命：一是按消息 id 去重更新（同 id 的消息会替换而不是重复追加），二是它同时接受消息对象和 `{ role, content }` 普通对象，自动转成标准消息。日常开发你先记住「返回新消息数组，框架负责追加」就够。

## State 设计实战：字段从哪来

新手建图最常见的卡壳不是语法，而是「State 里到底该放什么」。给一个可操作的方法：**把流程在心里跑一遍，每到一个节点问两句——它需要读什么？它干完活产出什么？所有答案的并集，就是 State 的字段。**

拿「文章润色流水线」练手：读初稿 → 语法检查 → 风格润色 → 输出终稿。

- 起点要读初稿：得有 `draft` 字段；
- 语法检查节点产出问题清单：得有 `issues` 字段；
- 润色节点要读初稿和问题清单，产出终稿：得有 `final` 字段；
- 想记录每个节点干过什么：加个 `log` 字段。

于是 State 是四个字段。再定语义：`draft` 和 `final` 覆盖语义（写新值替换旧的）；`issues` 看需求——只保留最新一次检查结果用覆盖，想累积用数组拼接；`log` 一定是拼接。字段、语义、默认值，一张表设计完：

| 字段 | 类型 | reducer 语义 | default |
| --- | --- | --- | --- |
| draft | string | 覆盖 | "" |
| issues | string[] | 拼接 | [] |
| final | string | 覆盖 | "" |
| log | string[] | 拼接 | [] |

还有一个反模式要避开：**把 State 当垃圾桶**。什么都往里扔，三个月后没人知道哪个字段谁在写。字段加入前先问「哪个节点读它」，没有读者的字段不加。State 是节点之间的合约，合约越短越好维护。

## Annotation 与 TypeScript：类型是怎么帮你的

`Annotation<number>({...})` 里的泛型参数是字段的 TS 类型，`typeof State.State` 则是整个 State 的类型。给节点参数标上它之后，写 `state.count` 有自动补全，写 `state.conut`（拼错）编译期就报错。字段多起来之后，这套类型提示是防呆主力，所以课程示例坚持标注，你也保持这个习惯。

一个容易困惑的点：`invoke({ count: 0 })` 传的是「初始值」，`default` 是「没传时的兜底」，节点返回的是「增量」。三个概念在代码里长得都像普通对象，但角色完全不同。初始值和 default 只在启动时生效一次；增量在每个节点结束后被 reducer 合并一次。

## 节点出错会怎样

节点是普通函数，函数就可能抛异常。默认行为是：**异常向上传播，整个 invoke 失败**，你能在调用处 try-catch 拿到原始错误。

```ts
const fragile = () => {
  throw new Error("外部服务超时");
};

try {
  await graph.invoke({ count: 0 });
} catch (e) {
  console.log("图执行失败：", e.message);
}
```

现在只要记住「失败会冒泡」这个默认。真实系统里的需求更细：某个节点失败时重试、失败后走备用路径、失败但不中断整体流程。这些都有对应的图级机制（重试策略、错误分支），属于生产化话题，第 10 章会讲设计标准。开发期的重要习惯是：节点抛错时，错误信息里写清楚「哪个节点、因为什么」——图里节点多，一句干巴巴的 `Error: timeout` 会让你排查到怀疑人生。

## 把第 2 章的链装进节点

节点函数里可以放任何代码，最自然的放法是 LangChain 部件。第 2 章的链直接变成节点：

```ts
import { ChatOpenAI } from "@langchain/openai";
import { ChatPromptTemplate } from "@langchain/core/prompts";
import { StringOutputParser } from "@langchain/core/output_parsers";

const model = new ChatOpenAI({
  model: "deepseek-v4-flash",
  apiKey: process.env.DEEPSEEK_API_KEY,
  configuration: { baseURL: "https://api.deepseek.com" },
});

const translateChain = ChatPromptTemplate
  .fromTemplate("把这句话翻译成英文：{text}")
  .pipe(model)
  .pipe(new StringOutputParser());

const graph = new StateGraph(MessagesAnnotation)
  .addNode("translate", async (state) => {
    const text = state.messages.at(-1).content;
    const translated = await translateChain.invoke({ text });
    return { messages: [new AIMessage(translated)] };
  })
  .addEdge(START, "translate")
  .addEdge("translate", END)
  .compile();
```

链负责「怎么翻译」，图负责「什么时候翻译、翻译完去哪」。零件和图纸的分工，在代码里就是这个样子。

## 看一眼图长什么样

结构定义是显式的，就能导出来看。编译后的图可以输出 Mermaid 源码（第 3 章见过的图格式）：

```ts
const drawable = graph.getGraph();
console.log(await drawable.drawMermaid());
```

打印结果类似：

```text
graph TD;
  __start__ --> step1;
  step1 --> step2;
  step2 --> __end__;
```

贴到任何 Mermaid 渲染器里就是一张流程图。图越复杂，这个能力越值钱——团队评审 Agent 流程时，你拿出的是图而不是代码。

## 动手练习

1. **三节点流水线**：在计数图上加第三个节点 `step3`，返回 `{ count: 100 }`，预测最终 count，再运行验证。然后把 `step1` 的 reducer 语义在脑子里换成覆盖，再预测一遍。判据：累加语义下是 111，覆盖语义下是 100。
2. **日志字段**：给 State 加一个 `log` 字段（字符串数组，reducer 用数组拼接），每个节点执行时追加一条「某某节点执行过」。判据：最终 log 里三条记录顺序与执行顺序一致。
3. **改写出错**：故意让某个节点返回 State 里不存在的字段名（比如 `{ conut: 5 }`），运行看结果。判据：执行**不报错**，但 State 里对应字段毫无变化——这是实测行为（v1.4.8），也是「状态没更新」类 bug 阴险的地方：拼错字段名不会有人提醒你。排查这类问题的习惯是打印节点返回后的 State，先核对返回的键名和 State 定义是否一字不差。

## 常见误区

**误区一：节点里直接改 state 参数。** `state.count = 5` 这样写不会生效（还可能引发诡异行为）。节点的契约是返回增量对象，合并是框架的事。

**误区二：默认值只想起来一半。** 常见症状是节点里读 `state.log.length` 报「读不到 length」——多半是字段没给 default，初始是 undefined。数组字段记得给 `default: () => []`。

**误区三：把全部业务逻辑塞进一个节点。** 一个节点干八件事，图就退化成了一行代码的包装，失去意义。节点的粒度按「一件可命名的事」切：调模型、执行工具、格式转换、业务判断。后面章节的分支、重试、观测都以节点为单位，切对了才接得住。

## 小结

本章把三要素落了地：State 用 Annotation 定义，字段语义在 reducer 里；节点是返回增量的函数；边用 START/END 连成结构，compile 出 Runnable。MessagesAnnotation 和 addMessages 给出了 Agent 场景的标配状态。五步骨架——定义状态、写节点、连边、编译、执行——是后面所有内容的模板。

下一章让图「活」起来：条件边做分支，节点互指成循环，用图重写第 4 章的 Agent。

## 自测

1. 节点的返回值经历了什么才变成 State 的一部分？reducer 的两个参数分别是什么？
2. 为什么 MessagesAnnotation 的 messages 字段必须用追加语义而不是覆盖语义？
3. `compile()` 除了「生成可执行图」还做了什么？这对开发有什么好处？
4. 为什么说「字段的语义在 reducer 里，不在节点里」？用 count 的累加与覆盖举例。

参考答案：1. 节点返回增量对象，框架对每个字段调用其 reducer，以「当前值、节点增量」算出新值。2. 对话需要完整历史，覆盖会让新回复顶掉历史消息，多轮对话无法成立。3. 做部分结构校验（如不可达节点），把这类结构错误暴露在运行之前；但它不校验条件边的目标节点名，别依赖它抓路由拼写错误。4. 同样的节点返回 `{ count: 1 }` 和 `{ count: 10 }`，累加 reducer 得 11，覆盖 reducer 得 10——结果由 reducer 决定，节点本身不承诺任何合并语义。
