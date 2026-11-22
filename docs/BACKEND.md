# 《断链》后端与联机

## Supabase 部署

1. 在测试项目验证后，备份生产项目。可在 Supabase **SQL Editor** 整段运行根目录 [supabase_setup.sql](../supabase_setup.sql)。它按顺序包含 [后端 v2 迁移](../supabase/migrations/20261121000000_backend_v2.sql) 和 [v1.5 房间迁移](../supabase/migrations/20261122000000_online_rooms.sql)，支持重复执行。已上线 v1.2 到 v1.4 的项目可只执行 v1.5 迁移。用 CLI 管理时按时间戳依序应用迁移。
2. 在 **Authentication → Sign In / Providers → Email** 开启 Email 登录和注册。继续使用账号名注册时保留 **Confirm email** 关闭。要启用真实邮箱验证码注册与找回密码，按下节配置邮件。
3. 在 **Realtime → Settings** 保持 Realtime 和 **Allow public access** 开启。大厅使用公共频道，v1.5 的选人房间和正式对局各使用私有频道，迁移已设置参赛者策略。
4. 在页面启动脚本执行前配置 `window.DUANLIAN_SUPA = { URL, KEY, EMAIL_AUTH }`，或在部署版本的 `index.html` 填写同名 `SUPA` 字段。使用项目 URL 和 publishable key（已有项目也可用 anon key）。客户端配置留空时，离线玩法照常可用。
5. 发布更新后的网页和安装包。让两位测试玩家用不同的浏览器配置登录，分别试一次「创建房间／加入房间」和「快速匹配」。打完后检查双方结算出现「服务器已确认」、最近对战出现「已验证」，以及排行榜分数、胜场和胜率。再于对战中断网几秒，在 20 秒内恢复连接，或用同一个账号和浏览器重新加载并回到同一房间。

升级保留账号、昵称、合法头像与称号及旧对战行。旧对战行标为未验证。原来的云端累计数据由 v1 客户端写入，第一次迁移会清空；玩家从 1000 分和零场已验证战绩开始。浏览器本地缓存继续可读。升级期间，旧客户端的云端战绩写入会被数据库拒绝，玩家需要使用同一联机协议版本。

## 账号登录与恢复

