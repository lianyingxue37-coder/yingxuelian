"""管理后台界面测试（假后端 dev/mock-gm.js，不连真实 Supabase）。
用法：仓库根目录 python3 -m http.server 8765，然后 python3 dev/test_gm.py（截图存到 /tmp/gm_*.png）"""
import asyncio, os
from playwright.async_api import async_playwright

URL = "http://127.0.0.1:8765/admin/index.html"
MOCK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock-gm.js")


async def local_only(route):
    if route.request.url.startswith("http://127.0.0.1:8765/"): await route.continue_()
    else: await route.fulfill(status=200, body="")


async def reason(pg, text="测试"):
    await pg.wait_for_selector(".modal #mdReason")
    await pg.fill(".modal #mdReason", text)
    await pg.click(".modal [data-ok]")
    await pg.wait_for_selector(".modal", state="detached")


async def toast(pg, text):
    await pg.wait_for_function(f"document.querySelector('#toast').classList.contains('on') && document.querySelector('#toast').textContent.includes({text!r})")


async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        ctx = await b.new_context(viewport={"width": 1280, "height": 800})
        await ctx.route("**/*", local_only)
        await ctx.add_init_script(path=MOCK)
        errors = []
        pg = await ctx.new_page()
        pg.on("pageerror", lambda e: errors.append(str(e)))
        await pg.goto(URL)

        # 非管理员登不进来
        await pg.fill("#lgUser", "player_a"); await pg.fill("#lgPass", "x"); await pg.click("#lgGo")
        await pg.wait_for_function("document.querySelector('#lgErr').textContent.includes('不是管理员')")
        # 站长登录 → 总览
        await pg.fill("#lgUser", "gm_owner"); await pg.fill("#lgPass", "x"); await pg.click("#lgGo")
        await pg.wait_for_selector(".stat .n")
        assert await pg.locator(".stat").count() == 12
        await pg.screenshot(path="/tmp/gm_overview.png")

        # 玩家列表 + 搜索
        await pg.click("[data-tab=players]"); await pg.wait_for_selector("tr.click")
        assert await pg.locator("tr.click").count() == 5
        await pg.fill("#pq", "阿甲"); await pg.press("#pq", "Enter")
        await pg.wait_for_function("document.querySelectorAll('tr.click').length === 1")
        await pg.click("tr.click"); await pg.wait_for_selector("#pd h2")
        assert "阿甲" in await pg.text_content("#pd h2")
        await pg.screenshot(path="/tmp/gm_player.png", full_page=True)

        # 原因必填：不填不能确认
        await pg.click("[data-pact=kick]"); await pg.wait_for_selector(".modal")
        await pg.click(".modal [data-ok]"); assert await pg.locator(".modal").count() == 1
        await pg.fill(".modal #mdReason", "卡房间"); await pg.click(".modal [data-ok]"); await toast(pg, "已踢下线")

        # 发放物品 → 佩戴称号 → 回收（称号自动摘掉）
        await pg.wait_for_selector("#pfGive")
        await pg.select_option("#pfGive", "SHOP_PATRON"); await pg.click("[data-pact=give]"); await reason(pg, "活动奖励"); await toast(pg, "已发放")
        await pg.wait_for_selector("[data-revoke=SHOP_PATRON]")
        await pg.select_option("#pfTitle", "SHOP_PATRON"); await pg.fill("#pfNick", "阿甲改"); await pg.fill("#pfRating", "1500")
        await pg.click("[data-pact=save]"); await reason(pg, "改资料"); await toast(pg, "资料已保存")
        db = await pg.evaluate("__GM_DB.players.find(p => p.username === 'player_a')")
        assert db["title"] == "SHOP_PATRON" and db["nickname"] == "阿甲改" and db["rating"] == 1500, db
        await pg.wait_for_selector("[data-revoke=SHOP_PATRON]")
        await pg.click("[data-revoke=SHOP_PATRON]"); await reason(pg, "发错了"); await toast(pg, "已回收")
        assert await pg.evaluate("__GM_DB.players.find(p => p.username === 'player_a').title") is None
        # 回收花钱买的物品有醒目提示
        await pg.wait_for_selector("[data-revoke=SHOP_DUANLIAN]")
        await pg.click("[data-revoke=SHOP_DUANLIAN]"); await pg.wait_for_selector(".modal >> text=玩家花钱买的")
        await pg.click(".modal [data-x]")

        # 成就：给 / 收
        await pg.click("[data-ach=ACH_WIN50]"); await reason(pg); await toast(pg, "已给予成就")
        await pg.wait_for_selector("[data-ach=ACH_WIN50].on")
        await pg.click("[data-ach=ACH_WIN50]"); await reason(pg); await toast(pg, "已回收成就")
        await pg.wait_for_selector("[data-ach=ACH_WIN50]:not(.on)")

        # 封号 7 天 → 解封
        await pg.click("[data-pact=ban]"); await pg.wait_for_selector(".modal select")
        await pg.select_option(".modal select", "168"); await pg.fill(".modal #mdReason", "外挂"); await pg.click(".modal [data-ok]")
        await toast(pg, "已封号"); await pg.wait_for_selector("[data-pact=unban]")
        await pg.click("[data-pact=unban]"); await reason(pg, "申诉通过"); await toast(pg, "已解封")
        await pg.wait_for_selector("[data-pact=ban]")
        # 清空战绩
        await pg.click("[data-pact=reset]"); await reason(pg, "刷分"); await toast(pg, "战绩已清空")
        assert await pg.evaluate("__GM_DB.players.find(p => p.username === 'player_a').rating") == 1000
        # 详情里能看到这些操作
        await pg.wait_for_selector("#pd >> text=封号")
        await pg.keyboard.press("Escape"); await pg.wait_for_selector(".drawer", state="detached")

        # 商品：新建 + 批量发放（含不存在的账号）
        await pg.click("[data-tab=items]"); await pg.wait_for_selector("[data-newitem]")
        await pg.click("[data-newitem]"); await pg.wait_for_selector(".modal [name=id]")
        await pg.fill(".modal [name=id]", "SHOP_EVENT1"); await pg.fill(".modal [name=name]", "开服纪念"); await pg.fill(".modal [name=price]", "30")
        await pg.fill(".modal #mdReason", "开服活动"); await pg.click(".modal [data-ok]"); await toast(pg, "已保存")
        await pg.wait_for_selector("[data-bulk=SHOP_EVENT1]")
        await pg.click("[data-bulk=SHOP_EVENT1]"); await pg.wait_for_selector(".modal textarea")
        await pg.fill(".modal textarea", "player_b\nplayer_c, nobody_x"); await pg.fill(".modal #mdReason", "开服活动"); await pg.click(".modal [data-ok]")
        await toast(pg, "发放 2 人"); await toast(pg, "nobody_x")
        assert await pg.evaluate("__GM_DB.inv.filter(i => i.item_id === 'SHOP_EVENT1').length") == 2

        # 公告
        await pg.click("[data-tab=news]"); await pg.wait_for_selector("#nbody")
        await pg.fill("#nbody", "今晚 22:00 维护 30 分钟"); await pg.select_option("#nlevel", "warn"); await pg.click("#npost"); await toast(pg, "公告已发布")
        await pg.wait_for_selector("text=显示中")
        await pg.click("[data-news]"); await pg.click(".modal [data-ok]"); await pg.wait_for_selector("text=已下线")

        # 日志
        await pg.click("[data-tab=log]"); await pg.wait_for_selector("table")
        assert await pg.locator("table tr").count() >= 12

        # 管理员：站长加一个，再移除
        await pg.click("[data-tab=admins]"); await pg.wait_for_selector("#aduser")
        await pg.fill("#aduser", "player_c"); await pg.click("#adadd"); await reason(pg, "新同事"); await toast(pg, "已添加")
        await pg.wait_for_selector("[data-deladmin=player_c]")
        await pg.click("[data-deladmin=player_c]"); await reason(pg, "离职"); await toast(pg, "已移除")

        # 对局页
        await pg.click("[data-tab=games]"); await pg.wait_for_selector("text=4821")

        # 普通管理员：不能动站长，看不到增删管理员
        await pg.click("#logout"); await pg.wait_for_selector("#lgUser")
        await pg.fill("#lgUser", "gm_admin"); await pg.fill("#lgPass", "x"); await pg.click("#lgGo"); await pg.wait_for_function("document.querySelector('#who').textContent.includes('gm_admin')")
        await pg.click("[data-tab=admins]"); await pg.wait_for_selector("text=只有站长能增删管理员")
        await pg.click("[data-tab=players]"); await pg.wait_for_selector("tr.click")
        await pg.click("tr.click >> text=gm_owner"); await pg.wait_for_selector("[data-pact=kick]")
        await pg.click("[data-pact=kick]"); await reason(pg); await toast(pg, "不能操作其他管理员")

        # 手机横屏 / 竖屏不溢出
        for w, h in ((844, 390), (390, 844)):
            await pg.set_viewport_size({"width": w, "height": h})
            await pg.keyboard.press("Escape")
            await pg.click("[data-tab=overview]"); await pg.wait_for_selector(".stat")
            assert await pg.evaluate("document.documentElement.scrollWidth <= innerWidth + 1"), (w, h)
        await pg.click("[data-tab=players]"); await pg.wait_for_selector("tr.click"); await pg.click("tr.click >> text=player_a"); await pg.wait_for_selector("#pd h2")
        await pg.screenshot(path="/tmp/gm_phone.png")

        print("errors", errors); assert not errors
        print("gm console passed")
        await b.close()

