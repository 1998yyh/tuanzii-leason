# 团子课堂 - 课程门户站开发交接文档

> 本文档记录了与用户逐条确认后的**完整共识**和**待办清单**,供接手的开发者(或模型)无缝继续。
> 所有决策均已和用户拍板确认,**无需重新征询**,照做即可。若遇文档未覆盖的实现细节,按 KISS / DRY / YAGNI 原则自行决定,不要过度设计。

---

## 一、项目背景(事实)

- 项目根目录:`/Users/hao.yang/Desktop/AI/tuanzii-leason`
- 纯静态站,**部署到腾讯云服务器在线访问**(不是双击 file:// 打开,所以可以用 fetch 读 json、可以有构建步骤)。
- 目标:做一个**课程门户站**,索引 `courses/` 目录下真实生成的课程,点卡片整页跳进那门课自带的页面。

### 现有资产

**顶层(旧 demo,待删除):**
- `index.html` —— 旧的"团子课堂"demo 首页(待重写为门户)
- `js/data.js` —— 写死的三门**假课**(JS/CSS/Python),要删
- `js/app.js` —— 卡片+弹窗+localStorage 进度逻辑,门户用不上,要删
- `css/style.css` —— 旧样式,要删
- `README.md` —— 注意:里面写的"双击 index.html 就能跑/零依赖"是**过时错误**信息,实际要部署到服务器

**真实课程(核心资产,`courses/langchain-langgraph/`):**
- 一个**完整能独立打开的课程站**,15 节课全有:
  - `index.html`(110 行,课程目录页,可独立跑)
  - `course.json`(课程元数据:title/subtitle/description/modules/lessons/status 等)
  - `lessons/01..15-*.html`(15 节课正文,**成品**)+ `lessons/*.md`(Markdown 源,副产物)
  - `assets/course.css`(131 行,**所有课程页共用同一个 CSS**——改它一处,15 节课+目录页全变)
  - `assets/mermaid.min.js`(图表库)
- **副产物(不该部署给访客看):**
  - `.teach-yourself-qc.json`(质检配置)
  - `quality/`(质检报告 md、评分 json、`phase-3-screenshots/*.png` 截图)
  - `lessons/*.md`(Markdown 源文件,HTML 才是成品)

### course.json 里可用的字段(封面无 icon/color 字段,需自动生成)

- `title`(标题)、`subtitle`(副标题)、`description`(简介)
- `modules`(数组,当前 3 个模块)、`lessons`(数组,当前 15 节课)
- `slug`(如 `langchain-langgraph`)、`status`(当前 `manual-review`)
- **没有** icon、color、封面图、可靠时长(`duration` 是"待定")

---

## 二、最终共识(逐条与用户确认,不要改)

### 门户站(新建,深色科技风)
1. **技术栈**:纯原生 HTML/CSS/JS,**零框架零构建**。文件平铺在**项目根目录**:
   - `index.html`(门户首页)
   - `portal.css`(门户样式)
   - `portal.js`(渲染逻辑)
   - `courses.json`(由 build.py 生成的课程清单)
2. **视觉风格**:**深色科技风**(dark mode)。
   - 深色底(近黑的深灰蓝,如 `#0f172a` / `#1e293b`,**非纯黑**)
   - 主点缀色:**青绿/薄荷绿 `#2dd4bf` 系**(标题高亮、卡片边框/hover 光晕、按钮)
   - 对比度必须达标,不糊眼。
3. **布局**:响应式**卡片网格**,手机自动堆成单列。
4. **门面(顶部)**:
   - 标题保留 **"🍡 团子课堂"**
   - 副标题走技术调性,如 **"AI 与全栈技术精选课程"**
5. **每张课程卡片显示**:标题 + 副标题 + 简介 + **"X 模块 · Y 节课"**统计(如"3 模块 · 15 节课")。
6. **卡片封面自动生成,零配置**:
   - 图标 = 课程标题的**首个字符**(或统一 emoji)
   - 颜色 = 用 **slug 字符串哈希**算出的稳定色值(同一门课每次颜色一致)
   - **不依赖图片文件,不改 course.json**
7. **点击卡片** = **整页跳转**到 `courses/<slug>/index.html`(进入课程自带的完整页面)。返回靠浏览器后退键。**不用 iframe。**
8. **底部**:**极简页脚**(如 `© 2026 团子课堂`),别的区块(关于/联系/订阅)一概不加。

### 构建脚本 build.py(Python 标准库,零依赖)
放项目根目录,用 `python3 build.py` 跑。干两件事:
1. **生成课程清单**:扫描 `courses/*/course.json`,拼出 `courses.json`。
   - 判定标准:**某子目录下有 `course.json` = 一门课**(靠这条自然排除 quality/ 等副产物目录)。
   - **排序**:按文件夹名(slug)**字母序**(`sorted()`)。
   - `courses.json` 里每门课至少含:slug、title、subtitle、description、模块数、课时数、入口路径(`courses/<slug>/index.html`),以及门户渲染需要的封面信息(可在 JS 端算,也可脚本算,择一,保持 DRY)。
2. **生成发布目录 `dist/`(净化)**:
   - 把**门户文件**(根目录的 index.html/portal.css/portal.js/courses.json)拷进 `dist/`。
   - 把每门课的**课程本体**拷进 `dist/courses/<slug>/`:`index.html`、`course.json`、`lessons/*.html`、`assets/`。
   - **副产物一律不拷**:`.teach-yourself-*`、`quality/`、`lessons/*.md` 跳过。
   - `dist/` = 最终上传腾讯云的东西。源目录保留副产物当"工作区"。
3. **容错(坏课处理)**:遇到读不了的 course.json(JSON 语法错)、缺关键字段(如缺 title)、缺 `index.html` 的课:
   - **跳过它,不上架**;
   - 同时在**终端打醒目警告**(如 `⚠️ 跳过 xxx:course.json 缺 title 字段`);
   - **构建不崩**(一门坏课不连累其他好课)。

### 课程页改造(改一个文件,全站生效)
- 只改 `courses/langchain-langgraph/assets/course.css`(131 行,所有课程页共用)。**不动任何 HTML。**
- 从**浅色 GitHub 风** → **护眼深色**:
  - 深灰蓝底(非纯黑)、**柔和浅灰字**(非刺眼纯白)
  - 点缀色继续用门户的**青绿 `#2dd4bf`**(链接、标题强调、代码块边等)
  - 代码块用更深一档的底 + 语法友好配色
  - 需适配的元素:`.site-header`、`main.chapter`/`main.home`、`h1-h4`、`blockquote`、`pre.code`/`code`、`table`/`th`/`td`、`.mermaid`、`.toc`、`.chapter-nav`、首页 `.subtitle`/`.desc`/`.module-tag`/`.lesson-card`
  - **重点**:课程页是**读长文**场景,护眼优先,对比度调到长时间阅读不累。
- **mermaid 注意**:`assets/mermaid.min.js` 渲染的图默认是浅色主题,深色底下可能糊。留意 `.mermaid` 容器背景,必要时给图表区一个浅色卡片底衬托,或配置 mermaid 深色主题(优先低成本方案)。

### 清理
- 删除顶层旧 demo:`js/data.js`、`js/app.js`、`css/style.css`(可清掉整个 `js/`、`css/` 目录),`index.html` 重写为门户。

---

## 三、设计系统(已用 ui-ux-pro-max 敲定)

已用 `ui-ux-pro-max` 定深色科技风 token,门户 `portal.css` 与课程页 `course.css` 各自内联同一套色值(KISS,未抽公共文件):

| Token | 值 | 用途 |
|-------|-----|------|
| `--bg-base` | `#0f172a` | 页面底 |
| `--bg-elevated` | `#1e293b` | 卡片/正文区 |
| `--bg-sunken` | `#0b1220` | 代码块/更深表面 |
| `--text-primary` | `#e2e8f0` / `#cbd5e1`(课程长文) | 正文 |
| `--accent` | `#2dd4bf` | 青绿点缀 |
| `--radius-md/lg` | `10–16px` | 圆角 |
| `--shadow-glow` | 青绿光晕 | 卡片 hover |

mermaid:课程页给 `.mermaid` 浅色卡片底衬,避免默认浅色图糊在深色页上。

---

## 四、待办清单(TODO)

按 **设计系统 → 门户三件套 → build.py → 清理 → 课程页深色化 → 验证** 的顺序推进:

- [x] **1. 用 ui-ux-pro-max 定深色科技风设计系统**
      调用 skill,确定深色底 + 青绿 `#2dd4bf` 的配色、层级、间距、圆角、阴影 token。重点保证长文阅读对比度达标。
- [x] **2. 写门户三件套 index.html + portal.css + portal.js**
      深色科技风:门面(🍡 团子课堂 + 技术副标题)、响应式卡片网格(手机单列)、极简页脚。portal.js fetch courses.json 渲染卡片,封面用标题首字+slug哈希色块自动生成,点卡片整页跳转 `courses/<slug>/index.html`。
- [x] **3. 写 build.py 构建脚本**
      Python 标准库零依赖。扫 courses/*/course.json 生成 courses.json(slug 字母序),拷课程本体进 dist/ 并净化副产物,坏课跳过+终端报警,构建不崩。
- [x] **4. 清理顶层旧 demo**
      删 js/data.js、js/app.js、css/style.css(清掉 js/、css/ 目录),index.html 重写。
- [x] **5. 课程页 course.css 深色化改造**
      把 courses/langchain-langgraph/assets/course.css 从浅色改护眼深色,复用设计系统 token,适配代码块/表格/引用/mermaid/toc/chapter-nav/lesson-card。改一个文件全站生效。
- [x] **6. 验证:跑 build.py 生成 dist 并核对**
      运行 build.py,确认 courses.json 正确、dist/ 干净无副产物、门户能列出 langchain 课、点击跳转路径对、课程页深色样式生效。清理临时文件。

---

## 五、注意事项 / 红线

- **不要动 git**(不提交、不建分支)——除非用户主动要求。
- 部署前跑 `python3 build.py`,只上传 `dist/`。
- README.md 里"双击即开/零依赖"信息过时,实现完可顺手更正为"部署到服务器 + build.py 构建"的说明。
- 遵循 KISS / DRY / YAGNI:门户就三四个文件平铺根目录,别引框架、别搞多余抽象、别为还没发生的需求提前设计。
- 课程页共用一个 CSS,改一处全生效——别去逐个改 HTML。
