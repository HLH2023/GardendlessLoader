(function () {
  "use strict";
  if (window.__gardendlessMediaLifecycle) return;
  window.__gardendlessMediaLifecycle = true;

  // 游戏音频有两套通路：
  //  1. game-audio.js 的 HTMLAudio 池（window.audioEngine，元素不挂 DOM，
  //     querySelectorAll 找不到）；
  //  2. Cocos AudioSource，DOM_AUDIO 走 <audio>，WEB_AUDIO 走 AudioContext。
  // 从 play() 入口登记所有媒体元素，能同时覆盖池化、临时创建和 Cocos 的 DOM
  // 音频；AudioContext 在游戏脚本之前包一层，暂停时一起 suspend。
  var media = new Set();
  var proto = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
  if (proto && typeof proto.play === "function" && !proto.play.__gardendlessTracked) {
    var originalPlay = proto.play;
    var trackedPlay = function () {
      media.add(this);
      return originalPlay.apply(this, arguments);
    };
    trackedPlay.__gardendlessTracked = true;
    proto.play = trackedPlay;
  }

  var contexts = new Set();
  var AudioCtx = window.AudioContext || window.webkitAudioContext;
  if (typeof AudioCtx === "function" && !AudioCtx.__gardendlessTracked) {
    try {
      var Wrapped = new Proxy(AudioCtx, {
        construct: function (target, args) {
          var ctx = Reflect.construct(target, args);
          contexts.add(ctx);
          return ctx;
        }
      });
      Wrapped.__gardendlessTracked = true;
      window.AudioContext = Wrapped;
      if (window.webkitAudioContext) window.webkitAudioContext = Wrapped;
    } catch (_) {}
  }

  var pausedMedia = [];
  var suspendedContexts = [];

  function pause() {
    // 游戏把 electronAPI.onWindowUnfocused 绑在 window blur 上
    // （tmppatch.js），派发 blur 让它在关卡内弹出自己的暂停菜单。
    // 监听器不检查 isTrusted，合成事件即可。
    try {
      window.dispatchEvent(new Event("blur"));
    } catch (_) {}
    pausedMedia = [];
    media.forEach(function (el) {
      try {
        if (!el.paused && !el.ended) {
          pausedMedia.push(el);
          el.pause();
        }
      } catch (_) {}
    });
    suspendedContexts = [];
    contexts.forEach(function (ctx) {
      try {
        if (ctx.state === "running") {
          suspendedContexts.push(ctx);
          ctx.suspend();
        }
      } catch (_) {}
    });
  }

  function resume() {
    // 只恢复「进入后台时正在播」的元素。游戏自己若也 play() 同一个元素，
    // 重复调用是幂等的，不会叠音。
    for (var i = 0; i < pausedMedia.length; i++) {
      try {
        var p = pausedMedia[i].play();
        if (p && typeof p.catch === "function") p.catch(function () {});
      } catch (_) {}
    }
    pausedMedia = [];
    for (var j = 0; j < suspendedContexts.length; j++) {
      try {
        suspendedContexts[j].resume();
      } catch (_) {}
    }
    suspendedContexts = [];
    try {
      window.dispatchEvent(new Event("focus"));
    } catch (_) {}
  }

  window.__gardendlessHostPause = pause;
  window.__gardendlessHostResume = resume;
})();
