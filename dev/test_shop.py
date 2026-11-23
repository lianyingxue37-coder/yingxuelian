"""商城（v3.5 断链币）：用假 Supabase（dev/mock-supabase.js）走一遍
浏览 → 登录 → 通道未开通 → 充值出付款码 → 余额不足 → 付款到账（轮询）→ 确认解锁 → 设为称号 → 手机横屏。
用法：python3 -m http.server 8765 后运行 python3 dev/test_shop.py（截图存到 /tmp/shop_*.png）"""
import asyncio, os
from playwright.async_api import async_playwright

URL = "http://127.0.0.1:8765/index.html"
MOCK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock-supabase.js")


async def local_only(route):
    if route.request.url.startswith("http://127.0.0.1:8765/"): await route.continue_()
    else: await route.fulfill(status=200, body="")


async def msg(pg, text):
    await pg.wait_for_function(f"document.querySelector('#shopMsg') && document.querySelector('#shopMsg').textContent.includes({text!r})")


async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        ctx = await b.new_context(viewport={"width": 1280, "height": 720}, service_workers="block")
        await ctx.route("**/*", local_only)
        await ctx.add_init_script(path=MOCK)
        errors = []
        a = await ctx.new_page()
        a.on("pageerror", lambda e: errors.append(str(e)))
        await a.goto(URL); await a.wait_for_function("DUANLIAN.ACC.state === 'out'")

        # 未登录：能看到商品和价格，但要先登录
        await a.evaluate("DUANLIAN.go('PG_SHOP')")
        await a.wait_for_selector("#shopBody .sitem")
        assert await a.locator("#shopBody .sitem").count() == 3
        assert await a.locator("#shopBody .sitem >> text=登录后购买").count() == 3
        assert await a.locator("#shopBody >> text=未成年人请勿购买").count() == 1

        # 登录，但充值通道还没开通：显示开通中，解锁按钮是「即将开放」
        await a.evaluate("localStorage.setItem('mock.yrf', JSON.stringify('off'))")
        await a.evaluate("DUANLIAN.accSignUp('buyer_a', 'buyer-a-test', '买家甲', 'CH_JIN')")
        await a.wait_for_function("DUANLIAN.ACC.state === 'in'")
        await a.evaluate("DUANLIAN.go('PG_SHOP')")
        await a.wait_for_selector("#shopBody >> text=充值通道开通中")
        assert await a.locator("#shopBody >> text=即将开放").count() == 3
        assert await a.locator("[data-shopbuy]").count() == 0

        # 开通后：余额 0，有两个积分包；没定价的称号仍是即将开放
        await a.evaluate("localStorage.removeItem('mock.yrf')")
        await a.click("[data-shoprefresh]")
        await a.wait_for_selector("[data-shopbuy=sku60]")
        assert await a.locator(".swallet .sp").text_content() == "0"
        assert await a.locator("[data-shopbuy]").count() == 2
        assert await a.locator("#shopBody >> text=即将开放").count() == 1

        # 没买的商城称号挂不上
        r = await a.evaluate("DUANLIAN.ACC.sb.from('profiles').update({ title: 'SHOP_DUANLIAN' }).eq('id', DUANLIAN.ACC.user.id).then(x => !!x.error)")
        assert r, "unowned shop title accepted"

        # 余额不足：先要确认，确认后提示去充值，不发放
        await a.click("[data-shopconfirm=SHOP_DUANLIAN]")
        await a.wait_for_selector("[data-shopunlock=SHOP_DUANLIAN] >> text=确认花 60 币")
        await a.click("[data-shopunlock=SHOP_DUANLIAN]")
        await msg(a, "断链币不够")
        assert await a.locator("[data-shopuse]").count() == 0

        # 充值：出付款码（这里没有图片地址，就本地画二维码）和打开支付宝的链接
        await a.click("[data-shopbuy=sku60]")
        await a.wait_for_selector(".spay svg.sqr")
        href = await a.locator(".spay a.btn").get_attribute("href")
        assert href.startswith("alipays://"), href
        await a.screenshot(path="/tmp/shop_pay.png")
        # 「付款」：余额 +60，轮询自动到账并收起付款码
        uid = await a.evaluate("DUANLIAN.ACC.user.id")
        await a.evaluate(f"localStorage.setItem('mock.coins', JSON.stringify({{ '{uid}': 60 }}))")
        await a.wait_for_function("!document.querySelector('.spay') && document.querySelector('.swallet .sp').textContent === '60'", timeout=15000)

        # 解锁成功 → 扣 60 → 设为称号
        await a.click("[data-shopconfirm=SHOP_DUANLIAN]")
        await a.click("[data-shopunlock=SHOP_DUANLIAN]")
        await a.wait_for_selector("[data-shopuse=SHOP_DUANLIAN]")
        assert await a.locator(".swallet .sp").text_content() == "0"
        await a.click("[data-shopuse=SHOP_DUANLIAN]")
        await a.wait_for_function("DUANLIAN.ACC.profile.title === 'SHOP_DUANLIAN'")
        await a.wait_for_selector("#shopBody >> text=使用中")
        # 取消确认能回去
        await a.click("[data-shopconfirm=SHOP_ZHONGYAN]")
        await a.click("[data-shopconfirm='']")
        await a.wait_for_selector("[data-shopconfirm=SHOP_ZHONGYAN] >> text=解锁 · 120 币")

        # 账户页显示称号名，资料里能选商城称号
        await a.evaluate("DUANLIAN.go('PG_ACCOUNT')")
        await a.wait_for_selector("#accBody .ptitle >> text=断链者")
        await a.click("#accEditBtn")
        assert await a.locator('#accEditForm [data-ti="SHOP_DUANLIAN"]').count() == 1

        # 手机横屏不溢出（带付款码）
        await a.set_viewport_size({"width": 844, "height": 390})
        await a.evaluate("DUANLIAN.go('PG_SHOP')"); await a.wait_for_selector("#shopBody .sitem")
        await a.click("[data-shopbuy=sku130]"); await a.wait_for_selector(".spay")
        assert await a.locator("#PG_SHOP .panel").evaluate("p => p.scrollWidth <= p.clientWidth + 1")
        await a.screenshot(path="/tmp/shop_phone.png", full_page=True)
        await a.click("[data-shopclose]"); await a.wait_for_selector(".spay", state="detached")

        print("errors", errors); assert not errors
        print("shop flow passed")
        await b.close()

asyncio.run(main())
