"""两个页面用假 Supabase（dev/mock-supabase.js）完整打一局联机，检查两边是否同步。
用法（先在仓库根目录 python3 -m http.server 8765）：
  python3 dev/test_online.py [延迟ms=60] [抖动ms=30] [kill|no] [丢包率=0]
"""
import asyncio, json, sys, os
from playwright.async_api import async_playwright
URL = "http://127.0.0.1:8765/index.html"
LAT = int(sys.argv[1]) if len(sys.argv) > 1 else 60
JIT = int(sys.argv[2]) if len(sys.argv) > 2 else 30
KILL = len(sys.argv) > 3 and sys.argv[3] == 'kill'
DROP = float(sys.argv[4]) if len(sys.argv) > 4 else 0
PRE = "const D=window.DUANLIAN; const {G,ACC,NET,ROOM,CFG,REC,Input,AI,lsHashOf,accSignUp,go}=D; const LS=D.LS;"
def ev(pg, expr): return pg.evaluate("()=>{" + PRE + "return (" + expr + ");}")
def run(pg, body): return pg.evaluate("()=>{" + PRE + body + "}")
async def main():
    async with async_playwright() as p:
        CHROME = os.environ.get("CHROME")  # 可选：指定本机 Chrome 路径
        b = await p.chromium.launch(**({"executable_path": CHROME} if CHROME else {}), args=["--no-sandbox"])
        ctx = await b.new_context(viewport={"width":1280,"height":720})
        await ctx.add_init_script(path=os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock-supabase.js"))
        await ctx.add_init_script(f"window.__LAT={LAT}; window.__JIT={JIT}; window.__DROP={DROP};")
        A = await ctx.new_page(); B = await ctx.new_page()
        errs = {'A': [], 'B': []}
        for n, pg in (('A', A), ('B', B)):
            pg.on("pageerror", lambda e, n=n: errs[n].append(str(e)))
            pg.on("console", lambda m, n=n: m.type in ('error', 'warning') and errs[n].append(m.text))
        await A.goto(URL); await B.goto(URL); await A.wait_for_timeout(800)
        await A.click('#accChip'); await A.wait_for_timeout(300)
        await A.click('[data-acctab="up"]'); await A.fill('#accForm input[name=u]', 'alice'); await A.fill('#accForm input[name=p]', 'secret1'); await A.fill('#accForm input[name=n]', '阿丽丝')
        await A.click('#accForm [data-av="CH_SHUANG"]'); await A.click('#accForm [type=submit]'); await A.wait_for_timeout(600)
        print('A acc', await ev(A, "{s:ACC.state, p:ACC.profile && ACC.profile.nickname, av: ACC.profile && ACC.profile.avatar, chip: document.querySelector('#accChip').innerText}"))
        await A.screenshot(path='/tmp/duanlian_A_acc.png')
        await run(B, "return accSignUp('bob', 'secret2', '小波', 'CH_LEI');"); await B.wait_for_timeout(300)
        print('B acc', await ev(B, "{s:ACC.state, p:ACC.profile && ACC.profile.nickname}"))
        await run(A, "go('PG_ONLINE')"); await run(B, "go('PG_ONLINE')"); await A.wait_for_timeout(900)
        print('lobby A', await ev(A, "NET.members.map(m=>m.nick+':'+m.status)"), 'B', await ev(B, "NET.members.map(m=>m.nick)"))
        await A.screenshot(path='/tmp/duanlian_A_lobby.png')
        await A.click('#onCreate'); await A.wait_for_timeout(600)
        code = await ev(A, "ROOM.code"); print('room', code)
        await B.fill('#onCode', code); await B.click('#onJoin'); await B.wait_for_timeout(1200)
        print('peers', await ev(A, "ROOM.peer && ROOM.peer.nick"), await ev(B, "ROOM.peer && ROOM.peer.nick"))
        await A.click('#sideP1 .pc[data-id="CH_YUE"]'); await A.click('#pickStage [data-id="STG_05"]'); await B.click('#sideP2 .pc[data-id="CH_YING"]'); await A.wait_for_timeout(600)
        print('sel A', await ev(A, "JSON.stringify(G.sel)")); print('sel B', await ev(B, "JSON.stringify(G.sel)"))
        print('B p1 disabled?', await ev(B, "document.querySelector('#sideP1 .pc').disabled"), 'B stage disabled?', await ev(B, "document.querySelector('#pickStage button').disabled"))
        await A.screenshot(path='/tmp/duanlian_A_room.png'); await B.screenshot(path='/tmp/duanlian_B_room.png')
        await run(A, "CFG.ROUND_TIME = 25; CFG.ROUNDS_TO_WIN = 1;")
        for pg in (A, B):
            await run(pg, """const ai = new AI(2), orig = Input.read.bind(Input);
              Input.read = pid => { const LS = D.LS; if (!LS.on) return orig(pid); const me = G.f[LS.me], op = G.f[1 - LS.me]; const o = ai.think(me, op); o.held = o.held || {}; o.pressed = o.pressed || {}; if (o.dash === 'SIDE_U') o.pressed.up = true; if (o.dash === 'DASH') o.pressed[me.face > 0 ? 'right' : 'left'] = true; return { held: o.held, pressed: o.pressed }; };""")
        await A.click('#btnFight'); await B.click('#btnFight')
        await A.wait_for_timeout(1500)
        print('start A', await ev(A, "{on:LS.on, D:LS.D, page:G.page, mode:G.mode, rt: CFG.ROUND_TIME}"), 'B', await ev(B, "{on:LS.on, D:LS.D, page:G.page, rt: CFG.ROUND_TIME, me: LS.me}"))
        await A.wait_for_timeout(2500); await A.screenshot(path='/tmp/duanlian_A_battle.png'); await B.screenshot(path='/tmp/duanlian_B_battle.png')
        t = 0
        while t < 120:
            await A.wait_for_timeout(3000); t += 3
            a = await ev(A, "{f:LS.frame, w:LS.wait|0, page:G.page, desync:LS.desync, hp:G.f.map(f=>Math.round(f.hp))}"); bb = None if B is None else await ev(B, "{f:LS.frame, w:LS.wait|0, page:G.page, desync:LS.desync, hp:G.f.map(f=>Math.round(f.hp))}")
            print(t, a, bb)
            if KILL and t == 9: await B.close(); print('B closed'); B = None
            if B is None:
                if a['page'] == 'PG_RESULT': break
                continue
            if a['page'] == 'PG_RESULT' and bb['page'] == 'PG_RESULT': break
        fin = "{hp: G.f.map(f=>Math.round(f.hp)), wins: G.f.map(f=>f.wins), x: G.f.map(f=>Math.round(f.x*100)/100), title: document.querySelector('#resTitle').innerText, hash: lsHashOf(), frame: G.frame, desync: LS.desync, onW: REC.stats.onW, onG: REC.stats.onG, sent: window.__sent}"
        fa = await ev(A, fin); print('A', fa)
        if B:
            fb = await ev(B, fin); print('B', fb)
            print('same', fa['hp'] == fb['hp'] and fa['wins'] == fb['wins'] and fa['x'] == fb['x'] and fa['hash'] == fb['hash'] and not fa['desync'] and not fb['desync'])
            await B.screenshot(path='/tmp/duanlian_B_result.png')
        await A.screenshot(path='/tmp/duanlian_A_result.png')
        print('errs', {k: v[:6] for k, v in errs.items()})
        await b.close()
asyncio.run(main())
