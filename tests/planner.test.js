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
  if (opts.init) await ctx.addInitScript(opts.init);
  const p = await ctx.newPage();
  p.on('pageerror', e => errors.push('pageerror: ' + e.message));
  await p.goto(opts.url || URL);
  await p.waitForSelector('#day-list .task, #day-list .empty');
  return { ctx, p };
}
const S = p => p.evaluate(() => JSON.parse(JSON.stringify(window.MM.state)));
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
    assert.equal(await bg(), 'rgb(232, 237, 243)');
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

  await test('layout fits phone widths with long names and large text', async () => {
    const { ctx, p } = await open({ viewport: { width: 320, height: 700 } });
    await p.addStyleTag({ content: 'html{font-size:130%}' });
    await p.click('#add-row');
    await p.fill('#ts-name', 'A'.repeat(120)); await p.click('#ts-save');
    for (const v of ['day', 'week', 'month', 'tools']) {
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
