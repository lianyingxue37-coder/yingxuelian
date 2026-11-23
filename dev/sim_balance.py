"""AI 对 AI 平衡统计：连段长度、结束原因、攻守互换、拆招 / 拆空、终焉次数。
用法：python3 -m http.server 8765 后运行 python3 dev/sim_balance.py [URL] [局数]"""
import asyncio, json, sys
from playwright.async_api import async_playwright
URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8765/index.html"; N = int(sys.argv[2]) if len(sys.argv) > 2 else 12
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(); pg = await b.new_page(); errs = []
        pg.on('pageerror', lambda e: errs.append(str(e)))
        await pg.goto(URL); await pg.wait_for_timeout(1500)
        r = await pg.evaluate("""async (N) => { const D = DUANLIAN; const ends = [], ev = {};
          D.on('EV_CHAIN_END', e => ends.push(e.text)); D.on('EV_CHAIN_DROP', e => ends.push(e.text)); D.on('EV_CHAIN_REPEAT', e => ends.push(e.text));
          D.on('EV_MECH', e => { ev[e.text] = (ev[e.text] || 0) + 1; }); D.on('EV_BREAK', e => { ev.chai = (ev.chai || 0) + 1; });
          const ids = D.CHARS.map(c => c.id); const res = []; let hits = [], swaps = 0;
          for (let k = 0; k < N; k++) {
            D.CFG.AI_LEVEL = k % 3;
            D.startMatch({ mode: 'cpu', p1: ids[k % ids.length], p2: ids[(k * 3 + 1) % ids.length], stage: D.STAGES[0].id, seed: k + 1 });
            D.G.autoP1 = true; let t = 0, last = -1;
            while (D.G.page === 'PG_BATTLE' && t < 60 * 60 * 6) { D.step(); t++; const w = D.G.f.findIndex(f => f.chain); if (w >= 0 && w !== last) { if (last >= 0) swaps++; last = w; } }
            res.push([t, D.G.f.map(f => f.stats.maxLv), D.G.f.map(f => f.stats.maxHits), D.G.f.map(f => f.stats.zy || 0)]);
          }
          const hist = {}, reasons = {}; const hl = [];
          for (const s of ends) { const m = s.match(/^(\\w+) (\\d+)连 DL(\\d)/); if (!m) continue; hist['DL' + m[3]] = (hist['DL' + m[3]] || 0) + 1; reasons[m[1]] = (reasons[m[1]] || 0) + 1; hl.push(+m[2]); }
          hl.sort((a, b) => a - b);
          return { res, hist, reasons, chains: ends.length, hitsMedian: hl[hl.length >> 1], hitsP90: hl[Math.floor(hl.length * .9)], hitsMax: hl[hl.length - 1], swaps, ev };
        }""", N)
        print(json.dumps(r, ensure_ascii=False)); print('errors', errs[:3])
        await b.close()
asyncio.run(main())
