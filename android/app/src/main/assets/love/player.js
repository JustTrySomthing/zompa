'use strict';

const canvas = document.getElementById('canvas');
const status = document.getElementById('status');
let runtime;
let pendingMatch;
let isPaused = false;
let gameRunning = false;
let audio = [100, 100, 100];

function applyAudio() {
  if (!runtime) return;
  const [volume, music, effects] = audio;
  runtime.ZompaFS.writeFile('/zompado/audio', `${music}:${effects}`);
  runtime.setZompaVolume(isPaused ? 0 : volume / 100);
}
let saveMounted = false;
let syncing;
let exiting = false;
const launch = new URLSearchParams(location.search);
const mode = launch.get('mode') || 'solo';
const build = Number(launch.get('build'));
const managesSave = mode !== 'online' && launch.get('save') !== null;
const fresh = launch.get('save') === 'new';
let setReady;
const ready = new Promise(resolve => { setReady = resolve; });
let started = false;

function showError() {
  setReady(false);
  status.hidden = false;
  status.textContent = 'This game couldn’t run in Zompa. Go back to the library to try again.';
}

function flushSaves() {
  if (!saveMounted) return Promise.resolve();
  syncing ??= new Promise((resolve, reject) => {
    runtime.ZompaFS.syncfs(false, error => {
      if (error) reject(error);
      else resolve();
    });
  }).finally(() => { syncing = undefined; });
  return syncing;
}

function autosave() {
  if (gameRunning && !exiting) flushSaves().catch(console.error);
}

window.zompaGame = Object.freeze({
  setMatch(state) {
    pendingMatch = state;
    if (runtime) runtime.ZompaFS.writeFile('/zompado/match', state);
  },
  setAudio(settings) {
    if (typeof settings !== 'string' || !/^(100|[1-9]?[0-9]):(100|[1-9]?[0-9]):(100|[1-9]?[0-9])$/.test(settings)) return;
    audio = settings.split(':').map(Number);
    applyAudio();
  },
  setPaused(paused) {
    if (isPaused === paused) return;
    isPaused = paused;
    if (paused) autosave();
    if (gameRunning) {
      if (paused) runtime.pauseMainLoop();
      else runtime.resumeMainLoop();
    }
    applyAudio();
  },
  takeMove() {
    if (!runtime) return null;
    const fs = runtime.ZompaFS;
    if (!fs.analyzePath('/zompado/move').exists) return null;
    try {
      if (fs.stat('/zompado/move').size !== 1) return null;
      const value = fs.readFile('/zompado/move', {encoding: 'utf8'});
      return /^[0-6]$/.test(value) ? Number(value) : null;
    } finally {
      fs.unlink('/zompado/move');
    }
  },
  flushSaves: autosave,
  async leave(quit) {
    if (!managesSave || exiting) return;
    exiting = true;
    document.title = 'Zompa player';
    this.setPaused(true);
    try {
      if (!gameRunning && !quit) {
        document.title = 'zompa-save:ok';
        return;
      }
      if (!await ready) throw new Error('Game not available');
      await syncing;
      if (quit && saveMounted) clearLocalSave(runtime.ZompaFS, mode, build);
      await flushSaves();
      document.title = 'zompa-save:ok';
    } catch (_) {
      exiting = false;
      document.title = 'zompa-save:error';
    }
  },
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
  await Love({
    arguments: ['./game.love'],
    canvas,
    locateFile: name => name,
    printErr: console.error.bind(console),
    onAbort: showError,
    zompaManagedSaves: managesSave,
    onZompaSavesLoaded: (error, fs) => {
      if (!managesSave) return;
      if (error) {
        showError();
        throw error;
      }
      if (fresh) clearLocalSave(fs, mode, build);
    },
    preRun: [module => {
      const fs = module.ZompaFS;
      fs.writeFile('/game.love', bytes);
      fs.mkdir('/zompa');
      fs.writeFile('/zompado/mode', mode);
      if (pendingMatch !== undefined) fs.writeFile('/zompado/match', pendingMatch);
      saveMounted = mode !== 'online' && Boolean(fs.filesystems.IDBFS);
      runtime = module;
      applyAudio();
    }],
    postRun: [() => {
      gameRunning = true;
      setReady(true);
      if (managesSave && fresh) {
        if (build > 0 && mode === 'local') runtime.ZompaFS.writeFile(dropFourLocalStarted, '');
        autosave();
      }
      if (isPaused) runtime.pauseMainLoop();
      status.hidden = true;
    }],
  });
}

canvas.addEventListener('contextmenu', event => event.preventDefault());
canvas.addEventListener('webglcontextlost', showError);
window.addEventListener('error', showError);
document.addEventListener('visibilitychange', autosave);
setInterval(autosave, 2000);
