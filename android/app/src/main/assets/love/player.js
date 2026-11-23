'use strict';

const canvas = document.getElementById('canvas');
const status = document.getElementById('status');
// Published Lua games read and write the original bridge directory.
const bridgeDirectory = '/zompado';
let runtime;
let pendingMatch;
let opponentName = '';
let genericTurns = false;
let isPaused = false;
let gameRunning = false;
let audio = [100, 100, 100];

function applyAudio() {
  if (!runtime) return;
  const [volume, music, effects] = audio;
  runtime.ZompaFS.writeFile(`${bridgeDirectory}/audio`, `${music}:${effects}`);
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
  setMatch(state, turns, name) {
    opponentName = typeof name === 'string' ? name : '';
    genericTurns = turns === true;
    pendingMatch = state;
    if (runtime) {
      runtime.ZompaFS.writeFile(`${bridgeDirectory}/match`, state);
      runtime.ZompaFS.writeFile(`${bridgeDirectory}/opponent`, opponentName);
    }
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
    if (!fs.analyzePath(`${bridgeDirectory}/move`).exists) return null;
    try {
      const size = fs.stat(`${bridgeDirectory}/move`).size;
      if (genericTurns ? size < 3 || size > 258 : size !== 1) return null;
      const value = fs.readFile(`${bridgeDirectory}/move`, {encoding: 'utf8'});
      if (genericTurns) return /^[-012]:[A-Za-z0-9_-]{1,256}$/.test(value) ? value : null;
      return /^[0-6]$/.test(value) ? Number(value) : null;
    } finally {
      fs.unlink(`${bridgeDirectory}/move`);
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
      fs.mkdir(bridgeDirectory);
      fs.writeFile(`${bridgeDirectory}/mode`, mode);
      if (pendingMatch !== undefined) {
        fs.writeFile(`${bridgeDirectory}/match`, pendingMatch);
        fs.writeFile(`${bridgeDirectory}/opponent`, opponentName);
      }
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
