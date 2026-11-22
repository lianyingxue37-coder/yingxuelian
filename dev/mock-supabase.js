// 测试用：模拟 supabase-js 的一小部分（auth / from / channel），频道消息用 BroadcastChannel，带可调延迟
(() => {
  window.DUANLIAN_SUPA = { URL: 'mock', KEY: 'mock' };
  const LS_ = { get(k, d) { try { const v = localStorage.getItem('mock.' + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } }, set(k, v) { localStorage.setItem('mock.' + k, JSON.stringify(v)); } };
  const lat = () => (window.__LAT ?? 50) + Math.random() * (window.__JIT ?? 30);
  const uuid = () => 'u' + Math.random().toString(16).slice(2, 10) + Date.now().toString(16).slice(-4);
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
      const rows = LS_.get('t.' + this.t, []), ok = r => this.f.every(([k, v]) => r[k] === v); let out;
      if (this.op === 'insert') { const o = { ...this.p, created_at: new Date().toISOString() }; if (this.t === 'matches') { o.id = rows.length + 1; o.user_id = o.user_id || (session && session.user.id); } rows.push(o); LS_.set('t.' + this.t, rows); out = [o]; }
      else if (this.op === 'update') { out = []; rows.forEach(r => { if (ok(r)) { Object.assign(r, this.p); out.push(r); } }); LS_.set('t.' + this.t, rows); }
      else { out = rows.filter(ok); if (this.ord) { const [k, d] = this.ord; out.sort((x, y) => (x[k] < y[k] ? -1 : 1) * d); } if (this.lim) out = out.slice(0, this.lim); }
      let data = out; if (this.one) { if (!out.length) return this.one === 2 ? { data: null, error: null } : { data: null, error: { message: 'no rows' } }; data = out[0]; }
      return { data: JSON.parse(JSON.stringify(data)), error: null };
    }
  }
  const chans = new Set();
  function channel(name, opts) {
    const bc = new BroadcastChannel('mockrt:' + name), key = (opts && opts.config && opts.config.presence && opts.config.presence.key) || uuid();
    const hs = [], pres = {}; let my = null, last = 0, closed = false;
    const syncs = () => hs.filter(h => h.type === 'presence' && h.ev === 'sync').forEach(h => h.cb());
    const post = m => { if (!closed) { window.__sent = (window.__sent || 0) + 1; if (m.k === 'bc' && Math.random() < (window.__DROP || 0)) return; bc.postMessage(m); } };
    bc.onmessage = e => { const m = e.data, at = Math.max(last, performance.now() + lat()); last = at; setTimeout(() => !closed && recv(m), at - performance.now()); };
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
        const rows = LS_.get('t.profiles', []); const m = u.user_metadata; rows.push({ id: u.id, username: m.username, nickname: m.nickname || m.username, avatar: m.avatar || 'CH_JIN', title: null, stats: {}, achievements: {}, created_at: new Date().toISOString() }); LS_.set('t.profiles', rows);
        const s = { user: { id: u.id, email, user_metadata: u.user_metadata, identities: [{}] } }; setSess(s); return { data: { user: s.user, session: s }, error: null };
      },
      async signInWithPassword({ email, password }) { const u = LS_.get('users', []).find(x => x.email === email && x.password === password); if (!u) return { data: {}, error: { message: 'Invalid login credentials' } }; const s = { user: { id: u.id, email, user_metadata: u.user_metadata } }; setSess(s); return { data: { user: s.user, session: s }, error: null }; },
      async signOut() { setSess(null); return { error: null }; },
    },
    from: t => new Q(t), channel, removeChannel(ch) { ch.unsubscribe(); },
  };
  window.supabase = { createClient: () => client };
})();
