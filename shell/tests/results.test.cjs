const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
function page() {
  let calls = 0, fail = false, event;
  const context = vm.createContext({
    navigator: {platform: 'Win32'}, location: {pathname: '/window.html'},
    window: {__TAURI__: {
      core: {invoke: async () => { calls++; if (fail) throw Error('transient'); return {image: `preview-${calls}`}; },
             convertFileSrc: value => value},
      path: {homeDir: async () => 'C:/Users/demo'},
      event: {listen: (name, handler) => { event = handler; return Promise.resolve(() => {}); }}
    }}
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../ui/results.js'), 'utf8'), context);
  return {render: (...args) => context.rendered(...args), calls: () => calls, fail: value => { fail = value; },
          generation: value => event({payload: {from: 'search', event: {event: 'generation', generation: value}}}),
          count: () => vm.runInContext('renders.size', context)};
}
test('preview identity includes file version and helper generation', async () => {
  const p = page();
  assert.equal(await p.render('photo', 'image', null, 240, 1, 10), 'preview-1');
  assert.equal(await p.render('photo', 'image', null, 240, 1, 10), 'preview-1');
  assert.equal(await p.render('photo', 'image', null, 240, 2, 10), 'preview-2');
  p.generation(2);
  assert.equal(await p.render('photo', 'image', null, 240, 2, 10), 'preview-3');
  assert.equal(p.calls(), 3);
  p.generation(1); // a delayed event from an older reader must not invalidate current previews
  assert.equal(await p.render('photo', 'image', null, 240, 2, 10), 'preview-3');
  assert.equal(p.calls(), 3);
});
test('transient render failures are retried', async () => {
  const p = page(); p.fail(true);
  await assert.rejects(p.render('video', 'video', 1, 240), /transient/);
  p.fail(false);
  assert.equal(await p.render('video', 'video', 1, 240), 'preview-2');
});
test('preview cache stays bounded and retains recently used entries', async () => {
  const p = page();
  for (let i = 0; i < 256; i++) await p.render(`image-${i}`, 'image', null, 240);
  await p.render('image-0', 'image', null, 240);
  await p.render('image-256', 'image', null, 240);
  assert.equal(p.count(), 256);
  const before = p.calls();
  await p.render('image-0', 'image', null, 240);
  assert.equal(p.calls(), before);
  await p.render('image-1', 'image', null, 240);
  assert.equal(p.calls(), before + 1);
});