asyncio.run(main())


async def game_announcement():
    """游戏标题页：显示生效公告一次，点「知道了」后不再弹；有第二条接着弹"""
    async with async_playwright() as p:
        b = await p.chromium.launch()
        ctx = await b.new_context(viewport={"width": 1280, "height": 720}, service_workers="block")
        await ctx.route("**/*", local_only)
        await ctx.add_init_script(path=os.path.join(os.path.dirname(MOCK), "mock-supabase.js"))
        await ctx.add_init_script("localStorage.setItem('mock.ann', JSON.stringify([{id: 1, body: '欢迎来到断链', level: 'info'}, {id: 2, body: '今晚维护', level: 'warn'}]))")
        errors = []
        pg = await ctx.new_page(); pg.on("pageerror", lambda e: errors.append(str(e)))
        await pg.goto(URL.replace("admin/index.html", "index.html"))
        await pg.wait_for_selector("#modal:not([hidden]) >> text=今晚维护")
        assert await pg.locator("#modal >> text=重要公告").count() == 1
        await pg.click("#annOk")
        await pg.wait_for_selector("#modal:not([hidden]) >> text=欢迎来到断链")
        await pg.click("#annOk"); await pg.wait_for_selector("#modal", state="hidden")
        await pg.reload(); await pg.wait_for_function("DUANLIAN.ACC.state !== 'loading'"); await pg.wait_for_timeout(1500)
        assert await pg.locator("#modal:not([hidden])").count() == 0, "seen announcement shown again"
        print("errors", errors); assert not errors
        print("game announcement passed")
        await b.close()

asyncio.run(game_announcement())
