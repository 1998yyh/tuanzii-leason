# 第 14 章 前端实现：页面、状态与 AI 交互体验

> 一句话总结：用 Vue 3 实现提交、列表、详情、审批四个界面，手写 fetch 版 SSE 客户端，把 Agent 的执行过程渲染成用户看得懂的体验。

## 本章任务：给用户一张脸

后端再强，员工不会用 curl 提工单。本章交付里程碑 M3：浏览器里完成全部角色操作——员工提交工单、看列表、进详情追问（看着 Agent 一步步处理）、审批员在审批中心点批准。前端技术栈：Vue 3 + Vite + vue-router，手写 CSS，不引组件库和 Pinia——焦点全部留给 AI 交互逻辑。

## 项目结构与两个基础件

`web/src` 下的最终结构：

```text
src/
├── main.ts            # 入口：挂路由
├── App.vue            # 布局：导航 + RouterView
├── router.ts          # 三个路由
├── api.ts             # HTTP 客户端 + SSE 解析（本章核心）
├── store.ts           # 类型与轻量共享状态
└── views/
    ├── SubmitView.vue  # 提交工单
    ├── ListView.vue    # 我的工单
    └── DetailView.vue  # 详情 + 对话 + 审批
```

先写两个基础件。`router.ts`：

```ts
import { createRouter, createWebHistory } from "vue-router";
import SubmitView from "./views/SubmitView.vue";
import ListView from "./views/ListView.vue";
import DetailView from "./views/DetailView.vue";

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: "/", redirect: "/submit" },
    { path: "/submit", component: SubmitView },
    { path: "/tickets", component: ListView },
    { path: "/tickets/:id", component: DetailView },   // :id 是路径参数
  ],
});
```

`main.ts`：`createApp(App).use(router).mount("#app")`。`App.vue` 放导航和两个 `RouterLink`，页面区放 `<RouterView />`——路由切到哪，对应的组件就渲染在哪。

### store.ts 与角色切换

视图引用的类型和共享状态集中在 `store.ts`：

```ts
// web/src/store.ts
import { reactive } from "vue";

export interface Ticket {
  id: number;
  title: string;
  description: string;
  category: string | null;
  status: string;
  created_by: string;
  created_at: string;
}

export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

// 轻量共享状态：module 级 reactive，任何组件 import 后读写同一份
export const store = reactive({
  role: "employee" as "employee" | "admin",
  pendingCount: 0,
});
```

`reactive` 和 `ref` 是表兄弟：ref 包单个值，reactive 包对象。模块顶层的 reactive 对象被多个组件 import 时，大家拿到的是同一份——这就是不要 Pinia 的底气：本项目跨页面共享的就「当前角色」和「待审批数」两样东西。

角色切换用它们串起来。教学项目没有登录页，在导航栏放两个按钮换 token（`App.vue` 的 script 部分）：

```ts
import { setToken } from "./api";
import { store } from "./store";

function switchRole(role: "employee" | "admin") {
  setToken(role === "admin" ? "admin-token" : "emp-token");
  store.role = role;
  location.reload();   // 教学项目的偷懒招：整页刷新让所有数据按新角色重拉
}
```

模板里两个按钮调它，再用 `store.role` 高亮当前角色。`location.reload()` 是砍需求的砍法——正规做法是各页面监听角色变化重新拉数据，但对本项目，刷新一次解决所有「旧角色数据残留」问题，简单且不会错。界面上把当前角色写清楚，学生跟练时才不会「我明明是管理员怎么 403」。

## api.ts：token 管理与 SSE 手动解析

前端所有请求要带 `x-token`。教学项目用预置 token 存在 localStorage（第 1 章的密钥戒律针对的是模型 API key，这里的 token 是应用自身的登录态，两回事）：

```ts
// web/src/api.ts
const TOKEN_KEY = "tp-token";

export function setToken(t: string) { localStorage.setItem(TOKEN_KEY, t); }
export function getToken() { return localStorage.getItem(TOKEN_KEY) ?? ""; }

export async function api<T>(path: string, options: RequestInit = {}): Promise<T> {
  const resp = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", "x-token": getToken(), ...(options.headers ?? {}) },
  });
  if (!resp.ok) {
    const body = await resp.json().catch(() => ({}));
    throw new Error(body.error ?? `请求失败：${resp.status}`);
  }
  return resp.json();
}
```

