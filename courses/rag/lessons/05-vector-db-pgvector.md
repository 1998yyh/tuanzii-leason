# 第 5 章 向量数据库与 pgvector：给向量安个家

> 一句话总结：搞懂向量数据库的四大职责与选型逻辑，用 PostgreSQL + pgvector 完成建表、相似度查询、元数据过滤和 HNSW 索引实战。

## 从一笔算不过来的账开始

第 2 章的玩具 RAG 把向量存在内存数组里，查询时全量遍历。五篇文档毫无压力，现在把数字放大：你的知识库有一万份文档，平均一份切十块，就是十万个向量。每次用户提问，都要把问题向量和这十万个向量各算一次余弦相似度。

一次余弦计算约两千次乘加（2048 维），十万次就是两亿次浮点运算，单次查询几秒钟起步。服务重启，数组全没了，十万个向量要重新调 Embedding API 生成，按量计费再烧一遍钱。想「只在上季度的文档里搜」？数组里没有地方放这个条件。

这三个麻烦——算得慢、存不住、没法过滤——就是向量数据库存在的理由。

## 向量数据库到底管什么

别被「数据库」三个字唬住，向量数据库干的就四件事：

**存**：向量持久化落盘，重启不丢，还能和向量的「主人」（原文、元数据）放在一起。

**索引**：给向量建 ANN 索引（第 3 章讲的 HNSW 就是其一），把「和十万个向量逐一比对」变成「在图结构里跳几百步」，毫秒级返回近似最近的 TopK。

**召回**：接受一个查询向量，按你指定的距离度量返回最相似的一批结果。

**过滤**：召回的同时支持元数据条件——「只在 document_id = 7 的块里找」「只要上季度的」。这条经常被忽视，但真实业务几乎一定会用到。

第 3 章解决「怎么算相似」，这一章解决「怎么存、怎么快速找、怎么带条件找」。

## 选型对比：专用向量库还是 pgvector

市面上的主流选择分成两派：专门的向量数据库，和在关系型数据库上长出来的向量能力。

| 方案 | 类型 | 亮点 | 代价 |
| --- | --- | --- | --- |
| Milvus | 专用向量库 | 大规模、分布式、功能最全 | 部署运维最重，小团队 hold 不住 |
| Qdrant | 专用向量库 | Rust 实现，性能好，过滤强 | 多一套存储系统要维护 |
| Weaviate | 专用向量库 | 模块化、自带混合检索 | 同上 |
| Pinecone | 云托管向量库 | 零运维 | 按量付费，数据出内网 |
| pgvector | PostgreSQL 扩展 | 和业务数据同库，SQL 全家桶 | 超大规模（亿级）下不如专用库 |

本课选 pgvector，理由很实际。第一，实战项目的文档、块、对话记录本来就要存关系型数据库，用 pgvector 意味着**业务数据和向量在同一个库里**：删文档时级联删向量是一个外键的事，不用维护两套存储的一致性。第二，你会的 SQL 全部直接复用，元数据过滤就是普通的 WHERE。第三，个人和中小团队的量级（百万向量以内），pgvector 的性能完全够用，它的 HNSW 实现和社区 benchmark 表现都相当扎实。

什么时候该换专用库？向量规模上到千万级以上、需要分布式水平扩展、或者检索 QPS 非常高的时候。第 16 章复盘会再聊这个判断。

## 环境搭建：三条命令起库

### 完成标准

能在 PostgreSQL 里执行 `SELECT extversion FROM pg_extension WHERE extname = 'vector';` 并看到版本号。

### Docker 方式（推荐，最省事）

装了 Docker 的同学一条命令起一个自带 pgvector 的 PostgreSQL 16：

```bash
docker run -d --name rag-pg \
  -e POSTGRES_PASSWORD=rag123 \
  -p 5432:5432 \
  pgvector/pgvector:pg16
```

镜像里的 PostgreSQL 已预装 pgvector 扩展。容器跑起来后，进数据库建一个课程专用库并启用扩展：

```bash
docker exec -it rag-pg psql -U postgres
```

```sql
CREATE DATABASE ragcourse;
\c ragcourse
CREATE EXTENSION vector;
SELECT extversion FROM pg_extension WHERE extname = 'vector';
```

最后一行看到版本号就齐了（2026-07-29 实测 `pgvector/pgvector:pg16` 镜像内置 0.8.5；0.8.x 系列修复过并行建索引的安全问题，用 0.8.1 及以下老版本的话建议升级）。

### 本地安装方式

