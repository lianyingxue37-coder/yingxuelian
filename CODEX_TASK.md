# CODEX_TASK.md — 《断链》后端优化 v2

> **状态：已完成，v1.2 合并进 main。** Codex 的提交 `f184f2f`（基线 `c01f983`）和 v1.1 的技能、好友、切磋三方合并；好友表加了列级权限和每分钟 20 次的请求限流，切磋局（`setup.spar`）服务器返回 `unrated` 不计分。下面是当时的任务原文。

请先读 `AGENTS.md`（结构、硬性规则、怎么测试）。这份是本轮任务：**在不影响离线玩法的前提下，把账户 / 战绩 / 联机的后端做成“服务器说了算”、更省流量、更稳**。
在分支 `codex/backend-v2` 上完成，开一个 PR，PR 描述里写清楚：改了什么、怎么部署（要在 Supabase 里跑哪些 SQL）、怎么验证。

> **v1.1 更新（Claude 已推到 main）**：新增好友系统（`friendships` 表 + RLS，见 `supabase_setup.sql` 第 4 节；`index.html` 里的「好友」一段；`dev/test_friends.py`），以及好友切磋房间（`ROOM.spar`，不计战绩）。另外角色招式改成了技能（飞行物 / 区域 / 陷阱等，作为 `G.ents` 里 `id: 'SK'` 的实体参与确定性模拟）。
> 开 PR 前请先 `git fetch && git rebase origin/main`，并把 `friendships` 纳入你的迁移文件和测试；好友切磋的结果也不要计入排行。

## 现状（v1.0）

**认证**：Supabase Auth。账号名 `u` 映射成假邮箱 `${u}@players.duanlian.game` + 密码注册 / 登录；后台必须关闭 Confirm email。

**数据表**（见 `supabase_setup.sql`）：
- `profiles(id, username, nickname, avatar, title, stats jsonb, achievements jsonb, …)`：所有人可读，本人可改**整行**。
- `matches(id, user_id, mode, my_char, opp_char, opp_id, opp_name, result, rounds, max_hits, max_lv, stage, created_at)`：本人可读写。
- 注册触发器 `handle_new_user` 自动建 profile。

**战绩 / 成就**（`index.html` →「战绩与成就：本地缓存 + 云端同步」）：
客户端自己统计（`REC.stats` / `REC.ach`，21 个成就见 `ACH`），和云端按「取较大值」合并后整包写回 `profiles.stats / achievements`。只统计「对战电脑」和「联机」。
→ **问题：完全由客户端上报，改一下就能刷数据。**

**联机**（「房间」「帧同步（lockstep）」「联机大厅界面」）：
- 大厅：Realtime presence 频道 `duanlian-lobby`（在线列表、快速匹配、邀请）。
- 房间：broadcast 频道 `duanlian-room-<4位房号>`，消息 `sel / ready / ping / pong / start / bye / again / quit / timeout / hash / 按键`。
- 帧同步：每帧 24 位按键掩码（12 个键的按住 + 按下）；输入延迟 `D = clamp(ceil(rtt/2/16.67)+2, 3, 14)`；从对方最后确认的帧开始、每次最多重发 60 帧；每 60 帧对一次 `lsHashOf()`；断线 / 认输 / 卡住 20 秒判负。房主下发种子和 CFG（画面 / 声音类除外）。
→ **问题：每帧都发一条消息，Supabase 免费版的 Realtime 消息配额大概只够同时 2 场左右；没有断线重连；匹配只靠 presence，没有段位。**

## 目标（按优先级）

### P0　战绩由服务器认定（防作弊）
1. 客户端**不能再直接写** `profiles.stats / achievements`（RLS / 列权限收紧；昵称、头像、称号仍可本人修改，并保留现有长度 / 格式校验）。
2. 新增 `security definer` RPC（例如 `submit_online_result(room_code, frame_count, final_hash, winner_slot, summary jsonb)`）：
   - 一局联机双方各提交一次；**双方提交一致**（同房间、同帧数、同 hash、同胜方）才写入权威结果：每人一条 `matches`（标记 `verified = true`），并在数据库里重新计算该玩家的 `stats`。
   - 不一致或只有一方提交：记为待定 / 有争议，不计入战绩（给个超时规则，比如 10 分钟后只采信「对手断线 / 认输」的情形，需要你设计并写进文档）。
   - 同一房间同一局只能计一次（幂等）。
