import 'dart:convert';

/// 本机存档的版本保护脚本。
///
/// 为什么需要：游戏存档在 localStorage 里，而 Android 本地 origin 固定为
/// `appassets.androidplatform.net`、桌面端本地端口也固定 —— 换游戏版本不会
/// 换 origin。升级时旧存档可以被新版本继承（允许），但降级时高版本存档
/// 绝不能交给低版本游戏读：游戏会改写 `version` 字段并可能按新结构解释
/// 旧数据，等下次升级就把损坏内容写回云端。
///
/// 这段脚本必须在游戏第一次读 localStorage 之前执行。它按「账号 + 版本」保存/恢复：
///   - 版本变化时，把上一版本的活动存档复制到 `__pvzBlocked_<账号>_<版本>_<键>`；
///   - 降级时先清空活动键，再恢复当前版本自己的备份（没有就保持空）；
///   - 升级时保留活动键（新版本可以继承），只留下旧版本备份；
///   - 同步状态（pending/云端基准/meta）也按账号与版本归档，避免旧版本的待上传
///     改动被重放到另一个版本的分区；
///   - 最后把 `__pvzSaveContext` 更新为当前版本，防止下次启动重复备份/清空。
///
/// 为什么要账号维度：换账号不会换 origin，也不一定换版本。只有版本维度的备份
/// 会在「Alice 在高版本留档 → 同一设备换成 Bob → Bob 进低版本」时把 Alice 的
/// 存档恢复给 Bob；此时 `__pvzSyncUser` 已经是 Bob，sync 不会触发换号隔离，
/// Bob 的保存就会被当成 Bob 的数据上传。备份必须带上写它的账号。
///
/// 两条硬约束：
///   - 只认领「当前代」的待上传槽。localStorage 里可能躺着上一个账号/上一代的
///     孤儿槽（sync.js 接管 carry 失败留下的），guard 无从判断归属，遍历归档
///     等于把 Alice 的离线进度交给 Bob。
///   - 归档必须读回确认，且**任何一项归档失败都不许动活动键、不许推进版本
///     上下文**。活动键里的内容常常是唯一副本，清掉就再也找不回来。
String buildLocalSaveGuardScript(String gameVersion) {
  final version = gameVersion.trim();
  if (version.isEmpty) return '';
  const gameKeys = <String>[
    'PvZ2_PlayerProperties',
    'PvZ2_Settings',
    'PvZ2_GitHubLevels',
    'PvZ2_GitHubLevels_Sha',
  ];
  // 与 sync.js 的键名保持一致。它们不是游戏存档，而是「这份内容基于哪个
  // 云端 revision、还有哪些没上传」；跨版本复用会让回放写错分区。
  // `__pvzPendingGv` 记录 pending 属于哪个游戏版本，必须跟 pending 同生共死：
  // 降级时若把它留在活动区，低版本会以为高版本的待上传队列是自己的。
  const stateKeys = <String>[
    '__pvzSyncMeta',
    '__pvzPending',
    '__pvzPendingGv',
    '__pvzCloudMtime',
    '__pvzCloudVer',
    '__pvzCloudProfiles',
    '__pvzRollbackSeen',
    '__pvzRestoredProfilesSeen',
  ];
  return '''
;(function(){
  try {
    var KEY='__pvzSaveContext';
    var USER_KEY='__pvzSyncUser';
    var GEN_KEY='__pvzSyncGeneration';
    var PENDING_KEY='__pvzPending';
    var PENDING_PREFIX='__pvzPending:';
    var CUR=${jsonEncode(version)};
    var GAME_KEYS=${jsonEncode(gameKeys)};
    var STATE_KEYS=${jsonEncode(stateKeys)};
    function get(k){ return localStorage.getItem(k); }
    function set(k,v){ localStorage.setItem(k,v); }
    function del(k){ localStorage.removeItem(k); }
    // 写入后读回确认：配额满、隐私模式、存储层静默丢弃都可能让 setItem
    // 既不抛异常也不真正落盘。只 catch 异常会误判归档成功，接着删掉唯一副本。
    function putVerify(k,v){
      try{
        set(k,v);
        return get(k)===v;
      }catch(e){ return false; }
    }
    // 枚举 localStorage 必须先取键快照：一边删一边按索引前进会跳键，甚至越界。
    function allKeys(){
      var out=[];
      try{
        var n=localStorage.length;
        for(var i=0;i<n;i++){
          var k=localStorage.key(i);
          if(typeof k==='string' && k) out.push(k);
        }
      }catch(e){}
      return out;
    }
    // 账号段：空/读不到一律落到匿名段。绝不回退到无账号的旧键名——旧键的
    // 归属已无法判定，认领它等于把可能属于别人的存档交给当前账号。
    function userTag(){
      var u=null;
      try{ u=get(USER_KEY); }catch(e){}
      if(u===null||u===undefined) return '_anon';
      u=String(u);
      if(!u) return '_anon';
      try{ return encodeURIComponent(u); }catch(e){ return '_anon'; }
    }
    var USER=userTag();
    function cmp(a,b){
      var pa=String(a).split('-')[0].split('.'), pb=String(b).split('-')[0].split('.');
      for(var i=0;i<4;i++){
        var x=+(pa[i]||0), y=+(pb[i]||0);
        if(x!==y) return x>y?1:-1;
      }
      return 0;
    }
    function gameKey(ver,k){ return '__pvzBlocked_'+USER+'_'+ver+'_'+k; }
    function stateKey(ver,k){ return '__pvzState_'+USER+'_'+ver+'_'+k; }
    function saveGame(ver){
      var failed=0;
      for(var i=0;i<GAME_KEYS.length;i++){
        var k=GAME_KEYS[i], v=get(k);
        if(v===null) continue;
        if(!putVerify(gameKey(ver,k),v)) failed++;
      }
      return failed;
    }
    function clearGame(){
      for(var i=0;i<GAME_KEYS.length;i++) del(GAME_KEYS[i]);
    }
    function hasGame(ver){
      for(var i=0;i<GAME_KEYS.length;i++){
        if(get(gameKey(ver,GAME_KEYS[i]))!==null) return true;
      }
      return false;
    }
    function restoreGame(ver){
      var n=0;
      for(var i=0;i<GAME_KEYS.length;i++){
        var v=get(gameKey(ver,GAME_KEYS[i]));
        if(v!==null){ try{ set(GAME_KEYS[i],v); n++; }catch(e){} }
      }
      return n;
    }
    function archiveState(ver){
      var failed=0;
      for(var i=0;i<STATE_KEYS.length;i++){
        var k=STATE_KEYS[i], v=get(k);
        if(v===null) continue;
        if(!putVerify(stateKey(ver,k),v)) failed++;
      }
      return failed;
    }
    function dropState(){
      for(var i=0;i<STATE_KEYS.length;i++) del(STATE_KEYS[i]);
    }
    function restoreState(ver){
      var n=0;
      for(var i=0;i<STATE_KEYS.length;i++){
        var v=get(stateKey(ver,STATE_KEYS[i]));
        if(v!==null){ try{ set(STATE_KEYS[i],v); del(stateKey(ver,STATE_KEYS[i])); n++; }catch(e){} }
      }
      return n;
    }
    // 待上传队列按代分槽（sync.js 的 __pvzPending:<gen>）。这里只搬「当前代」
    // 那一个槽：guard 无法知道其它槽属于谁——接管 carry 失败会留下上一账号/
    // 上一代的孤儿槽，遍历归档就是把 Alice 的离线进度搬到 Bob 前缀，Bob 恢复
    // 后会以 expectedUid=bob 上传 Alice 的金币。孤儿槽宁可永远不可达。
    // 没有 __pvzSyncGeneration 时基础 __pvzPending 交给 archiveState/dropState。
    // __pvzPendingLegacyFor 同理：键里不含账号/代归属，动它可能打乱别人的
    // 迁移状态，交给 sync.js 自己按代判断。
    function archivePending(ver){
      var gen=null;
      try{ gen=get(GEN_KEY); }catch(e){}
      if(gen===null||gen===undefined) return {moved:0,failed:0};
      gen=String(gen);
      if(!gen) return {moved:0,failed:0};
      var k=PENDING_PREFIX+gen;
      var v=get(k);
      if(v===null) return {moved:0,failed:0};
      if(!putVerify(stateKey(ver,k),v)){
        try{ window.__pvzPendingArchiveFailed=1; }catch(e){}
        return {moved:0,failed:1};
      }
      try{ del(k); }catch(e){}
      return {moved:1,failed:0};
    }
    // 归档失败时的唯一安全出口：版本上下文不推进，同时**阻止目标版本读到
    // 上一版本的活动存档**。只 return 会让低版本引擎直接解析高版本内容，
    // 正是版本保护要防的损坏路径。做法：
    //   1) 写标记，便于下次启动自检与日志；
    //   2) 给游戏键装读/写门闩：读返回 null、写丢弃（内容仍在存储里）；
    //   3) 停止文档继续解析并盖一层提示，避免引擎在“空档”上继续跑。
    function blockVersionSwitch(detail){
      try{ set('__pvzVersionBlocked',JSON.stringify(detail)); }catch(e){}
      try{
        var proto=Storage.prototype;
        var origGet=proto.getItem, origSet=proto.setItem;
        proto.getItem=function(k){
          try{
            if(this===window.localStorage &&
               GAME_KEYS.indexOf(String(k))!==-1) return null;
          }catch(e){}
          return origGet.apply(this,arguments);
        };
        proto.setItem=function(k,v){
          try{
            if(this===window.localStorage &&
               GAME_KEYS.indexOf(String(k))!==-1) return undefined;
          }catch(e){}
          return origSet.apply(this,arguments);
        };
      }catch(e){}
      var msg='版本切换未完成：本机存储空间不足或不可写。\\n' +
        '旧版本存档已原样保留，请清理空间后重新打开游戏。';
      try{
        if(!document.getElementById('__pvz_version_blocked')){
          var el=document.createElement('div');
          el.id='__pvz_version_blocked';
          el.setAttribute('style','position:fixed;inset:0;z-index:2147483647;' +
            'background:#111;color:#eee;font:16px/1.7 system-ui,-apple-system,' +
            'sans-serif;padding:32px;white-space:pre-wrap;box-sizing:border-box');
          el.textContent=msg;
          (document.body||document.documentElement).appendChild(el);
        }
      }catch(e){}
      try{ window.stop(); }catch(e){}
    }
    function mergePendingInto(base,extra){
      if(base===null||base===undefined||base==='') return extra;
      try{
        var a=JSON.parse(base), b=JSON.parse(extra);
        if(a && b && typeof a==='object' && typeof b==='object' &&
           !(a instanceof Array) && !(b instanceof Array)){
          for(var k in b){
            if(Object.prototype.hasOwnProperty.call(b,k)) a[k]=b[k];
          }
          return JSON.stringify(a);
        }
      }catch(e){}
      return null;
    }
    // 只合并「当前版本 + 当前账号」归档里的 generation 槽：把它们并进基础
    // __pvzPending，让 sync.js 的 legacy 迁移在本次启动接进当前 generation。
    // 高版本的槽归档在别的版本前缀下，不会被这里读到。
    function mergeArchivedPending(ver){
      var prefix=stateKey(ver,PENDING_PREFIX);
      var keys=allKeys();
      var base=get(PENDING_KEY);
      var merged=0, failed=0;
      for(var i=0;i<keys.length;i++){
        var k=keys[i];
        if(k.indexOf(prefix)!==0) continue;
        var v=get(k);
        if(v===null) continue;
        var next=mergePendingInto(base,v);
        // 解析失败时保留归档槽：它可能是唯一副本，删了就没了。
        if(next===null){ failed++; continue; }
        if(next!==base && !putVerify(PENDING_KEY,next)){ failed++; continue; }
        base=next;
        try{ del(k); }catch(e){}
        merged++;
      }
      // 版本标记必须和队列同生共死：旧备份里可能没有 __pvzPendingGv，这时
      // 合并出来的队列没有归属版本，sync.js 的跨版本守卫只能拿 __pvzCloudVerGv
      // 去猜方向，可能把降级队列误判成可继承。这些槽本来就属于 ver，补上。
      // 已有标记不覆盖（它记的是队列真正被写入时的版本）。
      if(merged>0 && get('__pvzPendingGv')===null){
        putVerify('__pvzPendingGv',ver);
      }
      if(failed){
        try{ window.__pvzPendingMergeFailed=failed; }catch(e){}
      }
      return merged;
    }
    var raw=get(KEY), prev=null;
    try{ prev=raw?JSON.parse(raw):null; }catch(e){}
    if(prev && prev.gameVersion && prev.gameVersion!==CUR){
      var before=String(prev.gameVersion);
      var lost=[];
      // 先把上一版本的内容与同步状态各存一份：降级时后面会清活动键。
      if(saveGame(before)) lost.push('game');
      if(archiveState(before)) lost.push('state');
      var pending=archivePending(before);
      if(pending.failed) lost.push('pending');
      if(lost.length){
        // 归档没有全部落地时清源就等于删掉唯一副本：活动键、基础 pending、
        // 归档三处都找不到玩家的离线进度。保留活动键与旧版本上下文，下次
        // 启动存储恢复后重试；已经写成功的归档保留（重写是幂等的）。
        var blocked={
          stored:before, current:CUR, lost:lost,
          pendingFailed:pending.failed, at:Date.now()
        };
        try{ window.__pvzVersionGuardBlocked=blocked; }catch(e){}
        try{
          window.__pvzVersionBlocked={
            kind:'archive_failed', stored:before, current:CUR, lost:lost
          };
        }catch(e){}
        blockVersionSwitch(blocked);
      } else {
        var moved=pending.moved;
        if(cmp(before,CUR)>0){
          clearGame();
          var restored=restoreGame(CUR);
          dropState();
          var state=restoreState(CUR);
          var merged=mergeArchivedPending(CUR);
          set('__pvzVersionBlocked',JSON.stringify({
            stored:before, current:CUR, restored:restored, stateKeys:state,
            pendingArchived:moved, pendingMerged:merged, pendingFailed:0,
            lost:lost, at:Date.now()
          }));
          window.__pvzVersionBlocked={
            stored:before, current:CUR, restored:restored,
            pendingArchived:moved
          };
        } else if(hasGame(CUR)){
          // 升级到已有本地备份的版本：恢复该版本自己的内容和同步状态。
          // 不能把低版本内容留在活动键里，否则下一次降级会用它覆盖高版本备份。
          clearGame();
          var upgraded=restoreGame(CUR);
          dropState();
          var upState=restoreState(CUR);
          var upMerged=mergeArchivedPending(CUR);
          del('__pvzVersionBlocked');
          window.__pvzVersionBlocked={
            kind:'upgrade_restore', from:before, current:CUR,
            restored:upgraded, stateKeys:upState,
            pendingArchived:moved, pendingMerged:upMerged
          };
        } else {
          // 首次进入这个版本：活动内容留给新版本继承；旧版本已在上面的
          // saveGame 里留档。当前代的待上传槽已经在 archivePending 里挪走。
          del('__pvzVersionBlocked');
          window.__pvzVersionBlocked=null;
        }
        set(KEY,JSON.stringify({gameVersion:CUR,from:before,at:Date.now()}));
      }
    } else if(!prev || !prev.gameVersion){
      set(KEY,JSON.stringify({gameVersion:CUR,at:Date.now()}));
    } else {
      // 同一版本：只更新时间，绝不重复备份/清空。
      prev.at=Date.now();
      set(KEY,JSON.stringify(prev));
    }
  } catch(e) {}
})();
''';
}
