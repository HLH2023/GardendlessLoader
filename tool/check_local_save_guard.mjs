#!/usr/bin/env node
/**
 * 本机存档版本保护（local_save_guard.dart）行为验收。
 *
 * 为什么需要：这段脚本只在 WebView/CEF 里跑，Dart 静态检查看不出状态机
 * 错误。oracle-sol review 依次抓到过：
 *   - 降级后 context 没推进 → 第二次启动把低版本进度写进高版本备份再清空；
 *   - 备份没有账号维度 → 换账号后 Bob 恢复出 Alice 的存档；
 *   - generation 待上传槽逃过版本隔离；
 *   - guard 遍历归档无主 generation 槽 → Alice 的孤立队列被记到 Bob 名下；
 *   - 归档写失败仍清源 → 唯一副本被删。
 *
 * 用法：node tool/check_local_save_guard.mjs
 * 依赖：dart（或 DART 环境变量指定的可执行文件）
 */
'use strict';
import { execFileSync } from 'node:child_process';
import vm from 'node:vm';

const DART = process.env.DART || 'dart';
let pass = 0;
let fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? ' -> ' + extra : '')); }
}

function scriptFor(version) {
  const out = execFileSync(DART, ['run', 'tool/dump_local_save_guard.dart', version], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  const at = out.indexOf(';(function(){');
  if (at < 0) throw new Error('guard script not found in dart output');
  return out.slice(at);
}

function makeStore(initial) {
  return new Map(Object.entries(initial || {}));
}

// 归档键名与 local_save_guard.dart 保持一致：账号 + 版本 + 原键名。
function gameArchive(user, ver, key) { return '__pvzBlocked_' + user + '_' + ver + '_' + key; }
function stateArchive(user, ver, key) { return '__pvzState_' + user + '_' + ver + '_' + key; }
const ANON = '_anon';

function runGuard(store, script, opts) {
  const failSet = opts && opts.failSet;
  const dropSet = opts && opts.dropSet;
  class Storage {
    get length() { return store.size; }
    key(i) {
      const keys = Array.from(store.keys());
      return i >= 0 && i < keys.length ? keys[i] : null;
    }
    getItem(k) { return store.has(String(k)) ? store.get(String(k)) : null; }
    setItem(k, v) {
      if (failSet && failSet(String(k))) throw new Error('quota exceeded');
      // 静默丢弃：不抛异常也不落盘，模拟隐私模式/被截断的存储层。
      if (dropSet && dropSet(String(k))) return;
      store.set(String(k), String(v));
    }
    removeItem(k) { store.delete(String(k)); }
  }
  const localStorage = new Storage();
  // document/window 只用于归档失败后的「阻断目标版本」出口：读/写门闩与
  // 停止解析。guard 本身只用到 getElementById/createElement/body/
  // documentElement/stop，测试桩保持最小。
  const byId = new Map();
  const documentStub = {
    body: null,
    documentElement: {
      children: [],
      appendChild(el) { this.children.push(el); if (el.id) byId.set(el.id, el); },
    },
    getElementById(id) { return byId.get(id) || null; },
    createElement() {
      return {
        id: '', textContent: '', attributes: {},
        setAttribute(k, v) { this.attributes[k] = v; },
      };
    },
  };
  const ctx = {
    localStorage,
    Storage,
    document: documentStub,
    window: {
      localStorage,
      stop() { ctx.__stopped = true; },
    },
    console,
  };
  vm.createContext(ctx);
  vm.runInContext(script, ctx);
  return ctx;
}

const GAME = 'PvZ2_PlayerProperties';
const guard20 = scriptFor('2.0');
const guard10 = scriptFor('1.0');

// 1) 首次启动：只记录上下文，不动存档
{
  const store = makeStore({ [GAME]: 'keep' });
  runGuard(store, guard10);
  check('首次启动只记录版本上下文', store.get(GAME) === 'keep' &&
    JSON.parse(store.get('__pvzSaveContext')).gameVersion === '1.0');
}

// 2) 2.0 → 1.0：高版本内容备份、活动键清空、同步队列按版本隔离
{
  const store = makeStore({
    __pvzSaveContext: JSON.stringify({ gameVersion: '2.0', at: 1 }),
    [GAME]: 'high-save',
    PvZ2_Settings: 'high-settings',
    __pvzPending: JSON.stringify({ [GAME]: 'high-pending' }),
  });
  runGuard(store, guard10);
  check('降级把高版本存档备份到账号+版本键',
    store.get(gameArchive(ANON, '2.0', GAME)) === 'high-save');
  check('降级清空活动键（旧游戏看不到高版本内容）', !store.has(GAME));
  check('降级把待上传队列按版本归档', !store.has('__pvzPending') &&
    store.get(stateArchive(ANON, '2.0', '__pvzPending')).includes('high-pending'));
  check('降级后上下文推进到低版本',
    JSON.parse(store.get('__pvzSaveContext')).gameVersion === '1.0');

  // 3) 第二次启动同一低版本：不能重复清空/覆盖备份（review P0）
  store.set(GAME, 'low-save');
  store.set('__pvzPending', JSON.stringify({ [GAME]: 'low-pending' }));
  runGuard(store, guard10);
  check('连续启动同版本保留低版本进度', store.get(GAME) === 'low-save');
  check('连续启动同版本不覆盖高版本备份',
    store.get(gameArchive(ANON, '2.0', GAME)) === 'high-save');
  check('连续启动同版本不丢低版本待上传队列',
    store.get('__pvzPending').includes('low-pending'));

  // 4) 再升级到 2.0：恢复 2.0 自己的内容，而不是把低版本留在活动键
  runGuard(store, guard20);
  check('升级恢复目标版本已有本地存档', store.get(GAME) === 'high-save');
  check('升级把低版本进度留档',
    store.get(gameArchive(ANON, '1.0', GAME)) === 'low-save');
  check('升级恢复目标版本的同步队列', store.get('__pvzPending') === null ||
    store.get('__pvzPending').includes('high-pending'));

  // 5) 再降级：低版本内容回来，高版本备份仍是高版本
  runGuard(store, guard10);
  check('再次降级恢复低版本自己的进度', store.get(GAME) === 'low-save');
  check('再次降级不把低版本写进高版本备份',
    store.get(gameArchive(ANON, '2.0', GAME)) === 'high-save');
}

// 6) 首次升级且目标版本没有本地备份：保留活动内容供新版本继承
{
  const store = makeStore({
    __pvzSaveContext: JSON.stringify({ gameVersion: '1.0', at: 1 }),
    [GAME]: 'inherit-me',
  });
  runGuard(store, guard20);
  check('首次升级保留活动内容供新版本继承', store.get(GAME) === 'inherit-me');
  check('首次升级把旧版本内容留档',
    store.get(gameArchive(ANON, '1.0', GAME)) === 'inherit-me');
}

// 7) 账号维度：Alice 的备份不能被同一设备上的 Bob 恢复
{
  const store = makeStore({
    __pvzSyncUser: 'alice',
    __pvzSaveContext: JSON.stringify({ gameVersion: '2.0', at: 1 }),
    [GAME]: 'alice-high',
    PvZ2_Settings: 'alice-settings',
  });
  runGuard(store, guard10);
  check('账号维度：Alice 降级把存档备份到 alice 前缀',
    store.get(gameArchive('alice', '2.0', GAME)) === 'alice-high');
  check('账号维度：Alice 降级后活动区不再有高版本内容',
    !store.has(GAME) && !store.has('PvZ2_Settings'));

  store.set('__pvzSyncUser', 'bob');
  runGuard(store, guard20); // Bob 进 2.0，没有 bob 的 2.0 备份
  check('账号维度：Bob 进 2.0 不恢复 Alice 的备份',
    !store.has(GAME), store.get(GAME));
  runGuard(store, guard10); // Bob 再降回 1.0
  check('账号维度：Bob 降级不恢复 Alice 的备份', !store.has(GAME));
  check('账号维度：Bob 降级不认领也不覆盖 Alice 的备份键',
    store.get(gameArchive('alice', '2.0', GAME)) === 'alice-high' &&
    !store.has(gameArchive('bob', '2.0', GAME)));
}

// 8) 当前代的待上传槽随版本移出活动区；无主槽不动
{
  const store = makeStore({
    __pvzSaveContext: JSON.stringify({ gameVersion: '2.0', at: 1 }),
    [GAME]: 'high-save',
    __pvzPending: JSON.stringify({ other: 'keep' }),
    __pvzSyncGeneration: 'g1',
    '__pvzPending:g1': JSON.stringify({ a: 1 }),
    '__pvzPending:g2': JSON.stringify({ b: 2 }),
    __pvzPendingGv: '2.0',
  });
  runGuard(store, guard10);
  check('generation：降级把当前代槽移出活动区', !store.has('__pvzPending:g1'));
  check('generation：当前代槽按账号+版本归档',
    (store.get(stateArchive(ANON, '2.0', '__pvzPending:g1')) || '').includes('"a":1'));
  check('generation：pending 所属游戏版本一起归档',
    store.get(stateArchive(ANON, '2.0', '__pvzPendingGv')) === '2.0' &&
    !store.has('__pvzPendingGv'));
  check('generation：降级后活动区没有基础 pending 可重放',
    !store.has('__pvzPending'));
  check('generation：无主 generation 槽原样保留',
    store.get('__pvzPending:g2') === JSON.stringify({ b: 2 }));

  // 9) 恢复到该版本：归档的当前代槽合并进基础键，无主槽不参与
  runGuard(store, guard20);
  const merged = JSON.parse(store.get('__pvzPending') || '{}');
  check('generation：恢复到该版本时归档槽合并进基础 pending',
    merged.other === 'keep' && merged.a === 1, store.get('__pvzPending'));
  check('generation：合并后删除归档槽',
    !store.has(stateArchive(ANON, '2.0', '__pvzPending:g1')));
  check('generation：归并不影响游戏键恢复', store.get(GAME) === 'high-save');
  check('generation：无主槽没被并进基础 pending',
    merged.b === undefined, store.get('__pvzPending'));
  check('generation：无主槽仍留在活动区且没进本账号归档',
    store.get('__pvzPending:g2') === JSON.stringify({ b: 2 }) &&
    !store.has(stateArchive(ANON, '2.0', '__pvzPending:g2')));

  // 10) 同版本再启动：不重复备份、不动活动 generation 槽
  store.set('__pvzPending:g3', JSON.stringify({ c: 3 }));
  const beforeBase = store.get('__pvzPending');
  runGuard(store, guard20);
  check('同版本：再启动不动 activity generation 槽',
    store.get('__pvzPending:g3') === JSON.stringify({ c: 3 }));
  check('同版本：再启动不改写基础 pending 与备份',
    store.get('__pvzPending') === beforeBase &&
    store.get(gameArchive(ANON, '2.0', GAME)) === 'high-save');
}

// 11) 归档队列缺 __pvzPendingGv：合并后补写恢复目标版本
{
  const store = makeStore({
    __pvzSaveContext: JSON.stringify({ gameVersion: '2.0', at: 1 }),
    [GAME]: 'high-save',
    __pvzSyncGeneration: 'g1',
    '__pvzPending:g1': JSON.stringify({ a: 1 }),
  });
  runGuard(store, guard10); // 2.0 → 1.0：归档当前代槽，此时没有 gv 可归档
  check('gv 缺失：降级后确实没有可归档的版本标记',
    !store.has('__pvzPendingGv') &&
    !store.has(stateArchive(ANON, '2.0', '__pvzPendingGv')));
  runGuard(store, guard20); // 恢复到 2.0：合并归档槽
  check('gv 缺失：合并后基础 pending 有内容',
    JSON.parse(store.get('__pvzPending') || '{}').a === 1, store.get('__pvzPending'));
  check('gv 缺失：合并后补写 pending 所属版本',
    store.get('__pvzPendingGv') === '2.0', store.get('__pvzPendingGv'));
}

// 12) 已有 __pvzPendingGv：合并不覆盖（标记记的是队列真正写入的版本）
{
  const store = makeStore({
    __pvzSaveContext: JSON.stringify({ gameVersion: '2.0', at: 1 }),
    [GAME]: 'high-save',
    __pvzSyncGeneration: 'g1',
    __pvzPendingGv: '1.9.0',
    '__pvzPending:g1': JSON.stringify({ a: 1 }),
  });
  runGuard(store, guard10);
  runGuard(store, guard20);
  check('gv 已有：合并不覆盖既有标记',
    store.get('__pvzPendingGv') === '1.9.0', store.get('__pvzPendingGv'));
  check('gv 已有：合并仍然发生',
    JSON.parse(store.get('__pvzPending') || '{}').a === 1, store.get('__pvzPending'));
}

// 13) 旧的无账号键：归属不明，不迁移、不认领、不被他人读到
{
  const store = makeStore({
    __pvzSyncUser: 'bob',
    __pvzSaveContext: JSON.stringify({ gameVersion: '2.0', at: 1 }),
    ['__pvzBlocked_0.15.0_' + GAME]: 'alice-legacy',
    ['__pvzState_0.15.0___pvzPending']: JSON.stringify({ [GAME]: 'legacy-pending' }),
  });
  runGuard(store, guard10);
  check('旧键：不被迁移到任何账号前缀',
    !store.has(gameArchive('bob', '0.15.0', GAME)) &&
    !store.has(gameArchive('alice', '0.15.0', GAME)) &&
    !store.has(gameArchive(ANON, '0.15.0', GAME)));
  check('旧键：原样保留（不删不改）',
    store.get('__pvzBlocked_0.15.0_' + GAME) === 'alice-legacy' &&
    store.has('__pvzState_0.15.0___pvzPending'));
  check('旧键：Bob 的活动区读不到旧备份内容',
    store.get(GAME) !== 'alice-legacy' && !store.has(GAME));
  check('旧键：旧 pending 不会被当成当前版本队列',
    !store.has('__pvzPending'));
}

// 14) P1-3：无主 generation 槽不能被归到当前账号名下
{
  const store = makeStore({
    __pvzSyncUser: 'bob',
    __pvzSaveContext: JSON.stringify({ gameVersion: '2.0', at: 1 }),
    [GAME]: 'bob-high',
    __pvzSyncGeneration: 'g-current',
    '__pvzPending:g-current': JSON.stringify({ coin: 7 }),
    '__pvzPending:g-alice-old': JSON.stringify({ coin: 9999 }),
  });
  runGuard(store, guard10);
  check('P1-3：Bob 降级只归档当前代槽',
    (store.get(stateArchive('bob', '2.0', '__pvzPending:g-current')) || '').includes('"coin":7'));
  check('P1-3：Alice 的遗留槽原样保留',
    store.get('__pvzPending:g-alice-old') === JSON.stringify({ coin: 9999 }));
  check('P1-3：遗留槽不出现在 Bob 前缀归档里',
    !store.has(stateArchive('bob', '2.0', '__pvzPending:g-alice-old')));

  runGuard(store, guard20); // Bob 再升级恢复 2.0
  const base = JSON.parse(store.get('__pvzPending') || '{}');
  check('P1-3：恢复时只合并当前代槽', base.coin === 7, store.get('__pvzPending'));
  check('P1-3：Alice 的遗留进度没被并进 Bob 的队列', base.coin !== 9999);
  check('P1-3：遗留槽始终留在活动区（不可达也不认领）',
    store.get('__pvzPending:g-alice-old') === JSON.stringify({ coin: 9999 }) &&
    !store.has(stateArchive('bob', '2.0', '__pvzPending:g-alice-old')));
}

// 15) P1-3：没有 __pvzSyncGeneration 时不动任何 generation 槽
{
  const store = makeStore({
    __pvzSaveContext: JSON.stringify({ gameVersion: '2.0', at: 1 }),
    [GAME]: 'high-save',
    '__pvzPending:g1': JSON.stringify({ a: 1 }),
  });
  runGuard(store, guard10);
  check('P1-3：没有当前代标记时不动任何 generation 槽',
    store.get('__pvzPending:g1') === JSON.stringify({ a: 1 }));
  check('P1-3：没有当前代标记时也不产生 generation 归档',
    !store.has(stateArchive(ANON, '2.0', '__pvzPending:g1')));
}

// 16) P1-6：归档写不进去时不许清源、不许推进版本上下文
{
  // a) 游戏键归档被拒
  const store = makeStore({
    __pvzSaveContext: JSON.stringify({ gameVersion: '2.0', at: 1 }),
    [GAME]: 'only-copy',
    PvZ2_Settings: 'only-settings',
    __pvzPending: JSON.stringify({ x: 'p' }),
  });
  const ctx = runGuard(store, guard10, { failSet: (k) => k.startsWith('__pvzBlocked_') });
  check('P1-6：游戏键归档失败时活动存档保留',
    store.get(GAME) === 'only-copy' && store.get('PvZ2_Settings') === 'only-settings');
  check('P1-6：游戏键归档失败时不推进版本上下文',
    JSON.parse(store.get('__pvzSaveContext')).gameVersion === '2.0');
  check('P1-6：游戏键归档失败时记录 __pvzVersionGuardBlocked',
    ctx.window.__pvzVersionGuardBlocked &&
    ctx.window.__pvzVersionGuardBlocked.lost.includes('game'),
    JSON.stringify(ctx.window.__pvzVersionGuardBlocked));
  // 只保留内容还不够：低版本引擎若继续读到高版本活动键，仍会按新结构解释
  // 并最终写回损坏内容。归档失败必须让目标版本读不到、也写不进游戏键。
  check('P1-6：归档失败时停止文档解析（目标游戏不启动）',
    ctx.__stopped === true, String(ctx.__stopped));
  check('P1-6：归档失败时显示阻断提示',
    !!ctx.document.getElementById('__pvz_version_blocked'));
  check('P1-6：归档失败后低版本读不到高版本活动存档',
    ctx.localStorage.getItem(GAME) === null && store.get(GAME) === 'only-copy',
    String(ctx.localStorage.getItem(GAME)));
  check('P1-6：归档失败后游戏写入不会覆盖唯一副本',
    (ctx.localStorage.setItem(GAME, 'clobbered'),
     store.get(GAME) === 'only-copy'),
    store.get(GAME));
}
{
  // b) 状态归档被拒
  const store = makeStore({
    __pvzSaveContext: JSON.stringify({ gameVersion: '2.0', at: 1 }),
    [GAME]: 'only-copy',
    __pvzPending: JSON.stringify({ x: 'p' }),
  });
  const ctx = runGuard(store, guard10, { failSet: (k) => k.startsWith('__pvzState_') });
  check('P1-6：状态归档失败时基础 pending 保留',
    store.get('__pvzPending') === JSON.stringify({ x: 'p' }));
  check('P1-6：状态归档失败时不推进版本上下文',
    JSON.parse(store.get('__pvzSaveContext')).gameVersion === '2.0');
  check('P1-6：状态归档失败时活动游戏键未被清空',
    store.get(GAME) === 'only-copy' &&
    ctx.window.__pvzVersionGuardBlocked.lost.includes('state'),
    JSON.stringify(ctx.window.__pvzVersionGuardBlocked));
}
{
  // c) 当前代槽归档被拒 → 恢复存储后重试成功
  const genArchiveKey = stateArchive(ANON, '2.0', '__pvzPending:g-current');
  const store = makeStore({
    __pvzSaveContext: JSON.stringify({ gameVersion: '2.0', at: 1 }),
    [GAME]: 'only-copy',
    __pvzSyncGeneration: 'g-current',
    '__pvzPending:g-current': JSON.stringify({ coin: 7 }),
  });
  const ctx = runGuard(store, guard10, { failSet: (k) => k === genArchiveKey });
  check('P1-6：generation 归档失败时槽仍在活动区',
    store.get('__pvzPending:g-current') === JSON.stringify({ coin: 7 }) &&
    !store.has(genArchiveKey));
  check('P1-6：generation 归档失败时不推进版本上下文',
    JSON.parse(store.get('__pvzSaveContext')).gameVersion === '2.0');
  check('P1-6：generation 归档失败计入 lost',
    ctx.window.__pvzVersionGuardBlocked.lost.includes('pending'),
    JSON.stringify(ctx.window.__pvzVersionGuardBlocked));

  // d) 存储恢复后同一次启动链路能正常收尾
  runGuard(store, guard10);
  check('P1-6：存储恢复后下次启动完成 generation 归档',
    store.get(genArchiveKey) === JSON.stringify({ coin: 7 }) &&
    !store.has('__pvzPending:g-current'));
  check('P1-6：恢复后推进上下文并清空活动键',
    JSON.parse(store.get('__pvzSaveContext')).gameVersion === '1.0' &&
    !store.has(GAME));
}
{
  // e) 静默丢弃（不抛异常）也必须被读回校验抓到
  const store = makeStore({
    __pvzSaveContext: JSON.stringify({ gameVersion: '2.0', at: 1 }),
    [GAME]: 'only-copy',
    __pvzPending: JSON.stringify({ x: 'p' }),
  });
  const ctx = runGuard(store, guard10, { dropSet: (k) => k.startsWith('__pvzBlocked_') });
  check('P1-6：静默丢弃的写入也判为归档失败',
    store.get(GAME) === 'only-copy' &&
    JSON.parse(store.get('__pvzSaveContext')).gameVersion === '2.0' &&
    !!ctx.window.__pvzVersionGuardBlocked);
}

console.log('\n结果：' + pass + ' 通过 / ' + fail + ' 失败');
process.exit(fail === 0 ? 0 : 1);