3. 「对战电脑」的结果服务器无法验证：仍可记录，但标 `verified = false`，**不进排行**。
4. 成就：能从已验证数据推出来的（胜场、联机胜场、最高连段等）改为服务器计算；推不出来的保留为本地成就，文档里说明。
5. 客户端相应改动：结果页 / 账户页显示服务器返回的数据；离线、未登录时照旧用本地记录。

### P1　联机省流量、更稳
1. **降消息频率**：按键改为每 2–4 帧打包一条（带最近若干未确认帧的冗余），掩码二进制打包（如 base64），目标每人 ≤ 15 条 / 秒；输入延迟策略相应调整。必须保持确定性和现有 hash 校验。
2. （可选，做得到更好）**WebRTC DataChannel 直连**：Supabase Realtime 只做信令（offer / answer / ICE），用公共 STUN；直连失败自动退回 Realtime 中转。对上层保持同样的 `lsSend / lsRecv` 接口。
3. **断线重连**：20 秒内回到同一房间可继续——需要保存按键历史并能从第 0 帧（或定期快照）确定性重算到当前帧。
4. 把 Realtime 用量估算写进文档（每场每分钟多少条消息、免费版能撑几场）。

### P2　匹配与排行
1. `profiles.rating`（默认 1000），在 P0 的 RPC 里按 Elo 更新（只看已验证的联机局）。
2. 服务器端匹配队列：表 + RPC（如 `mm_join / mm_leave / mm_poll`），按分数段匹配、超时放宽；快速匹配改用它（presence 继续用来显示在线列表）。
3. 排行榜：视图（前 100，按 rating，附胜场 / 胜率），游戏里加一个「排行榜」页面（菜单或账户页入口都行，界面风格照现有页面）。

### P3　运维
1. SQL 改成迁移文件：`supabase/migrations/<时间戳>_*.sql`，可重复执行；同时把 `supabase_setup.sql` 更新成“一次性完整建库脚本”，作者只需要在 SQL Editor 里整段跑一次。
2. RPC 加简单限流（每用户每分钟次数），防刷。
3. 写 `docs/BACKEND.md`：表结构、RPC、权限、限流、部署步骤、Realtime 用量、已知限制。

## 约束

- 遵守 `AGENTS.md` 的全部硬性规则（单文件、确定性、离线可玩、不提交密钥、保留 `window.DUANLIAN`、中文界面、在分支上开 PR）。
- **不要改玩法数值和画面**（作者在同时改这些）；客户端改动尽量集中在「账户 · 战绩 · 成就 · 联机」那一段。
- 不要求、也不要加入任何 `service_role` 密钥到客户端；需要高权限的逻辑放进 `security definer` 函数（或 Edge Function，若使用请写清部署方法）。
- 免费版 Supabase 能跑起来；所有新功能在 `SUPA.URL` 为空时安静地关闭。

## 验收

1. `python3 dev/test_online.py 60 30` 和 `python3 dev/test_online.py 50 40 no 0.15` 两边结束时 `same True`、`desync False`；同时打印出每人实际发送的消息条数，要比现在（约每秒 60 条）明显少。
2. 更新 `dev/mock-supabase.js` 让它能模拟新增的 RPC / 表（或另写一个测试），并新增一个脚本验证：
   - 已登录用户直接 `update profiles set stats = …` 会被拒绝；
   - 双方一致提交 → 战绩 +1；不一致 → 不计；同一局重复提交 → 只计一次。
3. 离线回归：不填 `SUPA` 时，对战电脑 / 双人 / 训练全部正常，控制台无报错。
4. 手机横屏 844×390 下新页面（排行榜等）不溢出、按钮能点。