不想用 Docker 的 macOS 同学：`brew install postgresql@16 pgvector`，然后 `brew services start postgresql@16`，剩下建库和 `CREATE EXTENSION vector` 的步骤一样。Windows 同学建议直接走 Docker，少踩一堆编译坑。

后面章节统一用 `ragcourse` 这个库。`psql` 是 PostgreSQL 自带的命令行客户端，本章的 SQL 都在它里面执行；不习惯命令行的也可以用任何数据库 GUI（TablePlus、DBeaver 都行）。

## 第一张向量表

建表之前先想清楚：一块数据长什么样？对照第 4 章的设计——正文、向量、元数据（出自哪份文档、第几块、所属标题）：

```sql
CREATE TABLE chunks (
  id          BIGSERIAL PRIMARY KEY,
  document_id TEXT NOT NULL,          -- 元数据：出自哪份文档
  seq         INT  NOT NULL,          -- 元数据：第几块
  heading     TEXT,                   -- 元数据：所属标题
  content     TEXT NOT NULL,          -- 块原文
  embedding   vector(4) NOT NULL      -- 向量，括号里是维度
);
```

`vector(4)` 是 pgvector 提供的向量类型，括号里的数字是维度。教学用 4 维好观察，真实项目要换成你的 Embedding 模型维度（比如 2048）。

维度是硬约束，插错直接报错：

```sql
INSERT INTO chunks (document_id, seq, heading, content, embedding)
VALUES ('handbook', 1, '报销规则', '报销应在 30 天内提交', '[0.9, 0.1, 0.2, 0.05]');

-- 下面这条会报错：expected 4 dimensions, not 3
INSERT INTO chunks (document_id, seq, content, embedding)
VALUES ('handbook', 2, '维度不对的块', '[0.1, 0.2, 0.3]');
```

这个报错值得你主动触发一次看眼熟。生产环境里「Embedding 模型换了维度，表还是旧维度」是高频事故，报错信息就是你现在看到的这句。实战项目里我们会让后端启动时主动校验「配置维度 = 表维度」，把事故挡在门外。

再插几条，凑齐一个迷你知识库：

```sql
INSERT INTO chunks (document_id, seq, heading, content, embedding) VALUES
  ('handbook', 2, '差旅标准', '一线城市住宿每晚不超过 500 元', '[0.85, 0.15, 0.1, 0.1]'),
  ('handbook', 3, '年假规则', '入职满一年享年假 5 天', '[0.1, 0.9, 0.1, 0.2]'),
  ('handbook', 4, '加班规则', '加班费按小时工资 1.5 倍计算', '[0.15, 0.85, 0.2, 0.15]'),
  ('handbook', 5, '设备报修', '设备损坏联系行政部报修', '[0.05, 0.1, 0.9, 0.3]');
```

## 相似度查询：三个距离操作符

pgvector 提供三个距离操作符，对应三种度量：

| 操作符 | 含义 | 适用 |
| --- | --- | --- |
| `<=>` | 余弦距离（1 − 余弦相似度） | 文本语义检索，本课默认 |
| `<->` | 欧氏距离（L2） | 向量已归一化时与余弦等价 |
| `<#>` | 负内积 | 特定模型要求内积度量时 |

注意第一个坑：`<=>` 算的是**距离**，越小越相似，和第 3 章的「相似度越大越相似」正好反过来。距离 0 表示完全同向，距离 2 表示完全反向。想换算回相似度，用 `1 - (embedding <=> 查询向量)`。

找出和问题向量 `[0.88, 0.12, 0.12, 0.08]` 最相似的三块：

```sql
SELECT content,
       embedding <=> '[0.88, 0.12, 0.12, 0.08]' AS distance
FROM chunks
ORDER BY embedding <=> '[0.88, 0.12, 0.12, 0.08]'
LIMIT 3;
```

`ORDER BY ... LIMIT 3` 就是 TopK 检索的 SQL 形态。跑一下（这是 2026-07-29 在 pgvector 0.8.5 上的真实输出）：

```text
            content            |       distance
-------------------------------+-----------------------
 一线城市住宿每晚不超过 500 元 | 0.0012504622247824226
 报销应在 30 天内提交          | 0.004345761644619084
 加班费按小时工资 1.5 倍计算   | 0.6660686308486407
```

排第一的是「一线城市住宿每晚不超过 500 元」，它的向量和查询向量方向最接近，距离只有 0.001 量级。注意第三名的距离一下子跳到 0.67——相关和不相关之间隔着一道明显的分数鸿沟，第 3 章说的「阈值判断」就是看这种鸿沟定的。

元数据过滤就是普通的 WHERE，没有任何新语法：

