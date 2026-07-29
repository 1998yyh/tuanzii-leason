# 第 15 章 前端实现：文档管理与问答对话界面

> 一句话总结：用 Vue 3 实现文档库页与对话页，手写 fetch 流式解析 SSE，完成打字机渲染与可点击的引用溯源。

## 页面与路由拆解

后端四大能力就位，本章给用户一个能摸到的界面。两个页面，一条导航：

```text
/documents   文档库页：上传、列表、状态标签、删除
/chat        对话页：左栏会话列表 + 右栏消息流 + 底部输入框
```

文件结构（`frontend/src/`）：

```text
├── api/           # 接口层：client(封装)、documents、chat(含 SSE 解析)
├── stores/        # Pinia：documents(文档与轮询)、chat(会话与流式状态)
├── views/         # 页面：DocumentsView、ChatView
├── components/    # 部件：MessageBubble(消息气泡)、CitationPopover(引用弹层)
├── router/        # 路由
└── App.vue        # 顶部导航 + RouterView
```

先装依赖（Vue 3.5.40、Vite 8.1.5 实测基线）：

```bash
npm install vue vue-router pinia markdown-it
npm install -D vite @vitejs/plugin-vue typescript @types/markdown-it
```

路由（`src/router/index.ts`）：`/` 重定向到文档库——第一次用还没有文档，先看文档库才合理。

```ts
import { createRouter, createWebHistory } from "vue-router";
import DocumentsView from "../views/DocumentsView.vue";
import ChatView from "../views/ChatView.vue";

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: "/", redirect: "/documents" },
    { path: "/documents", component: DocumentsView },
    { path: "/chat", component: ChatView },
    { path: "/chat/:id", component: ChatView },
  ],
});
```

入口 `src/main.ts` 挂上 Pinia 和路由：`createApp(App).use(createPinia()).use(router).mount("#app")`。

## API 层：统一封装与 multipart 的一个坑

`src/api/client.ts` 把所有 JSON 请求的公共动作收在一起：拼 `/api` 前缀、设 Content-Type、把非 200 统一变成带状态码的异常。

```ts
export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export async function api<T>(path: string, options?: RequestInit): Promise<T> {
  const resp = await fetch(`/api${path}`, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!resp.ok) {
    const body = await resp.json().catch(() => ({}));
    throw new ApiError(resp.status, body.error ?? `请求失败 ${resp.status}`);
  }
  return resp.json();
}
```

文档接口里，上传是唯一的 multipart 请求，有一个经典坑：

```ts
export function uploadDocument(file: File) {
  const form = new FormData();
  form.append("file", file); // 字段名必须和后端 upload.single("file") 对上
  // multipart 请求不能手动设 Content-Type，浏览器会自动带 boundary
  return fetch("/api/documents", { method: "POST", body: form }).then(async (r) => {
    const data = await r.json();
    if (!r.ok) throw new Error(data.error ?? "上传失败");
    return data;
  });
}
```

注意它没用 `api()` 封装——因为 `api()` 会强制设置 `Content-Type: application/json`，而 multipart 请求的 Content-Type 必须带 boundary 分隔符（形如 `multipart/form-data; boundary=----abc`），这个 boundary 只有浏览器生成 FormData 时才确定。手动覆盖成 json 或手写 multipart 都会导致后端 multer 解不出文件。口诀：**FormData 交给浏览器设头，JSON 才手动设头**。

## SSE 解析：EventSource 不行，那就自己来

第 14 章留的课题：EventSource 只支持 GET，问答必须 POST。方案是 fetch + ReadableStream 手工解析（`src/api/chat.ts` 的核心）：

