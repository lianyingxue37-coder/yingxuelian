window.createDuanlianAdminDemo = function () {
  const minute = 60000;
  const ago = (minutes) => new Date(Date.now() - minutes * minute).toISOString();
  const names = [
    ['lianying', '练影'], ['cangfeng', '藏锋'], ['jianglan', '江澜'], ['shuangye', '霜夜'],
    ['yuntai', '云台'], ['lieyan', '烈焰'], ['xiao_yue', '晓月'], ['xunlei', '迅雷'],
    ['moxing', '墨行'], ['baiyu', '白羽'], ['zhusheng', '竹声'], ['xingsui', '星碎'],
    ['duanliu', '断流'], ['yanshan', '岩山'], ['mingzhu', '明烛'], ['chunyu', '春雨'],
    ['yegui', '夜归'], ['jinghong', '惊鸿'], ['quanyu', '泉语'], ['bufeng', '捕风'],
    ['linfeng', '临风'], ['zhaoying', '照影'], ['huojin', '火烬'], ['liuye', '流夜'],
  ];
  const accounts = names.map(([username, nickname], index) => ({
    id: 'd1150000-0000-4000-8000-' + String(index + 1).padStart(12, '0'),
    username, nickname, rating: 1432 - index * 17,
    created_at: ago(index < 6 ? 42 + index * 110 : index * 510), last_sign_in_at: ago(8 + index * 14),
    banned_until: index === 4 ? new Date(Date.now() + 1440 * minute).toISOString() : null,
    is_admin: false,
  }));
  accounts.unshift({
    id: 'd1150000-0000-4000-8000-000000000030', username: 'demo_admin', nickname: '断链运营',
    rating: 1000, created_at: ago(13), last_sign_in_at: ago(2), banned_until: null, is_admin: true,
  });

  let rooms = [
    { id: 'd2050000-0000-4000-8000-000000000001', code: '8136', host: 'lianying', guest: 'jianglan', spar: false, matched: true, can_close: false },
    { id: 'd2050000-0000-4000-8000-000000000002', code: '4275', host: 'shuangye', guest: null, spar: true, matched: false, can_close: true },
    { id: 'd2050000-0000-4000-8000-000000000003', code: '6912', host: 'xunlei', guest: null, spar: false, matched: false, can_close: true },
    { id: 'd2050000-0000-4000-8000-000000000004', code: '3058', host: 'lieyan', guest: 'xiao_yue', spar: false, matched: false, can_close: false },
  ];
  const audit = [
    { actor_name: 'demo_admin', action: 'close_room', target_name: '7291', reason: '处理重复创建的公开房间', status: 'done', created_at: ago(14) },
    { actor_name: 'demo_admin', action: 'ban', target_name: 'yuntai', reason: '确认违反联机行为规范', status: 'done', created_at: ago(46) },
    { actor_name: 'demo_admin', action: 'unban', target_name: 'duanliu', reason: '复核完成，恢复登录', status: 'done', created_at: ago(132) },
  ];
  const trend = [2, 5, 3, 6, 8, 4, 10, 15, 11, 18, 14, 6];
  return {
    async overview() {
      const hour = new Date();
      hour.setMinutes(0, 0, 0);
      return {
        actor: 'demo_admin', at: new Date().toISOString(), players: accounts.length,
        new_players: accounts.filter((a) => Date.now() - new Date(a.created_at) < 1440 * minute).length,
        rooms: rooms.length, queued: 2, games: trend.reduce((total, n) => total + n, 0),
        verified: 86, disputed: 2, pending: 5,
        trend: trend.map((count, index) => ({ count, at: new Date(+hour - (23 - 2 * index) * 60 * minute).toISOString() })),
      };
    },
    async accounts(query, offset) {
      const q = query.trim().toLowerCase();
      return accounts.filter((a) => a.username.includes(q) || a.nickname.toLowerCase().includes(q) || a.id === q)
        .slice(offset, offset + 21);
    },
    async rooms() {
      return rooms.map((room, index) => ({ ...room, protocol: 18, host_until: ago(-(80 - index * 9) / 60) }));
    },
    async audit(offset) {
      return audit.slice(offset, offset + 21);
    },
    async health() {
      return { auth: true, realtime: true };
    },
    async action({ type, target, reason }) {
      if (type === 'close_room') {
        const room = rooms.find((item) => item.id === target.id && item.can_close);
        if (!room) throw new Error('room_unavailable');
        rooms = rooms.filter((item) => item.id !== target.id);
      } else {
        const account = accounts.find((item) => item.id === target.id);
        if (!account || account.is_admin) throw new Error('protected_account');
        account.banned_until = type === 'ban' ? '2126-11-23T00:00:00Z' : null;
      }
      audit.unshift({
        actor_name: 'demo_admin', action: type, target_name: target.code || target.username,
        reason, status: 'done', created_at: new Date().toISOString(),
      });
    },
  };
};
