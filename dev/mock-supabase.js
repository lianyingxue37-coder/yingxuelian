// 测试用：模拟 supabase-js 的一小部分（auth / from / rpc / channel，含好友表权限），频道消息用 BroadcastChannel，带可调延迟
(() => {
  window.DUANLIAN_SUPA = { URL: 'mock', KEY: 'mock', ...window.DUANLIAN_SUPA };
  const LS_ = { get(k, d) { try { const v = localStorage.getItem('mock.' + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } }, set(k, v) { localStorage.setItem('mock.' + k, JSON.stringify(v)); } };
  const lat = () => (window.__LAT ?? 50) + Math.random() * (window.__JIT ?? 30);
  const uuid = () => crypto.randomUUID();
  const SS = sessionStorage;
  let session = JSON.parse(SS.getItem('mock.session') || 'null'); const authCbs = [];
  const setSess = s => { session = s; SS.setItem('mock.session', JSON.stringify(s)); authCbs.forEach(cb => cb(s ? 'SIGNED_IN' : 'SIGNED_OUT', s)); };
  class Q {
    constructor(t) { this.t = t; this.op = 'select'; this.f = []; this.fin = null; this.p = null; this.one = 0; this.ord = null; this.lim = 0; }
    select() { return this; } insert(o) { this.op = 'insert'; this.p = o; return this; } update(o) { this.op = 'update'; this.p = o; return this; }
    eq(k, v) { this.f.push([k, v]); return this; } in(k, a) { this.fin = [k, a]; return this; } delete() { this.op = 'delete'; return this; } order(k, o) { this.ord = [k, o && o.ascending === false ? -1 : 1]; return this; } limit(n) { this.lim = n; return this; }
    single() { this.one = 1; return this; } maybeSingle() { this.one = 2; return this; }
    then(a, b) { return new Promise(r => setTimeout(() => r(this.exec()), 20)).then(a, b); }
    exec() {
      const uid = session?.user.id, cosmetic = ['nickname', 'avatar', 'title'];
      const deny = { data: null, error: { code: '42501', message: 'permission denied' } };
      if (this.t === 'friendships') return this.friends(uid, deny);
      // 商城：目录公开只读；库存只看自己的；没拥有的商城称号挂不上（同 20261125000000_shop.sql）
      if (this.t === 'shop_items') return this.op === 'select' ? this.done(SHOP_ITEMS.slice()) : deny;
      if (this.t === 'inventory' || this.t === 'shop_orders') return this.op === 'select' && uid ? this.done(LS_.get('t.' + this.t, []).filter(r => r.uid === uid)) : deny;
      if (this.t === 'profiles' && this.op === 'update' && typeof this.p.title === 'string' && this.p.title.startsWith('SHOP_')
        && !LS_.get('t.inventory', []).some(r => r.uid === uid && r.item_id === this.p.title)) return { data: null, error: { code: '42501', message: 'title not owned' } };
      if (this.op === 'insert' || (this.op === 'update' && (!uid || this.t !== 'profiles' || Object.keys(this.p).some(k => !cosmetic.includes(k))))) return deny;
      let rows = LS_.get('t.' + this.t, []);
      if (this.t === 'matches') rows = rows.filter(r => r.user_id === uid);
      if (this.t === 'duanlian_leaderboard') rows = LS_.get('t.profiles', []).filter(p => p.stats.onG)
        .sort((a, b) => b.rating - a.rating || b.stats.onW - a.stats.onW || a.id.localeCompare(b.id)).slice(0, 100)
        .map((p, i) => ({ rank: i + 1, nickname: p.nickname, avatar: p.avatar, rating: p.rating, games: p.stats.onG,
          wins: p.stats.onW, win_rate: Math.round(1000 * p.stats.onW / p.stats.onG) / 10 }));
      const ok = r => this.f.every(([k, v]) => r[k] === v) && (!this.fin || this.fin[1].includes(r[this.fin[0]])) && (this.op !== 'update' || r.id === uid);
      let out;
      if (this.op === 'update') { out = []; rows.forEach(r => { if (ok(r)) { Object.assign(r, this.p); out.push(r); } }); LS_.set('t.' + this.t, rows); }
      else { out = rows.filter(ok); if (this.ord) { const [k, d] = this.ord; out.sort((x, y) => (x[k] < y[k] ? -1 : 1) * d); } if (this.lim) out = out.slice(0, this.lim); }
      return this.done(out);
    }
    done(out) {
      let data = out; if (this.one) { if (!out.length) return this.one === 2 ? { data: null, error: null } : { data: null, error: { message: 'no rows' } }; data = out[0]; }
      return { data: JSON.parse(JSON.stringify(data)), error: null };
    }
    // 好友表按 supabase_setup.sql 的权限：只能以自己名义发请求、只有对方能同意、双方都能删
    friends(uid, deny) {
      if (!uid) return deny;
      const all = LS_.get('t.friendships', []), mine = r => r.requester === uid || r.addressee === uid;
      const ok = r => mine(r) && this.f.every(([k, v]) => r[k] === v) && (!this.fin || this.fin[1].includes(r[this.fin[0]]));
      if (this.op === 'insert') {
        const o = this.p, keys = Object.keys(o);
        if (keys.some(k => !['requester', 'addressee'].includes(k)) || (o.requester ?? uid) !== uid || !o.addressee || o.addressee === uid) return deny;
        if (all.some(r => (r.requester === uid && r.addressee === o.addressee) || (r.requester === o.addressee && r.addressee === uid)))
          return { data: null, error: { code: '23505', message: 'duplicate key value violates unique constraint "friendships_pair"' } };
        const row = { id: all.reduce((m, r) => Math.max(m, r.id), 0) + 1, requester: uid, addressee: o.addressee, status: 'pending', created_at: new Date().toISOString() };
        all.push(row); LS_.set('t.friendships', all); return this.done([row]);
      }
      if (this.op === 'update') {
        if (Object.keys(this.p).some(k => k !== 'status') || this.p.status !== 'accepted') return deny;
        const out = all.filter(r => ok(r) && r.addressee === uid); out.forEach(r => { r.status = 'accepted'; });
        LS_.set('t.friendships', all); return this.done(out);
      }
      if (this.op === 'delete') {
        const out = all.filter(ok); LS_.set('t.friendships', all.filter(r => !ok(r))); return this.done(out);
      }
      return this.done(all.filter(ok));
    }
  }

  const mockRooms = () => LS_.get('t.rooms', []);
  const saveRooms = rows => LS_.set('t.rooms', rows);
  const roomLive = r => r && r.hostUntil > Date.now();
  const seatLive = r => r?.guest && r.guestUntil > Date.now();
  const roomMember = (r, uid) => roomLive(r) && (r.host === uid || (seatLive(r) && r.guest === uid));
  const friendsWith = (a, b) => LS_.get('t.friendships', []).some(f => f.status === 'accepted'
    && ((f.requester === a && f.addressee === b) || (f.requester === b && f.addressee === a)));
  function makeRoom(id, host, guest, spar, protocol = 14) {
    const rooms = mockRooms().filter(r => roomLive(r) && r.host !== host);
    let code;
    do { code = String(1000 + Math.floor(Math.random() * 9000)); } while (rooms.some(r => r.code === code));
    const r = { id, host, guest, spar, protocol, code, matched: !!guest, hostUntil: Date.now() + 90000, guestUntil: guest ? Date.now() + 90000 : 0 };
    rooms.push(r); saveRooms(rooms); return r;
  }
  function roomRPC(name, args, uid, profiles) {
    const rooms = mockRooms(), r = rooms.find(x => x.id === args.p_room);
    const ok = data => ({ data, error: null });
    const protocol = args.p_protocol ?? 14;
    const view = r => ({ id: r.id, host: r.host, guest: seatLive(r) ? r.guest : null, spar: r.spar, matched: r.matched, code: r.code, protocol: r.protocol ?? 14 });
    if (name === 'room_create') return ok(view(makeRoom(uuid(), uid, null, !!args.p_spar, protocol)));
    if (name === 'room_enter') {
      const target = rooms.find(row => row.code === args.p_code && (!args.p_room || row.id === args.p_room));
      if (!roomLive(target)) return ok({ status: 'missing' });
      if ((target.protocol ?? 14) !== protocol) return ok({ status: 'version_mismatch' });
      if (target.host === uid) return ok(view(target));
      if (target.spar && !friendsWith(uid, target.host)) return ok({ status: 'friends_only' });
      if ((target.matched || seatLive(target)) && target.guest !== uid) return ok({ status: 'full' });
      if (target.inviteUntil > Date.now() && target.invited !== uid && target.guest !== uid) return ok({ status: 'reserved' });
      Object.assign(target, { guest: uid, guestUntil: Date.now() + 90000, invited: null, inviteUntil: 0 });
      saveRooms(rooms); return ok(view(target));
    }
    if (name === 'room_touch') {
      if (!roomMember(r, uid)) return ok(null);
      r[r.host === uid ? 'hostUntil' : 'guestUntil'] = Date.now() + 90000;
      saveRooms(rooms); return ok(view(r));
    }
    if (name === 'room_exit') {
      if (r?.host === uid || (r?.matched && r.guest === uid)) saveRooms(rooms.filter(x => x !== r));
      else if (r?.guest === uid) { r.guest = null; r.guestUntil = 0; saveRooms(rooms); }
      return ok(null);
    }
    if (name === 'room_invite') {
      const allowed = roomLive(r) && r.host === uid && !r.matched && !seatLive(r) && args.p_guest !== uid
        && profiles.some(p => p.id === args.p_guest) && (!r.spar || friendsWith(uid, args.p_guest));
      if (allowed) { r.invited = args.p_guest; r.inviteUntil = Date.now() + 45000; saveRooms(rooms); }
      return ok(!!allowed);
    }
    if (name === 'room_invites') return ok(rooms.filter(r => roomLive(r) && (r.protocol ?? 14) === protocol && r.invited === uid
      && r.inviteUntil > Date.now() && (!r.spar || friendsWith(uid, r.host)))
      .sort((a, b) => b.inviteUntil - a.inviteUntil)
      .map(r => {
        const p = profiles.find(x => x.id === r.host);
        return { id: r.id, code: r.code, spar: r.spar, uid: r.host, nick: p.nickname,
          avatar: p.avatar, title: p.title, expires: new Date(r.inviteUntil).toISOString() };
      }));
    if (name === 'room_decline') {
      if (r?.invited === uid) { r.invited = null; r.inviteUntil = 0; saveRooms(rooms); }
      return ok(null);
    }
    return { data: null, error: { message: 'Unknown RPC ' + name } };
  }

  function rpcExec(name, a) {
    const uid = session?.user.id;
    const deny = () => ({ data: null, error: { code: '42501', message: 'permission denied' } });
    if (!uid) return deny();
    const read = k => LS_.get('t.' + k, []);
    const save = (k, rows) => LS_.set('t.' + k, rows);
    const profiles = read('profiles'), mine = profiles.find(p => p.id === uid);
    if (name === 'room_start') {
      const room = mockRooms().find(r => r.id === a.p_room);
      if (!roomLive(room) || room.host !== uid || !seatLive(room) || room.spar !== a.p_setup.spar
          || (room.protocol ?? 14) !== (a.p_setup.protocol ?? 14)
          || (room.spar && !friendsWith(room.host, room.guest))) return deny();
      a = { ...a, p_code: room.code, p_guest: room.guest }; name = 'online_open';
    }
    if (name.startsWith('room_')) return roomRPC(name, a, uid, profiles);
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
      if (game.setup.spar === true) return { data: { status: 'unrated', stats: mine.stats, achievements: mine.achievements, rating: mine.rating }, error: null };
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
      const now = Date.now(), protocol = a.p_protocol ?? 13;
      const queue = read('queue').filter(x => x.assignment ? now - x.assignedAt < 15000 : now - x.seen < 8000);
      const row = queue.find(x => x.uid === uid);
      if (name === 'mm_join') {
        if (!row) queue.push({ uid, protocol, at: now, seen: now, rating: mine.rating });
        else Object.assign(row, { seen: now, protocol, at: row.assignment || row.protocol !== protocol ? now : row.at, assignment: null });
      } else if (name === 'mm_leave') {
        if (row) queue.splice(queue.indexOf(row), 1);
      } else if (!row || row.protocol !== protocol) data = { status: 'idle' };
      else {
        row.seen = now;
        const peer = queue.filter(x => x !== row && x.protocol === protocol && !x.assignment
          && Math.abs(x.rating - row.rating) <= 100 + 100 * Math.floor((now - Math.min(x.at, row.at)) / 10000))
          .sort((a, b) => Math.abs(a.rating - row.rating) - Math.abs(b.rating - row.rating) || a.at - b.at || a.uid.localeCompare(b.uid))[0];
        if (!row.assignment && peer) {
          const host = row.at < peer.at || (row.at === peer.at && row.uid < peer.uid);
          const pair = crypto.randomUUID();
          const code = protocol >= 14 ? makeRoom(pair, host ? uid : peer.uid, host ? peer.uid : uid, false, protocol).code
            : String(1000 + Math.floor(Math.random() * 9000));
          const assignment = { status: 'matched', pair, code };
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
      subscribe(cb) {
        setTimeout(() => {
          if (closed) return;
          if (name.startsWith('duanlian-room:') && !roomMember(mockRooms().find(r => r.id === name.slice(14)), session?.user.id)) {
            cb?.('CHANNEL_ERROR'); return;
          }
          cb?.('SUBSCRIBED'); post({ k: 'hello' });
        }, lat());
        return ch;
      },
      async track(meta) { my = meta; pres[key] = [meta]; post({ k: 'pres', key, meta }); syncs(); return 'ok'; },
      presenceState() { return JSON.parse(JSON.stringify(pres)); },
      async send(m) { post({ k: 'bc', event: m.event, payload: m.payload }); return 'ok'; },
      unsubscribe() { if (closed) return; post({ k: 'leave', key }); closed = true; setTimeout(() => bc.close(), 50); chans.delete(ch); },
    };
    chans.add(ch); return ch;
  }
  addEventListener('pagehide', () => chans.forEach(c => c.unsubscribe()));

  function mockAuth(persist) {
    let temporary = null;
    const current = () => persist ? session : temporary;
    const set = value => { if (persist) setSess(value); else temporary = value; };
    const signIn = u => {
      const s = { user: { id: u.id, email: u.email, user_metadata: u.user_metadata, identities: [{}] } };
      set(s); return { data: { user: s.user, session: s }, error: null };
    };
    const authError = message => ({ data: {}, error: { message } });
    const readUsers = () => LS_.get('users', []);
    return {
      async getSession() { return { data: { session: current() } }; },
      onAuthStateChange(cb) { authCbs.push(cb); return { data: { subscription: { unsubscribe() {} } } }; },
      async signUp({ email, password, options }) {
        const us = readUsers(), m = options?.data || {};
        if (us.some(u => u.email === email || u.user_metadata.username === m.username)) return authError('User already registered');
        const verified = email.endsWith('@players.duanlian.game');
        const u = { id: uuid(), email, password, user_metadata: m, verified }; us.push(u); LS_.set('users', us);
        const rows = LS_.get('t.profiles', []);
        rows.push({ id: u.id, username: m.username, nickname: m.nickname || m.username, avatar: m.avatar || 'CH_JIN',
          title: null, rating: 1000, stats: {}, achievements: {}, created_at: new Date().toISOString() });
        LS_.set('t.profiles', rows);
        if (verified) return signIn(u);
        return { data: { user: { id: u.id }, session: null }, error: null };
      },
      async signInWithPassword({ email, password }) {
        const u = readUsers().find(x => x.email === email && x.password === password);
        if (!u) return authError('Invalid login credentials');
        if (u.verified === false) return authError('Email not confirmed');
        return signIn(u);
      },
      async resend() { return { error: null }; },
      async resetPasswordForEmail(email) { LS_.set('recover.email', email); return { error: null }; },
      async verifyOtp({ email, token, type }) {
        const us = readUsers(), u = us.find(x => x.email === email);
        const allowed = type === 'signup' ? u?.verified === false : type === 'recovery' && u?.verified && LS_.get('recover.email', '') === email;
        if (!allowed || token !== '384759') return authError('OTP expired');
        if (type === 'recovery') LS_.set('recover.email', '');
        else { u.verified = true; LS_.set('users', us); }
        return signIn(u);
      },
      async updateUser({ password, current_password }) {
        const us = readUsers(), u = us.find(x => x.id === current()?.user.id);
        if (!u || (persist && current_password !== u.password)) return authError('current password mismatch');
        u.password = password; LS_.set('users', us); return { data: { user: current().user }, error: null };
      },
      async signOut() { set(null); return { error: null }; },
    };
  }
  // 商城：模拟 Edge Function `shop/claim`。测试往 localStorage 'mock.paid' 写 { 订单号: 商品 ID } 表示已在爱发电付款
  const SHOP_ITEMS = [
    { id: 'SHOP_DUANLIAN', name: '断链者', descr: '支持作者的第一枚称号', price_cny: 6, afdian_url: 'https://afdian.com/order/create?plan_id=mock1', sort: 10 },
    { id: 'SHOP_ZHONGYAN', name: '终焉行者', descr: '把势推到尽头的人', price_cny: 12, afdian_url: 'https://afdian.com/order/create?plan_id=mock2', sort: 20 },
    { id: 'SHOP_PATRON', name: '断链赞助人', descr: '感谢你让断链走得更远', price_cny: 30, afdian_url: null, sort: 40 },
  ];
  function shopClaim(body) {
    const uid = session?.user.id; if (!uid) return { ok: false, error: 'login' };
    const t = String(body?.out_trade_no || ''); if (!/^[0-9]{10,40}$/.test(t)) return { ok: false, error: 'format' };
    const item = LS_.get('paid', {})[t]; if (!item) return { ok: false, error: 'not_found' };
    const orders = LS_.get('t.shop_orders', []), prev = orders.find(o => o.out_trade_no === t);
    if (prev) return { ok: prev.uid === uid, status: prev.uid === uid ? 'already' : 'taken', item: prev.item_id };
    orders.push({ out_trade_no: t, uid, item_id: item, status: 'granted' }); LS_.set('t.shop_orders', orders);
    const inv = LS_.get('t.inventory', []); if (!inv.some(r => r.uid === uid && r.item_id === item)) inv.push({ uid, item_id: item }); LS_.set('t.inventory', inv);
    return { ok: true, status: 'granted', item };
  }
  const client = {
    functions: { invoke: (name, opts = {}) => new Promise(r => setTimeout(() => r(name === 'shop/claim' ? { data: shopClaim(opts.body), error: null } : { data: null, error: { message: 'unknown function' } }), 30)) },
    auth: mockAuth(true),
    from: t => new Q(t), channel, removeChannel(ch) { ch.unsubscribe(); },
    realtime: { async setAuth() {} },
    rpc: (name, args = {}) => new Promise(resolve => setTimeout(() => resolve(rpcExec(name, args)), 20)),
  };
  window.supabase = { createClient: (_url, _key, options) => options?.auth?.persistSession === false ? { auth: mockAuth(false) } : client };
})();
