# 团子课堂（tuanzii-leason）

课程门户站：索引 `courses/` 下真实课程，点击卡片整页进入该课自带页面。纯原生 HTML/CSS/JS，部署到服务器访问。

## 快速开始

```bash
# 1. 构建（生成 courses.json + 净化后的 dist/）
python3 build.py

# 2. 本地预览（必须走 HTTP，不能双击 file://）
cd dist
python3 -m http.server 8000
# 打开 http://localhost:8000
```

部署时只上传 `dist/` 到腾讯云（或其他静态托管）。

## 一键部署（腾讯云 CVM · OpenCloudOS 9）

面向空机：自动构建、装 Nginx、放行本机防火墙、rsync 同步。站点监听 **9000** 端口（不占 80）。

```bash
# 0. 密码部署需本机安装 sshpass（只需一次）
brew install hudochenkov/sshpass/sshpass

# 1. 复制并填写服务器信息
cp deploy.env.example deploy.env
# 编辑 deploy.env：DEPLOY_HOST / DEPLOY_USER / DEPLOY_PASSWORD=你的服务器密码

# 2. 一键部署（在本地跑，不要在服务器上跑）
chmod +x deploy.sh
./deploy.sh
# 访问 http://<公网IP>:9000/
```

**注意：** 腾讯云控制台 → 安全组需手动放行入站 **TCP 9000**（脚本只能改机器内 firewalld，改不了云安全组）。`deploy.env` 含密码，已加入 `.gitignore`，勿提交。

相关文件：`deploy.sh`、`deploy.env.example`、`deploy/nginx-tuanzii.conf`。

## 目录结构

```
tuanzii-leason/
├── index.html          # 门户首页
├── portal.css          # 门户样式（深色科技风）
├── portal.js           # 卡片渲染（fetch courses.json）
├── courses.json        # 由 build.py 生成的课程清单
├── build.py            # 构建脚本（标准库零依赖）
├── dist/               # 发布目录（构建产物，上传这个）
└── courses/
    └── <slug>/
        ├── index.html
        ├── course.json
        ├── lessons/*.html
        └── assets/     # 含 course.css + course.js（课程页共用）
```

## 构建说明

`python3 build.py` 会：

1. 扫描 `courses/*/course.json`，按 slug 字母序生成 `courses.json`
2. 把门户文件 + 课程本体拷进 `dist/`，跳过副产物（`quality/`、`*.md`、`.teach-yourself-*` 等）
3. 坏课（JSON 坏、缺 title、缺 index.html）跳过并打印警告，不中断构建

## 视觉

Guardnet 暗黑风（参考 teach-yourself-skill/examples）：纯黑底 `#000` + 冰蓝 accent `#8fb1ff`，hero 区大字标题 + 巨型水印 + 辉光光斑，章节卡片为 3 列辉光网格；课时页为「正文卡片 + 粘性目录侧栏」双栏布局，代码块自动包成带语言标签和一键复制的卡片，mermaid 用 dark 主题渲染。门户 portal.css 与课程页 course.css 共用同一套设计 token。

## 移动端适配

全站响应式（断点 1080 / 900 / 680px）：卡片网格 3→2→1 列降级，课时页侧栏目录在小屏收到正文上方。移动端细节：

- `text-size-adjust: 100%` 防 iOS 横屏擅自放大字号，`-webkit-tap-highlight-color` 统一点击高亮
- 正文 `overflow-wrap: break-word`，长 URL/长英文不撑破版面；`img/video` 限宽兜底
- 表格由 course.js 包一层 `.table-scroll` 横滚容器（无 JS 时小屏压列兜底），mermaid 图小屏保持原始尺寸横滚
- 目录链接、复制按钮等触摸目标在小屏加大，卡片带 `:active` 按下反馈（触屏无 hover）
