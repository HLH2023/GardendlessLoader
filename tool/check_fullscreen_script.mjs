// 桌面全屏注注入脚本的行为验收（Node 里跑，不需要 Windows）
//
// 为什么把这个脚本单独拉出来测：它假装成浏览器的全屏 API，游戏（Cocos + 资源包
// 里的 tmppatch.js）靠 `document.fullscreenElement` 判断当前状态。写错一个 getter
// 的表现是「第一次点能全屏、第二次点还是进入」或「点了全屏但其实没发消息」——
// 这类问题只有真机点两下才看得出来，所以把状态机搬到 Node 里逐条断言。
//
// 用法: node tool/check_fullscreen_script.mjs
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

const source = readFileSync('lib/src/services/desktop_fullscreen_script.dart', 'utf8');
const start = source.indexOf("r'''");
const end = source.lastIndexOf("'''");
if (start < 0 || end <= start) {
  console.log('  FAIL 找不到注入脚本的 raw string');
  process.exit(1);
}
const script = source.slice(start + 4, end);

function makeEnv({ withChannel = true } = {}) {
  const sent = [];
  const events = [];
  class Document {}
  class Element {}
  const document = new Document();
  document.documentElement = new Element();
  document.dispatchEvent = (event) => {
    events.push(event.type);
    return true;
  };
  // Event 必须显式给：Node 的 vm 上下文里没有浏览器的 Event 构造器，
  // 缺了它脚本里的 dispatchEvent 会静默失败（正是本测试要挡住的问题）。
  class Event { constructor(type) { this.type = type; } }
  // 浏览器一定有 window.close；脚本从 hlh.31 起会 bind 它来做退出接管，
  // 假 DOM 少了这个成员会让整段脚本在加载时抛错（测试环境保真度问题）。
  const window = { document, Element, Document, Event, close() {} };
  if (withChannel) {
    window.gardendlessDesktop = (message) => {
      sent.push(JSON.parse(String(message)));
    };
  }
  window.window = window;
  const context = vm.createContext(window);
  vm.runInContext(script, context, { filename: 'desktop_fullscreen_script.js' });
  return { window, document, sent, events, context };
}

console.log('== 游戏点「全屏」==');
{
  const { window, document, sent, events } = makeEnv();
  const result = document.documentElement.requestFullscreen();
  // 跨 realm 的 instanceof 不可靠（vm 里是另一个 Promise），看 thenable 即可。
  check('requestFullscreen 返回 Promise', result && typeof result.then === 'function');
  check('转发了 window:setFullscreen(true)', sent.length === 1 &&
    sent[0].command === 'window:setFullscreen' && sent[0].fullscreen === true,
    JSON.stringify(sent[0]));
  check('fullscreenElement 变成根元素',
    document.fullscreenElement === document.documentElement);
  check('派发了 fullscreenchange', events.includes('fullscreenchange'), events.join(','));
  check('window.__gardendlessFullscreen 已安装',
    window.__gardendlessFullscreen && window.__gardendlessFullscreen.isFullscreen() === true);
}

console.log('== 再点一次（游戏靠 fullscreenElement 判断走退出）==');
{
  const { document, sent, events } = makeEnv();
  // tmppatch.js 的 electron.ipcRenderer.send('e_fullScreen') 就是这个判断
  const toggle = () => (document.fullscreenElement
    ? document.exitFullscreen()
    : document.documentElement.requestFullscreen());

  toggle();
  check('第一次是进入', sent[0].fullscreen === true);
  check('状态为全屏', document.fullscreenElement === document.documentElement);
  toggle();
  check('第二次是退出', sent[1].fullscreen === false, JSON.stringify(sent[1]));
  check('状态回到窗口', document.fullscreenElement === null);
  toggle();
  check('第三次又进入（状态真的翻转了）', sent[2].fullscreen === true);
  check('fullscreenchange 触发 3 次',
    events.filter((e) => e === 'fullscreenchange').length === 3,
    events.join(','));
}

console.log('== 宿主回灌（F11 / 工具栏按钮）==');
{
  const { window, document, sent, events } = makeEnv();
  window.__gardendlessFullscreen.apply(true);
  check('apply(true) 后页面认为全屏', document.fullscreenElement === document.documentElement);
  check('apply 不重复发消息（不是用户动作）', sent.length === 0);
  check('派发了 fullscreenchange', events.includes('fullscreenchange'));
  window.__gardendlessFullscreen.apply(true);
  check('重复 apply 同一状态不再派发事件',
    events.filter((e) => e === 'fullscreenchange').length === 1, events.join(','));
  // F11 退出后，游戏再点「全屏」应该是进入
  window.__gardendlessFullscreen.apply(false);
  document.documentElement.requestFullscreen();
  check('F11 退出后再点仍是进入', sent[sent.length - 1].fullscreen === true);
}

console.log('== 没有宿主通道时不假装成功 ==');
{
  const { document, sent } = makeEnv({ withChannel: false });
  let rejected = false;
  const result = document.documentElement.requestFullscreen();
  await result.then(() => {}, () => { rejected = true; });
  check('没有通道时不发送任何消息', sent.length === 0);
  check('返回被拒绝的 Promise', rejected);
  check('状态保持窗口模式', document.fullscreenElement === null);
}

console.log('== 重复注入 ==');
{
  const { window, context, document } = makeEnv();
  const before = window.__gardendlessFullscreen;
  vm.runInContext(script, context);
  check('重复注入不会替换已安装的实现', window.__gardendlessFullscreen === before);
  check('重复注入后状态仍可翻转', (() => {
    document.documentElement.requestFullscreen();
    const on = document.fullscreenElement === document.documentElement;
    document.exitFullscreen();
    return on && document.fullscreenElement === null;
  })());
}

console.log('== webkit 前缀别名 ==');
{
  const { document, sent } = makeEnv();
  document.documentElement.webkitRequestFullscreen();
  document.webkitExitFullscreen();
  check('webkitRequestFullscreen 同样转发',
    sent[0] && sent[0].fullscreen === true, JSON.stringify(sent[0]));
  check('webkitExitFullscreen 同样转发',
    sent[1] && sent[1].fullscreen === false, JSON.stringify(sent[1]));
}

console.log('');
console.log(`结果：${passed} 通过 / ${failed} 失败`);
if (failed > 0) process.exitCode = 1;