- 账号名模式沿用 `<账号名>@players.duanlian.game`。老玩家照常用账号名登录，登录后可在账户页用当前密码改密，并继续管理昵称、头像与称号。历史账号使用的占位邮箱无法收信，邮箱找回适用于用真实邮箱注册的账号。
- 启用真实邮箱时，在 Supabase 开启 **Confirm email**，配置可用的 SMTP，再编辑 **Authentication → Email Templates** 下的 **Confirm signup** 和 **Reset password** 模板。两封邮件都应显示验证码 `{{ .Token }}`，玩家在游戏中输入验证码完成注册或找回。建议先在测试项目实收邮件，确认模板显示验证码。
- 邮件可正常送达后，把网页和 APK 的客户端设置为 `EMAIL_AUTH: true`。新玩家填写账号名和真实邮箱，邮箱用于登录及找回，账号名用来被好友搜索。邮箱由 Auth 保存，游戏公开资料和排行榜继续只显示游戏身份。找回使用独立的临时认证会话，完成后回到登录页。[Supabase 密码安全](https://supabase.com/docs/guides/auth/password-security) · [邮箱验证码](https://supabase.com/docs/guides/auth/auth-email-templates)

## 数据、权限与结算

| 对象 | 用途和写入权限 |
| --- | --- |
| `public.profiles` | Auth 注册触发器建档。客户端可读资料，本人可更新昵称、头像和称号，数据库校验格式并更新 `updated_at`。累计战绩、云端成就和 Elo 由数据库写入。 |
| `public.matches` | 客户端仅可读自己的记录。双方确认后各写一行 `verified=true`，以 `(game_id, user_id)` 唯一约束防重复。CPU 和 v1 历史为 `verified=false`。 |
| `duanlian_private.games / reports` | 每场独立 UUID，对应房间号、双方账号、种子、设置和结算状态。每名参赛者的第一份报告固定。 |
| `duanlian_private.rooms` | 房号、房主、客位、租约和当前邀请。只有房间 RPC 和 Realtime 策略访问。 |
| `duanlian_private.mm_queue / rpc_limits` | 排队心跳、配对结果和每账号每接口的分钟计数，客户端通过必要的 RPC 使用。 |
| `public.friendships` | 好友关系。只能以自己名义发请求（列权限只开 `requester / addressee`，状态固定为 pending），只有被加的一方能把状态改成 accepted，双方都能删除，第三人不可见。每账号每分钟最多 20 次请求。 |
| `public.duanlian_leaderboard` | 公开读取前 100 名，只收录有已确认战绩的玩家。按段位分、联机胜场和账号 ID 排序，胜率为胜场除以全部已确认场次。 |

- v1.5 的 `room_start` 按服务器记录的双方和切磋模式开局，并复用 `online_open` 登记本局，`online_game` 只向参赛账号返回开局参数。正式对局频道按游戏 UUID 鉴权；只有这两个账号可订阅或发送私有战斗广播。
- `submit_online_result` 用登录账号识别报告方。两份报告的帧数、最终 hash、胜方和双方回合数／最高连段／最高掉落阶段完全一致时，使用同一事务写双边记录、重算双方已验证统计和成就、更新 Elo。默认 1000 分，K=32，平局计 0.5。重复请求返回已有状态，不重复计分。
- 第一份报告进入待确认状态，从第一份报告起接受第二份报告 10 分钟，且最晚截止到开局后 2 小时。双方报告冲突记为争议。迟到的请求会把仍待定的局标为过期。超时、认输、断线未恢复、只有单边报告或双方报告冲突均不进已验证战绩和排行榜。
- 好友切磋的房间模式由服务器认定，客位仅向已互加的好友开放。房主仍可选局数。切磋结果返回 `unrated`，不写战绩和 Elo。好友请求与房间邀请的大厅广播用于提醒，客户端重新读取对应的服务端记录。
- `record_cpu_match` 保存已登录玩家的 CPU 对战记录，标为未验证。离线玩法继续记录本机数据。初出茅庐、胜场、累计场次、联机胜场、最高连段、最高掉落和全角色获胜可从已验证记录计算。终结技、破链、弹反、燃链、反弹、侧闪、投技、满血胜回合及最高难度 CPU 胜利成就保存在本机。对战电脑也能在本机解锁基于场次等条件的成就。
- `mm_join / mm_poll / mm_leave` 开始、刷新、取消排队。每 1.6 秒轮询一次，初始容许 100 分差，每等待满 10 秒再扩大 100 分，优先匹配分差较小的账号。8 秒无心跳的等待者失效，已分配的配对保留 15 秒供另一方领取。Presence 只负责显示在线状态以及房间会合。
- `room_create / room_enter / room_touch / room_exit` 分配四位房号并管理席位和租约。房主与客人分别约每 25 秒续期一次，失联后席位在 90 秒内保留，战斗重连仍按 20 秒的输入窗口处理。房主主动离开会关房，普通客人离开会释放客位。v1.5 匹配队列与旧协议分开。
- `room_invite / room_invites / room_decline` 保存、读取和拒绝邀请。邀请为收件人锁定客位 45 秒，只有收件人可读取和拒绝。客户端定期检查邀请，广播丢失时也能显示。大厅的在线状态和房号提示来自 Presence，入房资格和私有频道访问由数据库检查。
- 每账号按固定分钟窗口限流。开局 12 次、读取开局 60 次、提交或查询结果 45 次、CPU 记录 20 次、加入及取消排队各 15 次、排队轮询 55 次。创建房间与邀请各 12 次，入房、续期、离房与拒绝邀请各 24 次，读邀请 30 次。事务回滚的错误请求不消耗计数。结果确认失败时，客户端在当前账号下保存待提交报告并重试。

## 联机、重连与流量

每约 66.7 ms 发送一批输入，满速时对应四个 60 Hz 模拟帧。每帧的 24 位掩码占 3 字节，按连续帧做 Base64 编码；每批最多包含 32 帧，从对手尚未确认的第一帧重发。批次还携带输入确认号和最近的每 60 帧状态 hash。输入延迟根据往返时间取 7–20 帧。

同一个浏览器配置和账号保存分块的双方输入、房间和对局 ID。页面刷新后自动尝试恢复，重新进入相同房号也可恢复。客户端从相同种子回放到最近已保存的帧，并重新确认输入进度。没有新帧可推演时最多等待 20 秒。保持浏览器存储可用，并尽量使用同一标签页，或关闭旧标签后再重进房间。换设备、清空站点存储和多个标签页同时操作同一账号可能导致恢复失败。

满速一局每秒约 30 条客户端发送的 Broadcast，即 **1,800 条发送／场／分钟**。每条转发给另一人，Supabase 按发送和投递分别计数，约 **3,600 条计费消息／场／分钟**。这个估算不含大厅、选人、重连和结算尾部广播；没有启用 Broadcast ACK。免费项目的 100 条消息／秒上限适合一场满速对局，仍需为大厅留余量。两场满速约 120 条／秒。按每月 200 万条估算，约 9.3 小时的总对局时间，实际用量请看项目 Realtime Reports。[Realtime 限额](https://supabase.com/docs/guides/realtime/limits) · [消息计量](https://supabase.com/docs/guides/platform/manage-your-usage/realtime-messages)

## 验证

```bash
python -m pip install playwright
python -m playwright install chromium
python -m http.server 8765
```

在另一个终端执行：

```bash
python dev/test_online.py 60 30
python dev/test_online.py 50 40 no 0.15
python dev/test_online.py 50 40 reload 0.15
python dev/test_online.py 50 40 quick 0.15
python dev/test_friends.py
python dev/test_accounts_rooms.py
```

前两组应输出 `same True`，双方 `desync: False`、`verdict: verified` 和 `onG: 1`。每名玩家的 `input` 和 `input_per_s` 是从开局到结算的实际输入包数和速率，`sent` 是 mock 频道记录的总发送次数，含 Presence、选人和结算尾部。第三组模拟断线并刷新，第四组用 844×390 视口测试快速匹配和排行榜。好友脚本验证切磋不计战绩，账号和房间脚本验证邮箱验证码、改密、找回、旧账号登录，以及丢广播后的邀请、抢座限制和座位释放。

在测试 Supabase 项目的 SQL Editor 运行 [dev/test_backend.sql](../dev/test_backend.sql)，或使用连接到测试数据库的管理员运行该文件。测试当场回滚，检查受保护列、第三方无权结算、双方一致、争议、过期、重试幂等、CPU 记录、匹配范围放宽、限流、私有房间参赛权限、邀请可见性和队列协议隔离。用默认空 `SUPA` 打开网页也可验证对战电脑、双人对战和训练。

## 已知限制

数据库验证参赛身份和报告一致性。两个串通的账号仍可能提交相同的虚假报告，修改过的客户端也可拒绝提交输局。服务器当前不运行战斗模拟，且房主仍提供双方共用的规则参数。公开大厅沿用 Presence 提供在线提示，房间与战斗数据走各自的 Realtime 私有频道。待定和争议记录会留在数据库，游戏没有自动清理任务。
