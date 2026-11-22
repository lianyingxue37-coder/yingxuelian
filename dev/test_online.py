"""用模拟 Supabase 的两个浏览器页面打完联机对战。

先在仓库根目录启动 python -m http.server 8765，然后运行：
  python dev/test_online.py [延迟ms=60] [抖动ms=30] [no|kill|reload|quick] [丢包率=0]
"""
import asyncio
import os
from pathlib import Path
import sys
import time

from playwright.async_api import async_playwright

URL = "http://127.0.0.1:8765/index.html"
LAT = int(sys.argv[1]) if len(sys.argv) > 1 else 60
JIT = int(sys.argv[2]) if len(sys.argv) > 2 else 30
ACTION = sys.argv[3] if len(sys.argv) > 3 else "no"
DROP = float(sys.argv[4]) if len(sys.argv) > 4 else 0
AI_INPUT = """
(() => {
  const D = window.DUANLIAN;
  const { G, AI, Input } = D;
  const ai = new AI(2), original = Input.read.bind(Input);
  Input.read = pid => {
    const ls = D.LS;
    if (!ls.on) return original(pid);
    const me = G.f[ls.me], op = G.f[1 - ls.me], input = ai.think(me, op);
    const pressed = input.pressed || {};
    if (input.dash === 'SIDE_U') pressed.up = true;
    if (input.dash === 'DASH') pressed[me.face > 0 ? 'right' : 'left'] = true;
    return { held: input.held || {}, pressed };
  };
})()
"""
FINISH = """() => {
  const { G, ACC, LS } = DUANLIAN;
  return {
    page: G.page, final: LS.final, desync: LS.desync, sent: window.__sent ?? 0,
    input: LS.sentAtEnd, input_per_s: +(LS.sentAtEnd / LS.elapsed).toFixed(2), verdict: LS.verdict, onG: ACC.profile?.stats.onG ?? 0,
    onW: ACC.profile?.stats.onW ?? 0, rating: ACC.profile?.rating
  };
}"""


async def local_only(route):
    if route.request.url.startswith("http://127.0.0.1:8765/"):
        await route.continue_()
    else:
        await route.fulfill(status=200, body="")


