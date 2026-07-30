# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 身份定义

- **角色**: 静态课程门户站工程师（纯原生前端 + Python 构建脚本）
- **技术栈**: 原生 HTML/CSS/JS（零框架零依赖）+ Python 3 标准库（`build.py`，无第三方包）
- **项目描述**: 「团子课堂」课程门户站——索引 `courses/` 下的真实课程，卡片整页跳转进课程自带页面，构建后部署到腾讯云 CVM（OpenCloudOS 9 + Nginx，9000 端口）

## 可执行命令

```bash
python3 build.py                  # 构建：重新生成 courses.json + 净化 dist/（改任何课程文件后必跑）
cd dist && python3 -m http.server 8000   # 本地预览（必须走 HTTP，fetch courses.json 在 file:// 下会挂）
./deploy.sh                       # 一键部署（本地跑）：构建 → 装/配 Nginx → rsync dist/ 到服务器
```

没有测试框架、没有 lint 配置、没有 CI——**验证 = 跑 build.py 看警告 + 起 http.server 开浏览器核对**。

## 核心架构：构建净化链路

本项目最关键的链路是「源目录 → dist/」的净化拷贝，跨 `build.py` + `.gitignore` + `deploy.sh` 三个文件：

```
courses/<slug>/
├── course.json        ← 判定标准：有它 = 一门课（build.py 扫描入口）
├── index.html         ← 课程目录页（成品）
├── lessons/*.html     ← 课时成品（*.md 是源稿，不拷不进 dist）
├── reference/*.html   ← 学生可见参考资料（同 lessons 规则，只拷 HTML）
├── assets/            ← course.css + course.js + mermaid.min.js（整目录拷）
├── quality/ workspace/ .teach-yourself-*   ← 副产物：git 忽略 + dist 跳过
        │
        ▼  python3 build.py
courses.json（根目录，生成物）→ dist/（净化产物）→ deploy.sh rsync → /var/www/tuanzii
```

关键文件映射：

| 文件 | 职责 |
|---|---|
| `build.py` | 扫 `courses/*/course.json` 生成 `courses.json`（slug 字母序）；坏课（JSON 坏/缺 title/缺 index.html）跳过报警不崩 |
| `portal.js` | 门户渲染：fetch `courses.json` → 卡片网格；封面图标=标题首字，颜色=slug 哈希（JS 端算，course.json 无 icon/color 字段） |
| `deploy.sh` | 密码（sshpass）或密钥二选一认证；远端装 Nginx、注释默认 80 server、放行 firewalld/SELinux；rsync `--delete` 同步 dist/ |
| `deploy/nginx-tuanzii.conf` | 站点模板，`__LISTEN_PORT__`/`__WEB_ROOT__` 占位符由 deploy.sh sed 替换 |

## 编码规范（从代码中观察到的实际约定）

- **注释语言**: 全项目中文注释（README/部署脚本/HTML 注释都是中文），新代码保持一致
- **课程页共用资产**: 每门课所有课时共享 `assets/course.css` 和 `assets/course.js`——改样式/交互**只改这两个文件**，15+ 节课全生效，**绝不逐个改课时 HTML**
- **课时 HTML 尾部固定两件套**:
  ```html
  <script>mermaid.initialize({ startOnLoad: true, theme: "dark" });</script>
  <script src="../assets/course.js" defer></script>
  ```
  新增课时页必须带上，mermaid 主题固定 `dark`
- **course.js 渐进增强**: 无 JS 时 `pre.code` 自带卡片样式兜底，JS 只负责包装增强——新功能遵循同一原则（禁 JS 不碍事）
- **视觉系统**: Guardnet 暗黑风，纯黑底 `#000` + 冰蓝 accent `#8fb1ff`，门户 `portal.css` 与课程页 `course.css` 各自内联同一套 token（KISS，未抽公共文件）——**改 token 要两处同步**
- **build.py 风格**: 类型注解 + 中文 docstring + 中文终端输出（✅/⚠️/📦 emoji 前缀），新增输出沿用同一格式

## 三层边界模型

### ✅ 必须执行
- 改完任何课程文件（含 lessons/reference/assets/course.json）**必跑 `python3 build.py`** 再预览或部署
- 新课程上线 = `courses/<slug>/` 备好 course.json + index.html + lessons/*.html，跑 build.py 自动上架，**不需要改任何门户代码**
- 只部署 `dist/`，源目录的副产物（quality/、workspace/、*.md）留在本地当工作区

### ⚠️ 需先询问
- `./deploy.sh`（动生产服务器，且需要 `deploy.env` 里的密码）
- 修改 `courses/*/assets/course.css` / `course.js`（一改全课程生效，影响面大）
- 删除课程内容或整个课程目录
- 一切 git 提交/分支/推送操作（用户没主动要求就不做）

### ❌ 禁止操作
- **禁止手改 `courses.json`**——它是 build.py 生成物，手改必被覆盖
- **禁止手改 `dist/` 里的文件**——每次构建 `shutil.rmtree` 整个删了重建
- **禁止提交 `deploy.env`（含服务器密码）和 `dist/`**——已在 .gitignore，别用 `-f` 强行加
- **禁止把副产物塞进 dist/**：`quality/`、`workspace/`、`.teach-yourself-*`、`lessons/*.md`
- **禁止用 iframe 嵌课程页**——点卡片就是整页跳转，返回靠浏览器后退
- **禁止引框架/构建工具**（React/Vue/npm 等）——项目红线就是零依赖纯原生

## 部署环境特殊规范

目标机：腾讯云 CVM · OpenCloudOS 9（RHEL 系，用 `dnf`），站点监听 **9000 端口**（故意不占 80）。

- **云安全组是手动操作**：deploy.sh 只能改机器内 firewalld/SELinux，腾讯云控制台 → 安全组放行入站 TCP 9000 必须人去点，部署后打不开先查这里
- **认证二选一**：`deploy.env` 里 `DEPLOY_PASSWORD`（密码，需本机 sshpass）优先于 `DEPLOY_SSH_KEY`；填了密码脚本会强制清空 KEY
- **rsync 带 `--delete`**：远端 `/var/www/tuanzii` 里多出来的文件会被删，别在服务器上手动放东西
- **Nginx 默认 server 冲突**：OpenCloudOS 自带 nginx.conf 内嵌 listen 80 server，deploy.sh 会整段注释（打 `tuanzii-default-server-disabled` 标记），改 Nginx 配置时别还原它

## 文档同步

- `README.md` —— 面向使用者的快速开始/构建/部署说明（改构建或部署流程时同步更新）
- `HANDOFF.md` —— 历史交接文档，记录的配色（青绿 #2dd4bf）已被 Guardnet 暗黑风取代，**仅作决策历史参考，视觉以 README 和代码为准**

---
**版本**: v1.0
**最后更新**: 2026-07-29
