'use strict';

const $ = (id) => document.getElementById(id);
const config = window.DL_ADMIN_CONFIG;
const params = new URLSearchParams(location.search);
const demo = params.get('demo') === '1' || window.DL_ADMIN_DEMO_ONLY === true;
const pageSize = 20;
const number = new Intl.NumberFormat('zh-CN');
const dateTime = new Intl.DateTimeFormat('zh-CN', {
  year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
});
const clock = new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const pages = {
  overview: ['总览', '查看玩家增长、联机房间和对局结算。'],
  accounts: ['玩家账户', '搜索《断链》玩家，查看资料和管理登录权限。'],
  servers: ['服务器', '检查 Supabase 连接、匹配队列和联机房间。'],
  audit: ['操作日志', '查看管理员的账户处理和房间关闭记录。'],
};
const actionNames = { ban: '停用登录', unban: '恢复登录', close_room: '关闭房间' };
const auditStates = {
  pending: ['处理中', 'warn'], done: ['已完成', 'good'],
  failed: ['失败', 'bad'], uncertain: ['待核对', 'warn'],
};
const errors = {
  admin_required: '此账号没有后台管理权限。',
  authentication_required: '登录会话已失效，请重新登录。',
  protected_account: '此账号属于后台管理员，无法在这里停用或恢复。',
  account_not_found: '找不到该玩家账户。',
  account_state_changed: '账号状态已经变化，请刷新页面后再操作。',
  account_action_in_progress: '此账号有操作正在处理，请稍后刷新。',
  'rate limit exceeded': '操作过于频繁，请稍后重试。',
  room_unavailable: '该房间已关闭、过期或有人加入，请刷新后再操作。',
  action_uncertain: '暂时无法确认操作结果，请刷新账户状态并查看操作日志。',
  auth_update_failed: '认证服务没有完成请求。',
  admin_unavailable: '暂时无法访问后台，请稍后重试。',
  migration_required: '管理后台数据库迁移尚未应用。',
  function_unavailable: '账户管理服务尚未部署或暂时无法访问。',
  sdk_unavailable: '登录组件加载失败，请检查网络后重试。',
  invalid_credentials: '账号或密码有误，或该账号已停用。',
};
const html = (value) => String(value ?? '—').replace(/[&<>"']/g, (char) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[char]);
const date = (value) => value ? dateTime.format(new Date(value)) : '—';
const displayError = (error) => errors[error.message] || errors.admin_unavailable;

let backend;
let client;
let page = 'overview';
let accountQuery = '';
let accountOffset = 0;
let auditOffset = 0;
let renderedRows = [];
let loadId = 0;
let currentAction;
let toastTimer;

async function signIn(username, password) {
  if (!window.supabase) {
    await new Promise((resolve, reject) => {
      const sdk = document.createElement('script');
      sdk.src = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.119.2/dist/umd/supabase.js';
      sdk.integrity = 'sha384-A97u3Qnt9GZHURO9YJZRe7VQgGUeFzcv6I1oIGnUTxQrCxnpQMwR0/G8F2zt9abZ';
      sdk.crossOrigin = 'anonymous';
      sdk.onload = resolve;
      sdk.onerror = () => { sdk.remove(); reject(new Error('sdk_unavailable')); };
      document.head.append(sdk);
    });
  }
  client ??= window.supabase.createClient(config.url, config.key, {
    auth: { persistSession: false, detectSessionInUrl: false },
  });
  const email = username.includes('@') ? username : username.toLowerCase() + '@players.duanlian.game';
  const { error } = await client.auth.signInWithPassword({ email, password });
  if (error) {
    throw new Error(error.status === 400 || error.status === 403 ? 'invalid_credentials' : 'admin_unavailable');
  }
  async function rpc(name, args) {
    const { data, error: rpcError } = await client.rpc(name, args);
    if (rpcError) {
      if (rpcError.code === 'PGRST202' || rpcError.code === '42883') throw new Error('migration_required');
      if (rpcError.message === 'admin_required' || rpcError.code === '42501') throw new Error('admin_required');
      if (rpcError.code === 'PGRST301' || rpcError.code === 'PGRST303') throw new Error('authentication_required');
      throw new Error(rpcError.message);
    }
    return data;
  }
  return {
    overview: () => rpc('dl_admin_overview'),
    accounts: (query, offset) => rpc('dl_admin_accounts', { p_query: query, p_offset: offset }),
    rooms: () => rpc('dl_admin_rooms'),
    audit: (offset) => rpc('dl_admin_audit', { p_offset: offset }),
    async health() {
      const channel = client.channel('dl-admin-health-' + crypto.randomUUID());
      const realtime = new Promise((resolve) => {
        const timer = setTimeout(() => resolve(false), 4500);
        channel.subscribe((status) => {
          if (['SUBSCRIBED', 'TIMED_OUT', 'CHANNEL_ERROR', 'CLOSED'].includes(status)) {
            clearTimeout(timer);
            resolve(status === 'SUBSCRIBED');
          }
        });
      }).finally(() => { void client.removeChannel(channel); });
      const auth = client.auth.getUser().then(({ data, error }) => Boolean(data.user && !error));
      const results = await Promise.allSettled([auth, realtime]);
      return { auth: results[0].value === true, realtime: results[1].value === true };
    },
    async action({ type, target, reason }) {
      if (type === 'close_room') {
        return rpc('dl_admin_close_room', { p_room: target.id, p_reason: reason });
      }
      const { error: invokeError } = await client.functions.invoke('admin-accounts', {
        body: { target: target.id, action: type, reason },
      });
      if (invokeError) {
        const result = await invokeError.context?.json?.().catch(() => null);
        throw new Error(result?.error || 'function_unavailable');
      }
    },
  };
}

function badge(label, tone = '', dot = false) {
  return `<span class="badge ${tone}">${dot ? '<i class="dot" aria-hidden="true"></i>' : ''}${html(label)}</span>`;
}

function table(columns, rows, emptyMessage) {
  if (!rows.length) return `<p class="empty">${html(emptyMessage)}</p>`;
  return `<div class="table-scroll" tabindex="0" role="region" aria-label="${html(pages[page][0])}数据表"><table><thead><tr>${columns.map((name) => `<th scope="col">${html(name)}</th>`).join('')}</tr></thead>
    <tbody>${rows.map((cells) => `<tr>${cells.map((cell) => `<td>${cell}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
}

function pagination(offset, rows) {
  return `<div class="paging"><button class="button secondary" type="button" data-step="-1" ${offset === 0 ? 'disabled' : ''}>上一页</button>
    <span class="subtle">第 ${offset / pageSize + 1} 页</span>
    <button class="button secondary" type="button" data-step="1" ${rows.length <= pageSize ? 'disabled' : ''}>下一页</button></div>`;
}

function auditTable(rows) {
  return table(['操作时间', '管理员', '操作', '对象', '原因', '结果'], rows.map((item) => [
    `<span class="time">${date(item.created_at)}</span>`, html(item.actor_name),
    html(actionNames[item.action]), html(item.target_name), `<span class="note-cell">${html(item.reason)}</span>`,
    badge(...(auditStates[item.status] || ['未知'])),
  ]), '暂无操作记录');
}

function serviceList(items) {
  return `<dl class="service-list">${items.map(([name, value]) => `<div><dt>${html(name)}</dt><dd>${value}</dd></div>`).join('')}</dl>`;
}

function overview(summary, audit, latency) {
  const cards = [
    ['玩家账户', summary.players, `近 24 小时新增 ${number.format(summary.new_players)} 人`, '♙'],
    ['活跃房间', summary.rooms, '房主租约有效', '▤'],
    ['对局开局', summary.games, `近 24 小时已验证 ${number.format(summary.verified)} 局`, '⚔'],
    ['匹配排队', summary.queued, '近 8 秒内有心跳', '⇄'],
  ];
  const max = Math.max(1, ...summary.trend.map((bin) => Number(bin.count)));
  const ceiling = Math.ceil(max / 4) * 4;
  return `<div class="metrics">${cards.map(([label, value, detail, icon]) => `
    <article class="metric"><p class="metric-label">${label}<span class="metric-icon" aria-hidden="true">${icon}</span></p>
    <strong>${number.format(value)}</strong><small>${detail}</small></article>`).join('')}</div>
    <div class="columns">
      <article class="panel">
        <header class="panel-heading"><div><h2>对局趋势</h2><p class="subtle">近 24 小时 · 每 2 小时一组</p></div>
        <span class="chart-key"><i class="dot" aria-hidden="true"></i>开局数</span></header>
        <div class="chart">
          <div class="chart-body">
            <div class="chart-scale" aria-hidden="true">${[4, 3, 2, 1, 0].map((i) => `<span>${i * ceiling / 4}</span>`).join('')}</div>
            <div class="chart-bars">${summary.trend.map((bin) => {
              const title = `${clock.format(new Date(bin.at))} 起 · ${number.format(bin.count)} 局`;
              return `<div class="bar"><meter min="0" max="${ceiling}" value="${Number(bin.count)}" title="${title}" aria-label="${title}"></meter></div>`;
            }).join('')}</div>
          </div>
          <div class="chart-times" aria-hidden="true">${summary.trend.map((bin, index) =>
            `<span>${index % 3 === 0 || index === 11 ? clock.format(new Date(bin.at)) : ''}</span>`).join('')}</div>
        </div>
      </article>
      <article class="panel">
        <header class="panel-heading"><div><h2>联机状态</h2><p class="subtle">${demo ? '演示数据' : '来自 Supabase 数据库'}</p></div>
          <button class="text-button" type="button" data-open="servers">查看服务器</button></header>
        ${serviceList([
          ['数据库 API', badge(demo ? '模拟可达' : `可达 · ${latency} ms`, 'good', true)],
          ['当前待结算', `${number.format(summary.pending)} 局`],
          ['24 小时争议', `${number.format(summary.disputed)} 局`],
        ])}
      </article>
    </div>
    <article class="panel">
      <header class="panel-heading"><h2>最近操作</h2><button class="text-button" type="button" data-open="audit">查看全部</button></header>
      ${auditTable(audit.slice(0, 4))}
    </article>`;
}

function accounts(rows) {
  const items = rows.slice(0, pageSize);
  renderedRows = items;
  return `<article class="panel">
    <header class="panel-heading search-heading"><h2>玩家列表</h2>
      <form id="search" class="search"><label class="sr-only" for="account-query">搜索玩家</label>
        <input type="search" id="account-query" maxlength="80" value="${html(accountQuery)}" placeholder="账号名、昵称或玩家 ID">
        <button class="button primary">搜索</button></form></header>
    ${table(['玩家', '段位分', '注册时间', '最近登录', '状态', '操作'], items.map((item) => {
      const banned = item.banned_until && new Date(item.banned_until).getTime() > Date.now();
      const status = item.is_admin ? badge('管理员', 'blue') : badge(banned ? '已停用' : '正常', banned ? 'bad' : 'good', true);
      const action = banned ? 'unban' : 'ban';
      return [
        `<strong>${html(item.nickname)}</strong><span class="cell-detail">@${html(item.username)}</span><span class="cell-detail">${html(item.id)}</span>`,
        number.format(item.rating), `<span class="time">${date(item.created_at)}</span>`,
        `<span class="time">${date(item.last_sign_in_at)}</span>`, status,
        item.is_admin ? '—' : `<button type="button" class="text-button ${banned ? '' : 'text-danger'}" data-action="${action}" data-id="${html(item.id)}">${actionNames[action]}</button>`,
      ];
    }), '没有找到符合条件的玩家')}
    ${pagination(accountOffset, rows)}
  </article>`;
}

function servers(summary, rooms, latency, health) {
  renderedRows = rooms;
  const availability = (ok) => badge(demo ? '模拟可达' : (ok ? '可达' : '探测失败'), ok ? 'good' : 'warn', true);
  return `<div class="stack">
    <div class="columns server-columns">
      <article class="panel"><header class="panel-heading"><div><h2>Supabase 服务</h2><p class="subtle">从当前浏览器探测</p></div></header>
        ${serviceList([
          ['数据库 API', badge(demo ? '模拟可达' : `可达 · ${latency} ms`, 'good', true)],
          ['认证 API', availability(health.auth)], ['Realtime 订阅', availability(health.realtime)],
        ])}
      </article>
      <article class="panel"><header class="panel-heading"><div><h2>联机容量</h2><p class="subtle">当前数据库记录</p></div></header>
        ${serviceList([
          ['活跃房间', number.format(summary.rooms)], ['匹配排队', number.format(summary.queued)],
          ['当前待结算', number.format(summary.pending)],
        ])}
      </article>
    </div>
    <article class="panel"><header class="panel-heading"><div><h2>活跃房间</h2><p class="subtle">显示最近续期的最多 50 间房。可关闭尚未分配客位的等候房间。</p></div></header>
    ${table(['房号', '房主', '客位', '类型', '协议', '租约到期', '操作'], rooms.map((room) => [
      `<strong>${html(room.code)}</strong>`, html(room.host), html(room.guest || '等待中'),
      badge(room.matched ? '快速匹配' : room.spar ? '好友切磋' : '普通房间', room.matched ? 'blue' : ''),
      html(room.protocol), `<span class="time">${date(room.host_until)}</span>`,
      room.can_close ? `<button type="button" class="text-button text-danger" data-action="close_room" data-id="${html(room.id)}">关闭房间</button>` : '—',
    ]), '当前没有活跃房间')}
    </article>
  </div>`;
}

async function loadPage({ focusSearch = false } = {}) {
  if (!backend) return;
  const request = ++loadId;
  const start = performance.now();
  const content = $('page-content');
  $('error-banner').hidden = true;
  $('loading').textContent = '加载中…';
  $('refresh').disabled = true;
  content.setAttribute('aria-busy', 'true');
  try {
    let markup;
    let timestamp = new Date();
    if (page === 'accounts') {
      const rows = await backend.accounts(accountQuery, accountOffset);
      if (request !== loadId) return;
      markup = accounts(rows);
    } else if (page === 'audit') {
      const rows = await backend.audit(auditOffset);
      if (request !== loadId) return;
      markup = `<article class="panel"><header class="panel-heading"><h2>管理记录</h2></header>
        ${auditTable(rows.slice(0, pageSize))}${pagination(auditOffset, rows)}</article>`;
    } else {
      const summaryRequest = backend.overview().then((data) => ({ data, latency: Math.round(performance.now() - start) }));
      if (page === 'overview') {
        const [{ data, latency }, entries] = await Promise.all([summaryRequest, backend.audit(0)]);
        if (request !== loadId) return;
        timestamp = new Date(data.at);
        markup = overview(data, entries, latency);
      } else {
        const [{ data, latency }, rooms, health] = await Promise.all([summaryRequest, backend.rooms(), backend.health()]);
        if (request !== loadId) return;
        timestamp = new Date(data.at);
        markup = servers(data, rooms, latency, health);
      }
    }
    content.innerHTML = markup;
    $('refreshed').textContent = '更新于 ' + clock.format(timestamp);
    if (focusSearch) $('account-query')?.focus();
  } catch (error) {
    if (request !== loadId) return;
    if (['admin_required', 'authentication_required'].includes(error.message)) {
      await signOut(displayError(error));
      return;
    }
    renderedRows = [];
    content.replaceChildren();
    $('refreshed').textContent = '';
    $('error-banner').textContent = displayError(error);
    $('error-banner').hidden = false;
  } finally {
    if (request === loadId) {
      content.removeAttribute('aria-busy');
      $('loading').textContent = '';
      $('refresh').disabled = false;
    }
  }
}

function openPage(next, focus = true) {
  page = next;
  for (const nav of document.querySelectorAll('[data-page]')) {
    if (nav.dataset.page === next) nav.setAttribute('aria-current', 'page');
    else nav.removeAttribute('aria-current');
  }
  $('breadcrumb').textContent = pages[next][0];
  $('page-title').textContent = pages[next][0];
  $('page-description').textContent = pages[next][1];
  $('page-content').replaceChildren();
  $('refreshed').textContent = '';
  renderedRows = [];
  if (focus) $('main').focus();
  return loadPage();
}

function showApp(actor) {
  $('login').hidden = true;
  $('app').hidden = false;
  $('operator').textContent = actor;
  $('environment').classList.toggle('demo', demo);
  $('environment-name').textContent = demo ? '演示模式 · 示例数据' : config.label;
  $('logout').textContent = demo ? '重置演示' : '退出登录';
  openPage('overview', false);
}

async function signOut(message = '') {
  ++loadId;
  backend = null;
  renderedRows = [];
  accountQuery = '';
  accountOffset = 0;
  auditOffset = 0;
  $('page-content').replaceChildren();
  $('app').hidden = true;
  $('login').hidden = false;
  $('login-error').textContent = message;
  $('login-user').focus();
  if (client) {
    try { await client.auth.signOut({ scope: 'local' }); } catch { /* 本地界面已退出。 */ }
    client = null;
  }
}

function confirmAction(type, target) {
  currentAction = { type, target };
  const descriptions = {
    close_room: `房号 ${target.code || ''} 将立即关闭。`,
    ban: `@${target.username || ''} 将无法继续登录。已签发的访问令牌可能在到期前继续有效。`,
    unban: `@${target.username || ''} 可重新登录《断链》。`,
  };
  $('action-title').textContent = actionNames[type];
  $('action-description').textContent = descriptions[type];
  $('action-reason').value = '';
  $('action-error').textContent = '';
  $('action-submit').textContent = '确认' + actionNames[type];
  $('action-submit').className = 'button ' + (type === 'unban' ? 'primary' : 'danger');
  $('action-dialog').showModal();
  $('action-reason').focus();
}

$('login-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = event.currentTarget.querySelector('button');
  $('login-error').textContent = '';
  button.disabled = true;
  try {
    const api = await signIn($('login-user').value.trim(), $('login-password').value);
    const summary = await api.overview();
    backend = api;
    showApp(summary.actor);
  } catch (error) {
    await signOut(displayError(error));
  } finally {
    $('login-password').value = '';
    button.disabled = false;
  }
});
document.querySelector('.nav').addEventListener('click', (event) => {
  const nav = event.target.closest('[data-page]');
  if (nav && nav.dataset.page !== page) openPage(nav.dataset.page);
});
$('refresh').addEventListener('click', () => loadPage());
$('logout').addEventListener('click', () => {
  if (demo) {
    backend = window.createDuanlianAdminDemo();
    accountQuery = '';
    accountOffset = 0;
    auditOffset = 0;
    showApp('demo_admin');
  } else {
    const button = $('login-form').querySelector('button');
    button.disabled = true;
    void signOut().finally(() => { button.disabled = false; });
  }
});

$('page-content').addEventListener('submit', (event) => {
  if (event.target.id !== 'search') return;
  event.preventDefault();
  accountQuery = $('account-query').value.trim();
  accountOffset = 0;
  loadPage({ focusSearch: true });
});
$('page-content').addEventListener('click', (event) => {
  const button = event.target.closest('button');
  if (!button || $('page-content').getAttribute('aria-busy') === 'true') return;
  if (button.dataset.open) openPage(button.dataset.open);
  if (button.dataset.step) {
    const step = Number(button.dataset.step) * pageSize;
    if (page === 'accounts') accountOffset += step;
    if (page === 'audit') auditOffset += step;
    loadPage();
  }
  if (button.dataset.action) {
    const target = renderedRows.find((row) => row.id === button.dataset.id);
    if (target) confirmAction(button.dataset.action, target);
  }
});
$('action-cancel').addEventListener('click', () => $('action-dialog').close());
$('action-dialog').addEventListener('cancel', (event) => {
  if ($('action-submit').disabled) event.preventDefault();
});
$('action-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const reason = $('action-reason').value.trim();
  const submit = $('action-submit');
  if (!reason) {
    $('action-error').textContent = '请填写操作原因。';
    return;
  }
  $('action-error').textContent = '';
  submit.disabled = true;
  $('action-cancel').disabled = true;
  try {
    await backend.action({ ...currentAction, reason });
    $('action-dialog').close();
    const toast = $('toast');
    toast.textContent = actionNames[currentAction.type] + '成功';
    toast.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toast.hidden = true; }, 4300);
    await loadPage();
  } catch (error) {
    $('action-error').textContent = displayError(error);
  } finally {
    submit.disabled = false;
    $('action-cancel').disabled = false;
  }
});

if (demo) {
  backend = window.createDuanlianAdminDemo();
  showApp('demo_admin');
} else if (['localhost', '127.0.0.1', '[::1]'].includes(location.hostname)) {
  $('demo-link').hidden = false;
}