`api<T>` 是个泛型封装：调用处声明期望的返回类型，统一处理 token 头与错误格式。角色切换（员工/审批员）就是换 token 的事，页面上放个简单的切换按钮调 `setToken` 即可。

### SSE 解析：本章最硬的一段

第 13 章留的坑在这里填：追问是 POST，EventSource 用不了，只能 `fetch` 拿到响应体的字节流，自己按 SSE 协议解析。协议本身简单：事件之间空行分隔，数据行 `data: ` 开头。麻烦在于**字节流是随机切块到达的**——一个事件可能被拆在两次网络包里，必须缓冲拼接：

```ts
export async function streamSSE(
  path: string,
  body: unknown,
  onEvent: (data: unknown) => void
) {
  const resp = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-token": getToken() },
    body: JSON.stringify(body),
  });
  if (!resp.ok || !resp.body) throw new Error(`流式请求失败：${resp.status}`);

  const reader = resp.body.getReader();     // 拿到字节流的读取器
  const decoder = new TextDecoder();
  let buffer = "";                          // 没收完的半截事件留在这里

  while (true) {
    const { done, value } = await reader.read();  // 读下一块（块边界是随机的！）
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    const events = buffer.split("\n\n");    // 按事件边界切
    buffer = events.pop() ?? "";            // 最后一段可能不完整，留到下一轮
    for (const evt of events) {
      const line = evt.trim();
      if (!line.startsWith("data: ")) continue;
      const payload = line.slice(6);        // 去掉 "data: " 前缀
      if (payload === "[DONE]") return;     // 收到后端约定的结束信号
      onEvent(JSON.parse(payload));
    }
  }
}
```

逐段读懂它：`resp.body.getReader()` 把「一次性的响应」变成「可以反复 read 的流」；`TextDecoder` 的 `{ stream: true }` 处理多字节字符跨块（中文正好容易撞上）；`buffer` 是解决「事件被拆包」的关键——每次只处理完整事件，半截的留给下次。这段代码是通用的，任何 POST 流式接口都能用它，值得收进你的工具箱。

## 提交页：表单与错误呈现

`SubmitView.vue`，重点看 `<script setup>` 的写法：

```vue
<script setup lang="ts">
import { ref } from "vue";
import { useRouter } from "vue-router";
import { api } from "../api";

const router = useRouter();
const title = ref("");
const description = ref("");
const loading = ref(false);
const error = ref("");

async function submit() {
  error.value = "";
  if (!title.value.trim() || !description.value.trim()) {
    error.value = "标题和描述都要填";
    return;
  }
  loading.value = true;
  try {
    const r = await api<{ id: number; status: string }>("/api/tickets", {
      method: "POST",
      body: JSON.stringify({ title: title.value, description: description.value }),
    });
    router.push(`/tickets/${r.id}`);      // 提交成功跳详情页
  } catch (e) {
    error.value = (e as Error).message;   // 后端的 400 消息直接呈现
  } finally {
    loading.value = false;                // finally 保证按钮一定恢复
  }
}
</script>

<template>
  <h1>提交工单</h1>
  <form @submit.prevent="submit">
    <label>标题 <input v-model="title" /></label>
    <label>描述 <textarea v-model="description" rows="5"></textarea></label>
    <p v-if="error" class="error">{{ error }}</p>
    <button :disabled="loading">{{ loading ? "提交中…" : "提交" }}</button>
  </form>
</template>
```

Vue 的三个基本概念全在这了。`ref("")` 创建响应式变量，模板里 `v-model` 双向绑定输入框——用户打字，`title.value` 跟着变；代码改它，输入框跟着变。模板里的 `@submit.prevent` 是事件绑定（`.prevent` 阻止表单默认的整页刷新），`:disabled` 是属性绑定。`v-if` 控制元素存亡。

两个细节是经验：提交前置空 error、用 finally 恢复 loading——异步操作的「进行中」状态，忘了恢复就是把按钮永久禁用的经典 bug；后端返回的 400 消息直接展示，校验文案前后端只用写一套。

## 列表页：onMounted 与状态徽章

`ListView.vue` 的核心：

