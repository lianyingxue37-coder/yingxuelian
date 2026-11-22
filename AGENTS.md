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
| `supabase_setup.sql` | 完整建库 / 升级脚本（可重复运行）：资料、战绩、服务器结算与 Elo、匹配、限流、私有对局频道、好友。和 `supabase/migrations/20261121000000_backend_v2.sql` 内容一致，改一个就同步另一个 |
| `docs/BACKEND.md` | 后端说明：表与权限、结算规则、重连、流量估算、已知限制 |
| `.github/workflows/android.yml` | push 到 main 后自动打 APK 并发布到 Releases（版本号取自 `<div class="ver">vX.Y`） |
| `dev/mock-supabase.js` | 本地测试用的假 supabase-js（BroadcastChannel 模拟 Realtime，可调延迟、抖动、丢包） |
| `dev/test_online.py` | Playwright：两个页面注册、进大厅、开房间、打完一整局，检查两边是否同步 |
| `dev/test_friends.py` | Playwright：加好友 → 同意 → 邀请切磋 → 打一局（不计战绩）→ 加入好友房间 → 删除好友 |
| `dev/test_backend.sql` | 数据库断言（在测试项目或本地 Postgres 跑，结束时回滚）：权限、双边结算、争议、过期、Elo、匹配、限流、好友、切磋不计分 |

## index.html 分区（按出现顺序，搜索注释标题即可定位）

- `一、全局参数 CFG` … `七、设置项 SET`：全部数值、角色招式表（`CHARS` / `MV()` / `COMMON`）、场景、图标、按键、设置
- `输入` / `音效` / `姿势与骨架`（`POSES`、`skel`、`toWorld`）
- `角色实体`（`class Fighter`：`update` / `neutral` / `startMove` / `updMove`）
- `判定`（`hitRect` / `hurtRect` / `resolveHits`）、`核心：连段 / 暂存 / 掉落 / 破链`
- `外援 AS`、`AI`、`特效`、`回合流程`、`主循环`（`step` → `simStep`，`clampAll`）
- 绘制：场景、`角色专属技能表现 SK`、`技能化：每人三个技能`（`KIT` 技能表、冷却、技能实体 `G.ents` 里 `id: 'SK'`）、角色、粒子、HUD
- 界面与事件、全屏、虚拟摇杆
- **`账户 · 战绩 · 成就 · 联机（Supabase）`**：`SUPA` / `ACC` / `REC` / `ACH` / `NET` / `ROOM` / `LS`
  - 战绩：本机记录 + 服务器结算（`onlineResult` → `submit_online_result`，待提交的报告存本机重试）
  - `房间`（Presence 会合，`online_open` 开局）、`帧同步（lockstep）`（私有频道、批量发包、输入日志与 20 秒重连）、匹配（`mm_*`）、排行榜、`好友`（`friendships`、`fr*`、好友切磋 `ROOM.spar` → 开局参数 `setup.spar`，服务器返回 `unrated`）
- 最后是 `window.DUANLIAN = {...}`（调试 / 测试接口，**不要删**）

## 硬性规则

1. **保持单文件**：游戏代码都留在 `index.html`，不要引入打包工具；Pages 直接发布仓库根目录。
2. **确定性**：`simStep` 里调用到的一切（对战逻辑）只能用 `grand()` / `G.rng` 取随机数；`rand()` / `Math.random()` 只能用于画面（粒子、震屏）。对战逻辑里不要读 `Date.now()` / `performance.now()`。联机是 lockstep，双方各自模拟，`lsHashOf()` 每 60 帧对一次 x / y / z / hp / 护架 / 破链 / 胜场 / 状态 / 连段。
3. **离线必须能玩**：`SUPA.URL` 为空时 `ACC.state === 'off'`，账户和联机显示「未开通」，其它模式完全不受影响。
4. **不要提交任何密钥**：客户端只用 anon / publishable key。`service_role`、数据库密码、签名证书一律不进仓库（用 Supabase 后台或 GitHub Secrets）。
5. 保留 `window.DUANLIAN` 现有字段（测试依赖它）。
6. 界面文字用中文，语气和现有文案一致；手机横屏（844×390）也要能用。
7. 版本号在 `<div class="ver">v…` 里，改动发布时顺手加一位；安卓打包会自动按它打 tag。
8. **在分支上工作并开 Draft PR，不要直接推 main**——作者那边同时在改玩法和画面（主要在 `index.html` 前半部分），你的改动尽量集中在「账户 · 战绩 · 成就 · 联机」那一段，避免冲突。
9. 联机战绩只能由数据库认定：客户端不写 `profiles.stats / achievements / rating`，也不直接插 `matches`（权限已收紧）。

## 优化分支与 Claude 交接

- 每项 Codex 优化从最新的 `origin/main` 建立独立的 `codex/<主题>` 分支。提交后推送同名分支，开一个目标分支为 `main` 的 Draft PR。后续修改继续推到同一个分支，草稿由作者决定何时转为正式评审。
- 在 Draft PR 描述中交接给 Claude。写明分支和提交号、改动摘要、关键文件路径、验证命令及实际结果，以及部署步骤和待验证项。用 GitHub 上的提交、文件或 PR 链接定位代码，便于对照主线读取差异。
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
```

`dev/test_online.py` 会用 `dev/mock-supabase.js` 替换真实的 supabase-js，不需要联网，也不需要 Supabase 项目。
控制台里可以直接用 `window.DUANLIAN`：例如 `DUANLIAN.startMatch({mode:'cpu', p1:'CH_JIN', p2:'CH_LAN', stage:'STG_01'})`，`DUANLIAN.simStep(inA, inB)` 手动推进一帧。
