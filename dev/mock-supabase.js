// 测试用：模拟 supabase-js 的一小部分（auth / from / rpc / channel），频道消息用 BroadcastChannel，带可调延迟
(() => {
  window.DUANLIAN_SUPA = { URL: 'mock', KEY: 'mock' };
  const LS_ = { get(k, d) { try { const v = localStorage.getItem('mock.' + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } }, set(k, v) { localStorage.setItem('mock.' + k, JSON.stringify(v)); } };
  const lat = () => (window.__LAT ?? 50) + Math.random() * (window.__JIT ?? 30);
  const uuid = () => crypto.randomUUID();
  const SS = sessionStorage;
  let session = JSON.parse(SS.getItem('mock.session') || 'null'); const authCbs = [];
  const setSess = s => { session = s; SS.setItem('mock.session', JSON.stringify(s)); authCbs.forEach(cb => cb(s ? 'SIGNED_IN' : 'SIGNED_OUT', s)); };
  class Q {
    constructor(t) { this.t = t; this.op = 'select'; this.f = []; this.p = null; this.one = 0; this.ord = null; this.lim = 0; }
    select() { return this; } insert(o) { this.op = 'insert'; this.p = o; return this; } update(o) { this.op = 'update'; this.p = o; return this; }
    eq(k, v) { this.f.push([k, v]); return this; } order(k, o) { this.ord = [k, o && o.ascending === false ? -1 : 1]; return this; } limit(n) { this.lim = n; return this; }
    single() { this.one = 1; return this; } maybeSingle() { this.one = 2; return this; }
    then(a, b) { return new Promise(r => setTimeout(() => r(this.exec()), 20)).then(a, b); }
    exec() {
      const uid = session?.user.id, cosmetic = ['nickname', 'avatar', 'title'];
      const deny = { data: null, error: { code: '42501', message: 'permission denied' } };
      if (this.op === 'insert' || (this.op === 'update' && (!uid || this.t !== 'profiles' || Object.keys(this.p).some(k => !cosmetic.includes(k))))) return deny;
      let rows = LS_.get('t.' + this.t, []);
      if (this.t === 'matches') rows = rows.filter(r => r.user_id === uid);
      if (this.t === 'duanlian_leaderboard') rows = LS_.get('t.profiles', []).filter(p => p.stats.onG)
        .sort((a, b) => b.rating - a.rating || b.stats.onW - a.stats.onW || a.id.localeCompare(b.id)).slice(0, 100)
        .map((p, i) => ({ rank: i + 1, nickname: p.nickname, avatar: p.avatar, rating: p.rating, games: p.stats.onG,
          wins: p.stats.onW, win_rate: Math.round(1000 * p.stats.onW / p.stats.onG) / 10 }));
      const ok = r => this.f.every(([k, v]) => r[k] === v) && (this.op !== 'update' || r.id === uid);
      let out;
      if (this.op === 'update') { out = []; rows.forEach(r => { if (ok(r)) { Object.assign(r, this.p); out.push(r); } }); LS_.set('t.' + this.t, rows); }
      else { out = rows.filter(ok); if (this.ord) { const [k, d] = this.ord; out.sort((x, y) => (x[k] < y[k] ? -1 : 1) * d); } if (this.lim) out = out.slice(0, this.lim); }
      let data = out; if (this.one) { if (!out.length) return this.one === 2 ? { data: null, error: null } : { data: null, error: { message: 'no rows' } }; data = out[0]; }
      return { data: JSON.parse(JSON.stringify(data)), error: null };
    }
  }
function rpcExec(name, a) {
    const uid = session?.user.id;
    const deny = () => ({ data: null, error: { code: '42501', message: 'permission denied' } });
    if (!uid) return deny();
    const read = k => LS_.get('t.' + k, []);
    const save = (k, rows) => LS_.set('t.' + k, rows);
    const profiles = read('profiles'), mine = profiles.find(p => p.id === uid);
    const games = read('games'), game = games.find(g => g.id === a.p_game);
    const matches = read('matches');
    let data = null;
    if (name === 'online_open') {
      if (!game) {
        games.push({ id: a.p_game, code: a.p_code, host: uid, guest: a.p_guest, setup: a.p_setup, status: 'pending', reports: {} });
        save('games', games);
      } else if (game.host !== uid) return deny();
      data = a.p_game;
    } else if (name === 'online_game') {
      if (game && [game.host, game.guest].includes(uid)) data = game;
    } else if (name === 'submit_online_result') {
      if (!game || ![game.host, game.guest].includes(uid)) return deny();
      if (game.status === 'pending' && !game.reports[uid]) {
        const report = game.reports[uid] = [a.p_frames, a.p_final_hash, a.p_winner_slot, a.p_summary];
        const players = [game.host, game.guest];
        const other = game.reports[players.find(id => id !== uid)];
        if (other && JSON.stringify(report) !== JSON.stringify(other)) game.status = 'disputed';
        else if (other) {
          game.status = 'verified';
          const [host, guest] = players.map(id => profiles.find(p => p.id === id));
          const actual = a.p_winner_slot === -1 ? 0.5 : Number(a.p_winner_slot === 0);
          const delta = Math.round(32 * (actual - 1 / (1 + 10 ** ((guest.rating - host.rating) / 400))));
          host.rating += delta; guest.rating -= delta;
          players.forEach((id, slot) => {
            const p = profiles.find(p => p.id === id), opp = profiles.find(p => p.id === players[1 - slot]);
            const { rounds, hits, level } = a.p_summary[slot], myChar = game.setup.sel[slot ? 'p2' : 'p1'];
            const result = a.p_winner_slot === -1 ? 'draw' : a.p_winner_slot === slot ? 'win' : 'lose';
            const s = p.stats;
            s.games = (s.games || 0) + 1; s.onG = s.games;
            const counter = { win: 'wins', lose: 'losses', draw: 'draws' }[result];
            s[counter] = (s[counter] || 0) + 1; s.onW = s.wins || 0;
            s.maxHits = Math.max(s.maxHits || 0, hits); s.maxLv = Math.max(s.maxLv || 0, level);
            s.chars ||= {}; const c = s.chars[myChar] ||= { g: 0, w: 0 }; c.g++; c.w += Number(result === 'win');
            for (const [key, earned] of Object.entries({
              ACH_FIRST: s.games, ACH_WIN1: s.wins, ACH_WIN10: s.wins >= 10, ACH_WIN50: s.wins >= 50,
              ACH_G100: s.games >= 100, ACH_HIT10: s.maxHits >= 10, ACH_HIT25: s.maxHits >= 25,
              ACH_LV3: s.maxLv >= 3, ACH_LV4: s.maxLv >= 4, ACH_ON1: s.onW, ACH_ON10: s.onW >= 10,
              ACH_ALL: Object.values(s.chars).filter(c => c.w > 0).length === 7
            })) if (earned) p.achievements[key] = true;
            matches.push({ id: matches.length + 1, user_id: id, mode: 'online', my_char: myChar, opp_char: game.setup.sel[slot ? 'p1' : 'p2'],
              opp_name: opp.nickname, opp_id: opp.id, rounds: rounds + ':' + a.p_summary[1 - slot].rounds,
              max_hits: hits, max_lv: level, stage: game.setup.sel.stage, result, verified: true, game_id: game.id, created_at: new Date().toISOString() });
          });
          save('matches', matches); save('profiles', profiles);
        }
        save('games', games);
      }
      data = { status: game.status, stats: mine.stats, achievements: mine.achievements, rating: mine.rating };
    } else if (name === 'record_cpu_match') {
      matches.push({ id: matches.length + 1, user_id: uid, mode: 'cpu', my_char: a.p_my_char, opp_char: a.p_opp_char,
        opp_name: '电脑 · ' + a.p_ai, result: a.p_result, rounds: a.p_rounds, max_hits: a.p_hits, max_lv: a.p_level,
        stage: a.p_stage, verified: false, created_at: new Date().toISOString() });
      save('matches', matches);
    } else if (['mm_join', 'mm_leave', 'mm_poll'].includes(name)) {
      const now = Date.now();
      const queue = read('queue').filter(x => x.assignment ? now - x.assignedAt < 15000 : now - x.seen < 8000);
      const row = queue.find(x => x.uid === uid);
      if (name === 'mm_join') {
        if (!row) queue.push({ uid, at: now, seen: now, rating: mine.rating });
        else Object.assign(row, { seen: now, at: row.assignment ? now : row.at, assignment: null });
      } else if (name === 'mm_leave') {
        if (row) queue.splice(queue.indexOf(row), 1);
      } else if (!row) data = { status: 'idle' };
      else {
        row.seen = now;
        const peer = queue.filter(x => x !== row && !x.assignment
          && Math.abs(x.rating - row.rating) <= 100 + 100 * Math.floor((now - Math.min(x.at, row.at)) / 10000))
          .sort((a, b) => Math.abs(a.rating - row.rating) - Math.abs(b.rating - row.rating) || a.at - b.at || a.uid.localeCompare(b.uid))[0];
        if (!row.assignment && peer) {
          const host = row.at < peer.at || (row.at === peer.at && row.uid < peer.uid);
          const assignment = { status: 'matched', pair: crypto.randomUUID(), code: String(1000 + Math.floor(Math.random() * 9000)) };
          row.assignment = { ...assignment, host, peer: peer.uid };
          peer.assignment = { ...assignment, host: !host, peer: row.uid };
          row.assignedAt = peer.assignedAt = now;
        }
        data = row.assignment || { status: 'searching' };
      }
      save('queue', queue);
    } else return { data: null, error: { message: 'Unknown RPC ' + name } };
    return { data, error: null };
  }
  const chans = new Set();
  function channel(name, opts) {
    const bc = new BroadcastChannel('mockrt:' + (opts?.config?.private ? 'private:' : '') + name), key = (opts && opts.config && opts.config.presence && opts.config.presence.key) || uuid();
    const hs = [], pres = {}; let my = null, last = 0, closed = false;
    const syncs = () => hs.filter(h => h.type === 'presence' && h.ev === 'sync').forEach(h => h.cb());
    const post = m => { if (!closed) { window.__sent = (window.__sent || 0) + 1; if (m.k === 'bc' && (window.__DISCONNECT || Math.random() < (window.__DROP || 0))) return; bc.postMessage(m); } };
    bc.onmessage = e => { const m = e.data, at = Math.max(last, performance.now() + lat()); last = at; setTimeout(() => !closed && (!window.__DISCONNECT || m.k !== 'bc') && recv(m), at - performance.now()); };
    function recv(m) {
      if (m.k === 'hello') { if (my) post({ k: 'pres', key, meta: my }); }
      else if (m.k === 'pres') { pres[m.key] = [m.meta]; syncs(); }
      else if (m.k === 'leave') { delete pres[m.key]; syncs(); }
      else if (m.k === 'bc') hs.filter(h => h.type === 'broadcast' && h.ev === m.event).forEach(h => h.cb({ payload: m.payload }));
    }
    const ch = {
      on(type, filter, cb) { hs.push({ type, ev: filter.event, cb }); return ch; },
      subscribe(cb) { setTimeout(() => { cb && cb('SUBSCRIBED'); post({ k: 'hello' }); }, lat()); return ch; },
      async track(meta) { my = meta; pres[key] = [meta]; post({ k: 'pres', key, meta }); syncs(); return 'ok'; },
      presenceState() { return JSON.parse(JSON.stringify(pres)); },
      async send(m) { post({ k: 'bc', event: m.event, payload: m.payload }); return 'ok'; },
      unsubscribe() { if (closed) return; post({ k: 'leave', key }); closed = true; setTimeout(() => bc.close(), 50); chans.delete(ch); },
    };
    chans.add(ch); return ch;
  }
  addEventListener('pagehide', () => chans.forEach(c => c.unsubscribe()));
  const client = {
    auth: {
      async getSession() { return { data: { session } }; },
      onAuthStateChange(cb) { authCbs.push(cb); return { data: { subscription: { unsubscribe() {} } } }; },
      async signUp({ email, password, options }) {
        const us = LS_.get('users', []); if (us.find(u => u.email === email)) return { data: {}, error: { message: 'User already registered' } };
        const u = { id: uuid(), email, password, user_metadata: (options && options.data) || {} }; us.push(u); LS_.set('users', us);
        const rows = LS_.get('t.profiles', []); const m = u.user_metadata; rows.push({ id: u.id, username: m.username, nickname: m.nickname || m.username, avatar: m.avatar || 'CH_JIN', title: null, rating: 1000, stats: {}, achievements: {}, created_at: new Date().toISOString() }); LS_.set('t.profiles', rows);
        const s = { user: { id: u.id, email, user_metadata: u.user_metadata, identities: [{}] } }; setSess(s); return { data: { user: s.user, session: s }, error: null };
      },
      async signInWithPassword({ email, password }) { const u = LS_.get('users', []).find(x => x.email === email && x.password === password); if (!u) return { data: {}, error: { message: 'Invalid login credentials' } }; const s = { user: { id: u.id, email, user_metadata: u.user_metadata } }; setSess(s); return { data: { user: s.user, session: s }, error: null }; },
      async signOut() { setSess(null); return { error: null }; },
    },
    from: t => new Q(t), channel, removeChannel(ch) { ch.unsubscribe(); },
    realtime: { async setAuth() {} },
    rpc: (name, args = {}) => new Promise(resolve => setTimeout(() => resolve(rpcExec(name, args)), 20)),
  };
  window.supabase = { createClient: () => client };
})();