```ts
export interface ChatCallbacks {
  onMeta?: (conversationId: number) => void;
  onCitations?: (citations: Citation[]) => void;
  onToken?: (text: string) => void;
  onDone?: () => void;
  onError?: (message: string) => void;
}

// 流式问答：EventSource 只支持 GET，POST 必须 fetch + ReadableStream 手工解析 SSE
export async function streamChat(
  params: { conversationId?: number; question: string },
  cb: ChatCallbacks
) {
  const resp = await fetch("/api/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(params),
  });
  if (!resp.ok || !resp.body) throw new Error(`请求失败 ${resp.status}`);

  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    // SSE 以空行分隔事件，逐个取出解析
    let sep: number;
    while ((sep = buffer.indexOf("\n\n")) !== -1) {
      const rawEvent = buffer.slice(0, sep);
      buffer = buffer.slice(sep + 2);

      let event = "message";
      let data = "";
      for (const line of rawEvent.split("\n")) {
        if (line.startsWith("event: ")) event = line.slice(7);
        if (line.startsWith("data: ")) data = line.slice(6);
      }
      if (!data) continue;
      const payload = JSON.parse(data);

      if (event === "meta") cb.onMeta?.(payload.conversationId);
      else if (event === "citations") cb.onCitations?.(payload);
      else if (event === "token") cb.onToken?.(payload.text);
      else if (event === "done") cb.onDone?.();
      else if (event === "error") cb.onError?.(payload.message);
    }
  }
  cb.onDone?.(); // 流自然结束（即使 done 事件丢失也能收尾）
}
```

这段代码的每个动作都对应协议的一个现实。`resp.body.getReader()` 拿到响应体的读取器，数据到达一块就能读一块——这就是「流式」在浏览器里的物理形态。`TextDecoder` 带 `{ stream: true }`：多字节字符（中文）可能正好被切在两块数据之间，这个参数让解码器把不完整的字节序列留到下一块接着解，漏了它中文会偶发乱码。**buffer 是必须的自己动手的部分**：网络不保证一次 `read()` 正好给你完整事件，半包、粘包都是常态，所以收到的数据先拼进 buffer，只处理「以空行结尾」的完整事件，剩下的留着下次拼。事件内部按行拆 `event:` 和 `data:` 字段，最后按事件名分发到回调。

回调设计让组件层完全不关心协议——store 只管「来了 token 就拼到消息上」，和第 14 章后端 service 产出纯事件流是同一个分层思想：协议被关在 API 层。

## 状态管理：两个 store 的职责划分

Pinia 两个 store，按数据的生命周期划分：

**documents store**：文档列表、上传中状态、处理状态轮询。轮询的必要性来自第 13 章的异步设计——上传后处理要几秒，状态得有人去拉。

```ts
import { defineStore } from "pinia";
import { ref } from "vue";
import { fetchDocuments, uploadDocument, deleteDocument, type DocItem } from "../api/documents";

export const useDocumentsStore = defineStore("documents", () => {
  const list = ref<DocItem[]>([]);
  const uploading = ref(false);
  let pollTimer: number | undefined;

  async function refresh() {
    list.value = await fetchDocuments();
    // 有文档还在处理中就继续轮询，全部就绪/失败则停止
    if (list.value.some((d) => d.status === "pending" || d.status === "processing")) {
      pollTimer = window.setTimeout(refresh, 2000);
    }
  }

  function startPolling() {
    window.clearTimeout(pollTimer);
    void refresh();
  }

  async function upload(file: File) {
    uploading.value = true;
    try {
      await uploadDocument(file);
      startPolling(); // 上传成功后开始跟踪处理状态
    } finally {
      uploading.value = false;
    }
  }

  async function remove(id: number) {
    await deleteDocument(id);
    await refresh();
  }

  return { list, uploading, refresh, startPolling, upload, remove };
});
```

轮询的两个讲究：**有条件地轮**——列表里没有 pending/processing 就停，不空转；**单实例**——`startPolling` 先清旧定时器，不会因为连传三个文件起三个轮询循环。为什么用轮询而不是 SSE 推状态？够用且简单，两秒延迟在个人应用无感；状态推送是「为优化预留的口子」，不是现在的需求。

**chat store**：会话列表、当前会话消息、流式进行中状态。流式状态的建模是本章的关键设计：

