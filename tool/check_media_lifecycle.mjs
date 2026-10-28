// 安卓后台暂停/静音脚本的行为验收（Node 里跑，不需要设备）
//
// 为什么单独测：游戏的音频是 game-audio.js 里一个不挂 DOM 的 HTMLAudio 池，
// `document.querySelectorAll('audio')` 找不到；自动暂停又只绑在 window blur 上。
// 写错的表现是「切后台音乐还在放」或「回前台后用户原本暂停的音效自己响了」，
// 只有真机切后台才看得出来，所以把媒体/上下文的状态搬到 Node 里逐条断言。
//
// 用法: node tool/check_media_lifecycle.mjs
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

let passed = 0;
let failed = 0;
function check(name, ok, extra) {
  if (ok) {
    passed++;
    console.log(`  ok   ${name}${extra !== undefined ? ` -> ${extra}` : ''}`);
  } else {
    failed++;
    console.log(`  FAIL ${name}${extra !== undefined ? ` -> ${extra}` : ''}`);
  }
}

const source = readFileSync('assets/game_bridge/media_lifecycle.js', 'utf8');

class FakeMedia {
  constructor() {
    this.paused = true;
    this.ended = false;
  }
  play() {
    this.paused = false;
    return Promise.resolve();
  }
  pause() {
    this.paused = true;
  }
}
class FakeAudioContext {
  constructor() {
    this.state = 'running';
  }
  suspend() {
    this.state = 'suspended';
    return Promise.resolve();
  }
  resume() {
    this.state = 'running';
    return Promise.resolve();
  }
}

const events = [];
const window = {
  HTMLMediaElement: FakeMedia,
  AudioContext: FakeAudioContext,
  dispatchEvent(event) {
    events.push(event.type);
    return true;
  },
};
window.window = window;
const sandbox = {
  window,
  Event: class Event {
    constructor(type) {
      this.type = type;
    }
  },
  Proxy,
  Reflect,
  Set,
  console,
};
vm.createContext(sandbox);
vm.runInContext(source, sandbox);

check(
  '脚本导出暂停/恢复两个入口',
  typeof window.__gardendlessHostPause === 'function' &&
    typeof window.__gardendlessHostResume === 'function',
);

const a = new FakeMedia();
const b = new FakeMedia();
const idle = new FakeMedia();
a.play();
b.play();

window.__gardendlessHostPause();
check('暂停派发 blur（游戏据此弹出自己的暂停菜单）', events[0] === 'blur');
check('正在播放的媒体全部暂停', a.paused && b.paused);
check('本来就没播的媒体不受影响', idle.paused);

window.__gardendlessHostResume();
check('恢复派发 focus', events[1] === 'focus');
check('只恢复进入后台时正在播的媒体', !a.paused && !b.paused && idle.paused);

a.pause();
window.__gardendlessHostPause();
window.__gardendlessHostResume();
check('用户自己暂停的媒体不会被自动恢复', a.paused);

const context = new window.AudioContext();
check(
  'AudioContext 包装后仍可正常构造',
  context instanceof FakeAudioContext && context.state === 'running',
);
window.__gardendlessHostPause();
check('运行中的 AudioContext 被 suspend', context.state === 'suspended');
window.__gardendlessHostResume();
check('AudioContext 恢复运行', context.state === 'running');

console.log('');
console.log(`结果：${passed} 通过 / ${failed} 失败`);
if (failed > 0) process.exitCode = 1;