```vue
<script setup lang="ts">
import { onMounted, ref } from "vue";
import { api } from "../api";
import type { Ticket } from "../store";

const tickets = ref<Ticket[]>([]);
const error = ref("");

onMounted(async () => {
  try { tickets.value = await api<Ticket[]>("/api/tickets"); }
  catch (e) { error.value = (e as Error).message; }
});

const statusText: Record<string, string> = {
  processing: "处理中", pending_approval: "待审批", done: "已办结",
};
</script>

<template>
  <h1>我的工单</h1>
  <ul>
    <li v-for="t in tickets" :key="t.id">
      <RouterLink :to="`/tickets/${t.id}`">
        #{{ t.id }} {{ t.title }} <span class="badge">{{ statusText[t.status] ?? t.status }}</span>
      </RouterLink>
    </li>
  </ul>
</template>
```

`onMounted` 在组件出现在页面上之后执行，是拉取首屏数据的标准位置。`v-for` 循环渲染列表，`:key` 帮助 Vue 高效追踪每一项（用稳定 id，别用数组下标）。状态文案用映射表转换，数据库里的 `pending_approval` 在人界面上叫「待审批」——**存储用机器语言，界面用人话**，这层转换放在前端做。

## 详情页：把 Agent 过程变成用户体验

全章重心。用户在这个页面看到：工单信息、对话记录、Agent 的实时处理过程，还能继续追问。如果是待审批工单且当前是审批员，还会出现批准/拒绝按钮。

```vue
<script setup lang="ts">
import { onMounted, ref } from "vue";
import { useRoute } from "vue-router";
import { api, streamSSE } from "../api";
import type { Ticket, ChatMessage } from "../store";

const route = useRoute();
const id = Number(route.params.id);       // 读路径参数

const ticket = ref<Ticket | null>(null);
const messages = ref<ChatMessage[]>([]);
const activity = ref<string[]>([]);        // Agent 过程提示
const input = ref("");
const sending = ref(false);
const error = ref("");

onMounted(async () => {
  ticket.value = await api<Ticket>(`/api/tickets/${id}`);
  // 历史对话也可以从后端读（graph.getState），本练习留给你扩展
});

async function send() {
  const content = input.value.trim();
  if (!content || sending.value) return;
  input.value = "";
  sending.value = true;
  messages.value.push({ role: "user", content });   // 自己的消息先上屏
  activity.value = [];
  try {
    await streamSSE(`/api/tickets/${id}/messages`, { content }, (data) => {
      // updates 模式的增量：{ 节点名: { 更新的字段 } }
      const [nodeName, update] = Object.entries(data as Record<string, any>)[0];
      activity.value.push(`⚙️ ${nodeName} 处理完成`);
      const msgs = (update as any).messages;
      if (msgs?.length) {
        const text = msgs.map((m: any) => m.content ?? "").join("");
        if (text) messages.value.push({ role: "assistant", content: text });
      }
    });
  } catch (e) {
    error.value = (e as Error).message;
  } finally {
    sending.value = false;
  }
}
</script>

<template>
  <template v-if="ticket">
    <h1>#{{ ticket.id }} {{ ticket.title }}</h1>
    <p>{{ ticket.description }}</p>

    <div class="chat">
      <div v-for="(m, i) in messages" :key="i" :class="['msg', m.role]">{{ m.content }}</div>
      <div v-for="(a, i) in activity" :key="'a' + i" class="activity">{{ a }}</div>
      <div v-if="sending" class="activity">Agent 正在处理…</div>
    </div>

    <form @submit.prevent="send">
      <input v-model="input" placeholder="继续追问…" :disabled="sending" />
      <button :disabled="sending">发送</button>
    </form>
  </template>
</template>
```

这里的体验设计有两个刻意的选择。一是**用户消息先上屏**：不等后端确认，点击发送立刻看到自己的消息，界面的「跟手感」就是这么来的；失败了再提示。二是**过程提示与正文分离**：updates 流里的节点名（classify、consult）渲染成灰色的「⚙️」过程行，节点产出的消息渲染成正式回答——用户同时看到「它在干活」和「干活的结果」，这就是第 9 章说的 updates 模式的最佳用法。

对比一下就明白这有多重要：没有过程提示，用户面对的是一个转圈 5 秒的输入框，大概率刷新页面重来——而刷新意味着重复提交、重复扣费。**流式不是炫技，是留住用户注意力的必需品。**