```ts
import { defineStore } from "pinia";
import { reactive, ref } from "vue";
import {
  fetchConversations, fetchMessages, deleteConversation,
  streamChat, type Conversation, type Citation,
} from "../api/chat";

export interface UiMessage {
  role: "user" | "assistant";
  content: string;
  citations?: Citation[];
  interrupted?: boolean; // 流式中断标记
}

export const useChatStore = defineStore("chat", () => {
  const conversations = ref<Conversation[]>([]);
  const currentId = ref<number | null>(null);
  const messages = ref<UiMessage[]>([]);
  const streaming = ref(false); // 流式进行中禁止重复发送

  async function refreshConversations() {
    conversations.value = await fetchConversations();
  }

  async function openConversation(id: number) {
    currentId.value = id;
    const rows = await fetchMessages(id);
    messages.value = rows.map((m) => ({ role: m.role, content: m.content }));
  }

  function newConversation() {
    currentId.value = null;
    messages.value = [];
  }

  async function send(question: string) {
    if (streaming.value || !question.trim()) return;
    streaming.value = true;
    messages.value.push({ role: "user", content: question });
    // 必须用 reactive 包装再 push（原因见下文「一个 E2E 抓出来的 bug」）
    const assistant = reactive<UiMessage>({ role: "assistant", content: "", citations: [] });
    messages.value.push(assistant);

    try {
      await streamChat(
        { conversationId: currentId.value ?? undefined, question },
        {
          onMeta: (id) => { currentId.value = id; },
          onCitations: (c) => { assistant.citations = c; },
          // 流式 token 直接 mutate 当前消息，响应式驱动打字机
          onToken: (t) => { assistant.content += t; },
          onError: () => { assistant.interrupted = true; },
        }
      );
    } catch {
      assistant.interrupted = true;
    } finally {
      streaming.value = false;
      void refreshConversations(); // 标题和时间戳已更新
    }
  }

  async function removeConversation(id: number) {
    await deleteConversation(id);
    if (currentId.value === id) newConversation();
    await refreshConversations();
  }

  return {
    conversations, currentId, messages, streaming,
    refreshConversations, openConversation, newConversation, send, removeConversation,
  };
});
```

读 `send` 的设计：用户消息和一条**空的助手消息**先入列，然后流式回调往里灌内容——打字机效果的全部秘密就是「提前放好一条消息，然后逐 token 修改它」。`streaming` 标志位同时做三件事：禁止重复发送、禁用输入框、驱动按钮文案。`interrupted` 把「流断了」建模成消息的一个属性，而不是全局错误——已生成的部分内容得以保留展示。

## 一个 E2E 抓出来的 bug：ref 数组里的普通对象

上面的代码里藏着本章最重要的一个知识点，它是端到端测试抓出来的现行犯。最初的写法是：

```ts
// ❌ 有 bug 的初版
const assistant: UiMessage = { role: "assistant", content: "", citations: [] };
messages.value.push(assistant);
// ……onToken: (t) => { assistant.content += t; }
```

看起来天经地义，跑起来答案是空白。原因要进 Vue 响应式的机制里看：`ref([])` 会让数组本身和通过数组访问到的元素变成响应式代理，但你手里那个 `assistant` 变量是**原始普通对象**——push 之后，数组里存的是它，通过 `messages.value[2]` 访问时 Vue 返回代理；而回调里改的是原始对象的属性，这个修改**绕过了代理的依赖追踪**，视图收不到任何通知。

修法就是把对象先变成响应式再入列：`const assistant = reactive<UiMessage>({...})`。此时变量本身就是代理，回调里的每次 `+=` 都精确触发视图更新。

这个 bug 的恶劣之处在于：逻辑全对、数据全对、测试接口全通——后端 curl 一切正常，只有界面上答案不出来。它是「联调期最浪费时间」的那类问题，也是为什么第 16 章要坚持端到端旅程测试：单元测试测不出层与层接缝处的错。

## 文档库页

页面本身是把 store 能力接上 UI（`src/views/DocumentsView.vue`），关键片段：

