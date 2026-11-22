"""好友 + 好友切磋：两个页面用假 Supabase（dev/mock-supabase.js）走一遍完整流程。
用法（先在仓库根目录 python3 -m http.server 8765）：python3 dev/test_friends.py
"""
import asyncio, os

async def local_only(route):
    if route.request.url.startswith("http://127.0.0.1:8765/"): await route.continue_()
    else: await route.fulfill(status=200, body="")
from playwright.async_api import async_playwright
URL = "http://127.0.0.1:8765/index.html"
PRE = "const D=window.DUANLIAN; const {G,ACC,NET,ROOM,CFG,REC,Input,AI,accSignUp,go}=D; const LS=D.LS;"
def ev(pg, expr): return pg.evaluate("()=>{" + PRE + "return (" + expr + ");}")
def run(pg, body): return pg.evaluate("()=>{" + PRE + body + "}")
OUT = os.environ.get('SHOTS', '/tmp')
async def main():
    async with async_playwright() as p:
        CHROME = os.environ.get("CHROME")
        b = await p.chromium.launch(**({"executable_path": CHROME} if CHROME else {}), args=["--no-sandbox"])
        ctx = await b.new_context(viewport={"width": 1280, "height": 720}, service_workers="block")
        await ctx.route("**/*", local_only)
        await ctx.add_init_script(path=os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock-supabase.js"))
        await ctx.add_init_script("window.__LAT=40; window.__JIT=20;")
        A = await ctx.new_page(); B = await ctx.new_page(); errs = {'A': [], 'B': []}
        for n, pg in (('A', A), ('B', B)):
            pg.on("pageerror", lambda e, n=n: errs[n].append(str(e)))
            pg.on("dialog", lambda d: asyncio.ensure_future(d.accept()))
        await A.goto(URL); await B.goto(URL); await A.wait_for_timeout(800)
        await run(A, "return accSignUp('alice', 'secret1', '阿丽丝', 'CH_SHUANG');"); await run(B, "return accSignUp('bob', 'secret2', '小波', 'CH_LEI');")
        await A.wait_for_timeout(900)
        # A 加 B
        await run(A, "go('PG_ONLINE')"); await A.wait_for_timeout(300); await A.click('[data-ontab="friends"]'); await A.wait_for_timeout(300)
        await A.fill('#frName', 'bob'); await A.click('#frAddBtn'); await A.wait_for_timeout(900)
        print('A outgoing', await ev(A, "NET.fr.rows.map(r=>r.status)"), '| B badge', await ev(B, "document.querySelector('#frBadge').textContent + (document.querySelector('#frBadge').hidden?' hidden':'')"))
        await run(B, "go('PG_ONLINE')"); await B.wait_for_timeout(300); await B.click('[data-ontab="friends"]'); await B.wait_for_timeout(500)
        await B.screenshot(path=f'{OUT}/fr_B_request.png')
        await B.click('[data-frok]'); await B.wait_for_timeout(1000)
        print('A friends', await ev(A, "NET.fr.rows.map(r=>r.status)"), '| B friends', await ev(B, "NET.fr.rows.map(r=>r.status)"))
        await A.wait_for_timeout(400); await A.screenshot(path=f'{OUT}/fr_A_list.png')
        print('A sees bob', await ev(A, "document.querySelector('#onBody').innerText.replace(/\\s+/g,' ').slice(0,260)"))
        # A 邀请 B 切磋
        await A.click('[data-frinv]'); await A.wait_for_timeout(1200)
        print('B modal', await ev(B, "!document.querySelector('#modal').hidden && document.querySelector('#modal').innerText.replace(/\\s+/g,' ')"))
        await B.screenshot(path=f'{OUT}/fr_B_invite.png')
        await B.click('#invYes'); await B.wait_for_timeout(1500)
        print('room', await ev(A, "{code:ROOM.code, spar:ROOM.spar, peer:ROOM.peer&&ROOM.peer.nick, title:document.querySelector('#selMode').textContent}"), await ev(B, "{code:ROOM.code, spar:ROOM.spar, peer:ROOM.peer&&ROOM.peer.nick, rounds:ROOM.rounds}"))
        await A.click('[data-rounds="1"]'); await A.wait_for_timeout(600)
        print('rounds B', await ev(B, "ROOM.rounds"), await ev(B, "document.querySelector('#selMode').textContent"))
        await A.screenshot(path=f'{OUT}/fr_A_room.png')
        onG0 = await ev(A, "ACC.profile?.stats.onG ?? 0")
        await run(A, "CFG.ROUND_TIME = 20;")
        for pg in (A, B):
            await run(pg, """const ai = new AI(2), orig = Input.read.bind(Input);
              Input.read = pid => { const LS = D.LS; if (!LS.on) return orig(pid); const me = G.f[LS.me], op = G.f[1 - LS.me]; const o = ai.think(me, op); o.held = o.held || {}; o.pressed = o.pressed || {}; if (o.dash === 'SIDE_U') o.pressed.up = true; if (o.dash === 'DASH') o.pressed[me.face > 0 ? 'right' : 'left'] = true; return { held: o.held, pressed: o.pressed }; };""")
        await A.click('#btnFight'); await B.click('#btnFight'); await A.wait_for_timeout(1500)
        print('started', await ev(A, "{on:LS.on, spar:G.spar, rtw:CFG.ROUNDS_TO_WIN}"), await ev(B, "{on:LS.on, spar:G.spar, rtw:CFG.ROUNDS_TO_WIN}"))
        t = 0
        while t < 90:
            await A.wait_for_timeout(3000); t += 3
            pa = await ev(A, "G.page"); pb = await ev(B, "G.page")
            if pa == 'PG_RESULT' and pb == 'PG_RESULT': break
        fa = await ev(A, "{page:G.page, verify:document.querySelector('#resVerify').textContent, verdict:LS.verdict, desync:LS.desync, hp:G.f.map(f=>Math.round(f.hp)), onG:ACC.profile?.stats.onG ?? 0, reports:JSON.parse(localStorage.getItem('duanlian.report.' + ACC.user.id) || '[]').length}")
        fb = await ev(B, "{page:G.page, verdict:LS.verdict, desync:LS.desync, hp:G.f.map(f=>Math.round(f.hp))}")
        unrated = fa['onG'] == onG0 and fa['verdict'] == 'spar' and fb['verdict'] == 'spar' and fa['reports'] == 0
        print('result A', fa, '| B', fb, '| 不计战绩', unrated)
        assert unrated and not fa['desync'] and not fb['desync'], (fa, fb)
        await A.screenshot(path=f'{OUT}/fr_A_result.png')
        # B 开切磋房间，A 在好友列表里直接「加入」
        await run(A, "document.querySelector('#btnToTitle').click()"); await run(B, "document.querySelector('#btnToTitle').click()"); await A.wait_for_timeout(800)
        await run(B, "NET.tab='friends'; go('PG_ONLINE')"); await B.wait_for_timeout(300); await B.click('#frRoom'); await B.wait_for_timeout(1200)
        await run(A, "NET.tab='friends'; go('PG_ONLINE')"); await A.wait_for_timeout(900)
        print('A sees join', await ev(A, "!!document.querySelector('[data-frjoin]')"))
        await A.click('[data-frjoin]'); await A.wait_for_timeout(1500)
        print('joined', await ev(A, "{code:ROOM.code, spar:ROOM.spar, peer:ROOM.peer&&ROOM.peer.nick}"), await ev(B, "{code:ROOM.code, peer:ROOM.peer&&ROOM.peer.nick}"))
        # 删除好友
        await run(A, "roomLeave(); NET.tab='friends'; go('PG_ONLINE')"); await A.wait_for_timeout(600)
        await A.click('[data-frdel]'); await A.wait_for_timeout(900)
        print('after delete', await ev(A, "NET.fr.rows.length"), await ev(B, "NET.fr.rows.length"))
        assert await ev(A, "NET.fr.rows.length") == await ev(B, "NET.fr.rows.length") == 0
        print('errors', {k: v[:5] for k, v in errs.items()})
        assert not any(errs.values()), errs
        await b.close()
asyncio.run(main())
