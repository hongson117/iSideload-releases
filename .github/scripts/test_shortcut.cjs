const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../..');
const script = fs.readFileSync(path.join(root, 'shortcut.js'), 'utf8');
const guestA = 'AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA';
const guestB = 'BBBBBBBB-BBBB-4BBB-BBBB-BBBBBBBBBBBB';

function page(options = {}) {
  const url = new URL(options.url || `https://example.test/shortcut.html?v=5&guest=${guestA}&name=AceSport&slot=runner1`);
  const launches = [];
  const frames = [];
  const elements = new Map();
  const documentEvents = new Map();
  const windowEvents = new Map();
  const location = { search: url.search, hash: url.hash };
  Object.defineProperty(location, 'href', { get: () => url.href, set: target => launches.push(target) });
  const history = {
    state: options.state || null,
    replaceState(state, title, target) {
      if (options.historyFails) throw new Error('History unavailable');
      assert.equal(target, url.href, 'The saved install address must stay unchanged');
      this.state = state;
    }
  };
  const document = {
    visibilityState: 'visible',
    head: { appendChild() {} },
    createElement: () => ({}),
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, { hidden: false, href: 'sicontainer://', events: new Map(), addEventListener(name, callback) { this.events.set(name, callback); } });
      return elements.get(id);
    },
    addEventListener: (name, callback) => documentEvents.set(name, callback)
  };
  const window = {
    location, history,
    performance: { getEntriesByType: () => [{ type: options.navigation || 'navigate' }] },
    matchMedia: () => ({ matches: options.displayStandalone || false }),
    requestAnimationFrame: callback => frames.push(callback),
    addEventListener: (name, callback) => windowEvents.set(name, callback)
  };
  vm.runInNewContext(script, { URLSearchParams, window, document, navigator: { standalone: options.standalone || false } }, { timeout: 1000 });
  function paint() { while (frames.length) frames.shift()(); }
  function restore() {
    document.visibilityState = 'hidden';
    documentEvents.get('visibilitychange')?.();
    document.visibilityState = 'visible';
    documentEvents.get('visibilitychange')?.();
    windowEvents.get('pageshow')?.({ persisted: true });
    paint();
  }
  function click() {
    const button = elements.get('openBtn');
    button.events.get('click')?.();
    launches.push(button.href);
    paint();
  }
  return { launches, elements, history, paint, restore, click, url };
}

test('Safari setup remains stationary through sharing and returning', () => {
  const p = page({ url: `https://example.test/shortcut.html?guest=${guestA}#setup=1&icon=%2B%2F8%3D` });
  p.paint();
  for (let i = 0; i < 20; i++) p.restore();
  assert.equal(p.launches.length, 0);
  assert.equal(p.elements.get('setupSteps').hidden, false);
  assert.equal(p.elements.get('iconImg').src, 'data:image/jpeg;base64,+/8=');
  assert.equal(p.url.hash, '#setup=1&icon=%2B%2F8%3D');
});

test('old setup fragment and unescaped base64 plus remain supported', () => {
  const p = page({ url: `https://example.test/go.html?guest=${guestA}#setup&icon=+/8=` });
  p.paint();
  assert.equal(p.launches.length, 0);
  assert.equal(p.elements.get('iconImg').src, 'data:image/jpeg;base64,+/8=');
});

test('installed shortcut launches via Manager once after the fallback is painted', () => {
  const p = page({ standalone: true, url: `https://example.test/shortcut.html?guest=${guestB}&name=Lich#setup=1` });
  assert.equal(p.launches.length, 0);
  p.paint();
  assert.deepEqual(p.launches, [`sicontainer://launch?guest=${guestB}`]);
  for (let i = 0; i < 20; i++) p.restore();
  assert.equal(p.launches.length, 1);
  assert.ok(p.elements.get('status').textContent.includes('Chạm Mở'));
  p.click();
  assert.equal(p.launches.length, 2);
});

test('manual click before first paint cancels the queued automatic launch', () => {
  const p = page();
  p.click();
  assert.equal(p.launches.length, 1);
});

test('restored, reloaded and previously attempted documents require a fresh tap', () => {
  for (const options of [{ navigation: 'back_forward' }, { navigation: 'reload' }, { state: { sicShortcutAttempt: `${guestA}:runner1` } }]) {
    const p = page(options);
    p.paint(); p.restore();
    assert.equal(p.launches.length, 0);
    p.click();
    assert.equal(p.launches.length, 1);
  }
});

