# AGENTS.md — 《断链》项目说明（给 Codex / 其他编码代理）

一个单文件的 HTML5 Canvas 1v1 格斗游戏：无限连段、「破链」、按阶段「掉落」结算伤害。
网页版走 GitHub Pages，安卓安装包由 GitHub Actions 用 Capacitor 打包，账户和联机用 Supabase。

- 网页：https://lianyingxue37-coder.github.io/yingxuelian/
- 安装包：https://github.com/lianyingxue37-coder/yingxuelian/releases/latest/download/duanlian.apk
- 后端设计、部署和流量估算见 **docs/BACKEND.md**；上一轮任务记录在 CODEX_TASK.md（后端 v2，已在 v1.2 合并）。

## 仓库结构

| 文件 | 作用 |
|---|---|
| `index.html` | **整个游戏**（约 4900 行，HTML + CSS + JS 都在里面，没有构建步骤） |
| `sw.js` / `manifest.webmanifest` / `icon-*.png` | PWA |
| `download.html` | 安装包下载页（二维码） |
| `supabase_setup.sql` | 完整建库 / 升级脚本（可重复运行）：资料、战绩、服务器结算与 Elo、匹配、限流、私有对局频道、好友、服务器房间与邀请。按时间戳拼接 `supabase/migrations/` 下的迁移，增量 SQL 和完整脚本保持一致 |
| `docs/BACKEND.md` | 后端说明：表与权限、结算规则、重连、流量估算、已知限制 |
| `.github/workflows/android.yml` | push 到 main 后自动打 APK 并发布到 Releases（版本号取自 `<div class="ver">vX.Y`） |
| `dev/mock-supabase.js` | 本地测试用的假 supabase-js（BroadcastChannel 模拟 Realtime，可调延迟、抖动、丢包） |
| `dev/test_online.py` | Playwright：两个页面注册、进大厅、开房间、打完一整局，检查两边是否同步 |
| `dev/test_friends.py` | Playwright：加好友 → 同意 → 邀请切磋 → 打一局（不计战绩）→ 加入好友房间 → 删除好友 |
| `dev/test_accounts_rooms.py` | Playwright：登录、邮箱验证、改密与找回、私有房间和邀请 |
| `dev/test_backend.sql` | 数据库断言（在测试项目或本地 Postgres 跑，结束时回滚）：权限、双边结算、争议、过期、Elo、匹配、限流、好友、切磋不计分 |

## index.html 分区（按出现顺序，搜索注释标题即可定位）

- `一、全局参数 CFG` … `七、设置项 SET`：全部数值、角色招式表（`CHARS` / `MV()` / `COMMON`）、场景、图标、按键、设置
- `输入` / `音效` / `姿势与骨架`（`POSES`、`skel`、`toWorld`）
- `角色实体`（`class Fighter`：`update` / `neutral` / `startMove` / `updMove`）
- `判定`（`hitRect` / `hurtRect` / `resolveHits`）、`核心：连段 / 暂存 / 掉落 / 破链`
- `外援 AS`、`AI`、`特效`、`回合流程`、`主循环`（`step` → `simStep`，`clampAll`）
- 绘制：场景、`角色专属技能表现 SK`、`技能化：每人三个技能`（`KIT` 技能表、冷却、技能实体 `G.ents` 里 `id: 'SK'`）、角色、粒子、HUD
- `忍术化（v1.3）`：结印（`wpose: 'sealW'`）、术名（`jn`）、各技能的画法 `NJ_DRAW` / `NJ_FRONT`、奥义演出 `G.cine`（`njUltStart` / `njCineTick` / `NJ_ULT`）、替身术 `njSubstitute`
- `兵器化（v1.4）`：每人一件兵器（`WP`）、轻击三段和重击的招式表 `WP_MOVES`（`L → L2 → L3`，靠 `move.next` 串起来）、兵器画法 `wpJian` / `wpHammer` / `wpSpear` 等、出招特效 `WP_FX`、命中追加 `WP_HIT`、兵器音效 `WP_SFX`
- 界面与事件、全屏、虚拟摇杆
- **`账户 · 战绩 · 成就 · 联机（Supabase）`**：`SUPA` / `ACC` / `REC` / `ACH` / `NET` / `ROOM` / `LS`
  - 战绩：本机记录 + 服务器结算（`onlineResult` → `submit_online_result`，待提交的报告存本机重试）
  - `房间`（数据库房号、席位和邀请，私有 Presence，`room_start` 开局）、`帧同步（lockstep）`（私有频道、批量发包、输入日志与 20 秒重连）、匹配（`mm_*`）、排行榜、`好友`（`friendships`、`fr*`、好友切磋 `ROOM.spar` → 开局参数 `setup.spar`，服务器返回 `unrated`）