```sql
-- 只在 handbook 文档的前 3 块里检索
SELECT content, embedding <=> '[0.88, 0.12, 0.12, 0.08]' AS distance
FROM chunks
WHERE document_id = 'handbook' AND seq <= 3
ORDER BY distance
LIMIT 3;
```

「向量相似 + 业务条件」混在一条 SQL 里，这是 pgvector 相对专用向量库最顺手的时刻——过滤条件就是你的业务字段，不用学任何专门的过滤语法。

## 规模上来了：ANN 索引

现在的表只有五行，PostgreSQL 全表扫描（逐行算距离再排序）毫无压力。插十万行试试，查询就开始喘了。解决办法是给 embedding 列建 ANN 索引。pgvector 提供两种：

| 索引 | 原理一句话 | 特点 | 适用 |
| --- | --- | --- | --- |
| HNSW | 多层图，图上跳跃逼近 | 召回率高、查询快；占内存多、建索引慢 | 大多数场景的首选 |
| IVFFlat | 先聚类分桶，查询只搜最近的几个桶 | 建索引快、占内存少；召回率略低，需要表里先有数据再建 | 数据量超大且写入频繁 |

第 3 章讲过 HNSW 的直觉，直接建：

```sql
CREATE INDEX chunks_embedding_hnsw ON chunks
USING hnsw (embedding vector_cosine_ops);
```

IVFFlat 的建法放在这里对照（本课和实战项目都用 HNSW）：

```sql
-- lists 是分桶数量，官方经验值：行数 / 1000 左右
CREATE INDEX chunks_embedding_ivf ON chunks
USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
-- 查询时还要设 probes（搜几个桶），越大越准越慢
SET ivfflat.probes = 10;
```

两个细节不能省。一是 `vector_cosine_ops` 必须和你的查询操作符配套：用 `<=>` 查询就建 `vector_cosine_ops` 的索引，用 `<->` 就建 `vector_l2_ops`，配套错了索引不生效。二是 HNSW 有两个调优参数：`m`（每个点的最大连接数，默认 16，越大召回越准但内存越大）和 `ef_construction`（建索引时的搜索宽度，默认 64，越大索引质量越好但建得越慢）。默认参数对大多数场景够用，第 10 章学了评估后再谈调优。

建完索引，查询计划就变了。用 `EXPLAIN` 亲眼看看：

```sql
EXPLAIN SELECT content FROM chunks
ORDER BY embedding <=> '[0.88, 0.12, 0.12, 0.08]' LIMIT 3;
```

没建索引时计划里是 `Seq Scan`（全表扫描）；建完之后变成 `Index Scan using chunks_embedding_hnsw`。真实项目里，看到相似度查询走了 Seq Scan 就是警报——要么索引没建，要么没生效。

数据量太小的时候（比如就这几行），PostgreSQL 会故意不用索引——全表扫比走索引还便宜，这是优化器的正常判断，不是索引坏了。要观察索引效果，表里至少得有上万行。

## 实验：一万条向量，有无索引对比

光说不够，造点数据实测。生成一万条随机向量（4 维，教学够用；维度不影响结论）：

```sql
INSERT INTO chunks (document_id, seq, content, embedding)
SELECT 'bulk', g, '随机块 ' || g,
       ('[' || random() || ',' || random() || ',' || random() || ',' || random() || ']')::vector
FROM generate_series(1, 10000) AS g;
```

`generate_series` 生成一万行，每行一个随机四维向量。然后对比实验：

```sql
-- 先删掉刚才的索引
DROP INDEX IF EXISTS chunks_embedding_hnsw;

-- 无索引：看计划和耗时
EXPLAIN ANALYZE SELECT content FROM chunks
ORDER BY embedding <=> '[0.5, 0.5, 0.5, 0.5]' LIMIT 5;

-- 重建索引，再跑一次同样的查询
CREATE INDEX chunks_embedding_hnsw ON chunks
USING hnsw (embedding vector_cosine_ops);

EXPLAIN ANALYZE SELECT content FROM chunks
ORDER BY embedding <=> '[0.5, 0.5, 0.5, 0.5]' LIMIT 5;
```

重点看 `EXPLAIN ANALYZE` 输出里的两行：`Seq Scan` 还是 `Index Scan`，以及末尾的 `Execution Time`。一万行规模的真实对比（pgvector 0.8.5 实测）：

```text
无索引：  Seq Scan on chunks (actual time=0.007..1.010 rows=10005)
          Execution Time: 1.452 ms          ← 扫了全部 10005 行
有索引：  Index Scan using chunks_embedding_hnsw (actual time=0.462..0.472 rows=5)
          Execution Time: 0.502 ms          ← 只碰了 5 行
```

