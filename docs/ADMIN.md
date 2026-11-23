# 《断链》运营后台

后台入口为 `/admin/`。页面沿用 GitHub Pages，玩家账户、房间和对局来自同一个 Supabase 项目。默认公开配置指向东京生产项目 `gldzmkdvbiloitgkzqsy`，使用项目的公开 API key。后台与玩家客户端使用独立的登录会话。玩家客户端仍为 v3.5，联机协议和 APK 均无发布依赖。

## 本地预览

在仓库根目录运行 `python -m http.server 8769 --bind 127.0.0.1`，打开 [演示后台](http://127.0.0.1:8769/admin/?demo=1)。演示用浏览器内存保存示例数据，刷新或点「重置演示」即可恢复初始状态。

## 启用真实后台

1. 先在测试项目应用 [后台迁移](../supabase/migrations/20261127000000_admin_console.sql)。正式项目升级时执行同一份增量迁移。全新数据库也可以用仓库根目录的 `supabase_setup.sql`。
2. 部署 [admin-accounts](../supabase/functions/admin-accounts/index.ts) Edge Function。已安装并登录 Supabase CLI 时可执行 `supabase functions deploy admin-accounts --project-ref <项目引用 ID>`。后台使用项目提供的 `SUPABASE_URL` 和 `SUPABASE_SERVICE_ROLE_KEY`，无需把密钥交给网页。该函数使用 Auth 验证用户令牌，再检查数据库的管理员名单。保留默认入口 JWT 校验。无需调整现有的 `shop` 函数。
3. 管理员先注册一个《断链》账号。建议用独立账号。用 SQL Editor 对照游戏账号名或已从 Authentication 用户列表核对的 UUID 授权。

   ```sql
   insert into duanlian_private.admin_members (uid)
   select id from public.profiles where username = '<管理员游戏账号名>'
   on conflict (uid) do nothing;
   ```

   用下列查询核对权限。撤销时在 SQL Editor 对该 UUID 执行 `delete from duanlian_private.admin_members where uid = '<已核对的 UUID>';`。撤销后已有会话的下一次管理请求会立即失去权限。

   ```sql
   select p.id, p.username
   from duanlian_private.admin_members a
   join public.profiles p on p.id = a.uid;
   ```

4. 测试环境在 `admin/config.js` 填写测试项目 URL、publishable 或 anon key，并修改显示标签。部署生产时保留东京项目配置。通过 GitHub Pages 发布后，访问 [正式后台入口](https://lianyingxue37-coder.github.io/yingxuelian/admin/)。从管理台用已授权账号登录，确认能读到数据。使用测试玩家验证停用、恢复、空房关闭和审计，另用普通玩家账号验证登录后台被拒。

## 功能与数据口径

- **总览**显示玩家资料累计、新增、租约有效的房间、仍在发送心跳的排队玩家、近 24 小时开局趋势和最近操作。待结算包含在报告截止时间前仍处于 pending 的对局，这个数也可能包含正在进行的比赛。
- **服务器**从当前浏览器检查数据库 RPC、Auth API 和能否订阅 Realtime 频道。数据库耗时包含网络请求。房间列表最多显示最近续期的 50 项，仅可关闭尚无客位的非匹配房间。房间关闭和写入日志在同一数据库事务内完成。基础设施、套餐、日志和配额仍在 Supabase Dashboard 管理。
- **玩家账户**可按账号名、昵称或完整 UUID 搜索，查看段位、注册和最近登录时间。停用会调用 Auth Admin API，阻止后续登录。已发出的短期访问令牌可能持续有效到到期。可恢复登录，管理员账号由项目所有者管理。
- **操作日志**记录管理员、对象、原因、时间和结果。Auth 修改前先落审计记录。同一个账号最多同时有一项操作在处理。出现「待核对」时，以玩家当前登录状态为准，再核对 Supabase Auth 日志。后台不会自动重发一项结果不确定的操作。
- **权限**由 `duanlian_private.admin_members` 授予。普通玩家的认证会话无法调用管理 RPC。Edge Function 的审计授权和提交接口只允许 `service_role` 调用。

## 验证

在测试项目 SQL Editor 或测试 Postgres 运行 [dev/test_admin.sql](../dev/test_admin.sql)，事务会回滚。覆盖匿名权限、普通玩家、授权撤销、账户查询和分页、空房保护、账号操作并发和审计。可一并运行现有 `dev/test_backend.sql`、`dev/test_shop.sql` 和 `dev/test_coins.sql`。

在本地演示分别检查桌面与 844×390 横屏，测试搜索、停用／恢复、关闭房间和日志。正式启用前还需在测试 Supabase 项目实测 Edge Function 与 Auth Admin API 的连接。
