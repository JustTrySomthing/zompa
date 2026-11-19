'use strict';

const canvas = document.getElementById('canvas');
const status = document.getElementById('status');
let runtime;
let pendingMatch;
let saveMounted = false;
let syncing = false;
let started = false;

function showError() {
  status.hidden = false;
  status.textContent = 'This game couldn’t run in Zompado. Go back to the library to try again.';
}

function flushSaves() {
  if (!saveMounted || syncing) return;
  syncing = true;
  runtime.ZompadoFS.syncfs(false, () => { syncing = false; });
}

window.zompadoGame = Object.freeze({
  setMatch(state) {
    pendingMatch = state;
    if (runtime) runtime.ZompadoFS.writeFile('/zompado/match', state);
  },
  takeMove() {
    if (!runtime) return null;
    const fs = runtime.ZompadoFS;
    if (!fs.analyzePath('/zompado/move').exists) return null;
    try {
      if (fs.stat('/zompado/move').size !== 1) return null;
      const value = fs.readFile('/zompado/move', {encoding: 'utf8'});
      return /^[0-6]$/.test(value) ? Number(value) : null;
    } finally {
      fs.unlink('/zompado/move');
    }
  },
  flushSaves,
  start() {
    if (started) return;
    started = true;
    start().catch(showError);
  },
});

async function start() {
  const archive = await fetch('game.love', {cache: 'no-store'});
  if (!archive.ok) throw new Error('Game file unavailable');
  const bytes = new Uint8Array(await archive.arrayBuffer());
  const mode = new URLSearchParams(location.search).get('mode') || 'solo';
  await Love({
    arguments: ['./game.love'],
    canvas,
    locateFile: name => name,
    printErr: console.error.bind(console),
    onAbort: showError,
    preRun: [module => {
      const fs = module.ZompadoFS;
      fs.writeFile('/game.love', bytes);
      fs.mkdir('/zompado');
      fs.writeFile('/zompado/mode', mode);
      if (pendingMatch !== undefined) fs.writeFile('/zompado/match', pendingMatch);
      saveMounted = mode !== 'online' && Boolean(fs.filesystems.IDBFS);
      runtime = module;
    }],
    postRun: [() => { status.hidden = true; }],
  });
}

canvas.addEventListener('contextmenu', event => event.preventDefault());
canvas.addEventListener('webglcontextlost', showError);
window.addEventListener('error', showError);
document.addEventListener('visibilitychange', flushSaves);
setInterval(flushSaves, 2000);
