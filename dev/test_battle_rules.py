"""验证旧设置无法改变新版规则，场上也不会再出现拾取物。"""
import asyncio
import os

from playwright.async_api import async_playwright

URL = os.environ.get("URL", "http://127.0.0.1:8765/index.html")
LEGACY_SETTINGS = """
const key = 'duanlian.settings.v1';
if (!localStorage.getItem(key)) localStorage.setItem(key, JSON.stringify({
  GRAPHICS: 'low', SOUND: false, ROUNDS_TO_WIN: 1, ROUND_TIME: 60, AI_LEVEL: 2,
  WINDOW_MUL: .8, BRK_START: 100, IMMEDIATE_RATIO: .5, SHARDS: true, STAGE_W: 3200, MOVE_MUL: 1.6
}));
"""


async def local_only(route):
    if route.request.url.startswith(URL.rsplit("/", 1)[0] + "/"):
        await route.continue_()
    else:
        await route.fulfill(status=200, body="")


async def verify(browser, width, height):
    context = await browser.new_context(
        viewport={"width": width, "height": height}, has_touch=width < 1000, service_workers="block"
    )
    await context.route("**/*", local_only)
    await context.add_init_script(LEGACY_SETTINGS)
    page = await context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    await page.goto(URL)
    await page.click('#PG_TITLE [data-go="PG_SETTINGS"]')
    assert await page.locator("#setTabs button").evaluate_all(
        "(buttons) => buttons.map(button => button.dataset.settab)"
    ) == ["account", "video", "audio", "controls"]
    assert await page.locator("#SET_GRAPHICS option:checked").inner_text() == "低"
    await page.locator("#SET_GRAPHICS").select_option(label="高")
    assert await page.evaluate(
        """() => {
            const settings = JSON.parse(localStorage.getItem('duanlian.settings.v1'));
            return settings.GRAPHICS === 'high' && settings.SOUND === false
                && !('ROUND_TIME' in settings) && !('SHARDS' in settings);
        }"""
    )
    result = await page.evaluate(
        """() => {
            const {CFG, G, on, startMatch, simStep, render} = DUANLIAN;
            let pickups = 0;
            on('EV_SHARD_SPAWN', () => pickups++);
            const neutral = {held: {}, pressed: {}};
            const rules = [CFG.ROUNDS_TO_WIN, CFG.ROUND_TIME, CFG.AI_LEVEL, CFG.WINDOW_MUL,
                CFG.BRK_START, CFG.IMMEDIATE_RATIO, CFG.STAGE_W, CFG.MOVE_MUL];
            const matches = ['pvp', 'cpu', 'train'].map(mode => {
                startMatch({mode, p1:'CH_JIN', p2:'CH_LAN', stage:'STG_01', seed:77});
                G.paused = true;
                for (let i = 0; i < 1850; i++) { G.frame++; simStep(neutral, neutral); }
                render();
                return {mode, rounds:G.roundsToWin, time:G.timer, phase:G.rs,
                    hasPickups:'shards' in G || 'shards' in G.f[0].stats};
            });
            return {pickups, rules, matches};
        }"""
    )
    assert result["rules"] == [2, 99, 1, 1, 20, .3, 2400, 1.3], result
    assert result["pickups"] == 0 and len(result["matches"]) == 3, result
    for match in result["matches"]:
        assert match["rounds"] == 2 and match["phase"] == "RS_FIGHT" and not match["hasPickups"], match
        assert match["time"] == (99 * 60 if match["mode"] == "train" else 99 * 60 - 1760), match
    assert not errors, errors
    print(f"{width}x{height}: legacy preferences, fixed rules and three modes without pickups")
    await context.close()


async def main():
    async with async_playwright() as playwright:
        chrome = os.environ.get("CHROME")
        browser = await playwright.chromium.launch(**({"executable_path": chrome} if chrome else {}))
        for width, height in [(1280, 720), (844, 390)]:
            await verify(browser, width, height)
        await browser.close()


if __name__ == "__main__":
    asyncio.run(main())
