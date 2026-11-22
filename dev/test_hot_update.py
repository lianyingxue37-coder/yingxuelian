"""安装包热更新：模拟安卓安装包（window.__HOT_FORCE），本机存一份“新版”后重新打开，检查新版接管、坏版本自动退回、旧缓存清理。
用法：python3 -m http.server 8765 后运行 python3 dev/test_hot_update.py"""
import asyncio, re, sys
from pathlib import Path
from playwright.async_api import async_playwright

URL = "http://127.0.0.1:8765/index.html"
SRC = (Path(__file__).parent.parent / "index.html").read_text(encoding="utf-8")
VER = re.search(r'<meta name="dl-ver" content="([\d.]+)">', SRC).group(1)

def variant(ver, extra="", shell=None):
    s = SRC.replace(f'<meta name="dl-ver" content="{VER}">', f'<meta name="dl-ver" content="{ver}">', 1)
    s = s.replace(f'<div class="ver">v{VER} ·', f'<div class="ver">v{ver} ·', 1)
    if shell is not None: s = re.sub(r'<meta name="dl-shell" content="\d+">', f'<meta name="dl-shell" content="{shell}">', s, count=1)
    return s.replace("</body>", f"<script>{extra}</script></body>", 1)

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        ctx = await b.new_context(service_workers="block")
        await ctx.add_init_script("window.__HOT_FORCE = true;")
        await ctx.route("https://**/*", lambda r: r.abort())   # 不联网：不让后台下载覆盖测试数据
        pg = await ctx.new_page(); errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))
        pg.on("console", lambda m: m.type == "error" and errs.append(m.text))
        await pg.goto(URL); await pg.wait_for_timeout(800)
        st = lambda: pg.evaluate("[window.__HOT && window.__HOT.on, document.querySelector('.ver').textContent.split(' ')[0], document.querySelectorAll('#cv').length, typeof DUANLIAN, window.__MARK || 0, localStorage.getItem('dl-hot-try')]")
        print("bundled", await st()); assert (await st())[:4] == [False, f"v{VER}", 1, "object"]

        async def seed(html, ver, shell=1):
            await pg.evaluate("([h, v, s]) => { localStorage.setItem('dl-hot-html', h); localStorage.setItem('dl-hot-ver', v); localStorage.setItem('dl-hot-shell', String(s)); localStorage.removeItem('dl-hot-try'); }", [html, ver, shell])

        # 1) 新版接管：只有一份游戏在跑，新版的脚本执行，原文件后半段不执行
        await seed(variant("9.9", "window.__MARK = 1;"), "9.9")
        await pg.reload(); await pg.wait_for_timeout(1500)
        s = await st(); print("hot", s); assert s[:5] == [True, "v9.9", 1, "object", 1], s
        await pg.wait_for_timeout(3500); s = await st(); assert s[5] is None, s   # 活过 4 秒，清掉失败计数
        # 2) 坏的新版：连续两次启动失败后退回安装包版本
        await seed(variant("9.9", "throw new Error('boom');").replace("startDemo();", "throw new Error('broken build');", 1), "9.9")
        for i in range(3):
            await pg.reload(); await pg.wait_for_timeout(1200); print("broken run", i, await st())
        s = await st(); assert s[0] is False and s[1] == f"v{VER}", s
        assert await pg.evaluate("localStorage.getItem('dl-hot-ver')") is None
        # 3) 缓存比安装包旧 / 需要更新的外壳：直接清掉
        await seed(variant("0.1"), "0.1"); await pg.reload(); await pg.wait_for_timeout(800)
        assert (await st())[0] is False and await pg.evaluate("localStorage.getItem('dl-hot-ver')") is None
        await seed(variant("9.9", shell=99), "9.9", 99); await pg.reload(); await pg.wait_for_timeout(800)
        assert (await st())[0] is False and await pg.evaluate("localStorage.getItem('dl-hot-ver')") is None
        bad = [e for e in errs if "boom" not in e and "broken build" not in e and "Failed to load resource" not in e]
        print("errors", bad); assert not bad
        print("hot update OK")
        await b.close()
asyncio.run(main())
