'use strict';

// The pinned LÖVE runtime mounts this IndexedDB store for each game's origin.
const dropFourSaveRoot = '/home/web_user/love';
const dropFourLocalStarted = dropFourSaveRoot + '/.zompado-local-started';

function dropFourSaveKind(path, mode) {
  if (path.endsWith('/zompado-drop-four/zompado-saves/cats-' + mode)) return 'current';
  if (path.endsWith('/zompado-drop-four/' + mode + '.save')) return 'legacy';
  if (mode === 'local' && path === dropFourLocalStarted) return 'started';
  return null;
}

function dropFourUnfinished(history) {
  if (!/^[1-7]{0,41}$/.test(history)) return false;
  const columns = Array.from({length: 7}, () => []);
  for (let move = 0; move < history.length; move++) {
    const x = Number(history[move]) - 1;
    const y = columns[x].length;
    if (y === 6) return false;
    const side = move % 2;
    columns[x].push(side);
    for (const [dx, dy] of [[1, 0], [0, 1], [1, 1], [1, -1]]) {
      let count = 1;
      for (const direction of [-1, 1]) {
        let cx = x + dx * direction;
        let cy = y + dy * direction;
        while (columns[cx]?.[cy] === side) {
          count++;
          cx += dx * direction;
          cy += dy * direction;
        }
      }
      if (count >= 4) return false;
    }
  }
  return true;
}

function sessionFile(mode) {
  return dropFourSaveRoot + '/.zompado-session-' + mode;
}

function readLocalSaves(build, modes) {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open(dropFourSaveRoot);
    open.onupgradeneeded = () => open.transaction.abort();
    open.onerror = () => {
      if (open.error?.name === 'AbortError') resolve([]);
      else reject(open.error);
    };
    open.onsuccess = () => {
      const db = open.result;
      if (!db.objectStoreNames.contains('FILE_DATA')) {
        db.close();
        resolve([]);
        return;
      }
      const transaction = db.transaction('FILE_DATA');
      const saves = Object.fromEntries(modes.map(mode => [mode, {}]));
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => {
        db.close();
        reject(transaction.error);
      };
      transaction.oncomplete = () => {
        db.close();
        resolve(modes.filter(mode => {
          const {session, current, legacy, started} = saves[mode];
          if (session !== undefined) return session;
          if (build === 0) return false;
          const saved = build >= 6 ? current : undefined;
          if (saved !== undefined) {
            const match = /^1:[12]:[123]:[0-2]:[0-2]:([1-7]*)$/.exec(saved);
            return match !== null && dropFourUnfinished(match[1]);
          }
          if (legacy !== undefined) return legacy.length > 0 && dropFourUnfinished(legacy);
          return started === '';
        }));
      };
      const store = transaction.objectStore('FILE_DATA');
      const keys = store.getAllKeys();
      keys.onsuccess = () => {
        for (const path of keys.result) {
          if (typeof path !== 'string') continue;
          for (const mode of modes) {
            const kind = path === sessionFile(mode)
              ? 'session'
              : build > 0 ? dropFourSaveKind(path, mode) : null;
            if (!kind) continue;
            const file = store.get(path);
            file.onsuccess = () => {
              const contents = file.result?.contents;
              saves[mode][kind] = kind === 'session'
                ? Boolean(contents && contents.length > 0 && contents.length <= 262144)
                : contents && contents.length <= 64
                  ? new TextDecoder().decode(contents)
                  : 'invalid';
            };
          }
        }
      };
    };
  });
}

function localSavePaths(mode, build) {
  const paths = [sessionFile(mode)];
  if (build === 0) return paths;
  if (mode === 'local') paths.push(dropFourLocalStarted);
  for (const directory of [dropFourSaveRoot, dropFourSaveRoot + '/love']) {
    const game = directory + '/zompado-drop-four';
    paths.push(game + '/zompado-saves/cats-' + mode, game + '/' + mode + '.save');
  }
  return paths;
}

function clearLocalSave(fs, mode, build) {
  for (const path of localSavePaths(mode, build)) {
    if (fs.analyzePath(path).exists) fs.unlink(path);
  }
}

function discardLocalSave(mode, build) {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open(dropFourSaveRoot);
    open.onupgradeneeded = () => open.transaction.abort();
    open.onerror = () => {
      if (open.error?.name === 'AbortError') resolve();
      else reject(open.error);
    };
    open.onsuccess = () => {
      const db = open.result;
      if (!db.objectStoreNames.contains('FILE_DATA')) {
        db.close();
        resolve();
        return;
      }
      const transaction = db.transaction('FILE_DATA', 'readwrite');
      transaction.oncomplete = () => {
        db.close();
        resolve();
      };
      transaction.onabort = () => {
        db.close();
        reject(transaction.error);
      };
      const store = transaction.objectStore('FILE_DATA');
      for (const path of localSavePaths(mode, build)) store.delete(path);
    };
  });
}