```vue
<script setup lang="ts">
import { onMounted, ref } from "vue";
import { useDocumentsStore } from "../stores/documents";

const store = useDocumentsStore();
const fileInput = ref<HTMLInputElement>();

onMounted(() => store.startPolling());

const STATUS_LABEL: Record<string, string> = {
  pending: "待处理", processing: "处理中", ready: "就绪", failed: "失败",
};

function pick() { fileInput.value?.click(); }

async function onFileChange(e: Event) {
  const file = (e.target as HTMLInputElement).files?.[0];
  if (!file) return;
  if (file.size > 10 * 1024 * 1024) { alert("文件不能超过 10MB"); return; }
  try {
    await store.upload(file);
  } catch (err) {
    alert(err instanceof Error ? err.message : "上传失败");
  } finally {
    (e.target as HTMLInputElement).value = ""; // 允许重复上传同名文件
  }
}

async function onDelete(id: number, name: string) {
  if (confirm(`确定删除《${name}》？其分块与向量将一并删除。`)) await store.remove(id);
}
</script>

<template>
  <section>
    <header class="bar">
      <h2>文档库</h2>
      <button :disabled="store.uploading" @click="pick">
        {{ store.uploading ? "上传中……" : "上传文档" }}
      </button>
      <input ref="fileInput" type="file" accept=".md,.pdf,.txt" hidden @change="onFileChange" />
    </header>

    <p v-if="!store.list.length" class="empty">还没有文档，上传一份 Markdown / PDF / TXT 试试。</p>

    <table v-else>
      <thead><tr><th>文件名</th><th>格式</th><th>状态</th><th>块数</th><th></th></tr></thead>
      <tbody>
        <tr v-for="d in store.list" :key="d.id">
          <td>{{ d.filename }}</td>
          <td>{{ d.format }}</td>
          <td>
            <span class="status" :class="d.status">{{ STATUS_LABEL[d.status] }}</span>
            <span v-if="d.status === 'failed'" class="err" :title="d.errorMsg ?? ''">ⓘ</span>
          </td>
          <td>{{ d.chunkCount }}</td>
          <td><button class="del" @click="onDelete(d.id, d.filename)">删除</button></td>
        </tr>
      </tbody>
    </table>
  </section>
</template>
```

三个交互细节：隐藏的原生 `input[type=file]` 用按钮触发（原生文件框样式没法看）；上传后清空 input 的 value，否则连续选同一个文件不触发 change；失败状态旁的 ⓘ 用 `title` 属性展示 errorMsg（悬停可见，零组件成本的 tooltip）。删除用原生 `confirm`——个人应用不引入对话框组件库，这是 YAGNI。

## 对话页

`src/views/ChatView.vue` 把会话列表、消息流、输入区组合起来：

```vue
<script setup lang="ts">
import { onMounted, ref, nextTick } from "vue";
import { useChatStore } from "../stores/chat";
import { useDocumentsStore } from "../stores/documents";
import MessageBubble from "../components/MessageBubble.vue";
import CitationPopover from "../components/CitationPopover.vue";

const chat = useChatStore();
const docs = useDocumentsStore();
const input = ref("");
const listEl = ref<HTMLElement>();

onMounted(async () => {
  await Promise.all([chat.refreshConversations(), docs.refresh()]);
});

async function send() {
  const q = input.value.trim();
  if (!q) return;
  input.value = "";
  await chat.send(q);
  await nextTick();
  listEl.value?.scrollTo({ top: listEl.value.scrollHeight });
}

const hasReadyDoc = () => docs.list.some((d) => d.status === "ready");
</script>

<template>
  <div class="chat-layout">
    <aside class="sidebar">
      <button class="new" @click="chat.newConversation()">＋ 新对话</button>
      <ul>
        <li
          v-for="c in chat.conversations" :key="c.id"
          :class="{ on: c.id === chat.currentId }"
          @click="chat.openConversation(c.id)"
        >
          <span>{{ c.title }}</span>
          <button class="del" @click.stop="chat.removeConversation(c.id)">×</button>
        </li>
      </ul>
    </aside>

    <main class="main">
      <p v-if="!hasReadyDoc()" class="tip">
        还没有就绪的文档，先到「文档库」上传笔记，再来提问。
      </p>

      <div ref="listEl" class="messages">
        <template v-for="(m, i) in chat.messages" :key="i">
          <MessageBubble :message="m" :streaming="chat.streaming && i === chat.messages.length - 1" />
          <CitationPopover v-if="m.role === 'assistant' && m.citations?.length" :citations="m.citations" />
        </template>
        <p v-if="!chat.messages.length" class="empty">问点什么吧，比如「我记的 pgvector 索引怎么建？」</p>
      </div>

      <form class="composer" @submit.prevent="send">
        <input v-model="input" placeholder="输入问题，回车发送" :disabled="chat.streaming" />
        <button type="submit" :disabled="chat.streaming || !input.trim()">
          {{ chat.streaming ? "回答中……" : "发送" }}
        </button>
      </form>
    </main>
  </div>
</template>
```

