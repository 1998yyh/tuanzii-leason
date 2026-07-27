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
        └── assets/     # 含 course.css（课程页共用）
```

## 构建说明

`python3 build.py` 会：

1. 扫描 `courses/*/course.json`，按 slug 字母序生成 `courses.json`
2. 把门户文件 + 课程本体拷进 `dist/`，跳过副产物（`quality/`、`*.md`、`.teach-yourself-*` 等）
3. 坏课（JSON 坏、缺 title、缺 index.html）跳过并打印警告，不中断构建

## 视觉

浅色纸感风：暖白底 `#f6f5f2` + 墨色文字 + 朱柿 `#c2410c` 点睛，卡片封面为 slug 哈希的 pastel 渐变，代码块用暖墨底反色。门户与课程页共用同一套设计 token。
