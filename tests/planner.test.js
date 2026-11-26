// End-to-end checks for Daily_Missions.html.
// Run: node tests/planner.test.js   (needs the `playwright` package and Chromium)
'use strict';
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { chromium } = require('playwright');

const FILE = path.resolve(__dirname, '..', 'Daily_Missions.html');
const URL = 'file://' + FILE;
const OLD_BACKUP = path.join(__dirname, 'fixtures', 'old-tracker-backup.json');
const NOW = new Date('2026-11-20T09:05:00'); // a Friday
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'mm-test-'));

let browser, passed = 0, failed = 0;
const errors = [];

async function open(opts = {}) {
  const ctx = await browser.newContext({
    viewport: opts.viewport || { width: 390, height: 844 },
    hasTouch: opts.touch !== false, isMobile: opts.touch !== false,
    colorScheme: opts.scheme || 'light', acceptDownloads: true,
  });
  await ctx.clock.install({ time: opts.now || NOW });
  await ctx.clock.resume();
  if (opts.test !== false) await ctx.addInitScript('window.__MM_TEST__ = true');
  if (opts.init) await ctx.addInitScript('try{if(window.top===window){' + opts.init + '\n}}catch(e){}');
  const p = await ctx.newPage();
  p.on('pageerror', e => errors.push('pageerror: ' + e.message));
  await p.goto(opts.url || URL);
  await p.waitForSelector('#day-list .task, #day-list .empty, #lock:not([hidden])');
  return { ctx, p };
}
const S = p => p.evaluate(() => JSON.parse(JSON.stringify(window.MM.state)));
const stored = p => p.evaluate(() => localStorage.getItem('morning-missions-v3'));
async function restoreFile(p, name, obj) {
  const file = path.join(TMP, name); fs.writeFileSync(file, typeof obj === 'string' ? obj : JSON.stringify(obj));
  await tab(p, 'tools'); await p.setInputFiles('#backup-file', file); return file;
}
async function setPasscode(p, code) {
  await tab(p, 'tools'); await p.click('#lock-enable');
  await p.fill('#pass-new', code); await p.fill('#pass-new2', code);
  await p.click('#pass-ok');
  await p.waitForFunction(() => !document.querySelector('dialog[open]'), null, { timeout: 15000 });
}
async function unlock(p, code) {
  await p.fill('#lock-pass', code); await p.click('#lock-go');
}
async function hideApp(p, hidden) {
  await p.evaluate(h => { Object.defineProperty(document, 'hidden', { get: () => h, configurable: true }); Object.defineProperty(document, 'visibilityState', { get: () => h ? 'hidden' : 'visible', configurable: true }); document.dispatchEvent(new Event('visibilitychange')); }, hidden);
}
const top = p => p.evaluate(() => window.scrollTo(0, 0));
const titles = p => p.$$eval('#day-list .task .task-title', els => els.map(e => e.textContent));
const times = p => p.$$eval('#day-list .task .task-time', els => els.map(e => e.textContent));
async function goto(p, date) {
  await p.evaluate(d => { const b = document.createElement('button'); b.dataset.goto = d; document.body.appendChild(b); b.click(); b.remove(); }, date);
}
async function tab(p, v) { await p.click(`.tabs [data-view=${v}]`); }
async function openEdit(p, title, which = '.task-title') {
  const row = p.locator('#day-list .task', { has: p.locator('.task-title', { hasText: new RegExp('^' + title + '$') }) });
  await row.locator(which).click();
  await p.waitForSelector('#task-sheet[open]');
}
const cdp = new WeakMap();
async function cdpTouch(p, type, x, y) {
  if (!cdp.has(p)) cdp.set(p, await p.context().newCDPSession(p));
  await cdp.get(p).send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y }] });
}
// Choices in confirmation dialogs resolve on the dialog's close event, which fires a moment later.
async function choose(p, sel) {
  await p.click(sel);
  await p.waitForFunction(() => !document.querySelector('dialog[open]'));
  await p.waitForTimeout(30);
}

async function test(name, fn) {
  if (process.env.ONLY && !name.includes(process.env.ONLY)) return;
  try { await fn(); passed++; console.log('  ok   ' + name); }
  catch (e) { failed++; console.log('  FAIL ' + name + '\n       ' + (e && e.stack || e).toString().split('\n').slice(0, 4).join('\n       ')); }
}

