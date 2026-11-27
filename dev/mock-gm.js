/* 管理后台本地测试用的假后端：python3 dev/test_gm.py 时注入，不连真实 Supabase。
   数据只在内存里，刷新就恢复。登录：gm_owner / 任意密码（站长），gm_admin（管理员），其他账号 = 不是管理员。 */
(() => {
  const now = Date.now(), iso = d => new Date(d).toISOString();
  const P = (id, username, nickname, extra = {}) => ({ id, username, nickname, avatar: 'CH_JIN', title: null, rating: 1000, stats: {}, achievements: {}, created_at: iso(now - 86400e3 * (5 + id.charCodeAt(1) % 9)), last_sign_in_at: iso(now - 3600e3), banned_until: null, sessions: 1, ...extra });
  const db = {
    players: [P('u0', 'gm_owner', '站长'), P('u1', 'gm_admin', '管理员'), P('u2', 'player_a', '阿甲', { rating: 1320, stats: { games: 40, wins: 25, onG: 12, onW: 7, maxHits: 22 }, achievements: { ACH_FIRST: true, ACH_WIN1: true } }),
      P('u3', 'player_b', '阿乙', { rating: 980, avatar: 'CH_LAN' }), P('u4', 'player_c', '阿丙')],
    admins: { u0: 'owner', u1: 'admin' },
    items: [{ id: 'SHOP_DUANLIAN', kind: 'title', name: '断链者', descr: '支持作者的第一枚称号', price_coins: 60, sort: 10, active: true },
      { id: 'SHOP_PATRON', kind: 'title', name: '断链赞助人', descr: '感谢你让断链走得更远', price_coins: 300, sort: 40, active: true },
      { id: 'SHOP_PORTRAITS', kind: 'bundle', name: '全角色立绘组合包', descr: '七名角色的原创新版立绘', price_coins: null, sort: 50, active: true }],
    inv: [{ uid: 'u2', item_id: 'SHOP_DUANLIAN', source: 'coins', at: iso(now - 86400e3) }],
    matches: [{ id: 1, user_id: 'u2', mode: 'online', my_char: 'CH_JIN', opp_char: 'CH_LAN', opp_name: '阿乙', result: 'win', max_hits: 14, created_at: iso(now - 7200e3), verified: true }],
    news: [], log: [], me: null, seq: 1,
  };
  const ACH = /^ACH_(FIRST|WIN1|WIN10|WIN50|G100|HIT10|HIT25|LV3|LV4|FIN10|BRK10|PARRY20|BURN|AIR|SIDE|THROW|PERFECT|ALL|CPU2|ON1|ON10)$/;
  const fail = m => { throw new Error(m); };
  const pl = id => db.players.find(p => p.id === id) || fail('player_not_found');
  const need = () => { if (!db.me || !db.admins[db.me]) fail('not_admin'); return db.me; };
  const target = id => { const p = pl(id); if (db.admins[id] && db.admins[db.me] !== 'owner') fail('protected_admin'); return p; };
  const reason = r => { if (!r || !String(r).trim()) fail('reason_required'); return String(r).trim(); };
  const write = (action, t, r, detail) => db.log.unshift({ id: db.seq++, at: iso(Date.now()), actor_name: pl(db.me).username, action, target: t, target_name: t ? pl(t).username : null, reason: r, detail: detail || {} });
  const banned = p => p.banned_until && (p.banned_until === 'infinity' || new Date(p.banned_until) > Date.now());
  const F = {
    gm_me: () => { need(); return { uid: db.me, username: pl(db.me).username, role: db.admins[db.me] }; },
    gm_overview: () => { need(); return { players: db.players.length, new_1d: 1, new_7d: db.players.length, active_1d: 3, active_7d: 4, banned: db.players.filter(banned).length, matches_1d: 6, online_1d: 2,
      rooms_live: 1, queue_live: 0, items_owned: db.inv.length, announcements: db.news.filter(n => n.active).length,
      signups: [3, 1, 0, 2, 4, 1, 2].map((n, i) => ({ d: iso(now - 86400e3 * (6 - i)).slice(0, 10), n })), games: [5, 9, 3, 7, 12, 6, 8].map((n, i) => ({ d: iso(now - 86400e3 * (6 - i)).slice(0, 10), n })), recent: db.log.slice(0, 8) }; },
    gm_players: a => { need(); const q = (a.p_query || '').toLowerCase(); let rows = db.players.filter(p => !q || p.username.includes(q) || p.nickname.toLowerCase().includes(q) || p.id === q);
      if (a.p_sort === 'rating') rows = rows.slice().sort((x, y) => y.rating - x.rating);
      return { total: rows.length, rows: rows.slice(a.p_offset || 0, (a.p_offset || 0) + 50).map(p => ({ ...p, banned: banned(p), games: p.stats.games || 0, admin: !!db.admins[p.id], items: db.inv.filter(i => i.uid === p.id).length })) }; },
    gm_player: a => { need(); const p = pl(a.p_target); return { ...p, banned: banned(p), admin: db.admins[p.id] || null, friends: 2,
      inventory: db.inv.filter(i => i.uid === p.id).map(i => { const it = db.items.find(x => x.id === i.item_id); return { id: it.id, name: it.name, kind: it.kind, at: i.at, source: i.source }; }),
      matches: db.matches.filter(m => m.user_id === p.id), log: db.log.filter(l => l.target === p.id) }; },
    gm_catalog: () => { need(); return db.items.map(i => ({ ...i, owners: db.inv.filter(x => x.item_id === i.id).length })); },
    gm_matches: () => { need(); return { games: [{ id: 'g1', opened_at: iso(now - 7200e3), status: 'verified', host: 'player_a', guest: 'player_b', winner_slot: 0, spar: false }], rooms: [{ id: 'r1', code: '4821', host: 'player_c', guest: null, spar: false, matched: false, host_until: iso(now + 30e3) }] }; },
    gm_log: a => { need(); return db.log.filter(l => !a.p_target || l.target === a.p_target); },
    gm_player_edit: a => { need(); const r = reason(a.p_reason), p = target(a.p_target), before = { nickname: p.nickname, avatar: p.avatar, title: p.title, rating: p.rating };
      if (a.p_rating != null && (a.p_rating < 0 || a.p_rating > 5000)) fail('bad_rating');
      const title = a.p_title === '' ? null : a.p_title ?? p.title;
      if (title && title.startsWith('SHOP_') && !db.inv.some(i => i.uid === p.id && i.item_id === title)) fail('title not owned');
      Object.assign(p, { nickname: a.p_nickname || p.nickname, avatar: a.p_avatar || p.avatar, title, rating: a.p_rating ?? p.rating });
      write('edit_profile', p.id, r, { before, after: { nickname: p.nickname, avatar: p.avatar, title: p.title, rating: p.rating } }); },
    gm_item: a => { need(); const r = reason(a.p_reason); if (!db.items.some(i => i.id === a.p_item)) fail('item_not_found'); let changed = 0, skipped = 0;
      for (const t of a.p_targets) { const p = db.players.find(x => x.id === t); if (!p) { skipped++; continue; }
        const has = db.inv.findIndex(i => i.uid === t && i.item_id === a.p_item);
        if (a.p_op === 'grant' && has < 0) { db.inv.push({ uid: t, item_id: a.p_item, source: 'gm', at: iso(Date.now()) }); changed++; write('grant_item', t, r, { item: a.p_item }); }
        else if (a.p_op === 'revoke' && has >= 0) { db.inv.splice(has, 1); if (p.title === a.p_item) p.title = null; changed++; write('revoke_item', t, r, { item: a.p_item }); }
        else skipped++; }
      return { changed, skipped }; },
    gm_achievement: a => { need(); const r = reason(a.p_reason), p = target(a.p_target); if (!ACH.test(a.p_ach)) fail('bad_achievement');
      if (a.p_op === 'grant') p.achievements[a.p_ach] = true; else { delete p.achievements[a.p_ach]; if (p.title === a.p_ach) p.title = null; }
      write(a.p_op + '_achievement', p.id, r, { achievement: a.p_ach }); },
    gm_reset_record: a => { need(); const r = reason(a.p_reason), p = target(a.p_target); const n = db.matches.filter(m => m.user_id === p.id).length;
      db.matches = db.matches.filter(m => m.user_id !== p.id); p.stats = {}; p.rating = 1000; write('reset_record', p.id, r, { matches_deleted: n }); },
    gm_ban: a => { need(); const r = reason(a.p_reason), p = target(a.p_target); if (p.id === db.me) fail('cannot_ban_self');
      p.banned_until = a.p_hours === 0 ? null : a.p_hours === -1 ? 'infinity' : iso(Date.now() + a.p_hours * 3600e3); if (p.banned_until) p.sessions = 0;
      write(p.banned_until ? 'ban' : 'unban', p.id, r, { hours: a.p_hours, until: p.banned_until }); return p.banned_until; },
    gm_kick: a => { need(); const r = reason(a.p_reason), p = target(a.p_target); const n = p.sessions; p.sessions = 0; write('kick', p.id, r, { sessions: n }); return n; },
    gm_item_save: a => { need(); const r = reason(a.p_reason); let it = db.items.find(i => i.id === a.p_id); const isNew = !it;
      if (!it) { it = { id: a.p_id }; db.items.push(it); } Object.assign(it, { kind: a.p_kind, name: a.p_name, descr: a.p_descr, price_coins: a.p_price_coins, sort: a.p_sort, active: a.p_active });
      write(isNew ? 'create_item' : 'edit_item', null, r, { item: a.p_id }); },
    gm_announcements: () => { need(); return db.news.slice().reverse(); },
    gm_announce: a => { need(); if (a.p_id == null) { const id = db.seq++; db.news.push({ id, body: a.p_body, level: a.p_level, active: true, starts_at: iso(Date.now() - 1000), ends_at: a.p_hours ? iso(Date.now() + a.p_hours * 3600e3) : null, created_at: iso(Date.now()) }); write('announce', null, a.p_body, { id }); return id; }
      const n = db.news.find(x => x.id === a.p_id) || fail('not_found'); n.active = a.p_active; write('announce_toggle', null, n.body, { id: n.id, active: n.active }); return n.id; },
    gm_admins: () => { need(); return Object.entries(db.admins).map(([uid, role]) => ({ uid, role, username: pl(uid).username, nickname: pl(uid).nickname, added_at: iso(now - 86400e3) })); },
    gm_admin_set: a => { need(); if (db.admins[db.me] !== 'owner') fail('not_admin'); const r = reason(a.p_reason); const p = db.players.find(x => x.username === a.p_username) || fail('player_not_found');
      if (p.id === db.me) fail('cannot_change_self'); if (a.p_role) db.admins[p.id] = a.p_role; else delete db.admins[p.id]; write('admin_set', p.id, r, { role: a.p_role || null }); },
  };
  window.__GM_DB = db;
  window.__GM_MOCK = {
    rpc: async (fn, args) => { await new Promise(r => setTimeout(r, 20)); if (!F[fn]) throw new Error('no rpc ' + fn); return JSON.parse(JSON.stringify(F[fn](args) ?? null)); },
    byUsernames: async list => db.players.filter(p => list.includes(p.username)).map(p => ({ id: p.id, username: p.username })),
    signIn: async u => { const p = db.players.find(x => x.username === u.toLowerCase()); if (!p) throw new Error('Invalid login credentials'); db.me = p.id; sessionStorage.setItem('gm.mock.me', p.id); },
    signOut: async () => { db.me = null; sessionStorage.removeItem('gm.mock.me'); },
    session: async () => { db.me = sessionStorage.getItem('gm.mock.me'); return db.me ? { user: { id: db.me } } : null; },
  };
})();