test('a new guest is not suppressed by the previous guest history state', () => {
  const p = page({ state: { sicShortcutAttempt: `${guestA}:runner1` }, url: `https://example.test/shortcut.html?guest=${guestB}` });
  p.paint();
  assert.deepEqual(p.launches, [`sicontainer://launch?guest=${guestB}`]);
});

test('history failure cannot produce a visibility or BFCache loop', () => {
  const p = page({ historyFails: true });
  p.paint(); p.restore(); p.restore();
  assert.equal(p.launches.length, 1);
});

test('invalid guest or unsupported slot produces a visible recovery screen', () => {
  for (const query of ['guest=../wrong', `guest=${guestA}&slot=runner2`, 'name=App']) {
    const p = page({ url: `https://example.test/shortcut.html?${query}` });
    p.paint();
    assert.equal(p.launches.length, 0);
    assert.ok(p.elements.get('status').textContent.includes('tạo lại'));
    assert.equal(p.elements.get('openBtn').href, 'sicontainer://');
  }
});

test('old launched marker remains manual and display-mode standalone handles setup', () => {
  const legacy = page({ url: `https://example.test/go.html?guest=${guestA}&launched=1` });
  legacy.paint();
  assert.equal(legacy.launches.length, 0);
  const installed = page({ displayStandalone: true, url: `https://example.test/shortcut.html?guest=${guestA}#setup` });
  installed.paint();
  assert.equal(installed.launches.length, 1);
});

test('old and new entry pages contain visible fallback and standalone metadata', () => {
  const current = fs.readFileSync(path.join(root, 'shortcut.html'), 'utf8');
  assert.equal(fs.readFileSync(path.join(root, 'go.html'), 'utf8'), current);
  assert.match(current, /apple-mobile-web-app-capable" content="yes"/);
  assert.match(current, /id="openBtn" href="sicontainer:\/\/"/);
  assert.match(current, /shortcut\.js\?v=5/);
});

test('service worker serves offline shell and leaves other requests/caches alone', async () => {
  const events = new Map();
  const stores = new Map([['unrelated-app-cache', new Map()], ['sicontainer-go-v4', new Map()]]);
  let offline = false;
  const caches = {
    keys: async () => [...stores.keys()],
    delete: async key => stores.delete(key),
    async open(name) {
      if (!stores.has(name)) stores.set(name, new Map());
      const entries = stores.get(name);
      return {
        addAll: async urls => { for (const url of urls) entries.set(url, new Response('cached shell')); },
        put: async (url, response) => entries.set(url, response),
        match: async url => entries.get(url)?.clone()
      };
    }
  };
  vm.runInNewContext(fs.readFileSync(path.join(root, 'sw.js'), 'utf8'), {
    URL, Response, caches,
    fetch: async () => { if (offline) throw new Error('Offline'); return new Response('online shell'); },
    self: { location: { href: 'https://example.test/app/sw.js' }, addEventListener: (name, callback) => events.set(name, callback), skipWaiting: async () => {}, clients: { claim: async () => {} } }
  }, { timeout: 1000 });
  for (const name of ['install', 'activate']) {
    const pending = [];
    events.get(name)({ waitUntil: promise => pending.push(promise) });
    await Promise.all(pending);
  }
  assert.ok(stores.has('unrelated-app-cache'));
  assert.ok(!stores.has('sicontainer-go-v4'));
  async function request(url, method = 'GET') {
    const pending = [];
    let response;
    events.get('fetch')({ request: { url, method }, waitUntil: promise => pending.push(promise), respondWith: promise => { response = promise; } });
    const result = await response;
    await Promise.all(pending);
    return result;
  }
  assert.equal(await request('https://example.test/app/app-updates.json'), undefined);
  assert.equal(await request('https://other.test/app/shortcut.html'), undefined);
  assert.equal(await request('https://example.test/app/shortcut.html', 'POST'), undefined);
  assert.equal(await (await request('https://example.test/app/shortcut.html?guest=A')).text(), 'online shell');
  offline = true;
  assert.equal(await (await request('https://example.test/app/shortcut.html?guest=B')).text(), 'online shell');
  assert.equal(await (await request('https://example.test/app/shortcut.js?v=5')).text(), 'cached shell');
  stores.get('sicontainer-shortcuts-v5').clear();
  const missing = await request('https://example.test/app/shortcut.html');
  assert.equal(missing.status, 503);
  assert.ok((await missing.text()).length > 0);
});