一万行下差距是 3 倍左右，还不算惊人，但注意本质差别：Seq Scan 的耗时随行数线性涨（十万行就是十倍），HNSW 的耗时对行数几乎不敏感。把 generate_series 改成十万再试，差距会拉到数量级——这就是第 3 章「ANN 用一点近似换数量级速度」的实证。

实验做完可以把这一万条清掉：`DELETE FROM chunks WHERE document_id = 'bulk';`

## 从 Node.js 连过来

SQL 会在 psql 里敲了，程序里怎么用？Node 侧官方主流驱动是 `pg`（node-postgres）：

```bash
npm install pg
```

```ts
import pg from "pg";
const { Pool } = pg;

// 连接池：维护一组可复用的数据库连接，避免每次查询都新建连接
const pool = new Pool({
  host: "localhost",
  database: "ragcourse",
  user: "postgres",
  password: "rag123",
});

// 向量用字符串字面量传给 SQL
const qVector = `[${[0.88, 0.12, 0.12, 0.08].join(",")}]`;

const { rows } = await pool.query(
  `SELECT content, embedding <=> $1 AS distance
   FROM chunks
   WHERE document_id = $2
   ORDER BY distance
   LIMIT $3`,
  [qVector, "handbook", 3]
);

for (const row of rows) console.log(row.distance.toFixed(4), row.content);
await pool.end();
```

三个要点。第一，`Pool` 是连接池：数据库连接是贵重资源，建一次 TCP 握手加认证要几十毫秒，池子预先维护几条连接反复复用，这是所有后端应用的标配姿势。第二，SQL 里的 `$1 $2 $3` 是参数占位符，值走数组传入，永远不要拿字符串拼接 SQL——拼接是 SQL 注入的温床，这条纪律从第一天就要有。第三，向量以 `'[0.88,0.12,...]'` 的字符串形式传给占位符，pgvector 在数据库侧自动解析成 vector 类型。

实战项目会在这之上再包一层 Drizzle ORM 做类型安全，但向量检索这条 SQL 会保留原生写法——ORM 对向量操作符的支持至今都不如手写 SQL 直接。

## 常见误区

**误区一：距离和相似度搞反。** `<=>` 是距离，小为好。有人按「相似度越大越好」的思路设阈值 `distance > 0.6 才保留`，结果把最相关的结果全过滤了。设阈值前先想清楚你手里拿的是距离还是相似度（第 14 章做拒答判断时还会强调）。

**误区二：建了索引查询就一定快。** 数据量小，优化器不走索引；操作符和索引类型不配套（`<=>` 配 `vector_l2_ops`），索引不生效；过滤条件把结果集筛得太小时，优化器也可能弃索引走全表。用 `EXPLAIN` 验证，别猜。

**误区三：索引是免费午餐。** HNSW 索引要占内存（图结构约为向量数据的三成），写入时还要维护图，插入更新会比无索引慢。读多写少的知识库场景完全值得，写入极其频繁的场景要掂量。

**误区四：向量库选完就万事大吉。** 数据库只负责「快」，「准」取决于 Embedding 质量和分块质量。第 10 章你会看到，检索出问题先查的永远不是索引。

## 小结与自测

本章你的向量从内存数组搬进了正经数据库：向量数据库的四大职责（存、索引、召回、过滤）；pgvector 的选型逻辑（业务数据与向量同库的价值）；`vector(n)` 类型与维度硬约束；三个距离操作符和「距离越小越相似」；HNSW 索引的建法、配套规则和验证手段；Node 侧连接池与参数化查询两条纪律。

自测：

1. `<=>` 算出来的值，0.1 和 0.9 哪个更相似？为什么这个操作符的设计容易让人搞反？
2. 同事说「我建了 HNSW 索引，但 EXPLAIN 显示还是 Seq Scan」，你会让他按什么顺序排查？
3. 实战项目「删文档级联删向量」，如果用「业务库 MySQL + 专用向量库」的双存储方案，这件事会麻烦在哪？
4. `vector(2048)` 的表，Embedding 模型换成输出 1024 维的新型号，直接写入会发生什么？正确的迁移步骤是什么？
5. 什么信号出现时，你会认真考虑把 pgvector 换成专用向量库？

模块一到此收官：背景（1）、全景（2）、Embedding（3）、分块（4）、向量库（5），索引期和查询期的每个零件你都摸过了。模块二开始上强度——第 6 章先解决「用户的问题本身就很难检索」这个现实：查询理解与改写。