注意 `@click.stop` 在删除按钮上：会话条目整体可点（打开会话），删除按钮必须阻止事件冒泡，否则点删除会变成「先打开再删除」。`hasReadyDoc` 的空态引导是产品闭环的一部分——没有就绪文档时提问注定拒答，不如提前指路。

## 消息渲染：Markdown、角标与 v-html 的边界

助手答案是 Markdown 文本，答案里的 `[n]` 要变成可点击的角标（`src/components/MessageBubble.vue`）：

```vue
<script setup lang="ts">
import { computed } from "vue";
import MarkdownIt from "markdown-it";
import type { UiMessage } from "../stores/chat";

const props = defineProps<{ message: UiMessage; streaming: boolean }>();
const emit = defineEmits<{ cite: [ref: number] }>();

const md = new MarkdownIt({ linkify: true, breaks: true });

// 把答案中的 [n] 角标换成可点击的引用按钮占位
const rendered = computed(() => {
  let html = md.render(props.message.content);
  html = html.replace(
    /\[(\d+)\]/g,
    (_m, n) => `<button class="cite-badge" data-ref="${n}">[${n}]</button>`
  );
  return html;
});

function onClick(e: MouseEvent) {
  const btn = (e.target as HTMLElement).closest(".cite-badge") as HTMLElement | null;
  if (btn) emit("cite", Number(btn.dataset.ref));
}
</script>

<template>
  <div class="bubble" :class="message.role">
    <div class="content" @click="onClick" v-html="rendered"></div>
    <span v-if="streaming && message.role === 'assistant'" class="cursor">▍</span>
    <p v-if="message.interrupted" class="interrupted">回答中断，请重试</p>
  </div>
</template>
```

两个技术点。一是角标替换发生在 **Markdown 渲染之后**：先把文本渲成 HTML，再正则替换 `[n]` 为按钮标签——顺序反了（先替换再渲染）的话，markdown-it 会把按钮 HTML 当普通文本转义掉。二是点击处理用**事件委托**：`v-html` 注入的按钮没法直接绑 Vue 事件，在容器上监听 click、用 `closest('.cite-badge')` 判断点的是不是角标，一个监听器管所有动态按钮。

流式过程中的「半包 Markdown」问题这里选了最务实的解法：流式期间照样每次全量渲染当前 content（块级元素未闭合时 markdown-it 会按已有内容尽力渲染，视觉上就是内容在「长」），配合光标符号 `▍` 提示正在生成。精确的对齐渲染（等围栏闭合才渲染代码块）属于体验优化，第 16 章列为可选打磨项。

安全边界要交代一句：`v-html` 注入的是模型生成的内容，理论上模型输出可以包含恶意 HTML/XSS。markdown-it 默认会转义原始 HTML（本例未开启 `html: true`），所以模型写的 `<script>` 只会被当文本显示——保持这个默认，别手痒打开。