async def main():
    async with async_playwright() as p:
        chrome = os.environ.get("CHROME")
        browser = await p.chromium.launch(**({"executable_path": chrome} if chrome else {}))
        size = {"width": 844, "height": 390} if ACTION == "quick" else {"width": 1280, "height": 720}
        ctx = await browser.new_context(viewport=size, service_workers="block")
        await ctx.route("**/*", local_only)
        await ctx.add_init_script(path=Path(__file__).with_name("mock-supabase.js"))
        await ctx.add_init_script(f"window.__LAT={LAT}; window.__JIT={JIT}; window.__DROP={DROP};")
        a, b = await ctx.new_page(), await ctx.new_page()
        errors = {"A": [], "B": []}
        for name, page in (("A", a), ("B", b)):
            page.on("pageerror", lambda e, n=name: errors[n].append(str(e)))
            page.on("console", lambda m, n=name: m.type == "error" and errors[n].append(m.text))
        await asyncio.gather(a.goto(URL), b.goto(URL))

        await a.click("#accChip")
        await a.click('[data-acctab="up"]')
        await a.fill("#accForm input[name=u]", "alice")
        await a.fill("#accForm input[name=p]", "demo-alice")
        await a.fill("#accForm input[name=n]", "阿丽丝")
        await a.click('#accForm [data-av="CH_SHUANG"]')
        await a.click("#accForm [type=submit]")
        await a.wait_for_function("DUANLIAN.ACC.profile?.avatar === 'CH_SHUANG'")
        await b.evaluate("DUANLIAN.accSignUp('bob', 'demo-bob', '小波', 'CH_LEI')")
        for page in (a, b):
            await page.evaluate("DUANLIAN.go('PG_ONLINE')")
        for page in (a, b):
            await page.wait_for_function("DUANLIAN.NET.members.length === 2")

        if ACTION == "quick":
            await asyncio.gather(a.click("#onQuick"), b.click("#onQuick"))
            await a.wait_for_function("DUANLIAN.ROOM.match?.pair")
            await b.wait_for_function("DUANLIAN.ROOM.match?.pair")
            if await b.evaluate("DUANLIAN.ROOM.host"):
                a, b = b, a
        else:
            await a.click("#onCreate")
            await a.wait_for_selector("#PG_SELECT.on")
            await b.fill("#onCode", await a.evaluate("DUANLIAN.ROOM.code"))
            await b.click("#onJoin")

        for page in (a, b):
            await page.wait_for_selector("#PG_SELECT.on")
            await page.wait_for_function("DUANLIAN.ROOM.peer")
            await page.evaluate(AI_INPUT)
        print("room", await a.evaluate("DUANLIAN.ROOM.code"), flush=True)
        await a.click('#sideP1 .pc[data-id="CH_YUE"]')
        await a.click('#pickStage [data-id="STG_05"]')
        await b.click('#sideP2 .pc[data-id="CH_YING"]')
        await a.evaluate("Object.assign(DUANLIAN.CFG, { ROUND_TIME: 25, ROUNDS_TO_WIN: 1 })")
        await a.click("#btnFight")
        await b.click("#btnFight")
        await asyncio.gather(*(page.wait_for_function("DUANLIAN.LS.on") for page in (a, b)))
        start = time.monotonic()

        if ACTION in ("reload", "kill"):
            await b.wait_for_function("DUANLIAN.LS.frame >= 300")
            if ACTION == "reload":
                before = await b.evaluate("DUANLIAN.LS.frame")
                await b.evaluate("window.__DISCONNECT = true")
                await asyncio.sleep(3)
                assert await a.evaluate("DUANLIAN.LS.wait > 1000"), "peer did not wait for inputs"
                await b.reload()
                await b.wait_for_function(f"DUANLIAN.LS.on && DUANLIAN.LS.frame >= {before + 120}")
                await b.evaluate(AI_INPUT)
                print("reloaded and resumed both players", flush=True)
            else:
                await b.close()
                b = None

        pages = [a, b] if b else [a]
        await asyncio.gather(*(page.wait_for_selector("#PG_RESULT.on", timeout=120000) for page in pages))
        elapsed = time.monotonic() - start
        if b:
            await asyncio.gather(*(page.wait_for_function("DUANLIAN.LS.verdict === 'verified'", timeout=12000) for page in pages))
        states = await asyncio.gather(*(page.evaluate(FINISH) for page in pages))
        for name, state in zip(("A", "B"), states):
            print(name, state, flush=True)
        if b:
            same = states[0]["final"] == states[1]["final"] and not any(s["desync"] for s in states)
            print("same", same, flush=True)
            assert same
            assert all(s["onG"] == 1 for s in states), states
        else:
            assert states[0]["verdict"] == "unverified" and states[0]["onG"] == 0, states
        print(f"match duration {elapsed:.2f}s, broadcasts sent per player " + ", ".join(str(s["input"]) for s in states), flush=True)
        if ACTION == "quick":
            await a.click("#btnToTitle")
            await a.click("#onRank")
            await a.wait_for_selector("#rankBody tbody tr")
            assert await a.locator("#rankBody tbody tr").count() == 2
            assert await a.locator("#PG_RANK .panel").evaluate("p => p.scrollWidth <= p.clientWidth + 1")
            await a.click("#PG_RANK [data-back]")
            await a.wait_for_selector("#PG_ONLINE.on")
            print("leaderboard fits 844x390, navigation passed", flush=True)
        print("errors", errors)
        assert not any(errors.values()), errors


if __name__ == "__main__":
    asyncio.run(main())
