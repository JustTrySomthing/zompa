const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('android/app/src/main/assets/love/player.js', 'utf8');
const context = {
  window: { addEventListener() {} },
  document: { getElementById: () => ({ addEventListener() {} }), addEventListener() {} },
  URLSearchParams, location: { search: '?mode=online' }, setInterval() {},
};
vm.createContext(context);
vm.runInContext(source, context);
const game = context.window.zompaGame;
const bridge = '/zompado/';
const files = new Map();
function mount() {
  context.fakeRuntime = { ZompaFS: { writeFile: (name, data) => files.set(name, data), unlink: name => files.delete(name) } };
  vm.runInContext('runtime = fakeRuntime; publishMatchPages();', context);
}
const tokens = Array.from({length: 4097}, (_, i) => String(i).padStart(256, 'x'));
for (let i = 0; i < 32; i++) {
  const page = tokens.slice(i * 128, (i + 1) * 128).join(',');
  assert.equal(page.length, 32895);
  game.stageMatchPage(i, page);
}
game.commitMatchPages('2:1:32', 'Opponent');
assert.equal(files.size, 0);
game.stageMatchPage(31, 'uncommitted_at_startup');
mount();
assert.equal(files.get(bridge + 'match-pages'), '2:1:32');
const firstRevision = files.get(bridge + 'match-revision');
game.stageMatchPage(31, 'staged');
game.setOpponentName('Updated opponent');
assert.equal(files.get(bridge + 'opponent'), 'Updated opponent');
assert.equal(files.get(bridge + 'match-page-31').split(',').at(-1), tokens[4095]);
game.stageMatchPage(31, tokens.slice(3968, 4096).join(','));
assert.equal(files.get(bridge + 'match-page-31').split(',').at(-1), tokens[4095]);
game.stageMatchPage(32, tokens[4096]);
assert.equal(files.has(bridge + 'match-page-32'), false);
game.commitMatchPages('2:0:33', 'Opponent');
assert.equal(files.get(bridge + 'match-page-32'), tokens[4096]);
assert.equal(files.get(bridge + 'match-pages'), '2:0:33');
const appendedRevision = files.get(bridge + 'match-revision');
game.commitMatchPages('2:1:33', 'Updated opponent');
assert.equal(files.get(bridge + 'match-revision'), appendedRevision);
game.commitMatchPages('1:1:32', 'Opponent');
assert.equal(files.get(bridge + 'match-pages'), '1:1:32');
assert.equal(files.has(bridge + 'match-page-32'), false);
assert.notEqual(files.get(bridge + 'match-revision'), firstRevision);
console.log('PASS: 4097 maximum-size turns, startup delivery, atomic append and rollback.');