## 审批中心：最小实现

审批员的界面可以很简单：待审批列表 + 每个卡片两个按钮。在 DetailView 上加一段（或单独一个 view，随你组织）：

```vue
<script setup lang="ts">
// 待审批列表数据（审批员角色进入时加载）
const pending = ref<Ticket[]>([]);
async function loadPending() {
  pending.value = await api<Ticket[]>("/api/approvals");
}
async function decide(ticketId: number, approved: boolean) {
  const r = await api<{ reply: string }>(`/api/approvals/${ticketId}/decide`, {
    method: "POST",
    body: JSON.stringify({ approved }),
  });
  messages.value.push({ role: "assistant", content: r.reply });  // 结果直接进对话流
  pending.value = pending.value.filter((t) => t.id !== ticketId); // 从待办里移除
}
</script>
```

审批员点「批准」的那一刻，串起的是一条很长的链：浏览器 POST → decide 接口 → `Command({ resume: true })` → checkpointer 取出冻结状态 → refundFlow 从 interrupt 行继续 → 执行退款 → 结果回传 → 前端渲染。你在第 9 章学的机制，现在是一个真实按钮背后的完整旅程。

## 样式：够用就行的手写 CSS

不引组件库，但基本的可读性要有。核心就几类：聊天气泡（用户靠右浅色、助手靠左深色）、过程提示（小字灰色）、徽章（圆角色块）、表单（纵向排列的 label）。全部不到 100 行，写在 `style.css` 里全局生效。做教学项目，CSS 的目标是「不分散对交互逻辑的注意力」，不是好看——当然，把它做好看是绝佳的课后练习。

## 验收：M3 全角色走查

浏览器里按剧本走：

1. 员工身份提交「差旅住宿报销额度是多少」→ 跳详情页，看到知识库回答和来源；
2. 追问「审批流程呢」→ 看到「⚙️ classify 处理完成」过程行逐条出现，然后出回答；
3. 提交「申请退回多扣的 800 元」→ 状态显示待审批；
4. 切审批员身份 → 审批中心看到卡片 → 点批准 → 对话流里出现执行结果；
5. 员工回到列表 → 两个工单状态分别是「已办结」。

全过，M3 达成。这个项目从用户视角已经是个完整产品了。

## 常见坑位

- **SSE 没数据但接口 200**：检查后端响应头是不是 `text/event-stream`，以及代理/服务器有没有缓冲响应（Vite 代理默认没问题；nginx 需要 `proxy_buffering off`，第 15 章会撞上）。
- **中文乱码或事件解析错位**：`TextDecoder` 忘了 `{ stream: true }`，多字节字符被从中间切断。
- **页面切换后还在收流**：组件销毁时没有中断 reader（`reader.cancel()`）。本练习页面简单影响不大，长列表页就要处理，否则流在后台空跑。
- **v-for 没 key 或 key 用下标**：消息乱序、输入框状态错位——Vue 复用错了 DOM。

## 小结

本章给用户装上了脸：router + views 的页面骨架、api.ts 的 token 封装、fetch 版 SSE 手动解析（缓冲拼接是核心难点）、响应式表单与列表、以及最重要的——把 updates 流渲染成「过程提示 + 正式回答」的双层体验。审批按钮串起了从浏览器点击到图恢复执行的完整链路。

下一章收官：联调排错、旅程测试、生产构建与部署，以及全课复盘。

## 自测

1. SSE 解析为什么需要 buffer？`events.pop()` 留下的那段是什么？
2. 为什么用户消息要「先上屏」而不是等后端确认？
3. updates 流里的节点名和节点产出的消息，在界面上分别承担什么角色？
4. EventSource 为什么不能用在这个项目？替代方案的关键 API 是什么？

参考答案：1. 字节流随机切块，一个事件可能跨两块；pop 留下的是末尾不完整的一段，等下一块拼齐再解析。2. 保证界面跟手，网络延迟不转嫁成用户感知；失败再补偿提示。3. 节点名渲染过程提示（它在干活），节点消息渲染正式回答（干活的结果）。4. EventSource 只支持 GET，追问必须 POST；替代方案是 fetch + resp.body.getReader() 手动解析流。