(async () => {
  browser = await chromium.launch();
  console.log('Daily Missions planner tests');

  await test('opens on today in the one-day view with the starter routine', async () => {
    const { ctx, p } = await open();
    assert.equal(await p.textContent('#day-hero h1'), 'Friday');
    assert.equal(await p.title(), 'Daily Missions');
    assert.equal(await p.textContent('.brand span'), 'DAILY MISSIONS');
    assert.equal((await titles(p)).length, 13);
    assert.equal(await p.isVisible('#view-week'), false);
    assert.match(await p.textContent('#day-hero .date'), /Today/);
    assert.equal(await p.locator('#day-list .task.now .task-title').textContent(), 'Study');
    await goto(p, '2026-11-21');
    assert.match(await p.textContent('#day-list'), /Rest day/);
    await ctx.close();
  });

  await test('check marks save and survive a reload', async () => {
    const { ctx, p } = await open();
    await p.locator('#day-list .task').nth(0).locator('input').check();
    assert.match(await p.textContent('#day-hero .ring strong'), /8%/);
    await p.reload(); await p.waitForSelector('#day-list .task');
    assert.equal(await p.locator('#day-list .task').nth(0).locator('input').isChecked(), true);
    assert.deepEqual((await S(p)).days['2026-11-20'].c, ['0']);
    await ctx.close();
  });

  await test('add a one-day task and a repeating task', async () => {
    const { ctx, p } = await open();
    await p.click('#add-row');
    await p.fill('#ts-name', 'Dentist'); await p.fill('#ts-start', '11:00'); await p.fill('#ts-end', '12:00');
    await p.click('#task-sheet [data-mask="0"]');
    assert.match(await p.textContent('#ts-days-hint'), /Only on/);
    await p.click('#ts-save');
    assert.ok((await titles(p)).includes('Dentist'));
    assert.equal((await S(p)).days['2026-11-20'].a.length, 1);
    await goto(p, '2026-11-27');
    assert.ok(!(await titles(p)).includes('Dentist'));
    await goto(p, '2026-11-20');
    await p.click('#add-top');
    await p.fill('#ts-name', 'Stretch'); await p.fill('#ts-start', '07:00'); await p.fill('#ts-end', '07:10');
    await p.click('#task-sheet [data-mask="96"]');
    await p.click('#ts-save');
    assert.match(await p.textContent('#toast-msg'), /not on this Friday/);
    await goto(p, '2026-11-21');
    assert.deepEqual(await titles(p), ['Stretch']);
    await goto(p, '2026-11-14');
    assert.ok(!(await titles(p)).includes('Stretch'), 'new repeating task must not appear on earlier days');
    await ctx.close();
  });

  await test('tap a time to change it for one day only', async () => {
    const { ctx, p } = await open();
    await openEdit(p, 'Yoga', '.task-time');
    await p.fill('#ts-start', '06:20');
    await p.dispatchEvent('#ts-start', 'input');
    assert.equal(await p.inputValue('#ts-end'), '06:40', 'end time shifts with the start time');
    await p.click('#ts-save');
    await p.waitForSelector('#scope-dialog[open]');
    await choose(p, '#scope-day');
    const t = await times(p);
    assert.equal(t[1], '6:20–6:40 AM');
    assert.match(await p.locator('#day-list .task').nth(1).textContent(), /Changed this day/);
    await goto(p, '2026-11-23');
    assert.equal((await times(p))[1], '6:15–6:35 AM');
    await ctx.close();
  });

  await test('change a task from this day on keeps earlier days as they were', async () => {
    const { ctx, p } = await open();
    await openEdit(p, 'Coffee');
    await p.fill('#ts-name', 'Espresso');
    await p.click('#ts-save'); await choose(p, '#scope-after');
    assert.ok((await titles(p)).includes('Espresso'));
    await goto(p, '2026-11-18'); assert.ok((await titles(p)).includes('Coffee'));
    await goto(p, '2026-11-24'); assert.ok((await titles(p)).includes('Espresso'));
    await ctx.close();
  });

  await test('changing repeat days applies from that day on', async () => {
    const { ctx, p } = await open();
    await openEdit(p, 'Study');
    await p.click('#ts-days [data-day="5"]');
    assert.match(await p.textContent('#ts-days-hint'), /applies from/);
    await p.click('#ts-save');
    assert.equal(await p.isVisible('#scope-dialog'), false, 'no scope question for day changes');
    await goto(p, '2026-11-21'); assert.ok((await titles(p)).includes('Study'));
    await goto(p, '2026-11-14'); assert.ok(!(await titles(p)).includes('Study'));
    await ctx.close();
  });

  await test('remove one day only, remove from a day on, and undo', async () => {
    const { ctx, p } = await open();
    await openEdit(p, 'Walk down'); await p.click('#ts-delete'); await choose(p, '#scope-day');
    assert.ok(!(await titles(p)).includes('Walk down'));
    await goto(p, '2026-11-23'); assert.ok((await titles(p)).includes('Walk down'));
    await goto(p, '2026-11-20');
    await openEdit(p, 'Shower'); await p.click('#ts-delete'); await choose(p, '#scope-after');
    assert.ok(!(await titles(p)).includes('Shower'));
    await goto(p, '2026-11-19'); assert.ok((await titles(p)).includes('Shower'));
    await goto(p, '2026-11-23'); assert.ok(!(await titles(p)).includes('Shower'));
    await p.click('#toast-act');
    assert.ok((await titles(p)).includes('Shower'), 'undo brings it back');
    await ctx.close();
  });

  await test('drag the grip to reorder without changing times', async () => {
    const { ctx, p } = await open({ touch: false, viewport: { width: 1280, height: 900 } });
    await top(p);
    const before = await titles(p), beforeTimes = await times(p);
    const g = await p.locator('#day-list .task').nth(0).locator('.grip').boundingBox();
    const r2 = await p.locator('#day-list .task').nth(2).boundingBox();
    await p.mouse.move(g.x + g.width / 2, g.y + g.height / 2); await p.mouse.down();
    await p.mouse.move(g.x + g.width / 2, r2.y + r2.height * 0.75, { steps: 12 }); await p.mouse.up();
    const after = await titles(p);
    assert.deepEqual(after.slice(0, 3), [before[1], before[2], before[0]], 'got ' + JSON.stringify(after.slice(0, 4)));
    assert.equal((await times(p))[2], beforeTimes[0], 'time moves with the task, unchanged');
    assert.equal(await p.isVisible('#task-sheet'), false);
    await goto(p, '2026-11-23');
    assert.deepEqual((await titles(p)).slice(0, 3), [before[1], before[2], before[0]], 'shared tasks keep the new order on other days');
    await ctx.close();
  });

  await test('press and hold a task on a touch screen to drag it', async () => {
    const { ctx, p } = await open();
    await top(p);
    const before = await titles(p);
    const r0 = await p.locator('#day-list .task').nth(0).locator('.task-title').boundingBox();
    const r3 = await p.locator('#day-list .task').nth(3).boundingBox();
    const x = r0.x + 40, y = r0.y + r0.height / 2;
    await cdpTouch(p, 'touchStart', x, y);
    await p.waitForTimeout(650);
    for (let i = 1; i <= 10; i++) await cdpTouch(p, 'touchMove', x, y + (r3.y + r3.height * 0.95 - y) * i / 10);
    await cdpTouch(p, 'touchEnd', x, 0);
    await p.waitForTimeout(100);
    const after = await titles(p);
    assert.deepEqual(after.slice(0, 4), [before[1], before[2], before[3], before[0]]);
    assert.equal(await p.isVisible('#task-sheet'), false, 'long press does not open the editor');
    await ctx.close();
  });

  await test('keyboard reorder, sort by time, and swipe to change day', async () => {
    const { ctx, p } = await open();
    const before = await titles(p);
    await p.locator('#day-list .task').nth(1).locator('.grip').focus();
    await p.keyboard.press('ArrowUp');
    assert.deepEqual((await titles(p)).slice(0, 2), [before[1], before[0]]);
    await p.click('#sort-time');
    assert.deepEqual(await titles(p), before);
    await top(p);
    const h = await p.locator('#day-hero').boundingBox();
    const y = h.y + h.height / 2;
    await cdpTouch(p, 'touchStart', 300, y);
    for (let i = 1; i <= 6; i++) await cdpTouch(p, 'touchMove', 300 - i * 30, y + 2);
    await cdpTouch(p, 'touchEnd', 0, 0);
    await p.waitForTimeout(50);
    assert.equal(await p.textContent('#day-hero h1'), 'Saturday');
    await ctx.close();
  });

  await test('week view: seven columns, check from the week, open a day', async () => {
    const { ctx, p } = await open();
    await tab(p, 'week');
    assert.equal(await p.locator('.wcol').count(), 7);
    await p.locator('.wcol').nth(3).locator('input').first().check();
    assert.match(await p.textContent('[data-whead="2026-11-19"] .wstat'), /^1\/13$/);
    assert.equal((await S(p)).days['2026-11-19'].c.length, 1);
    await p.click('[data-whead="2026-11-17"]');
    assert.equal(await p.textContent('#day-hero h1'), 'Tuesday');
    await ctx.close();
  });

  await test('month view: navigate back and open a day', async () => {
    const { ctx, p } = await open();
    await p.locator('#day-list .task input').first().check();
    await tab(p, 'month');
    assert.match(await p.textContent('#view-month h2'), /November 2026/);
    assert.match(await p.textContent('.mcell.today'), /8%/);
    await p.click('[data-mstep="-1"]');
    assert.match(await p.textContent('#view-month h2'), /October 2026/);
    await p.click('[data-mstep="1"]');
    await p.click('.mcell[data-goto="2026-11-18"]');
    assert.equal(await p.textContent('#day-hero h1'), 'Wednesday');
    await ctx.close();
  });

  await test('theme cycles auto, light, dark and clock switches to 24-hour', async () => {
    const { ctx, p } = await open({ scheme: 'dark' });
    const bg = () => p.evaluate(() => getComputedStyle(document.body).backgroundColor);
    assert.equal(await bg(), 'rgb(17, 26, 37)', 'auto follows the system dark setting');
    await p.click('#theme-btn'); assert.equal(await p.getAttribute('html', 'data-theme'), 'light');
    assert.equal(await bg(), 'rgb(211, 217, 225)');
    await p.click('#theme-btn'); assert.equal(await p.getAttribute('html', 'data-theme'), 'dark');
    await p.click('#theme-btn'); assert.equal(await p.getAttribute('html', 'data-theme'), null);
    await tab(p, 'tools'); await p.check('input[name=clock][value="24"]');
    await tab(p, 'day'); assert.equal((await times(p))[0], '06:00–06:15');
    await ctx.close();
  });

  await test('storage: old days past the history limit archive to scores', async () => {
    const init = () => {
      if (sessionStorage.getItem('seeded')) return; sessionStorage.setItem('seeded', '1');
      const days = {}; const d = new Date(2025, 5, 2, 12);
      const iso = x => x.getFullYear() + '-' + String(x.getMonth() + 1).padStart(2, '0') + '-' + String(x.getDate()).padStart(2, '0');
      for (let i = 0; i < 400; i++) { if (d.getDay() > 0 && d.getDay() < 6) days[iso(d)] = { c: ['6', 'b', 'e'] }; d.setDate(d.getDate() + 1); }
      localStorage.setItem('morning-missions-v3', JSON.stringify({ v: 3, name: '', seq: 18, since: '2025-06-02', pruned: null,
        set: { theme: 'auto', clock: 12, keep: 12, cap: 500, old: 'score', ask: true, scope: 'ask' },
        tasks: JSON.parse(localStorage.getItem('tasks-template')), days, notes: { '2025-06-02': 'old note' }, scores: {} }));
    };
    const tpl = await (async () => { const { ctx, p } = await open(); const t = (await S(p)).tasks; await ctx.close(); return t; })();
    const { ctx, p } = await open({ init: `localStorage.setItem('tasks-template', ${JSON.stringify(JSON.stringify(tpl))});(${init})()` });
    assert.match(await p.textContent('#banner'), /older than your history setting/);
    await p.click('[data-prune="go"]');
    const st = await S(p);
    assert.equal(st.pruned, '2025-11-20');
    assert.ok(!st.days['2025-06-02'] && !st.notes['2025-06-02'], 'old details and notes removed');
    assert.ok(st.days['2025-11-20'], 'days inside the window stay');
    assert.match(st.scores['2025-06'], /^,3\/13,3\/13/, 'June 1 is before tracking began');
    await goto(p, '2025-06-03');
    assert.match(await p.textContent('#day-list'), /archived/);
    assert.match(await p.textContent('#day-list'), /3 of 13/);
    await tab(p, 'month');
    assert.match(await p.textContent('.mcell[data-goto="2025-06-03"]'), /23%/);
    await ctx.close();
  });

  await test('storage: a size limit trims the oldest days automatically when asking is off', async () => {
    const big = await (async () => {
      const { ctx, p } = await open(); const st = await S(p); await ctx.close();
      st.since = '2022-01-03'; st.set.keep = 0; st.set.cap = 100; st.set.ask = false;
      const d = new Date(2022, 0, 3, 12);
      const iso = x => x.getFullYear() + '-' + String(x.getMonth() + 1).padStart(2, '0') + '-' + String(x.getDate()).padStart(2, '0');
      for (let i = 0; i < 1780; i++) { st.days[iso(d)] = { c: ['0', '2', '4', '6', '7', '9', 'a', 'b', 'c', 'e', 'f', 'g', 'h'] }; d.setDate(d.getDate() + 1); }
      return st;
    })();
    assert.ok(JSON.stringify(big).length > 100 * 1024);
    const { ctx, p } = await open({ init: `if(!sessionStorage.getItem('s')){sessionStorage.setItem('s','1');localStorage.setItem('morning-missions-v3', ${JSON.stringify(JSON.stringify(big))});}` });
    await p.waitForTimeout(100);
    const st = await S(p);
    assert.ok(JSON.stringify(st).length <= 100 * 1024, 'under the limit after trimming');
    assert.ok(st.pruned > '2022-01-03' && st.pruned < '2026-11-20');
    assert.match(await p.textContent('#toast-msg'), /archived/);
    await ctx.close();
  });

  await test('backup export and restore round trip', async () => {
    const { ctx, p } = await open();
    await p.locator('#day-list .task input').nth(2).check();
    await tab(p, 'tools'); await p.fill('#set-name', 'Tester');
    const [dl] = await Promise.all([p.waitForEvent('download'), p.click('#export-backup')]);
    const file = path.join(TMP, 'backup.json'); await dl.saveAs(file);
    const backup = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.equal(backup.v, 3); assert.equal(backup.name, 'Tester');
    await p.click('#erase-all'); await choose(p, '#ask-ok');
    assert.equal((await S(p)).name, '');
    await tab(p, 'tools');
    await p.setInputFiles('#backup-file', file);
    await p.waitForSelector('#ask-dialog[open]'); await choose(p, '#ask-ok');
    const st = await S(p);
    assert.equal(st.name, 'Tester'); assert.deepEqual(st.days['2026-11-20'].c, ['4']);
    await ctx.close();
  });

  await test('restores a backup from the older weekly tracker', async () => {
    const { ctx, p } = await open();
    await tab(p, 'tools');
    await p.setInputFiles('#backup-file', OLD_BACKUP);
    await p.waitForSelector('#ask-dialog[open]'); await choose(p, '#ask-ok');
    const st = await S(p);
    assert.equal(st.name, 'Test Player');
    assert.equal(Object.keys(st.tasks).length, 18, 'shared tasks merge into one repeating task');
    assert.equal(st.notes['2026-11-16'], 'Old notes line');
    await goto(p, '2026-11-16');
    const done = await p.$$eval('#day-list .task.done .task-title', els => els.map(e => e.textContent));
    assert.deepEqual(done, ['Water, pray, laundry', 'Yoga']);
    await goto(p, '2026-11-17');
    assert.deepEqual(await p.$$eval('#day-list .task.done .task-title', els => els.map(e => e.textContent)), ['Water, pray, workout']);
    await goto(p, '2026-11-19');
    assert.deepEqual(await p.$$eval('#day-list .task.done .task-title', els => els.map(e => e.textContent)), ['Group']);
    await goto(p, '2026-11-11');
    assert.deepEqual(await p.$$eval('#day-list .task.done .task-title', els => els.map(e => e.textContent)), ['Plan for the day']);
    await ctx.close();
  });

  await test('moves data saved by the older tracker on the same device', async () => {
    const old = fs.readFileSync(OLD_BACKUP, 'utf8');
    const { ctx, p } = await open({ init: `if(!sessionStorage.getItem('s')){sessionStorage.setItem('s','1');localStorage.clear();localStorage.setItem('morning-missions-v2', ${JSON.stringify(old)});}` });
    assert.match(await p.textContent('#banner'), /moved into this planner/);
    assert.equal((await S(p)).name, 'Test Player');
    await ctx.close();
  });

  await test('HTML copy carries the data and keeps its own storage', async () => {
    const { ctx, p } = await open();
    await tab(p, 'tools'); await p.fill('#set-name', 'Copy Owner');
    const [dl] = await Promise.all([p.waitForEvent('download'), p.click('#save-html')]);
    const file = path.join(TMP, 'copy.html'); await dl.saveAs(file);
    await ctx.close();
    const c2 = await open({ url: 'file://' + file });
    const st = await S(c2.p);
    assert.equal(st.name, 'Copy Owner'); assert.ok(st.pid);
    const html = fs.readFileSync(file, 'utf8');
    assert.ok(html.includes('id="theme-boot"'), 'copy keeps the early theme loader');
    const htmlTag = html.slice(html.indexOf('<html'), html.indexOf('>', html.indexOf('<html')) + 1);
    assert.ok(!/data-theme/.test(htmlTag), 'copy does not freeze the theme: ' + htmlTag);
    assert.ok(await c2.p.evaluate(() => Object.keys(localStorage).some(k => /^morning-missions-v3-/.test(k))));
    await c2.ctx.close();
  });

  await test('weekly record shows check marks and the Android file bridge is used', async () => {
    const { ctx, p } = await open({ init: 'window.NativeFiles={saveText:(n,m,c)=>{window.__saved=[n,m,c.length];},printHtml:h=>{window.__printed=h.length;}}' });
    await p.locator('#day-list .task input').first().check();
    await tab(p, 'week'); await p.click('[data-record="2026-11-16"]');
    await p.waitForSelector('#record-dialog[open]');
    const f = p.frameLocator('#rec-frame');
    assert.match(await f.locator('tbody').textContent(), /✓/);
    assert.match(await f.locator('.sum').textContent(), /1 of \d+ objectives/);
    await p.click('#rec-download');
    const saved = await p.evaluate(() => window.__saved);
    assert.equal(saved[0], 'Daily_Missions_Week_2026-11-16.html');
    await p.click('#rec-print'); assert.ok(await p.evaluate(() => window.__printed > 1000));
    await ctx.close();
  });

  await test('task name suggests tasks you already have', async () => {
    const { ctx, p } = await open();
    const names = () => p.$$eval('#ts-suggest:not([hidden]) .s-name', els => els.map(e => e.textContent));
    await p.click('#add-row');
    await p.locator('#ts-name').pressSequentially('med');
    assert.deepEqual(await names(), ['Meditation', 'Meds & breakfast', 'Yoga & meditation']);
    assert.match(await p.textContent('#ts-suggest li:first-child .s-meta'), /^6:35–6:50 AM · Mon Wed Fri$/);
    await p.keyboard.press('ArrowDown'); await p.keyboard.press('ArrowDown'); await p.keyboard.press('Enter');
    assert.equal(await p.inputValue('#ts-name'), 'Meds & breakfast');
    assert.equal(await p.inputValue('#ts-start'), '07:20'); assert.equal(await p.inputValue('#ts-end'), '07:45');
    assert.equal(await p.isVisible('#task-sheet'), true, 'Enter on a suggestion picks it instead of saving');
    assert.match(await p.textContent('#ts-name-hint'), /already on this day at 7:20–7:45 AM/);
    await p.fill('#ts-name', ''); await p.locator('#ts-name').pressSequentially('wal');
    await p.click('#ts-suggest li:has-text("Walk down")');
    assert.equal(await p.inputValue('#ts-name'), 'Walk down'); assert.equal(await p.inputValue('#ts-start'), '09:20');
    assert.equal(await p.isVisible('#ts-suggest'), false);
    await p.fill('#ts-name', ''); await p.locator('#ts-name').pressSequentially('yo');
    assert.equal(await p.isVisible('#ts-suggest'), true);
    await p.keyboard.press('Escape');
    assert.equal(await p.isVisible('#ts-suggest'), false, 'Escape closes the list');
    assert.equal(await p.isVisible('#task-sheet'), true, 'Escape leaves the editor open');
    await p.fill('#ts-name', ''); await p.locator('#ts-name').pressSequentially('Piano practice');
    assert.equal(await p.isVisible('#ts-suggest'), false);
    await p.keyboard.press('Enter');
    assert.ok((await titles(p)).includes('Piano practice'), 'new names still save');
    await ctx.close();
  });

  await test('one-day tasks are suggested, and editing keeps the time', async () => {
    const { ctx, p } = await open();
    await p.click('#add-row'); await p.fill('#ts-name', 'Dentist'); await p.fill('#ts-start', '11:00'); await p.fill('#ts-end', '12:00');
    await p.click('#task-sheet [data-mask="0"]'); await p.click('#ts-save');
    await goto(p, '2026-11-23');
    await p.click('#add-row'); await p.locator('#ts-name').pressSequentially('dent');
    assert.match(await p.textContent('#ts-suggest li:first-child'), /^Dentist11:00 AM – 12:00 PM · One-day task$/);
    await p.keyboard.press('Escape'); await p.click('#task-sheet .sheet-foot [data-close]');
    await openEdit(p, 'Yoga');
    await p.fill('#ts-name', ''); await p.locator('#ts-name').pressSequentially('yog');
    assert.deepEqual(await p.$$eval('#ts-suggest .s-name', els => els.map(e => e.textContent)), ['Yoga & meditation'], 'the task being edited is not suggested to itself');
    await p.click('#ts-suggest li:has-text("Yoga & meditation")');
    assert.equal(await p.inputValue('#ts-name'), 'Yoga & meditation');
    assert.equal(await p.inputValue('#ts-start'), '06:15', 'editing keeps the time');
    await ctx.close();
  });

  await test('finish day: each 10% bracket maps to its own tier and emblem', async () => {
    const { ctx, p } = await open();
    const r = await p.evaluate(() => {
      const M = window.MM;
      const ks = [[0, 13], [1, 13], [2, 13], [3, 13], [5, 13], [7, 13], [8, 13], [10, 13], [11, 13], [12, 13], [13, 13], [249, 250], [1, 10], [10, 100], [99, 100]].map(([d, t]) => M.tierOf(d, t));
      return { ks, svgs: M.TIERS.map((_, k) => M.emblemSVG(k)), names: M.TIERS.map(t => t.n) };
    });
    assert.deepEqual(r.ks.map(x => x.k), [0, 0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 9, 1, 1, 9]);
    assert.deepEqual(r.ks.map(x => x.p), [0, 8, 15, 23, 38, 54, 62, 77, 85, 92, 100, 99, 10, 10, 99]);
    assert.equal(r.svgs.length, 11);
    assert.equal(new Set(r.svgs).size, 11, 'every tier has a different emblem');
    assert.equal(new Set(r.names).size, 11);
    await ctx.close();
  });

  await test('finish day plays the tier, can be skipped, replayed, and closed', async () => {
    const { ctx, p } = await open();
    for (let i = 0; i < 7; i++) await p.locator('#day-list .task input').nth(i).check();
    assert.equal(await p.textContent('#finish-day .fb-main'), 'Finish day');
    await p.click('#finish-day');
    await p.waitForSelector('#win[open]');
    assert.equal(await p.textContent('#win-name'), 'Vanguard');
    assert.equal(await p.textContent('#win-tag'), 'Mission tier 6');
    assert.match(await p.textContent('#win-sub'), /7 of 13 objectives/);
    assert.equal(await p.isVisible('#win-skip'), true);
    await p.waitForTimeout(900);
    assert.ok(await p.evaluate(() => window.MM.fxCount() > 0), 'sparks are flying');
    await p.click('#win-stage', { position: { x: 20, y: 20 } });
    assert.equal(await p.textContent('#win-pct'), '54%');
    assert.equal(await p.evaluate(() => getComputedStyle(document.getElementById('win-actions')).opacity), '1');
    assert.equal(await p.isVisible('#win-skip'), false);
    await p.click('#win-replay');
    assert.equal(await p.isVisible('#win-skip'), true, 'replay starts again');
    await p.waitForTimeout(3800);
    assert.equal(await p.textContent('#win-pct'), '54%', 'plays through to the end on its own');
    await p.click('#win-close');
    assert.equal(await p.isVisible('#win'), false);
    assert.equal((await S(p)).days['2026-11-20'].f, 1);
    assert.equal(await p.textContent('#finish-day .fb-main'), 'Replay result');
    assert.match(await p.textContent('#finish-day .fb-sub'), /tier 6: Vanguard/);
    await p.reload(); await p.waitForSelector('#day-list .task');
    assert.equal(await p.textContent('#finish-day .fb-main'), 'Replay result', 'finished state survives reload');
    await ctx.close();
  });

  await test('a perfect day plays the Legend tier with confetti', async () => {
    const { ctx, p } = await open();
    const n = await p.locator('#day-list .task input').count();
    for (let i = 0; i < n; i++) await p.locator('#day-list .task input').nth(i).check();
    await p.locator('#day-hero [data-finish]').click();
    await p.waitForSelector('#win[open]');
    assert.equal(await p.textContent('#win-name'), 'Legend');
    assert.equal(await p.textContent('#win-tag'), 'Mission tier 11');
    await p.waitForTimeout(1200);
    const fx = await p.evaluate(() => window.MM.fxCount());
    assert.ok(fx > 60, 'confetti and streaks: ' + fx);
    await p.waitForTimeout(5500);
    assert.equal(await p.textContent('#win-pct'), '100%');
    assert.equal(await p.isVisible('#win-perfect'), true);
    await ctx.close();
  });

  await test('a 0% day still gets an encouraging result', async () => {
    const { ctx, p } = await open();
    await p.click('#finish-day'); await p.waitForSelector('#win[open]');
    assert.equal(await p.textContent('#win-name'), 'Recruit');
    assert.match(await p.textContent('#win-msg'), /Every mission starts somewhere/);
    await p.keyboard.press('Escape');
    assert.equal(await p.isVisible('#win'), false, 'Escape or the back button closes it');
    await ctx.close();
  });

  await test('sound plays with the result and the mute switch silences it', async () => {
    const stub = `(()=>{const node=()=>{const n={connect:()=>n,start(){window.__started=(window.__started||0)+1},stop(){},type:'',buffer:null,Q:{value:1},gain:{value:1,setValueAtTime(){},exponentialRampToValueAtTime(){}},frequency:{value:1,setValueAtTime(){},exponentialRampToValueAtTime(){}}};return n;};
      window.AudioContext=class{constructor(){window.__ctx=(window.__ctx||0)+1;this.currentTime=0;this.state='running';this.destination=node();this.sampleRate=8000;}createGain(){return node()}createOscillator(){return node()}createDynamicsCompressor(){return node()}createBiquadFilter(){return node()}createBufferSource(){return node()}createBuffer(){return {getChannelData:()=>new Float32Array(8)}}resume(){}};})()`;
    const { ctx, p } = await open({ init: stub });
    await p.click('#finish-day'); await p.waitForSelector('#win[open]');
    const first = await p.evaluate(() => window.__started || 0);
    assert.ok(first >= 3, 'sounds started: ' + first);
    await p.click('#win-mute');
    assert.equal((await S(p)).set.sound, false);
    assert.match(await p.getAttribute('#win-mute', 'aria-label'), /Sound off/);
    await p.click('#win-stage', { position: { x: 20, y: 20 } });
    await p.click('#win-replay');
    assert.equal(await p.evaluate(() => window.__started), first, 'no new sounds while muted');
    await p.click('#win-close');
    await tab(p, 'tools');
    assert.equal(await p.isChecked('input[name=sound][value=off]'), true);
    await p.check('input[name=sound][value=on]');
    assert.equal((await S(p)).set.sound, true);
    await ctx.close();
  });

  await test('Tools can preview any medal without saving', async () => {
    const { ctx, p } = await open();
    await tab(p, 'tools');
    assert.equal(await p.locator('#tier-preview option').count(), 12);
    await p.selectOption('#tier-preview', '11'); await p.click('#tier-play');
    await p.waitForSelector('#win[open]');
    assert.equal(await p.textContent('#win-tag'), 'Goal achieved');
    assert.match(await p.textContent('#win-sub'), /Preview only/);
    await p.click('#win-stage', { position: { x: 20, y: 20 } }); await p.click('#win-close');
    await p.waitForFunction(() => !document.querySelector('#win[open]'));
    assert.deepEqual((await S(p)).goals, {}, 'the goal preview saves nothing');
    await p.selectOption('#tier-preview', '8'); await p.click('#tier-play');
    await p.waitForSelector('#win[open]');
    assert.equal(await p.textContent('#win-name'), 'Ace');
    assert.match(await p.textContent('#win-sub'), /Preview only/);
    await p.click('#win-stage', { position: { x: 20, y: 20 } });
    assert.equal(await p.textContent('#win-pct'), '85%');
    await p.click('#win-close');
    assert.equal((await S(p)).days['2026-11-20'], undefined, 'nothing was recorded');
    await ctx.close();
  });

  await test('each medal has its own sound, and none of them distort', async () => {
    const { ctx, p } = await open();
    // 11 tiers plus the goal-achieved fanfare (index 11).
    const r = await p.evaluate(async () => { const out = []; for (let k = 0; k < 12; k++) out.push(await window.MM.renderTier(k)); return out; });
    r.forEach((x, k) => {
      const name = k === 11 ? 'goal sound' : 'medal ' + (k + 1);
      assert.ok(x.peak > 0.05, name + ' makes sound (peak ' + x.peak.toFixed(3) + ')');
      assert.ok(x.peak <= 1, name + ' does not clip (peak ' + x.peak.toFixed(3) + ')');
      assert.ok(x.seconds > 0.6 && x.seconds < 4.5, name + ' length ' + x.seconds.toFixed(2) + 's');
    });
    const sig = x => x.env.map((e, i) => e * 1000 + x.zc[i] / 10);
    let worst = 0;
    for (let a = 0; a < 12; a++) for (let b = a + 1; b < 12; b++) {
      const A = sig(r[a]), B = sig(r[b]); let dot = 0, na = 0, nb = 0;
      for (let i = 0; i < A.length; i++) { dot += A[i] * B[i]; na += A[i] * A[i]; nb += B[i] * B[i]; }
      const sim = dot / Math.sqrt(na * nb); worst = Math.max(worst, sim);
      assert.ok(sim < 0.985, 'medals ' + (a + 1) + ' and ' + (b + 1) + ' sound too alike');
    }
    assert.ok(r[10].seconds > r[0].seconds, 'Legend lasts longer than Recruit');
    console.log('       closest pair similarity ' + worst.toFixed(3) + ' | lengths (s): ' + r.map(x => x.seconds.toFixed(1)).join(' ') + ' | peaks: ' + r.map(x => x.peak.toFixed(2)).join(' '));
    await ctx.close();
  });

  await test('reduced motion shows the result card without effects', async () => {
    const { ctx, p } = await open();
    await p.emulateMedia({ reducedMotion: 'reduce' });
    for (let i = 0; i < 12; i++) await p.locator('#day-list .task input').nth(i).check();
    await p.click('#finish-day'); await p.waitForSelector('#win[open]');
    assert.equal(await p.textContent('#win-name'), 'Hero');
    assert.equal(await p.textContent('#win-pct'), '92%');
    assert.equal(await p.evaluate(() => window.MM.fxCount()), 0);
    assert.equal(await p.isVisible('#win-skip'), false);
    await ctx.close();
  });

  await test('finish day is offered only for days that can be finished', async () => {
    const { ctx, p } = await open();
    assert.equal(await p.isVisible('#finish-day'), true);
    await goto(p, '2026-11-23'); assert.equal(await p.isVisible('#finish-day'), false, 'not for future days');
    assert.equal(await p.locator('#day-hero [data-finish]').count(), 0);
    await goto(p, '2026-11-21'); assert.equal(await p.isVisible('#finish-day'), false, 'not for rest days');
    await goto(p, '2026-11-19'); assert.equal(await p.isVisible('#finish-day'), true, 'past days can be finished');
    await ctx.close();
  });

  await test('light mode uses soft greys instead of white', async () => {
    const { ctx, p } = await open({ scheme: 'light' });
    const bgOf = sel => p.evaluate(s => getComputedStyle(document.querySelector(s)).backgroundColor, sel);
    assert.equal(await bgOf('body'), 'rgb(211, 217, 225)');
    assert.equal(await bgOf('#day-hero'), 'rgb(232, 236, 240)');
    assert.equal(await bgOf('#day-list .task'), 'rgb(232, 236, 240)');
    assert.equal(await bgOf('#day-list .task:nth-child(2)'), 'rgb(224, 229, 235)');
    await p.click('#add-row');
    assert.equal(await bgOf('#task-sheet'), 'rgb(232, 236, 240)');
    await ctx.close();
  });

  await test('weekly record preview follows the theme, no white flash in dark mode', async () => {
    for (const [scheme, want] of [['dark', 'rgb(17, 26, 37)'], ['light', 'rgb(232, 236, 240)']]) {
      const { ctx, p } = await open({ scheme });
      await tab(p, 'week'); await p.click('[data-record="2026-11-16"]');
      await p.waitForSelector('#record-dialog[open]');
      assert.notEqual(await p.evaluate(() => getComputedStyle(document.getElementById('rec-frame')).backgroundColor), 'rgb(255, 255, 255)');
      const f = p.frameLocator('#rec-frame');
      await f.locator('table').waitFor();
      const got = await f.locator('body').evaluate(b => [getComputedStyle(b).backgroundColor, document.documentElement.dataset.theme]);
      assert.deepEqual(got, [want, scheme], scheme + ' preview');
      await ctx.close();
    }
    const { ctx, p } = await open({ scheme: 'light' });
    await p.click('#theme-btn'); await p.click('#theme-btn');
    await tab(p, 'week'); await p.click('[data-record="2026-11-16"]');
    const f = p.frameLocator('#rec-frame'); await f.locator('table').waitFor();
    assert.equal(await f.locator('body').evaluate(b => getComputedStyle(b).backgroundColor), 'rgb(17, 26, 37)', 'manual dark theme wins over a light system');
    await ctx.close();
  });

  await test('downloaded record adapts to the viewer and always prints white', async () => {
    const { ctx, p } = await open();
    await tab(p, 'week'); await p.click('[data-record="2026-11-16"]');
    const [dl] = await Promise.all([p.waitForEvent('download'), p.click('#rec-download')]);
    const file = path.join(TMP, 'record.html'); await dl.saveAs(file);
    await ctx.close();
    const html = fs.readFileSync(file, 'utf8');
    assert.ok(!/<html[^>]*data-theme/.test(html), 'downloaded file is not pinned to a theme');
    const ctx2 = await browser.newContext({ colorScheme: 'dark' });
    const q = await ctx2.newPage(); await q.goto('file://' + file);
    const bg = () => q.evaluate(() => getComputedStyle(document.body).backgroundColor);
    assert.equal(await bg(), 'rgb(17, 26, 37)', 'dark on a dark phone');
    await q.emulateMedia({ media: 'print' });
    assert.equal(await bg(), 'rgb(255, 255, 255)', 'prints on white');
    await ctx2.close();
  });

  await test('a saved dark theme applies before the page first draws', async () => {
    const { ctx, p } = await open({ scheme: 'light' });
    await p.click('#theme-btn'); await p.click('#theme-btn');
    assert.equal(await p.getAttribute('html', 'data-theme'), 'dark');
    await ctx.addInitScript(() => {
      new MutationObserver((m, o) => { if (document.body) { window.__themeAtBody = document.documentElement.getAttribute('data-theme'); o.disconnect(); } })
        .observe(document, { childList: true, subtree: true });
    });
    await p.reload(); await p.waitForSelector('#day-list .task');
    assert.equal(await p.evaluate(() => window.__themeAtBody), 'dark');
    await ctx.close();
  });

  await test('security: the content policy matches the scripts and blocks network and injected code', async () => {
    const html = fs.readFileSync(FILE, 'utf8');
    const hash = id => "'sha256-" + require('crypto').createHash('sha256').update(html.match(new RegExp('<script id="' + id + '">([\\s\\S]*?)</script>'))[1]).digest('base64') + "'";
    const meta = html.match(/<meta http-equiv="Content-Security-Policy" content="([^"]*)">/)[1];
    assert.ok(meta.includes(hash('theme-boot')) && meta.includes(hash('app')), 'policy lists the current script hashes (run build/csp.py)');
    assert.match(meta, /default-src 'none'/); assert.match(meta, /connect-src 'none'/);
    const { ctx, p } = await open();
    const r = await p.evaluate(async () => {
      const seen = []; document.addEventListener('securitypolicyviolation', e => seen.push(e.violatedDirective));
      const net = await fetch('https://example.com/steal').then(() => 'sent', () => 'blocked');
      const sc = document.createElement('script'); sc.textContent = 'window.__pwned = 1'; document.body.appendChild(sc);
      await new Promise(r => setTimeout(r, 50));
      return { net, pwned: window.__pwned, seen };
    });
    assert.equal(r.net, 'blocked'); assert.equal(r.pwned, undefined, 'an injected inline script does not run');
    assert.ok(r.seen.includes('connect-src') && r.seen.some(d => d.startsWith('script-src')), 'violations: ' + r.seen);
    await ctx.close();
  });

  await test('security: hostile text in tasks, names and notes is shown as text, never run', async () => {
    const evil = '<img src=x onerror="window.__xss=1">';
    const { ctx, p } = await open();
    await p.click('#add-row'); await p.fill('#ts-name', evil); await p.click('#ts-save');
    await tab(p, 'tools'); await p.fill('#set-name', '<script>window.__xss=2</script>');
    await tab(p, 'day'); await p.evaluate(() => { document.querySelector('.notes-box').open = true; });
    await p.fill('.notes-box textarea', '</textarea><svg onload="window.__xss=3">');
    assert.ok((await titles(p)).includes(evil));
    assert.equal(await p.locator('#day-list img, #day-list svg[onload]').count(), 0);
    await p.click('#add-row'); await p.locator('#ts-name').pressSequentially('<img');
    assert.equal(await p.locator('#ts-suggest img').count(), 0); await p.click('#task-sheet .sheet-foot [data-close]');
    await tab(p, 'week'); assert.equal(await p.locator('#view-week img').count(), 0);
    await p.click('[data-record="2026-11-16"]');
    const f = p.frameLocator('#rec-frame'); await f.locator('table').waitFor();
    assert.ok((await f.locator('tbody').textContent()).includes(evil));
    assert.equal(await f.locator('img').count(), 0);
    const [dl] = await Promise.all([p.waitForEvent('download'), p.click('#rec-download')]);
    const rec = path.join(TMP, 'evil-record.html'); await dl.saveAs(rec);
    const recHtml = fs.readFileSync(rec, 'utf8');
    assert.ok(recHtml.includes('&lt;img src=x onerror=&quot;window.__xss=1&quot;&gt;') && !recHtml.includes(evil));
    assert.match(recHtml, /Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"/);
    await p.click('#record-dialog .sheet-head [data-close]');
    await tab(p, 'tools');
    const [dl2] = await Promise.all([p.waitForEvent('download'), p.click('#save-html')]);
    const copy = path.join(TMP, 'evil-copy.html'); await dl2.saveAs(copy);
    assert.equal(await p.evaluate(() => window.__xss), undefined);
    await ctx.close();
    const c2 = await open({ url: 'file://' + copy });
    assert.ok((await titles(c2.p)).includes(evil));
    assert.equal(await c2.p.evaluate(() => window.__xss), undefined, 'the HTML copy does not run injected code');
    assert.equal((fs.readFileSync(copy, 'utf8').match(/<script\b/g) || []).length, 3 + 2, 'only the shipped scripts (plus two quoted in the app code)');
    await c2.ctx.close();
  });

  await test('security: hostile or oversized backups are rejected or cleaned', async () => {
    const { ctx, p } = await open();
    const base = await S(p);
    const tryRestore = async (name, obj) => {
      await restoreFile(p, name, obj);
      const ok = await p.waitForSelector('#ask-dialog[open]', { timeout: 1500 }).then(() => true, () => false);
      if (ok) await choose(p, '#ask-ok');
      return { ok, toast: await p.textContent('#toast-msg') };
    };
    let r = await tryRestore('proto.json', '{"v":3,"tasks":{},"__proto__":{"polluted":1},"set":{"__proto__":{"polluted":1},"theme":"dark"}}');
    assert.equal(r.ok, true);
    assert.equal(await p.evaluate(() => ({}).polluted), undefined, 'no prototype pollution');
    r = await tryRestore('ctor.json', { v: 3, tasks: { constructor: { o: 1, h: [{ f: '2026-01-01', t: 'Gym\u202Eevil\u0007', s: 60, e: 120, d: 127 }] } } });
    assert.equal(r.ok, true);
    await tab(p, 'day');
    assert.deepEqual(await titles(p), ['Gymevil'], 'odd ids work and hidden control characters are stripped');
    r = await tryRestore('days-proto.json', { v: 3, tasks: base.tasks, days: JSON.parse('{"__proto__":{"c":["0"]}}') });
    assert.equal(r.ok, false); assert.match(r.toast, /Could not restore/);
    const many = {}; for (let i = 0; i < 1001; i++) many[i.toString(36)] = { o: i, h: [{ f: '2026-01-01', t: 'T' + i, s: 60, e: 90, d: 1 }] };
    r = await tryRestore('many.json', { v: 3, tasks: many });
    assert.equal(r.ok, false); assert.match(r.toast, /too many tasks/);
    r = await tryRestore('seq.json', { v: 3, tasks: base.tasks, seq: 1e300 });
    assert.equal(r.ok, false);
    r = await tryRestore('slow.json', { dm: 'enc1', kdf: 'PBKDF2-SHA256', it: 1e9, salt: 'AAAAAAAAAAAAAAAAAAAAAA==', iv: 'AAAAAAAAAAAAAAAA', ct: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' });
    assert.equal(r.ok, false, 'an encrypted backup with absurd key-stretching settings is refused');
    assert.equal(await p.isVisible('#pass-dialog'), false);
    await ctx.close();
  });

  await test('security: refuses to run inside another page, and hides the test hook', async () => {
    const wrap = path.join(TMP, 'frame.html');
    fs.writeFileSync(wrap, '<!doctype html><iframe id="f" src="' + URL + '" width="400" height="600"></iframe>');
    const ctx = await browser.newContext(); const p = await ctx.newPage(); await p.goto('file://' + wrap);
    const fr = p.frameLocator('#f'); await fr.locator('body').waitFor();
    assert.match(await fr.locator('body').textContent(), /Open Daily Missions directly/);
    assert.equal(await fr.locator('#day-list .task').count(), 0);
    const q = await ctx.newPage(); await q.goto(URL); await q.waitForSelector('#day-list .task, #day-list .empty');
    assert.equal(await q.evaluate(() => typeof window.MM), 'undefined');
    await ctx.close();
  });

  await test('app lock: encrypts everything and asks for the passcode', async () => {
    const { ctx, p } = await open();
    await p.locator('#day-list .task input').first().check();
    await setPasscode(p, 'correct horse');
    assert.match(await p.textContent('#lock-status'), /^On\./);
    const raw = await stored(p);
    const blob = JSON.parse(raw);
    assert.equal(blob.dm, 'enc1'); assert.equal(blob.it, 600000);
    assert.ok(!/Yoga|Coffee|"c"/.test(raw), 'nothing readable is stored');
    await p.reload(); await p.waitForSelector('#lock:not([hidden])');
    assert.equal(await p.isVisible('#main'), false);
    assert.equal(await p.locator('.task').count(), 0);
    assert.equal(await p.evaluate(() => window.MM.state), null);
    await unlock(p, 'wrong one');
    await p.waitForFunction(() => /did not work/.test(document.getElementById('lock-error').textContent), null, { timeout: 15000 });
    await unlock(p, 'correct horse');
    await p.waitForSelector('#day-list .task', { timeout: 15000 });
    assert.equal(await p.locator('#day-list .task input').first().isChecked(), true);
    assert.equal(await p.isVisible('#lock'), false);
    await p.locator('#day-list .task input').nth(1).check();
    await p.waitForFunction(() => { try { return JSON.parse(localStorage.getItem('morning-missions-v3')).dm === 'enc1'; } catch (e) { return false; } });
    await p.reload(); await p.waitForSelector('#lock:not([hidden])');
    await unlock(p, 'correct horse'); await p.waitForSelector('#day-list .task', { timeout: 15000 });
    assert.equal(await p.locator('#day-list .task input').nth(1).isChecked(), true, 'changes made while unlocked are saved encrypted');
    await ctx.close();
  });

  await test('app lock: locks again after leaving the app, and wipes the screen', async () => {
    const { ctx, p } = await open();
    await setPasscode(p, 'swordfish42');
    await hideApp(p, true); await hideApp(p, false);
    assert.equal(await p.isVisible('#lock'), false, 'a quick switch away does not lock (1 minute default)');
    await p.selectOption('#set-lockafter', '0');
    await newGoal(p, 'secret goal', async () => { await p.check('#gs-use-steps'); await p.fill('[data-gs-step="0"]', 'secret step'); });
    await p.click('#view-goals .goal-name'); await p.waitForSelector('#goal-sheet[open]');
    await hideApp(p, true); await p.waitForSelector('#lock:not([hidden])'); await hideApp(p, false);
    assert.equal(await p.isVisible('#goal-sheet'), false, 'locking closes the goal editor');
    const left = await p.content();
    assert.ok(!left.includes('secret goal') && !left.includes('secret step'), 'no goal text is left in the page');
    await unlock(p, 'swordfish42'); await p.waitForSelector('#day-list .task', { timeout: 15000 });
    assert.match(await p.textContent('#day-goals'), /secret goal/);
    await tab(p, 'day'); await p.evaluate(() => { document.querySelector('.notes-box').open = true; }); await p.fill('.notes-box textarea', 'private note');
    await hideApp(p, true);
    await p.waitForSelector('#lock:not([hidden])');
    assert.equal(await p.locator('.task').count(), 0);
    assert.ok(!(await p.content()).includes('private note'), 'nothing personal is left in the page');
    await hideApp(p, false);
    await unlock(p, 'swordfish42'); await p.waitForSelector('#day-list .task', { timeout: 15000 });
    await tab(p, 'tools'); await p.click('#lock-now');
    await p.waitForSelector('#lock:not([hidden])');
    await ctx.close();
  });

  await test('app lock: encrypted backups and HTML copies need the passcode', async () => {
    const { ctx, p } = await open();
    await tab(p, 'tools'); await p.fill('#set-name', 'Locked Owner');
    await setPasscode(p, 'tango-delta');
    const [dl] = await Promise.all([p.waitForEvent('download'), p.click('#export-backup')]);
    assert.match(dl.suggestedFilename(), /-encrypted\.json$/);
    const bfile = path.join(TMP, 'enc-backup.json'); await dl.saveAs(bfile);
    const btext = fs.readFileSync(bfile, 'utf8');
    assert.equal(JSON.parse(btext).dm, 'enc1'); assert.ok(!btext.includes('Locked Owner'));
    const [dl2] = await Promise.all([p.waitForEvent('download'), p.click('#save-html')]);
    const cfile = path.join(TMP, 'enc-copy.html'); await dl2.saveAs(cfile);
    assert.ok(!fs.readFileSync(cfile, 'utf8').includes('Locked Owner'));
    p.once('download', () => {});
    await p.click('#export-plain'); assert.equal(await p.isVisible('#ask-dialog'), true, 'unencrypted export asks first'); await choose(p, '#ask-cancel');
    await ctx.close();
    const c2 = await open();
    await restoreFile(c2.p, 'enc-backup.json', btext);
    await c2.p.waitForSelector('#pass-dialog[open]');
    await c2.p.fill('#pass-cur', 'nope'); await c2.p.click('#pass-ok');
    await c2.p.waitForFunction(() => /did not work/.test(document.getElementById('pass-error').textContent), null, { timeout: 15000 });
    await c2.p.fill('#pass-cur', 'tango-delta'); await c2.p.click('#pass-ok');
    await c2.p.waitForSelector('#ask-dialog[open]', { timeout: 15000 }); await choose(c2.p, '#ask-ok');
    assert.equal((await S(c2.p)).name, 'Locked Owner');
    await c2.ctx.close();
    const c3 = await open({ url: 'file://' + cfile });
    await c3.p.waitForSelector('#lock:not([hidden])');
    await unlock(c3.p, 'tango-delta'); await c3.p.waitForSelector('#day-list .task', { timeout: 15000 });
    assert.equal((await S(c3.p)).name, 'Locked Owner');
    await c3.ctx.close();
  });

  await test('app lock: change the passcode, turn it off, and forgotten-passcode reset', async () => {
    const { ctx, p } = await open();
    await setPasscode(p, 'first-code');
    await p.click('#lock-change');
    await p.fill('#pass-cur', 'not-it'); await p.fill('#pass-new', 'second-code'); await p.fill('#pass-new2', 'second-code'); await p.click('#pass-ok');
    await p.waitForFunction(() => /not right/.test(document.getElementById('pass-error').textContent), null, { timeout: 15000 });
    await p.fill('#pass-cur', 'first-code'); await p.click('#pass-ok');
    await p.waitForFunction(() => !document.querySelector('dialog[open]'), null, { timeout: 15000 });
    await p.reload(); await p.waitForSelector('#lock:not([hidden])');
    await unlock(p, 'first-code');
    await p.waitForFunction(() => /did not work/.test(document.getElementById('lock-error').textContent), null, { timeout: 15000 });
    await unlock(p, 'second-code'); await p.waitForSelector('#day-list .task', { timeout: 15000 });
    await tab(p, 'tools'); await p.click('#lock-disable');
    await p.fill('#pass-cur', 'second-code'); await p.click('#pass-ok');
    await p.waitForFunction(() => !document.querySelector('dialog[open]'), null, { timeout: 15000 });
    assert.equal(JSON.parse(await stored(p)).v, 3, 'stored without encryption again');
    await setPasscode(p, 'third-code');
    await p.reload(); await p.waitForSelector('#lock:not([hidden])');
    for (let i = 0; i < 5; i++) { await unlock(p, 'bad' + i); await p.waitForFunction(() => !document.getElementById('lock-go').disabled, null, { timeout: 15000 }); }
    await unlock(p, 'third-code');
    assert.match(await p.textContent('#lock-error'), /Too many tries/);
    await p.click('#lock-forgot'); await choose(p, '#ask-ok');
    await p.waitForSelector('#day-list .task');
    assert.equal(JSON.parse(await stored(p)).v, 3);
    assert.equal(await p.isVisible('#lock'), false);
    await ctx.close();
  });

  await test('erase all also removes leftover copies', async () => {
    const { ctx, p } = await open({ init: "if(!sessionStorage.getItem('s')){sessionStorage.setItem('s','1');localStorage.setItem('morning-missions-v3-unreadable-1','old');}" });
    await p.evaluate(() => localStorage.setItem('morning-missions-v2', '{}'));
    await tab(p, 'tools'); await p.click('#erase-all'); await choose(p, '#ask-ok');
    const keys = await p.evaluate(() => Object.keys(localStorage));
    assert.ok(!keys.some(k => /unreadable|missions-v2/.test(k)), 'keys left: ' + keys);
    await ctx.close();
  });

  const NATIVE_MOCK = `window.__nn={calls:[],perm:'ask',lists:[]};
    window.NativeNotify={status:()=>JSON.stringify({perm:window.__nn.perm,exact:true,count:0}),
      requestPermission:()=>{window.__nn.calls.push('req');setTimeout(()=>{if(window.__nn.perm==='ask')window.__nn.perm='granted';window.onNativeNotifyPermission&&window.onNativeNotifyPermission();},10);},
      schedule:j=>{window.__nn.lists.push(JSON.parse(j));return 0;},test:j=>{window.__nn.test=JSON.parse(j);},openSettings:()=>{window.__nn.calls.push('settings');}};
    window.NativeApp={setSecure:v=>{window.__nn.secure=v;}};`;
  const lastList = p => p.evaluate(() => window.__nn.lists[window.__nn.lists.length - 1] || null);

  await test('notifications: browser explains they need the Android app', async () => {
    const { ctx, p } = await open();
    await tab(p, 'tools');
    assert.match(await p.textContent('#n-status'), /work in the Daily Missions Android app/);
    assert.equal(await p.isVisible('#n-opts'), false);
    assert.equal(await p.isDisabled('input[name=notif][value=on]'), true);
    assert.equal(await p.isVisible('#secure-line'), false);
    await ctx.close();
  });

  await test('notifications: turning on asks permission and plans each kind of reminder', async () => {
    const { ctx, p } = await open({ init: NATIVE_MOCK });
    await tab(p, 'tools');
    assert.match(await p.textContent('#n-status'), /^Off\./);
    await p.check('input[name=notif][value=on]');
    await p.waitForFunction(() => window.__nn.perm === 'granted' && window.__nn.lists.length > 0);
    assert.deepEqual(await p.evaluate(() => window.__nn.calls), ['req']);
    const list = await lastList(p);
    const ids = list.map(x => x.id);
    assert.ok(ids.includes('t:2026-11-20:f') && ids.includes('t:2026-11-20:h'), 'task reminders later today');
    assert.ok(!ids.some(i => /^t:2026-11-20:(0|2|e)$/.test(i)), 'no reminders for tasks that already started');
    assert.ok(ids.includes('m:2026-11-20:e'), 'missed-task nudge for Study, which just ended');
    assert.ok(!ids.includes('s:2026-11-20') && ids.includes('s:2026-11-23'), 'morning summary for the next working day');
    assert.ok(ids.includes('f:2026-11-20'), 'finish-day reminder tonight');
    assert.ok(!ids.some(i => i.includes('2026-11-21')), 'nothing on the rest day');
    const walk = list.find(x => x.id === 't:2026-11-20:f');
    assert.deepEqual([walk.at, walk.title, walk.priv], ['2026-11-20T09:20', 'Walk down', 1]);
    assert.equal(list.find(x => x.id === 'f:2026-11-20').at, '2026-11-20T21:00');
    assert.equal(list.find(x => x.id === 's:2026-11-23').at, '2026-11-23T05:45');
    assert.ok(list.every((x, i) => i === 0 || list[i - 1].at <= x.at), 'sorted by time');
    assert.ok(list[list.length - 1].at < '2026-12-04', 'two weeks ahead');
    assert.match(await p.textContent('#n-status'), /^On\. Next: Walk down, today at 9:20 AM\./);
    await ctx.close();
  });

  await test('notifications: checking a task and changing settings re-plan the reminders', async () => {
    const { ctx, p } = await open({ init: NATIVE_MOCK + "window.__nn.perm='granted';" });
    await tab(p, 'tools'); await p.check('input[name=notif][value=on]');
    await p.waitForFunction(() => window.__nn.lists.length > 0);
    await tab(p, 'day');
    const row = p.locator('#day-list .task', { has: p.locator('.task-title', { hasText: /^Walk down$/ }) });
    await row.locator('input').check();
    await p.waitForFunction(() => !window.__nn.lists[window.__nn.lists.length - 1].some(x => x.id === 't:2026-11-20:f'));
    assert.ok(!(await lastList(p)).some(x => x.id === 'm:2026-11-20:f'), 'no nudge for a checked task');
    await tab(p, 'tools');
    await p.selectOption('#n-priv', 'never');
    await p.waitForFunction(() => window.__nn.lists[window.__nn.lists.length - 1].every(x => !/Walk|Yoga|Study|Group|Coffee/.test(x.title + x.body)));
    assert.ok((await lastList(p)).every(x => x.priv === 0));
    await p.selectOption('#n-lead', '15');
    await p.waitForFunction(() => window.__nn.lists[window.__nn.lists.length - 1].some(x => x.id === 't:2026-11-20:g' && x.at === '2026-11-20T09:20'));
    await p.uncheck('#n-task');
    await p.waitForFunction(() => !window.__nn.lists[window.__nn.lists.length - 1].some(x => x.id.startsWith('t:')));
    assert.equal(await p.isDisabled('#n-lead'), true);
    await p.click('#n-none');
    await p.waitForFunction(() => window.__nn.lists[window.__nn.lists.length - 1].length === 0);
    await p.click('#n-all');
    await p.waitForFunction(() => window.__nn.lists[window.__nn.lists.length - 1].length > 20);
    await p.fill('#n-finat', '20:30'); await p.dispatchEvent('#n-finat', 'change');
    await p.waitForFunction(() => window.__nn.lists[window.__nn.lists.length - 1].some(x => x.id === 'f:2026-11-20' && x.at === '2026-11-20T20:30'));
    await p.check('input[name=notif][value=off]');
    await p.waitForFunction(() => window.__nn.lists[window.__nn.lists.length - 1].length === 0);
    await p.reload(); await p.waitForSelector('#day-list .task');
    const st = await S(p);
    assert.deepEqual([st.set.notif, st.set.nTask, st.set.nLead, st.set.nPriv, st.set.nFinAt], [false, true, 15, 'never', 1230], 'settings survive a reload');
    await ctx.close();
  });

  await test('notifications: test button, blocked permission, and screenshot blocking', async () => {
    const { ctx, p } = await open({ init: NATIVE_MOCK + "window.__nn.perm='granted';" });
    await tab(p, 'tools'); await p.check('input[name=notif][value=on]');
    await p.click('#n-test');
    const tn = await p.evaluate(() => window.__nn.test);
    assert.equal(tn.ch, 'test'); assert.equal(tn.title, 'Walk down');
    await p.evaluate(() => { window.__nn.perm = 'denied'; });
    await tab(p, 'day'); await tab(p, 'tools');
    assert.match(await p.textContent('#n-status'), /blocked for Daily Missions/);
    await p.click('#n-settings');
    assert.ok((await p.evaluate(() => window.__nn.calls)).includes('settings'));
    await setPasscode(p, 'secret-123');
    assert.match(await p.textContent('#n-hint'), /without encryption/);
    assert.equal(await p.isVisible('#secure-line'), true);
    await p.check('#set-secure');
    assert.equal(await p.evaluate(() => window.__nn.secure), true);
    await ctx.close();
  });

  await test('restore uses the Android file picker when the app provides one', async () => {
    const old = fs.readFileSync(OLD_BACKUP, 'utf8');
    const { ctx, p } = await open({ init: `window.NativeFiles={openText:()=>setTimeout(()=>window.onNativeFileOpened(true),10),takeOpened:()=>${JSON.stringify(old)}};` });
    await tab(p, 'tools'); await p.click('#import-backup');
    await p.waitForSelector('#ask-dialog[open]'); await choose(p, '#ask-ok');
    assert.equal((await S(p)).name, 'Test Player');
    await ctx.close();
  });

  const yogaRow = p => p.locator('#day-list .task', { has: p.locator('.task-title', { hasText: /^Yoga$/ }) });
  async function newGoal(p, name, setup) {
    if (!(await p.isVisible('#view-goals'))) await tab(p, 'goals');
    await p.click('#view-goals .vnav-actions [data-goal-new]'); await p.waitForSelector('#goal-sheet[open]');
    await p.fill('#gs-name', name); if (setup) await setup();
    await p.click('#gs-save');
  }
  async function closeWin(p) {
    await p.waitForSelector('#win[open]');
    await p.click('#win-stage', { position: { x: 20, y: 20 } }); await p.click('#win-close');
    await p.waitForFunction(() => !document.querySelector('#win[open]'));
    await p.waitForTimeout(30); // the close event fires a moment later
  }

  await test('goals: rough dates name, time, and order their groups', async () => {
    const { ctx, p } = await open();
    const r = await p.evaluate(() => { const M = window.MM; return {
      names: ['2027-S1', '2026-S4', '2027-06', '2027-Q2', '2027'].map(M.byName),
      periods: ['2026-S4', '2027-Q2', '2028-02', '2027', '2027-S2'].map(M.byPeriod),
      left: ['2026-11', '2026-12', '2026-S4', '2027', '2025'].map(b => M.timeLeft(b).txt),
      first: ['s', 'q', 'm', 'y'].map(k => M.byChoices(k).slice(0, 2)) }; });
    assert.deepEqual(r.names, ['Spring 2027', 'Winter 2026/27', 'By June 2027', 'Q2 2027', 'By end of 2027']);
    assert.deepEqual(r.periods, [{ start: '2026-12-01', end: '2027-02-28' }, { start: '2027-04-01', end: '2027-06-30' }, { start: '2028-02-01', end: '2028-02-29' }, { start: '2027-01-01', end: '2027-12-31' }, { start: '2027-06-01', end: '2027-08-31' }]);
    assert.deepEqual(r.left, ['10 days left', '~6 weeks left', '~3 months left', '~13 months left', 'Time is up']);
    assert.deepEqual(r.first, [['2026-S3', '2026-S4'], ['2026-Q4', '2027-Q1'], ['2026-11', '2026-12'], ['2026', '2027']]);
    await ctx.close();
  });

  await test('goals: steps, linked tasks, and a number show on Goals, Day, Month, and the record', async () => {
    const { ctx, p } = await open();
    await tab(p, 'goals');
    assert.match(await p.textContent('#view-goals'), /Set a goal to work toward/);
    assert.match(await p.textContent('#day-goals'), /Work toward something bigger/);
    await p.click('#view-goals .vnav-actions [data-goal-new]'); await p.waitForSelector('#goal-sheet[open]');
    assert.match(await p.textContent('#gs-when-hint'), /Winter 2026\/27.*Feb 28, 2027/, 'defaults to a season a couple of months out');
    assert.equal(await p.isVisible('#gs-delete'), false);
    await p.fill('#gs-name', 'Run a 5K');
    await p.check('#gs-use-steps');
    await p.fill('[data-gs-step="0"]', 'Buy shoes'); await p.press('[data-gs-step="0"]', 'Enter');
    await p.fill('[data-gs-step="1"]', 'Sign up'); await p.press('[data-gs-step="1"]', 'Enter');
    await p.fill('[data-gs-step="2"]', 'Throwaway'); await p.click('[data-gs-rm="2"]');
    await p.check('#gs-use-links'); await p.click('#gs-save');
    assert.match(await p.textContent('#gs-error'), /Pick at least one task/);
    await p.click('[data-glink="2"]'); await p.click('#gs-save');
    assert.match(await p.textContent('#gs-error'), /how many check-offs/);
    await p.fill('#gs-target', '4');
    await p.check('#gs-use-num'); await p.fill('#gs-nt', '3.1'); await p.fill('#gs-nu', 'miles');
    await p.click('#gs-save');
    assert.match(await p.textContent('#toast-msg'), /Goal added under Winter 2026\/27/);
    const g = Object.values((await S(p)).goals)[0];
    assert.deepEqual(g, { t: 'Run a 5K', by: '2026-S4', c: '2026-11-20', ms: [{ t: 'Buy shoes' }, { t: 'Sign up' }], lk: ['2'], lt: 4, ns: 0, nv: 0, nt: 3.1, nu: 'miles' });
    await newGoal(p, 'Save for a bike', async () => {
      await p.check('input[name=gs-kind][value=m]');
      assert.equal(await p.inputValue('#gs-when'), '2027-02', 'switching to months keeps about the same date');
      await p.selectOption('#gs-when', '2026-12');
      await p.check('#gs-use-num'); await p.fill('#gs-nv', '250'); await p.fill('#gs-nt', '800'); await p.fill('#gs-nu', '$');
    });
    assert.deepEqual(await p.$$eval('#view-goals .ggroup .panel-head h2', els => els.map(e => e.firstChild.textContent)), ['By December 2026', 'Winter 2026/27'], 'soonest group first');
    assert.match(await p.textContent('#view-goals .ggroup .panel-head h2 span'), /~6 weeks left/);
    assert.match(await p.textContent('#view-goals [data-gnum]'), /\$250 \/ \$800/);
    // Day screen: goals fed by this day's tasks come first, and the linked task wears a badge.
    await tab(p, 'day');
    assert.deepEqual(await p.$$eval('#day-goals .gd-name', els => els.map(e => e.textContent)), ['Run a 5K', 'Save for a bike']);
    assert.match(await yogaRow(p).locator('.gbadge').textContent(), /Run a 5K/);
    await yogaRow(p).locator('input').check();
    assert.match(await p.textContent('#toast-msg'), /\+1 toward "Run a 5K": 1 of 4 check-offs/);
    assert.match(await p.textContent('#day-goals'), /1 of 1 linked task done today/);
    await p.locator('#day-goals [data-gstep]').click(); // the list re-renders to show the next step
    assert.match(await p.textContent('#day-goals .gnext'), /Sign up/);
    assert.equal(await p.textContent('#day-goals .gd-pct'), '25%', 'average of steps 1/2, check-offs 1/4, and miles 0/3.1');
    // Month: goals card, a flag on the goal date, and the weekly record lists goals.
    await tab(p, 'month');
    assert.match(await p.textContent('.mgoals'), /Coming up[\s\S]*Save for a bike[\s\S]*Run a 5K/);
    await p.click('[data-mstep="1"]');
    assert.match(await p.getAttribute('.mcell[data-goto="2026-12-31"]', 'aria-label'), /Goal date: By December 2026/);
    assert.equal(await p.locator('.mcell[data-goto="2026-12-31"] .mmark svg').count(), 1);
    assert.match(await p.textContent('.mgoals'), /Due this month[\s\S]*Save for a bike/);
    await p.click('.mgoals [data-goal-open]'); await p.waitForSelector('#goal-sheet[open]');
    assert.equal(await p.inputValue('#gs-name'), 'Save for a bike');
    await p.click('#goal-sheet [data-close]');
    await tab(p, 'tools'); await p.click('#rec-this');
    const rec = await p.getAttribute('#rec-frame', 'srcdoc');
    assert.match(rec, /<h2>Goals<\/h2>[\s\S]*Save for a bike[\s\S]*Run a 5K<\/b> · Winter 2026\/27 · 25% so far/);
    await ctx.close();
  });

  await test('goals: finishing every part plays the trophy, and undoing a part reopens the goal', async () => {
    const { ctx, p } = await open();
    await newGoal(p, 'Morning yoga', async () => { await p.check('#gs-use-links'); await p.click('[data-glink="2"]'); await p.fill('#gs-target', '1'); });
    await tab(p, 'day');
    await yogaRow(p).locator('input').check();
    await p.waitForSelector('#win[open]');
    assert.equal(await p.textContent('#win-tag'), 'Goal achieved');
    assert.equal(await p.textContent('#win-name'), 'Morning yoga');
    assert.match(await p.textContent('#win-sub'), /Winter 2026\/27, 3 months early/);
    assert.equal(await p.evaluate(() => document.getElementById('win').classList.contains('goal-win')), true);
    assert.ok(await p.evaluate(() => document.querySelectorAll('#win-emblem .em-frame path').length) >= 3, 'trophy emblem');
    await closeWin(p);
    assert.equal(await p.evaluate(() => document.getElementById('win').classList.contains('goal-win')), false);
    assert.equal(Object.values((await S(p)).goals)[0].d, '2026-11-20');
    assert.equal(await p.locator('#day-goals .gd').count(), 0, 'achieved goals leave the Day screen');
    assert.equal(await yogaRow(p).locator('.gbadge').count(), 0);
    await tab(p, 'goals');
    assert.match(await p.textContent('#goals-won summary'), /Achieved1/);
    assert.match(await p.textContent('#goals-won'), /Morning yoga.*achieved Nov 20, 2026, 3 months early/);
    await tab(p, 'month');
    assert.match(await p.getAttribute('.mcell[data-goto="2026-11-20"]', 'aria-label'), /Goal achieved: Morning yoga/);
    assert.match(await p.textContent('.mgoals'), /Achieved this month[\s\S]*Morning yoga/);
    await tab(p, 'day');
    await yogaRow(p).locator('input').uncheck();
    assert.equal(Object.values((await S(p)).goals)[0].d, undefined, 'unchecking reopens it');
    assert.equal(await p.locator('#day-goals .gd').count(), 1);
    await ctx.close();
  });

  await test('goals: update a number, mark a simple goal achieved, edit, and delete with undo', async () => {
    const { ctx, p } = await open();
    await newGoal(p, 'Save for a bike', async () => { await p.check('#gs-use-num'); await p.fill('#gs-nv', '250'); await p.fill('#gs-nt', '800'); await p.fill('#gs-nu', '$'); });
    await p.click('#view-goals [data-gnum]'); await p.waitForSelector('#num-dialog[open]');
    assert.match(await p.textContent('#num-body'), /now \$250, target \$800/);
    await p.click('[data-nstep="1"]'); assert.equal(await p.inputValue('#num-val'), '251');
    await p.fill('#num-val', '400'); await p.press('#num-val', 'Enter');
    assert.match(await p.textContent('#toast-msg'), /Save for a bike: \$400 \(50%\)/);
    assert.equal(await p.textContent('#view-goals .goal-pct'), '50%');
    await p.click('#view-goals [data-gnum]'); await p.fill('#num-val', '800'); await p.click('#num-ok');
    await closeWin(p);
    // A goal with no parts is marked achieved by hand.
    await newGoal(p, 'Learn to juggle');
    assert.match(await p.textContent('#view-goals'), /Tap the goal to add steps/);
    await p.click('#view-goals .goal-name:text("Learn to juggle")'); await p.waitForSelector('#goal-sheet[open]');
    assert.equal(await p.isVisible('#gs-done-line'), true);
    await p.check('#gs-done'); await p.click('#gs-save');
    await closeWin(p);
    let goals = Object.values((await S(p)).goals);
    assert.deepEqual(goals.map(g => [g.t, g.d, g.m]), [['Save for a bike', '2026-11-20', undefined], ['Learn to juggle', '2026-11-20', 1]]);
    // A goal whose parts are all complete cannot be unmarked without changing a part.
    await p.evaluate(() => { document.getElementById('goals-won').open = true; });
    await p.click('#goals-won .goal-name:text("Save for a bike")'); await p.waitForSelector('#goal-sheet[open]');
    await p.uncheck('#gs-done'); await p.click('#gs-save');
    assert.match(await p.textContent('#gs-error'), /Every part of this goal is complete/);
    await p.fill('#gs-nt', '1000'); await p.click('#gs-save');
    goals = (await S(p)).goals;
    assert.equal(Object.values(goals)[0].d, undefined, 'raising the target reopens it');
    assert.equal(await p.textContent('#view-goals .goal-pct'), '80%');
    // Delete, then undo.
    await p.click('#view-goals .goal-name:text("Save for a bike")'); await p.click('#gs-delete');
    await p.waitForSelector('#ask-dialog[open]'); await choose(p, '#ask-ok');
    assert.equal(Object.keys((await S(p)).goals).length, 1);
    await p.click('#toast-act');
    assert.equal(Object.keys((await S(p)).goals).length, 2);
    await ctx.close();
  });

  await test('goals: backups keep them, damaged ones are refused, and archiving keeps check-off counts', async () => {
    const { ctx, p } = await open();
    const r = await p.evaluate(() => {
      const M = window.MM, base = () => ({ v: 3, tasks: { a: { o: 1, h: [{ f: '2000-01-01', t: 'Run', s: 360, e: 390, d: 127 }] } } });
      const ok = M.validate(Object.assign(base(), { goals: { g1: { t: ' Run‮ 5K ', by: '2027-S1', c: '2026-01-01', ms: [{ t: 'Shoes', c: 1 }, { t: '' }, { x: 1 }], lk: ['a', 'a', 'BAD!'], lt: 10, lb: 3, ns: 0, nv: 2, nt: 3.1, nu: 'miles', extra: 1, m: 2 } } }));
      const bad = [{ g1: { t: 'x', by: '2027-13', c: '2026-01-01' } }, { g1: { t: '', by: '2027', c: '2026-01-01' } }, { 'BAD ID': { t: 'x', by: '2027', c: '2026-01-01' } }, { g1: { t: 'x', by: '2027', c: 'nope' } }, { g1: { t: 'x', by: '2027', c: '2026-01-01', ms: Array(51).fill({ t: 's' }) } }, 'not goals']
        .map(goals => { try { M.validate(Object.assign(base(), { goals })); return 'accepted'; } catch (e) { return e.message; } });
      const many = {}; for (let i = 0; i < 301; i++) many['g' + i.toString(36)] = { t: 'x', by: '2027', c: '2026-01-01' };
      let tooMany; try { M.validate(Object.assign(base(), { goals: many })); tooMany = 'accepted'; } catch (e) { tooMany = e.message; }
      return { ok: JSON.parse(JSON.stringify(ok.goals)), seq: ok.seq, bad, tooMany };
    });
    assert.deepEqual(r.ok, { g1: { t: 'Run 5K', by: '2027-S1', c: '2026-01-01', ms: [{ t: 'Shoes', c: 1 }], lk: ['a'], lt: 10, lb: 3, ns: 0, nv: 2, nt: 3.1, nu: 'miles' } });
    assert.ok(r.seq > parseInt('g1', 36), 'new ids never collide with goal ids');
    r.bad.forEach((m, i) => assert.notEqual(m, 'accepted', 'damaged goal ' + i + ' was accepted'));
    assert.match(r.tooMany, /too many goals/);
    // Archiving old days keeps the check-offs they gave a goal.
    const counts = await p.evaluate(() => {
      const M = window.MM, st = M.state;
      st.goals.zz = { t: 'Yoga 10 times', by: '2027', c: '2026-10-01', lk: ['2'], lt: 10 };
      for (const d of ['2026-09-30', '2026-10-05', '2026-10-07', '2026-11-02', '2026-11-20']) st.days[d] = { c: ['2'] };
      const before = M.gProgress(st.goals.zz).lk.done; M.archive('2026-11-01');
      return { before, after: M.gProgress(st.goals.zz).lk.done, lb: st.goals.zz.lb, left: Object.keys(st.days).sort() };
    });
    assert.deepEqual(counts, { before: 4, after: 4, lb: 2, left: ['2026-11-02', '2026-11-20'] });
    // Restoring a backup with goals says so, and hostile goal text stays text.
    await restoreFile(p, 'goals.json', { v: 3, tasks: { a: { o: 1, h: [{ f: '2000-01-01', t: 'Run', s: 360, e: 390, d: 127 }] } }, goals: { g1: { t: '<img src=x onerror="window.__pwned=1">', by: '2027', c: '2026-11-01', ms: [{ t: '<b>bold</b>' }] } } });
    await p.waitForSelector('#ask-dialog[open]');
    assert.match(await p.textContent('#ask-body'), /1 task, 1 goal, and/);
    await choose(p, '#ask-ok');
    await tab(p, 'goals');
    assert.equal(await p.locator('#view-goals img, #view-goals b:text("bold")').count(), 0);
    assert.match(await p.textContent('#view-goals .goal-name'), /<img src=x/);
    assert.equal(await p.evaluate(() => window.__pwned), undefined);
    await ctx.close();
  });

  await test('repeat patterns: every 2 weeks, monthly by date or weekday, and every few days', async () => {
    const { ctx, p } = await open();
    await p.click('#add-row');
    await p.fill('#ts-name', 'Clean fridge'); await p.fill('#ts-start', '11:00'); await p.fill('#ts-end', '11:30');
    assert.deepEqual(await p.$$eval('#ts-rep option', o => o.map(x => x.value + '=' + x.textContent)),
      ['w1=Every week', 'w2=Every 2 weeks', 'w3=Every 3 weeks', 'w4=Every 4 weeks', 'm=Every month on the 20th', 'mw=Every month on the third Friday', 'dn=Every few days', 'once=This day only']);
    await p.selectOption('#ts-rep', 'w2');
    assert.match(await p.textContent('#ts-days-hint'), /Every 2 weeks: Fri\. After this day, next on Fri, Dec 4\./);
    await p.click('#ts-save');
    assert.match(await p.textContent('#toast-msg'), /Added\. Repeats every 2 weeks: Fri\./);
    await goto(p, '2026-11-27'); assert.ok(!(await titles(p)).includes('Clean fridge'), 'skips the next week');
    await goto(p, '2026-12-04'); assert.ok((await titles(p)).includes('Clean fridge'));
    assert.match(await p.locator('#day-list .task', { hasText: 'Clean fridge' }).locator('.task-meta').textContent(), /Every 2 weeks: Fri/);
    await goto(p, '2026-11-20');
    await p.click('#add-row'); await p.fill('#ts-name', 'Book club'); await p.fill('#ts-start', '19:00'); await p.fill('#ts-end', '20:00');
    await p.selectOption('#ts-rep', 'mw'); await p.click('#ts-save');
    await goto(p, '2026-12-11'); assert.ok(!(await titles(p)).includes('Book club'));
    await goto(p, '2026-12-18'); assert.ok((await titles(p)).includes('Book club'), 'third Friday of December');
    await goto(p, '2026-11-20');
    await p.click('#add-row'); await p.fill('#ts-name', 'Water plants'); await p.fill('#ts-start', '18:00'); await p.fill('#ts-end', '18:10');
    await p.selectOption('#ts-rep', 'dn');
    assert.equal(await p.isVisible('#ts-week-ui'), false, 'weekdays are hidden for every few days');
    await p.fill('#ts-ndays', '3'); await p.dispatchEvent('#ts-ndays', 'input');
    assert.match(await p.textContent('#ts-days-hint'), /Every 3 days\. After this day, next on Mon, Nov 23\./);
    await p.click('#ts-save');
    await goto(p, '2026-11-23'); assert.ok((await titles(p)).includes('Water plants'));
    await goto(p, '2026-11-24'); assert.ok(!(await titles(p)).includes('Water plants'));
    // Changing the pattern applies from that day on.
    await goto(p, '2026-11-23'); await openEdit(p, 'Water plants');
    assert.equal(await p.inputValue('#ts-rep'), 'dn'); assert.equal(await p.inputValue('#ts-ndays'), '3');
    await p.fill('#ts-ndays', '4'); await p.dispatchEvent('#ts-ndays', 'input');
    assert.match(await p.textContent('#ts-days-hint'), /applies from Mon, Nov 23 on/);
    await p.click('#ts-save');
    await goto(p, '2026-11-27'); assert.ok((await titles(p)).includes('Water plants'));
    await goto(p, '2026-11-26'); assert.ok(!(await titles(p)).includes('Water plants'));
    await goto(p, '2026-11-20'); assert.ok((await titles(p)).includes('Water plants'), 'earlier days keep the old pattern');
    const r = await p.evaluate(() => { const M = window.MM; return [
      M.hits({ k: 'm', n: 31 }, '2027-02-28'), M.hits({ k: 'm', n: 31 }, '2027-02-27'), M.hits({ k: 'm', n: 0 }, '2026-11-30'),
      M.hits({ k: 'mw', i: 5, w: 4 }, '2026-11-27'), M.hits({ k: 'mw', i: 5, w: 4 }, '2026-11-20'),
      M.hits({ k: 'd', n: 3, a: '2026-11-20' }, '2026-11-17'), M.hits({ k: 'w', n: 2, a: '2026-11-16' }, '2026-11-02'),
      M.repeatLabel(127, { k: 'm', n: 0 }), M.repeatLabel(127, { k: 'mw', i: 5, w: 4 }), M.repeatLabel(21, { k: 'w', n: 3, a: '2026-11-16' })]; });
    assert.deepEqual(r, [true, false, true, true, false, true, true, 'Monthly on the last day', 'Monthly on the last Friday', 'Every 3 weeks: Mon Wed Fri']);
    const bad = await p.evaluate(() => { try { window.MM.validate({ v: 3, tasks: { a: { o: 1, h: [{ f: '2000-01-01', t: 'X', s: 60, e: 90, d: 127, p: { k: 'yearly' } }] } } }); return 'accepted'; } catch (e) { return e.message; } });
    assert.match(bad, /invalid repeat pattern/);
    await ctx.close();
  });

  await test('overnight tasks run past midnight, and their reminders follow', async () => {
    const { ctx, p } = await open({ now: new Date('2026-11-20T23:00:00'), init: NATIVE_MOCK + "window.__nn.perm='granted';" });
    await p.click('#add-row');
    await p.fill('#ts-name', 'Night shift'); await p.fill('#ts-start', '22:00'); await p.fill('#ts-end', '22:00'); await p.dispatchEvent('#ts-end', 'input');
    assert.match(await p.textContent('#ts-dur'), /must be different/);
    await p.fill('#ts-end', '06:00'); await p.dispatchEvent('#ts-end', 'input');
    assert.match(await p.textContent('#ts-dur'), /Overnight: lasts 8 h and ends the next day\./);
    await p.fill('#ts-start', '23:00'); await p.dispatchEvent('#ts-start', 'input');
    assert.equal(await p.inputValue('#ts-end'), '07:00', 'moving the start keeps the length across midnight');
    await p.click('#task-sheet [data-mask="0"]'); await p.click('#ts-save');
    const row = p.locator('#day-list .task', { hasText: 'Night shift' });
    assert.match(await row.textContent(), /Overnight/);
    assert.match(await row.locator('.task-time').textContent(), /11:00 PM – 7:00 AM/);
    assert.equal(await row.evaluate(r => r.classList.contains('now')), true, 'it is happening at 11 PM');
    await tab(p, 'tools'); await p.check('input[name=notif][value=on]');
    await p.waitForFunction(() => window.__nn.lists.length > 0);
    const list = await lastList(p), nudge = list.find(x => x.id.startsWith('m:2026-11-20:') && x.title === 'Still open: Night shift');
    assert.equal(nudge && nudge.at, '2026-11-21T07:30', 'the missed-task nudge comes after it ends the next morning');
    await ctx.close();
  });

  await test('task notes show under the task and save without asking about repeats', async () => {
    const { ctx, p } = await open();
    await openEdit(p, 'Study');
    await p.fill('#ts-notes', 'Chapter 4\nThen flashcards'); await p.click('#ts-save');
    await p.waitForFunction(() => !document.querySelector('dialog[open]'));
    assert.equal(await p.textContent('#toast-msg'), 'Notes saved.');
    const note = p.locator('#day-list .task', { hasText: 'Study' }).locator('.task-note');
    assert.equal(await note.textContent(), 'Chapter 4');
    assert.equal((await S(p)).tasks.e.n, 'Chapter 4\nThen flashcards');
    await goto(p, '2026-11-19');
    assert.equal(await p.locator('#day-list .task', { hasText: 'Study' }).locator('.task-note').textContent(), 'Chapter 4', 'notes show on every day');
    await p.click('#undo-btn');
    assert.equal((await S(p)).tasks.e.n, undefined);
    await p.click('#add-row'); await p.fill('#ts-name', 'Dentist'); await p.fill('#ts-notes', 'Bring the insurance card');
    await p.click('#task-sheet [data-mask="0"]'); await p.click('#ts-save');
    assert.equal((await S(p)).days['2026-11-19'].a[0].n, 'Bring the insurance card');
    const cleaned = await p.evaluate(() => window.MM.validate({ v: 3, tasks: { a: { o: 1, n: 'hi‮ there\u0000', h: [{ f: '2000-01-01', t: 'X', s: 60, e: 90, d: 127 }] } } }).tasks.a.n);
    assert.equal(cleaned, 'hi there');
    await ctx.close();
  });

  await test('task history counts a task by name, and the Month screen lists every task', async () => {
    const { ctx, p } = await open();
    await p.evaluate(() => { const st = window.MM.state; st.since = '2026-11-02'; st.days['2026-11-16'] = { c: ['2'] }; st.days['2026-11-18'] = { c: ['2'] }; });
    await yogaRow(p).locator('input').check();
    await openEdit(p, 'Yoga'); await p.click('#ts-history'); await p.waitForSelector('#hist-dialog[open]');
    assert.equal(await p.textContent('#hist-title'), 'Yoga');
    const stats = await p.$$eval('#hist-body .mstat', els => els.map(e => e.textContent));
    assert.deepEqual(stats, ['3 of 9This month (33%)', '3 of 9Last 30 days (33%)', '3Current streak (days)', '3Best streak (days)']);
    assert.match(await p.textContent('#hist-body'), /Last done: today/);
    assert.equal(await p.locator('#hist-body .hgrid .done').count(), 3);
    assert.equal(await p.locator('#hist-body .hgrid .miss').count(), 6);
    assert.equal(await p.locator('#hist-body .hgrid .fut').count(), 4, 'Nov 23, 25, 27, and 30 are coming up');
    await p.click('#hist-body [data-hstep="-1"]');
    assert.match(await p.textContent('#hist-body .vnav-title'), /October 2026/);
    assert.equal(await p.locator('#hist-body .hgrid .gap').count(), 31, 'no record before the planner started');
    await p.click('#hist-dialog [data-close]'); await p.click('#task-sheet [data-close]');
    await tab(p, 'month');
    assert.equal(await p.locator('.mtasks li').count(), 8, 'the longest lists are trimmed');
    assert.equal(await p.textContent('.mtasks li'), 'Call family0 of 15 done0%', 'most scheduled first, then by name');
    await p.click('[data-alltasks]');
    assert.ok(await p.locator('.mtasks li').count() > 8);
    const yoga = p.locator('.mtasks li', { has: p.locator('.mg-name > span', { hasText: /^Yoga$/ }) });
    assert.match(await yoga.textContent(), /3 of 9 done/);
    await yoga.locator('[data-hist]').click(); await p.waitForSelector('#hist-dialog[open]');
    assert.equal(await p.textContent('#hist-title'), 'Yoga');
    await p.click('#hist-dialog [data-close]');
    await ctx.close();
  });

  await test('undo keeps many steps, with redo, a header button, and keyboard shortcuts', async () => {
    const { ctx, p } = await open();
    assert.equal(await p.isVisible('#undo-btn'), false);
    for (const name of ['Alpha', 'Bravo', 'Charlie']) {
      await p.click('#add-row'); await p.fill('#ts-name', name); await p.click('#task-sheet [data-mask="0"]'); await p.click('#ts-save');
    }
    assert.deepEqual(await p.evaluate(() => window.MM.undoDepth()), [3, 0]);
    assert.match(await p.getAttribute('#undo-btn', 'aria-label'), /^Undo: Added for Fri, Nov 20 only \(3 changes can be undone\)$/);
    await p.click('#undo-btn');
    assert.equal(await p.textContent('#toast-msg'), 'Undone: Added for Fri, Nov 20 only');
    await p.click('#undo-btn');
    let t = await titles(p); assert.ok(t.includes('Alpha') && !t.includes('Bravo') && !t.includes('Charlie'));
    await p.click('#toast-act');
    t = await titles(p); assert.ok(t.includes('Bravo') && !t.includes('Charlie'), 'redo brings back the last undone step');
    assert.deepEqual(await p.evaluate(() => window.MM.undoDepth()), [2, 1]);
    await p.keyboard.press('Control+z');
    assert.ok(!(await titles(p)).includes('Bravo'));
    await p.keyboard.press('Control+Shift+z');
    assert.ok((await titles(p)).includes('Bravo'));
    await p.click('#add-row'); await p.fill('#ts-name', 'Delta'); await p.click('#task-sheet [data-mask="0"]'); await p.click('#ts-save');
    assert.deepEqual(await p.evaluate(() => window.MM.undoDepth()), [3, 0], 'a new change clears redo');
    for (let i = 0; i < 3; i++) await p.click('#undo-btn');
    assert.equal(await p.isVisible('#undo-btn'), false);
    assert.ok(!(await titles(p)).some(x => /Alpha|Bravo|Delta/.test(x)));
    await ctx.close();
  });

  await test('any task, one-day ones too, can count toward a goal from the task editor', async () => {
    const { ctx, p } = await open();
    await newGoal(p, 'Run 20 times', async () => { await p.check('#gs-use-links'); await p.click('[data-glink="2"]'); await p.fill('#gs-target', '20'); });
    await tab(p, 'day');
    await p.click('#add-row'); await p.fill('#ts-name', 'Run in the park');
    assert.equal(await p.isVisible('#ts-goals-f'), true);
    await p.click('#ts-goals [data-tgoal]'); await p.click('#task-sheet [data-mask="0"]'); await p.click('#ts-save');
    const st = await S(p), id = st.days['2026-11-20'].a.find(a => a.t === 'Run in the park').id, g = Object.values(st.goals)[0];
    assert.deepEqual(g.lk, ['2', id]);
    const run = p.locator('#day-list .task', { has: p.locator('.task-title', { hasText: /^Run in the park$/ }) });
    assert.match(await run.locator('.gbadge').textContent(), /Run 20 times/);
    await run.locator('input').check();
    assert.match(await p.textContent('#toast-msg'), /\+1 toward "Run 20 times": 1 of 20 check-offs/);
    await tab(p, 'goals'); await p.click('#view-goals .goal-name');
    const chip = p.locator('#gs-links [data-glink="' + id + '"]');
    assert.equal(await chip.getAttribute('aria-pressed'), 'true');
    assert.match(await chip.textContent(), /One day: Fri, Nov 20/);
    await p.click('#goal-sheet [data-close]');
    await tab(p, 'day'); await openEdit(p, 'Run in the park');
    await p.click('#ts-goals [data-tgoal]'); await p.click('#ts-save');
    assert.equal(await p.textContent('#toast-msg'), 'Goal links saved.');
    assert.deepEqual(Object.values((await S(p)).goals)[0].lk, ['2']);
    await ctx.close();
  });

  await test('seasons can follow the Southern Hemisphere', async () => {
    const { ctx, p } = await open();
    const names = () => p.evaluate(() => ['2027-S1', '2027-S2', '2027-S3', '2026-S4'].map(window.MM.byName));
    assert.deepEqual(await names(), ['Spring 2027', 'Summer 2027', 'Fall 2027', 'Winter 2026/27']);
    await tab(p, 'tools'); await p.check('input[name=hemi][value=s]');
    assert.deepEqual(await names(), ['Autumn 2027', 'Winter 2027', 'Spring 2027', 'Summer 2026/27']);
    assert.equal((await S(p)).set.hemi, 's');
    await ctx.close();
  });

  await test('goal reminders: a heads-up before the goal date, on the day, and a weekly check-in', async () => {
    const { ctx, p } = await open({ init: NATIVE_MOCK + "window.__nn.perm='granted';" });
    await newGoal(p, 'Finish the course', async () => {
      await p.check('input[name=gs-kind][value=m]'); await p.selectOption('#gs-when', '2026-11');
      await p.check('#gs-use-steps'); await p.fill('[data-gs-step="0"]', 'Week 1'); await p.press('[data-gs-step="0"]', 'Enter'); await p.fill('[data-gs-step="1"]', 'Week 2');
    });
    await tab(p, 'tools'); await p.check('input[name=notif][value=on]');
    await p.waitForFunction(() => window.__nn.lists.length > 0);
    let list = await lastList(p);
    const pick = id => { const x = list.find(r => r.id === id); return x && [x.at, x.title, x.body, x.ch]; };
    assert.deepEqual(pick('g:2026-11:lead'), ['2026-11-23T09:00', 'Goal date in 1 week: By November 2026', 'Finish the course is at 0%.', 'goal']);
    assert.deepEqual(pick('g:2026-11:last'), ['2026-11-30T09:00', 'Goal date today: By November 2026', 'Finish the course is at 0%.', 'goal']);
    assert.deepEqual(pick('w:2026-11-22'), ['2026-11-22T18:00', 'Weekly goal check-in', 'Finish the course 0%.', 'goal']);
    await p.selectOption('#n-weekday', '2'); await p.fill('#n-weekat', '07:30'); await p.dispatchEvent('#n-weekat', 'change');
    await p.waitForFunction(() => { const l = window.__nn.lists[window.__nn.lists.length - 1]; return l.some(x => x.id === 'w:2026-11-25'); });
    list = await lastList(p);
    assert.equal(list.find(x => x.id === 'w:2026-11-25').at, '2026-11-25T07:30');
    await p.selectOption('#n-priv', 'never');
    await p.waitForFunction(() => window.__nn.lists[window.__nn.lists.length - 1].some(x => x.title === 'A goal date is coming up'));
    list = await lastList(p);
    assert.ok(!JSON.stringify(list).includes('Finish the course'), 'no goal names when names are never shown');
    await p.uncheck('#n-goal'); await p.uncheck('#n-week');
    await p.waitForFunction(() => !window.__nn.lists[window.__nn.lists.length - 1].some(x => x.ch === 'goal'));
    await ctx.close();
  });

  await test('home-screen widget gets today and the next two days, and can hide names', async () => {
    const W = NATIVE_MOCK + "window.NativeApp.setWidget=j=>{(window.__nn.w||(window.__nn.w=[])).push(JSON.parse(j));};";
    const { ctx, p } = await open({ init: W });
    await p.waitForFunction(() => window.__nn.w && window.__nn.w.length > 0);
    const last = () => p.evaluate(() => window.__nn.w[window.__nn.w.length - 1]);
    let w = await last();
    assert.deepEqual([w.v, w.names, w.days.map(d => d.d)], [1, true, ['2026-11-20', '2026-11-21', '2026-11-22']]);
    assert.deepEqual([w.days[0].title, w.days[0].done, w.days[0].total, w.days[0].items.length], ['Friday, Nov 20', 0, 13, 13]);
    assert.deepEqual(w.days[0].items[0], { t: 'Water, pray, laundry', tm: '6:00 AM', s: 360, e: 375, c: 0 });
    assert.equal(w.days[1].total, 0);
    await yogaRow(p).locator('input').check();
    await p.waitForFunction(() => window.__nn.w[window.__nn.w.length - 1].days[0].done === 1);
    w = await last(); assert.equal(w.days[0].items.find(x => x.t === 'Yoga').c, 1);
    await tab(p, 'tools');
    assert.match(await p.textContent('#w-status'), /touch and hold an empty spot on your home screen/);
    await p.uncheck('#set-wnames');
    await p.waitForFunction(() => window.__nn.w[window.__nn.w.length - 1].names === false);
    w = await last(); assert.deepEqual(w.days[0].items, []);
    assert.equal(w.days[0].done, 1, 'progress still shows');
    await ctx.close();
    const b = await open();
    await tab(b.p, 'tools');
    assert.match(await b.p.textContent('#w-status'), /part of the Daily Missions Android app/);
    assert.equal(await b.p.isDisabled('#set-wnames'), true);
    await b.ctx.close();
  });

  await test('layout fits phone widths with long names and large text', async () => {
    const { ctx, p } = await open({ viewport: { width: 320, height: 700 } });
    await p.addStyleTag({ content: 'html{font-size:130%}' });
    await p.click('#add-row');
    await p.fill('#ts-name', 'A'.repeat(120)); await p.click('#ts-save');
    await tab(p, 'goals'); await p.click('#view-goals .vnav-actions [data-goal-new]');
    await p.fill('#gs-name', 'B'.repeat(120)); await p.check('#gs-use-steps'); await p.fill('[data-gs-step="0"]', 'C'.repeat(120));
    await p.check('#gs-use-num'); await p.fill('#gs-nv', '123456789'); await p.fill('#gs-nt', '987654321'); await p.fill('#gs-nu', 'D'.repeat(16));
    const sheet = await p.evaluate(() => { const b = document.querySelector('#goal-sheet .sheet-body'); return [b.scrollWidth, b.clientWidth]; });
    assert.equal(sheet[0], sheet[1], 'goal editor scrolls sideways');
    await p.click('#gs-save');
    for (const v of ['day', 'week', 'month', 'goals', 'tools']) {
      await tab(p, v);
      const w = await p.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
      assert.equal(w[0], w[1], v + ' view scrolls sideways');
    }
    await tab(p, 'day'); await p.click('#add-row'); await p.locator('#ts-name').pressSequentially('a');
    const box = await p.locator('#ts-suggest').boundingBox();
    assert.ok(box && box.x >= 0 && box.x + box.width <= 320, 'suggestion list fits the screen');
    await ctx.close();
  });

  await browser.close();
  if (errors.length) { failed++; console.log('  FAIL page errors:\n       ' + errors.join('\n       ')); }
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
