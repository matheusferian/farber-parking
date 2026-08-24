// ══════════════════════════════════════════════════════════════════════
// AirValet — Offline Mode: IndexedDB infrastructure.
//
// v1 (Phase 1): `offline_checkins` store, diagnostics-only.
// v2 (Phase 2): adds `server_snapshot` (last-known-good passenger list,
// written only after a successful loadData(), read on cold offline
// launch so ticket-number math has a starting point) and the real
// (non-diagnostic) check-in queueing helpers that saveEntry() now uses
// when offline. `offline_checkins` records written for a real check-in
// carry isOfflinePending:true and a deterministic negative `localId`
// (see offlineLocalIdFromSyncId) so they can be merged into the in-memory
// `data` array as ordinary-looking rows without ever colliding with a
// real Supabase bigint id.
// ══════════════════════════════════════════════════════════════════════

var OFFLINE_DB_NAME = 'airvalet_offline';
var OFFLINE_DB_VERSION = 2;
var OFFLINE_STORE_CHECKINS = 'offline_checkins';
var OFFLINE_STORE_SNAPSHOT = 'server_snapshot';
var OFFLINE_SNAPSHOT_KEY = 'current';

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
      if(!db.objectStoreNames.contains(OFFLINE_STORE_SNAPSHOT)){
        // Out-of-line key (fixed key OFFLINE_SNAPSHOT_KEY) — always exactly
        // one row: the most recent successful loadData() result.
        db.createObjectStore(OFFLINE_STORE_SNAPSHOT);
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

// ── offline_checkins CRUD — used by both diagnostics and (from Phase 2
// onward) real emergency check-ins queued by saveEntry() ────────────
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

// ── Server snapshot — last-known-good passenger list ────────────────
// Written by index.html's loadData() ONLY after a successful sbGet(), so
// it always reflects real server state as of the last time we were
// online. Never written on a failed/offline load. Read on cold offline
// launch (and by the offline ticket-number calculation) so the app has
// a starting point for "what tickets already exist today" without
// needing the network. Fixed out-of-line key: exactly one row exists.
function offlineSnapshotSave(passengerArray){
  return offlineDbTx(OFFLINE_STORE_SNAPSHOT, 'readwrite').then(function(store){
    return new Promise(function(resolve, reject){
      var req = store.put({data: passengerArray, savedAt: new Date().toISOString()}, OFFLINE_SNAPSHOT_KEY);
      req.onsuccess = function(){ resolve(true); };
      req.onerror = function(e){ reject(e.target.error); };
    });
  });
}

function offlineSnapshotLoad(){
  return offlineDbTx(OFFLINE_STORE_SNAPSHOT, 'readonly').then(function(store){
    return new Promise(function(resolve, reject){
      var req = store.get(OFFLINE_SNAPSHOT_KEY);
      req.onsuccess = function(e){ resolve(e.target.result || null); };
      req.onerror = function(e){ reject(e.target.error); };
    });
  });
}

// ── Local (pending, not-yet-synced) passenger identity ───────────────
// A pending offline check-in has no real Supabase bigint id yet — it
// must never be sent through a server mutation as if it did (see
// isOfflinePendingId(), used by sbUpdate()/changePassengerReturnDate()/
// deletePassengerWithLog() in index.html to reject exactly that). This
// derives a small, deterministic NEGATIVE integer from offline_sync_id:
// negative so it can never collide with a real (always positive)
// Supabase id, and a plain number (not a UUID string) so it drops
// safely into the existing onclick="fn(123)"-style numeric-literal HTML
// attributes used throughout the app's card rendering.
function offlineLocalIdFromSyncId(syncId){
  var s = String(syncId || '');
  var h = 5381;
  for(var i=0; i<s.length; i++){ h = ((h*33) ^ s.charCodeAt(i)) >>> 0; }
  return -1 * ((h % 999999999) + 1); // always negative, never 0
}

function isOfflinePendingId(id){
  return typeof id === 'number' && id < 0;
}

// Single shared copy of the required user-facing copy for "this action
// isn't allowed yet because the record hasn't reached the server." Used
// both by the centralized guard inside sbUpdate()/changePassengerReturnDate()/
// deletePassengerWithLog() (index.html) and by the UX-layer pre-checks at
// the main action entry points (Deliver/Customs/Lockbox/H19/Welcome
// Back/inline edit/Archive), so the wording never drifts between the two.
var OFFLINE_PENDING_SYNC_MSG = 'Available after synchronization.';
function offlinePendingBlockError(){
  return new Error(OFFLINE_PENDING_SYNC_MSG);
}

// ── Real (non-diagnostic) check-in queueing ──────────────────────────
// Builds the actual IndexedDB record for a real emergency offline
// check-in. `payload` is the same field shape saveEntry() already sends
// to sbInsert() online (ts, checkin_date, name, phone, ticket, ret, car,
// color, loc, status, block, obs, not_returning_with_makers_air,
// deldate) — kept identical on purpose so mapPassengerRow() in
// index.html can shape a pending record exactly like a server row once
// localId is substituted for id.
function offlineBuildCheckinRecord(payload){
  var syncId = (crypto && crypto.randomUUID) ? crypto.randomUUID() : (String(Date.now())+'-'+Math.random());
  return {
    offline_sync_id: syncId,
    payload: payload,
    createdAt: new Date().toISOString(),
    syncState: 'LOCAL_PENDING',
    serverPassengerId: null,
    isOfflinePending: true,
    attemptCount: 0,
    lastAttemptAt: null,
    lastError: null,
    deviceId: (typeof getOfflineDeviceId === 'function') ? getOfflineDeviceId() : null,
    deviceCode: (typeof getOfflineDeviceCode === 'function') ? getOfflineDeviceCode() : '',
    localId: offlineLocalIdFromSyncId(syncId)
  };
}

// Builds a synthetic, clearly-fake diagnostics-only test record —
// never used for a real check-in. This is separate from
// offlineBuildCheckinRecord() above (the real one saveEntry() uses).
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
