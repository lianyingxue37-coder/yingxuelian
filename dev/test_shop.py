"""商城预览、七张立绘、已拥有称号和横屏回归。"""
import os
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

URL = os.environ.get("URL", "http://127.0.0.1:8765/index.html")
MOCK = Path(__file__).with_name("mock-supabase.js")


def main():
    with sync_playwright() as p:
        chrome = os.environ.get("CHROME")
        browser = p.chromium.launch(**({"executable_path": chrome} if chrome else {}))
        ctx = browser.new_context(viewport={"width": 844, "height": 390}, service_workers="block")
        ctx.add_init_script(path=MOCK)
        origin = URL.rsplit("/", 1)[0]
        ctx.route("**/*", lambda route: route.continue_() if route.request.url.startswith(origin + "/") else route.abort())
        page = ctx.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.goto(URL)
        page.wait_for_function("DUANLIAN.ACC.state === 'out'")
        page.locator("[data-go=PG_SHOP]").click()
        expect(page.get_by_role("button", name="支付宝 · 即将上线")).to_be_disabled()
        expect(page.get_by_role("button", name="微信支付 · 即将上线")).to_be_disabled()
        expect(page.get_by_role("heading", name="全角色立绘组合包")).to_be_visible()
        expect(page.locator(".portrait-pack .shopsoon")).to_have_text("即将上线")
        expect(page.locator("[data-shop-portrait]")).to_have_count(7)
        for button in page.locator("[data-shop-portrait]").all():
            button.click()
            expect(page.locator("#shopPreview")).to_be_visible()
            page.wait_for_function("document.querySelector('#shopPreview img').naturalWidth > 0")
            page.get_by_role("button", name="关闭预览").click()
        assert page.locator("#PG_SHOP .panel").evaluate("(p) => p.scrollWidth <= p.clientWidth + 1")

        page.evaluate("DUANLIAN.accSignUp('buyer_a', 'buyer-a-test', '测试买家', 'CH_JIN')")
        page.wait_for_function("DUANLIAN.ACC.state === 'in'")
        page.evaluate("""() => localStorage.setItem('mock.t.inventory', JSON.stringify([
            { uid: DUANLIAN.ACC.user.id, item_id: 'SHOP_DUANLIAN' },
            { uid: DUANLIAN.ACC.user.id, item_id: 'SHOP_PORTRAITS' },
        ]))""")
        page.evaluate("DUANLIAN.go('PG_TITLE'); DUANLIAN.go('PG_SHOP')")
        expect(page.locator(".portrait-pack").get_by_text("已拥有")).to_be_visible()
        page.get_by_role("button", name="设为称号").click()
        expect(page.locator("#shopBody").get_by_text("使用中")).to_be_visible()
        expect(page.locator("[data-shopbuy],[data-shopunlock],.spay")).to_have_count(0)
        page.evaluate("DUANLIAN.go('PG_ACCOUNT')")
        expect(page.locator("#accBody .ptitle").get_by_text("断链者")).to_be_visible()
        page.locator("#accEditBtn").click()
        expect(page.locator("[data-ti=SHOP_PORTRAITS]")).to_have_count(0)
        assert not errors, errors
        print("shop preview passed: disabled channels, 7 portraits, entitlements, 844x390")
        browser.close()


if __name__ == "__main__":
    main()
