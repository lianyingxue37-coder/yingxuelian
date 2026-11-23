"""商城：用假 Supabase（dev/mock-supabase.js）走一遍浏览 → 登录 → 扫码购买链接 → 填订单号领取 → 设为称号 → 别人不能重复领取。
用法：python3 -m http.server 8765 后运行 python3 dev/test_shop.py（截图存到 /tmp/shop_*.png）"""
import asyncio, os
from playwright.async_api import async_playwright

URL = "http://127.0.0.1:8765/index.html"
MOCK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock-supabase.js")


async def local_only(route):
    if route.request.url.startswith("http://127.0.0.1:8765/"): await route.continue_()
    else: await route.fulfill(status=200, body="")


async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        ctx = await b.new_context(viewport={"width": 1280, "height": 720}, service_workers="block")
        await ctx.route("**/*", local_only)
        await ctx.add_init_script(path=MOCK)
        errors = []
        a, c = await ctx.new_page(), await ctx.new_page()
        for pg in (a, c):
            pg.on("pageerror", lambda e: errors.append(str(e)))
            await pg.goto(URL); await pg.wait_for_function("DUANLIAN.ACC.state === 'out'")

        # 未登录：能看到商品，但要先登录
        await a.evaluate("DUANLIAN.go('PG_SHOP')")
        await a.wait_for_selector("#shopBody .sitem")
        assert await a.locator("#shopBody .sitem").count() == 3
        assert await a.locator("#shopBody .sitem >> text=登录后购买").count() == 3
        assert await a.locator("#shopBody >> text=未成年人请勿购买").count() == 1

        # 登录后：购买链接指向爱发电；领取码 = DL + 用户 ID 前 8 位
        await a.evaluate("DUANLIAN.accSignUp('buyer_a', 'buyer-a-test', '买家甲', 'CH_JIN')")
        await a.wait_for_function("DUANLIAN.ACC.state === 'in'")
        await a.evaluate("DUANLIAN.go('PG_SHOP')")
        await a.wait_for_selector("#shopClaim")
        hrefs = await a.locator("#shopBody a.btn").evaluate_all("l => l.map(x => x.href)")
        assert hrefs == ["https://afdian.com/order/create?plan_id=mock1", "https://afdian.com/order/create?plan_id=mock2"], hrefs
        assert await a.locator("#shopBody >> text=即将开放").count() == 1
        uid = await a.evaluate("DUANLIAN.ACC.user.id")
        code = await a.locator(".scode").text_content()
        assert code == "DL" + uid.replace("-", "")[:8].upper(), code
        await a.screenshot(path="/tmp/shop_desktop.png")

        # 没买的商城称号挂不上
        r = await a.evaluate("DUANLIAN.ACC.sb.from('profiles').update({ title: 'SHOP_DUANLIAN' }).eq('id', DUANLIAN.ACC.user.id).then(x => !!x.error)")
        assert r, "unowned shop title accepted"

        # 填订单号领取：格式错 → 提示；没付款 → 提示；付款后 → 到账
        await a.fill("#shopClaim [name=t]", "12ab"); await a.click("#shopClaim [type=submit]")
        await a.wait_for_function("document.querySelector('#shopMsg').textContent.includes('一串数字')")
        await a.fill("#shopClaim [name=t]", "202611231234567890"); await a.click("#shopClaim [type=submit]")
        await a.wait_for_function("document.querySelector('#shopMsg') && document.querySelector('#shopMsg').textContent.includes('没找到')")
        await a.evaluate("localStorage.setItem('mock.paid', JSON.stringify({ '202611231234567890': 'SHOP_DUANLIAN' }))")
        await c.evaluate("localStorage.setItem('mock.paid', JSON.stringify({ '202611231234567890': 'SHOP_DUANLIAN' }))")
        await a.fill("#shopClaim [name=t]", "202611231234567890"); await a.click("#shopClaim [type=submit]")
        await a.wait_for_selector("[data-shopuse=SHOP_DUANLIAN]")
        await a.click("[data-shopuse=SHOP_DUANLIAN]")
        await a.wait_for_function("DUANLIAN.ACC.profile.title === 'SHOP_DUANLIAN'")
        await a.wait_for_selector("#shopBody >> text=使用中")
        # 账户页显示称号名，资料里能选商城称号
        await a.evaluate("DUANLIAN.go('PG_ACCOUNT')")
        await a.wait_for_selector("#accBody .ptitle >> text=断链者")
        await a.click("#accEditBtn")
        assert await a.locator('#accEditForm [data-ti="SHOP_DUANLIAN"]').count() == 1

        # 同一订单别人不能再领
        await c.evaluate("DUANLIAN.accSignUp('buyer_c', 'buyer-c-test', '买家丙', 'CH_LAN')")
        await c.wait_for_function("DUANLIAN.ACC.state === 'in'")
        await c.evaluate("DUANLIAN.go('PG_SHOP')"); await c.wait_for_selector("#shopClaim")
        await c.fill("#shopClaim [name=t]", "202611231234567890"); await c.click("#shopClaim [type=submit]")
        await c.wait_for_function("document.querySelector('#shopMsg') && document.querySelector('#shopMsg').textContent.includes('其他账户')")
        assert await c.locator("[data-shopuse]").count() == 0

        # 手机横屏不溢出
        await a.set_viewport_size({"width": 844, "height": 390})
        await a.evaluate("DUANLIAN.go('PG_SHOP')"); await a.wait_for_selector("#shopBody .sitem")
        assert await a.locator("#PG_SHOP .panel").evaluate("p => p.scrollWidth <= p.clientWidth + 1")
        await a.screenshot(path="/tmp/shop_phone.png")

        print("errors", errors); assert not errors
        print("shop flow passed")
        await b.close()

asyncio.run(main())
