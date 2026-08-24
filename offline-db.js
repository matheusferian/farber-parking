// ══════════════════════════════════════════════════════════════════════
// AirValet — Offline Mode Phase 1: IndexedDB infrastructure.
//
// Phase 1 scope only: opens the database and exposes minimal CRUD for
// the `offline_checkins` store, used ONLY by the diagnostics panel to
// write/read/delete synthetic test records. Nothing in the normal
// New Entry path (saveEntry()) calls into this file yet — that's Phase 2.
// No real passenger data is ever written here in Phase 1.
// ══════════════════════════════════════════════════════════════════════

var OFFLINE_DB_NAME = 'airvalet_offline';
var OFFLINE_DB_VERSION = 1;
var OFFLINE_STORE_CHECKINS = 'offline_checkins';

var _offlineDbPromise = null;

function openOfflineDb(){
  if(_offlineDbPromise) return _offlineDbPromise;
  _offlineDbPromise = new Promise(function(resolve, reject){
    if(!('indexedDB' in window)){
      reject(new Error('IndexedDB not supported in this browser'));
      return;
    }
    var req = indexedDB.open(OFFLINE_DB_NAME, OFFLINE_DB_VERSION);
    req.onupgradeneeded = function(e){
      var db = e.target.result;
      if(!db.objectStoreNames.contains(OFFLINE_STORE_CHECKINS)){
        var store = db.createObjectStore(OFFLINE_STORE_CHECKINS, {keyPath:'offline_sync_id'});
        store.createIndex('syncState', 'syncState', {unique:false});
        store.createIndex('createdAt', 'createdAt', {unique:false});
      }
    };
    req.onsuccess = function(e){ resolve(e.target.result); };
    req.onerror = function(e){ reject(e.target.error || new Error('IndexedDB open failed')); };
  });
  return _offlineDbPromise;
}

function offlineDbTx(storeName, mode){
  return openOfflineDb().then(function(db){
    return db.transaction(storeName, mode).objectStore(storeName);
  });
}

// ── Minimal CRUD — diagnostics-only in Phase 1 ──────────────────────
function offlineCheckinPut(record){
  return offlineDbTx(OFFLINE_STORE_CHECKINS, 'readwrite').then(function(store){
    return new Promise(function(resolve, reject){
      var req = store.put(record);
      req.onsuccess = function(){ resolve(record); };
      req.onerror = function(e){ reject(e.target.error); };
    });
  });
}

function offlineCheckinGetAll(){
  return offlineDbTx(OFFLINE_STORE_CHECKINS, 'readonly').then(function(store){
    return new Promise(function(resolve, reject){
      var req = store.getAll();
      req.onsuccess = function(e){ resolve(e.target.result || []); };
      req.onerror = function(e){ reject(e.target.error); };
    });
  });
}

function offlineCheckinDelete(offlineSyncId){
  return offlineDbTx(OFFLINE_STORE_CHECKINS, 'readwrite').then(function(store){
    return new Promise(function(resolve, reject){
      var req = store.delete(offlineSyncId);
      req.onsuccess = function(){ resolve(true); };
      req.onerror = function(e){ reject(e.target.error); };
    });
  });
}

// Builds a synthetic, clearly-fake diagnostics-only test record —
// never used for a real check-in. Phase 2 will introduce the real
// queueCheckin(payload) that saveEntry() calls; this is not that.
function offlineBuildDebugTestRecord(){
  return {
    offline_sync_id: (crypto && crypto.randomUUID) ? crypto.randomUUID() : String(Date.now())+'-'+Math.random(),
    payload: {name:'DIAGNOSTIC TEST RECORD', ticket:'TEST', note:'Phase 1 infrastructure test — not a real check-in'},
    createdAt: new Date().toISOString(),
    syncState: 'LOCAL_PENDING',
    serverPassengerId: null,
    attemptCount: 0,
    lastAttemptAt: null,
    lastError: null,
    deviceId: (typeof getOfflineDeviceId === 'function') ? getOfflineDeviceId() : null
  };
}
