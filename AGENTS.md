# AGENTS.md — 《断链》项目说明（给 Codex / 其他编码代理）

一个单文件的 HTML5 Canvas 1v1 格斗游戏：无限连段、「破链」、按阶段「掉落」结算伤害。
网页版走 GitHub Pages，安卓安装包由 GitHub Actions 用 Capacitor 打包，账户和联机用 Supabase。

- 网页：https://lianyingxue37-coder.github.io/yingxuelian/
- 安装包：https://github.com/lianyingxue37-coder/yingxuelian/releases/latest/download/duanlian.apk
- 这一轮交给你的任务在 **CODEX_TASK.md**（后端优化 v2）。

## 仓库结构

| 文件 | 作用 |
|---|---|
| `index.html` | **整个游戏**（约 4300 行，HTML + CSS + JS 都在里面，没有构建步骤） |
| `sw.js` / `manifest.webmanifest` / `icon-*.png` | PWA |
| `download.html` | 安装包下载页（二维码） |
| `supabase_setup.sql` | 当前的 Supabase 建表脚本（profiles、matches、注册触发器、RLS） |
| `.github/workflows/android.yml` | push 到 main 后自动打 APK 并发布到 Releases（版本号取自 `<div class="ver">vX.Y`） |
| `dev/mock-supabase.js` | 本地测试用的假 supabase-js（BroadcastChannel 模拟 Realtime，可调延迟、抖动、丢包） |
| `dev/test_online.py` | Playwright：两个页面注册、进大厅、开房间、打完一整局，检查两边是否同步 |
| `dev/test_friends.py` | Playwright：加好友 → 同意 → 邀请切磋 → 打一局（不计战绩）→ 加入好友房间 → 删除好友 |

## index.html 分区（按出现顺序，搜索注释标题即可定位）

- `一、全局参数 CFG` … `七、设置项 SET`：全部数值、角色招式表（`CHARS` / `MV()` / `COMMON`）、场景、图标、按键、设置
- `输入` / `音效` / `姿势与骨架`（`POSES`、`skel`、`toWorld`）
- `角色实体`（`class Fighter`：`update` / `neutral` / `startMove` / `updMove`）
- `判定`（`hitRect` / `hurtRect` / `resolveHits`）、`核心：连段 / 暂存 / 掉落 / 破链`
- `外援 AS`、`AI`、`特效`、`回合流程`、`主循环`（`step` → `simStep`，`clampAll`）
- 绘制：场景、`角色专属技能表现 SK`、`技能化：每人三个技能`（`KIT` 技能表、冷却、技能实体 `G.ents` 里 `id: 'SK'`）、角色、粒子、HUD
- 界面与事件、全屏、虚拟摇杆
- **`账户 · 战绩 · 成就 · 联机（Supabase）`**：`SUPA` / `ACC` / `REC` / `ACH` / `NET` / `ROOM` / `LS`
  - `战绩与成就：本地缓存 + 云端同步`
  - `房间`、`帧同步（lockstep）`、`联机大厅界面`、`好友`（`friendships` 表、`fr*` 函数、好友切磋 `ROOM.spar`）
- 最后是 `window.DUANLIAN = {...}`（调试 / 测试接口，**不要删**）

## 硬性规则

1. **保持单文件**：游戏代码都留在 `index.html`，不要引入打包工具；Pages 直接发布仓库根目录。
2. **确定性**：`simStep` 里调用到的一切（对战逻辑）只能用 `grand()` / `G.rng` 取随机数；`rand()` / `Math.random()` 只能用于画面（粒子、震屏）。对战逻辑里不要读 `Date.now()` / `performance.now()`。联机是 lockstep，双方各自模拟，`lsHashOf()` 每 60 帧对一次 x / y / z / hp / 护架 / 破链 / 胜场 / 状态 / 连段。
3. **离线必须能玩**：`SUPA.URL` 为空时 `ACC.state === 'off'`，账户和联机显示「未开通」，其它模式完全不受影响。
4. **不要提交任何密钥**：客户端只用 anon / publishable key。`service_role`、数据库密码、签名证书一律不进仓库（用 Supabase 后台或 GitHub Secrets）。
5. 保留 `window.DUANLIAN` 现有字段（测试依赖它）。
6. 界面文字用中文，语气和现有文案一致；手机横屏（844×390）也要能用。
7. 版本号在 `<div class="ver">v…` 里，改动发布时顺手加一位；安卓打包会自动按它打 tag。
8. **在分支上工作并开 PR，不要直接推 main**——作者那边同时在改玩法和画面（主要在 `index.html` 前半部分），你的改动尽量集中在「账户 · 战绩 · 成就 · 联机」那一段，避免冲突。

## 本地运行与测试

```bash
python3 -m http.server 8765          # 在仓库根目录
# 浏览器打开 http://localhost:8765/index.html
pip install playwright && playwright install chromium
python3 dev/test_online.py 60 30          # 延迟 60ms、抖动 30ms
python3 dev/test_online.py 50 40 no 0.15  # 再加 15% 丢包
```

`dev/test_online.py` 会用 `dev/mock-supabase.js` 替换真实的 supabase-js，不需要联网，也不需要 Supabase 项目。
控制台里可以直接用 `window.DUANLIAN`：例如 `DUANLIAN.startMatch({mode:'cpu', p1:'CH_JIN', p2:'CH_LAN', stage:'STG_01'})`，`DUANLIAN.simStep(inA, inB)` 手动推进一帧。