- 最后是 `window.DUANLIAN = {...}`（调试 / 测试接口，**不要删**）

## 硬性规则

1. **保持单文件**：游戏代码都留在 `index.html`，不要引入打包工具；Pages 直接发布仓库根目录。
2. **确定性**：`simStep` 里调用到的一切（对战逻辑）只能用 `grand()` / `G.rng` 取随机数；`rand()` / `Math.random()` 只能用于画面（粒子、震屏）。对战逻辑里不要读 `Date.now()` / `performance.now()`。联机是 lockstep，双方各自模拟，`lsHashOf()` 每 60 帧对一次 x / y / z / hp / 护架 / 破链 / 胜场 / 状态 / 连段。
3. **离线必须能玩**：`SUPA.URL` 为空时 `ACC.state === 'off'`，账户和联机显示「未开通」，其它模式完全不受影响。
4. **不要提交任何密钥**：客户端只用 anon / publishable key。`service_role`、数据库密码、签名证书一律不进仓库（用 Supabase 后台或 GitHub Secrets）。
5. 保留 `window.DUANLIAN` 现有字段（测试依赖它）。
   奥义演出 `G.cine` 期间 `simStep` 只推进演出帧（双方同一帧开始、同样长度）；改演出长度或替身落点时，两边必须仍然一致。
   防御键、主动跳跃和空中追击已移除。闪避依赖侧闪、后撤步和替身术（`evade()` 的统计仍记在 `stats.parries`）。受击飞起和倒地保留，角色落地后恢复操作。联机输入中原跳跃和防御的位置保持为零。
6. 界面文字用中文，语气和现有文案一致；手机横屏（844×390）也要能用。
7. 版本号在 `<div class="ver">v…` 里，改动发布时顺手加一位；安卓打包会自动按它打 tag。
8. **在分支上验证并通过 PR 发布，不要直接推 main**。以最新主线为基线，避免覆盖作者同时进行的玩法和画面改动。通过验收后直接发布正式版，作者指定保留草稿时再停在草稿。
9. 联机战绩只能由数据库认定：客户端不写 `profiles.stats / achievements / rating`，也不直接插 `matches`（权限已收紧）。

## 待办（给 Codex）

- **联机协议**：v1.7 地面战斗使用协议 15。修改确定性对战规则时，同步更新大厅、房间、开局参数和匹配协议。先部署兼容旧客户端的数据库迁移，再发布客户端。

## 正式发布与 Claude 交接

- 每项优化从最新的 `origin/main` 建立或更新相应分支。通过本地和相关联机验证后，合并到 `main` 并检查 GitHub Pages 与安卓构建，确认网页和安装包均为本次版本。
- 在 PR 描述中交接给 Claude。写明分支和提交号、改动摘要、关键文件路径、验证命令及实际结果、部署步骤和发布链接。
- 如果暂时无法推送，保留本地分支，并提供源码或可应用的补丁，以及包含相同信息的交接说明。打包时排除 `.git` 和本机凭据。

## 本地运行与测试

```bash
python3 -m http.server 8765          # 在仓库根目录
# 浏览器打开 http://localhost:8765/index.html
pip install playwright && playwright install chromium
python3 dev/test_online.py 60 30          # 延迟 60ms、抖动 30ms
python3 dev/test_online.py 50 40 no 0.15  # 再加 15% 丢包
python3 dev/test_online.py 50 40 reload 0.15  # 对局中断线、刷新后恢复
python3 dev/test_online.py 50 40 quick 0.15   # 快速匹配 + 844×390 排行榜
python3 dev/test_friends.py
python3 dev/test_accounts_rooms.py
```

`dev/test_online.py` 会用 `dev/mock-supabase.js` 替换真实的 supabase-js，不需要联网，也不需要 Supabase 项目。
控制台里可以直接用 `window.DUANLIAN`：例如 `DUANLIAN.startMatch({mode:'cpu', p1:'CH_JIN', p2:'CH_LAN', stage:'STG_01'})`，`DUANLIAN.simStep(inA, inB)` 手动推进一帧。