## 引用弹层

`src/components/CitationPopover.vue` 点击角标后拉取完整原文：

```vue
<script setup lang="ts">
import { ref } from "vue";
import { fetchChunk } from "../api/chat";

const props = defineProps<{ citations: { ref: number; chunkId: number; heading: string | null; snippet: string }[] }>();
const active = ref<number | null>(null);
const detail = ref<{ content: string; heading: string | null; doc_name: string } | null>(null);

async function toggle(ref: number, chunkId: number) {
  if (active.value === ref) { active.value = null; return; }
  active.value = ref;
  detail.value = await fetchChunk(chunkId); // 完整原文与出处
}
</script>

<template>
  <div class="citations" v-if="citations.length">
    <span class="label">参考来源：</span>
    <button
      v-for="c in citations" :key="c.ref"
      class="cite-badge" :class="{ on: active === c.ref }"
      @click="toggle(c.ref, c.chunkId)"
    >[{{ c.ref }}]</button>
    <div v-if="active && detail" class="popover">
      <p class="src">出自《{{ detail.doc_name }}》{{ detail.heading ?? "（无标题节）" }}</p>
      <p class="text">{{ detail.content }}</p>
    </div>
  </div>
</template>
```

数据在这里形成了一个三级结构：SSE 的 citations 事件带 snippet（80 字预览，随答案即时可用）→ 点击后调 `/api/chunks/:id` 拿完整原文 → 原文里有 heading 和 doc_name（出处）。第 4 章挂元数据时说「现在挂一行，将来多一倍玩法」，这就是玩法的终端呈现。

## 里程碑 3 验收：完整旅程走一遍

后端（`npx tsx src/index.ts`）和前端（`npx vite`）都起好，在浏览器里走完整旅程：

1. 打开 `http://localhost:5173/documents`，点「上传文档」选一份 Markdown 笔记；
2. 状态标签从「待处理」变「处理中」再变「就绪」（轮询在工作），块数出现；
3. 点顶部「对话」，底部输入「pgvector 的 HNSW 索引怎么建？」，回车；
4. 左侧出现新会话，答案逐字流出，句末 `[1]` 是蓝色可点角标；
5. 点 `[1]`，弹层显示「出自《test-note.md》索引类型」和完整原文；
6. 追问「那它的参数怎么调？」，系统理解「它」是谁（改写生效），继续带引用回答；
7. 刷新页面，会话和历史都在（持久化生效）。

这套旅程已经用 Playwright 端到端实测通过（记录在学习档案里）：上传 → 就绪（3 块）→ 流式答案带角标 → 多轮 4 条消息，全绿。你的本地之旅如果卡在哪一步，对照下面的坑位清单。

## 常见坑位清单

- **答案空白但接口正常**：检查是不是踩了「普通对象 push 进 ref 数组」的响应式坑（本文专节）。
- **流式中文偶发乱码**：`TextDecoder` 漏了 `{ stream: true }`，多字节字符被切块切断。
- **所有事件挤在最后一起到**：中间有代理缓冲（公司网关/某些浏览器插件），或后端 `res.write` 前被全局中间件包了响应。本地开发先裸连 8000 端口排除前端因素。
- **上传 400「缺少文件字段」**：前端字段名和后端 `upload.single("file")` 没对上，或手动设了 Content-Type。
- **点删除会话变成打开会话**：漏了 `@click.stop`。

## 小结与预告

本章交付了用户体验的最后一公里：fetch + ReadableStream 手写 SSE 解析（含 buffer 粘包处理与流式解码）；Pinia 双 store 的职责划分与流式状态建模；那个 E2E 才抓得到的响应式 bug；Markdown 渲染 + 角标事件委托 + 引用弹层的完整溯源交互。

至此，个人笔记助手的四大功能全部可用。最后一章收口：端到端联调排错、测试策略、Docker Compose 一键部署，以及最重要的——技术决策复盘：这套架构哪里会先到极限，混合检索、重排、任务队列这些扩展点该怎么接。
