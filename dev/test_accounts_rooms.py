"""在 844×390 视口检查账号、验证码与服务器房间。需启动本地 HTTP 服务。"""
import asyncio
import os
from pathlib import Path

from playwright.async_api import async_playwright

URL = "http://127.0.0.1:8765/index.html"
EMAIL = "pilot@example.test"
OTP = "384759"


async def local_only(route):
    if route.request.url.startswith("http://127.0.0.1:8765/"):
        await route.continue_()
    else:
        await route.fulfill(status=200, body="")


async def submit(page, selector, **fields):
    for name, value in fields.items():
        await page.locator(f"{selector} [name={name}]").fill(value)
    await page.locator(f"{selector} [type=submit]").click()


async def signed_in(page):
    await page.wait_for_function("DUANLIAN.ACC.state === 'in'")


async def signed_out(page):
    await page.locator("#accOut").click()
    await page.wait_for_function("DUANLIAN.ACC.state === 'out'")


async def login(page, password):
    await submit(page, "#accForm", u=EMAIL, p=password)


async def make_pages(ctx, errors):
    pages = [await ctx.new_page() for _ in range(3)]
    for page in pages:
        page.on("pageerror", lambda e: errors.append(str(e)))
        await page.goto(URL)
        await page.wait_for_function("DUANLIAN.ACC.state === 'out'")
    return pages


async def account_flow(a):
    await a.click("#accChip")
    await a.click('[data-acctab="up"]')
    await submit(a, "#accForm", u="pilot", email=EMAIL, p="initial-test", n="测试玩家")
    await a.wait_for_selector("#accChallenge")
    assert await a.evaluate("DUANLIAN.ACC.state") == "out"
    await submit(a, "#accChallenge", token="000001")
    await a.wait_for_function("document.querySelector('#accChallenge [role=alert]').textContent")
    await a.click("#accResend")
    await a.wait_for_function("!DUANLIAN.ACC.busy")
    await submit(a, "#accChallenge", token=OTP)
    await signed_in(a)
    assert await a.evaluate("DUANLIAN.ACC.profile.username") == "pilot"

    await a.click("#accEditBtn")
    await a.fill("#accEditForm [name=n]", "飞行员")
    await a.click('#accEditForm [data-av="CH_LEI"]')
    await a.click("#accEditForm [type=submit]")
    await a.wait_for_function("DUANLIAN.ACC.profile.nickname === '飞行员' && DUANLIAN.ACC.profile.avatar === 'CH_LEI'")
    await a.click("#accPasswordBtn")
    await submit(a, "#accPassword", current="wrong-test", p="changed-test", again="changed-test")
    await a.wait_for_function("document.querySelector('#accPassword [role=alert]').textContent")
    await submit(a, "#accPassword", current="initial-test", p="changed-test", again="changed-test")
    await a.wait_for_selector("#accPassword", state="detached")
    await signed_out(a)
    await login(a, "initial-test")
    await a.wait_for_function("document.querySelector('#accForm [role=alert]').textContent")
    await login(a, "changed-test")
    await signed_in(a)
    await signed_out(a)

    await a.click('[data-acctab="recover"]')
    await submit(a, "#accRecover", email=EMAIL)
    await submit(a, "#accChallenge", token=OTP, p="recovered-test", again="recovered-test")
    await a.wait_for_selector("#accForm")
    assert await a.evaluate("DUANLIAN.ACC.state") == "out"
    await login(a, "changed-test")
    await a.wait_for_function("document.querySelector('#accForm [role=alert]').textContent")
    await login(a, "recovered-test")
    await signed_in(a)
    assert await a.evaluate("DUANLIAN.ACC.profile.nickname") == "飞行员"
    assert await a.locator("#PG_ACCOUNT .panel").evaluate("p => p.scrollWidth <= p.clientWidth + 1")
    print("email signup + OTP; profile; current-password change; sign-out and email reset passed")


async def join_code(page, code):
    await page.fill("#onCode", code)
    await page.locator("#onCode").press("Enter")


async def room_flow(a, b, c):
    # Simulate two already-existing username-only accounts using the legacy signup path.
    await b.evaluate("DUANLIAN.accSignUp('guest_b', 'guest-b-test', '乙', 'CH_JIN')")
    await c.evaluate("DUANLIAN.accSignUp('guest_c', 'guest-c-test', '丙', 'CH_LAN')")
    await c.evaluate("DUANLIAN.go('PG_ACCOUNT')")
    await signed_out(c)
    await submit(c, "#accForm", u="guest_c", p="guest-c-test")
    await signed_in(c)
    for page in (a, b, c):
        await page.evaluate("DUANLIAN.go('PG_ONLINE')")
    await a.wait_for_function("DUANLIAN.NET.members.length === 3")
    b_uid = await b.evaluate("DUANLIAN.ACC.user.id")

    # Drop the lobby broadcast. The recipient still receives the server-stored invitation on polling.
    await b.evaluate("window.__DISCONNECT = true")
    await a.click(f'[data-inv="{b_uid}"]')
    await a.wait_for_selector("#PG_SELECT.on")
    ticket = await a.evaluate("({code:DUANLIAN.ROOM.code, id:DUANLIAN.ROOM.id})")
    await b.wait_for_selector("#invYes", timeout=10000)
    await join_code(c, ticket["code"])
    await c.wait_for_function("document.querySelector('#toast').textContent.includes('受邀玩家保留')")
    await b.evaluate("window.__DISCONNECT = false")
    await b.click("#invYes")
    await b.wait_for_selector("#PG_SELECT.on")
    await a.wait_for_function("DUANLIAN.ROOM.peer?.nick === '乙'")
    assert await b.evaluate("DUANLIAN.ROOM.id") == ticket["id"]

    await join_code(c, ticket["code"])
    await c.wait_for_function("document.querySelector('#toast').textContent.includes('房间已满')")
    await b.click("#btnSelBack")
    await a.wait_for_function("!DUANLIAN.ROOM.peer")
    await join_code(c, ticket["code"])
    await c.wait_for_selector("#PG_SELECT.on")
    await a.wait_for_function("DUANLIAN.ROOM.peer?.nick === '丙'")
    print("legacy login; lost invite broadcast; reserved seat; third player blocked; freed seat reusable")


async def main():
    errors = []
    async with async_playwright() as p:
        chrome = os.environ.get("CHROME")
        browser = await p.chromium.launch(**({"executable_path": chrome} if chrome else {}))
        ctx = await browser.new_context(viewport={"width": 844, "height": 390}, service_workers="block")
        await ctx.route("**/*", local_only)
        await ctx.add_init_script(path=Path(__file__).with_name("mock-supabase.js"))
        await ctx.add_init_script("window.DUANLIAN_SUPA = { ...window.DUANLIAN_SUPA, EMAIL_AUTH: true };")
        a, b, c = await make_pages(ctx, errors)
        await account_flow(a)
        await room_flow(a, b, c)
    assert not errors, errors
    print("page errors: 0")


if __name__ == "__main__":
    asyncio.run(main())
