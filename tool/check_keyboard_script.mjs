// 桌面键盘注入脚本的行为验收（Node 假 DOM，不需要 Windows）
//
// 为什么单独测：这段脚本依赖 CEF 的焦点上报和 Windows 键码，
// 真机上一旦时序/字段错了，表现都是「鼠标能玩、键盘全废」，很难从界面区分。
// 这里把两个已经踩过的坑固化下来：
//   1. body 还没出现时不能写「已安装」标志，否则 loadEnd 的重装会被挡掉；
//   2. webview_cef 给的 event.code 为空，Cocos 按 code 匹配热键，
//      必须从 keyCode 还原并重派发到 #GameCanvas（且不能双份）。
//
// 用法: node tool/check_keyboard_script.mjs
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

const source = readFileSync('lib/src/services/desktop_keyboard_script.dart', 'utf8');
const start = source.indexOf("r'''");
const end = source.lastIndexOf("'''");
if (start < 0 || end <= start) {
  console.log('  FAIL 找不到注入脚本的 raw string');
  process.exit(1);
}
const script = source.slice(start + 4, end);

class FakeKeyboardEvent {
  constructor(type, init) {
    Object.assign(this, init);
    this.type = type;
    this.defaultPrevented = false;
  }
  preventDefault() {
    this.defaultPrevented = true;
  }
  stopPropagation() {}
}

function makeEnv({ withBody = true } = {}) {
  const reports = [];
  const dispatched = [];
  const docListeners = {};
  const winListeners = {};
  const intervals = [];
  let probe = null;
  let attached = false;

  const canvas = {
    tagName: 'CANVAS',
    id: 'GameCanvas',
    nodeType: 1,
    dispatchEvent(event) {
      dispatched.push(event);
    },
  };

  const doc = {
    readyState: withBody ? 'complete' : 'loading',
    body: null,
    activeElement: null,
    createElement(tag) {
      probe = {
        tagName: tag.toUpperCase(),
        id: '',
        nodeType: 1,
        attributes: {},
        style: {},
        setAttribute(key, value) {
          this.attributes[key] = value;
        },
        addEventListener() {},
        focus() {
          doc.activeElement = this;
        },
        blur() {
          if (doc.activeElement === this) doc.activeElement = null;
        },
      };
      return probe;
    },
    querySelector() {
      return attached ? probe : null;
    },
    getElementById(id) {
      return id === 'GameCanvas' ? canvas : null;
    },
    addEventListener(type, fn) {
      (docListeners[type] ||= []).push(fn);
    },
  };

  function attachBody() {
    doc.body = {
      tagName: 'BODY',
      appendChild(element) {
        element.isConnected = true;
        attached = true;
      },
    };
  }
  if (withBody) attachBody();

  const win = {
    gardendlessDesktop(message) {
      reports.push(JSON.parse(String(message)));
    },
    addEventListener(type, fn) {
      (winListeners[type] ||= []).push(fn);
    },
  };

  const sandbox = {
    window: win,
    document: doc,
    setTimeout(fn) {
      fn();
      return 1;
    },
    setInterval(fn) {
      intervals.push(fn);
      return 1;
    },
    clearInterval() {},
    JSON,
    Date,
    KeyboardEvent: FakeKeyboardEvent,
    console,
  };
  vm.runInNewContext(script, sandbox);

  return {
    canvas,
    doc,
    win,
    reports,
    dispatched,
    attachBody,
    triggerDoc(type) {
      (docListeners[type] || []).forEach((fn) => fn({}));
    },
    fireWindow(type, event) {
      (winListeners[type] || []).forEach((fn) => fn(event));
    },
  };
}

function nativeEvent({ target, code, key, keyCode }) {
  let stopped = 0;
  let prevented = 0;
  return {
    type: 'keydown',
    target,
    code,
    key,
    keyCode,
    cancelable: true,
    ctrlKey: false,
    shiftKey: false,
    altKey: false,
    metaKey: false,
    repeat: false,
    location: 0,
    isComposing: false,
    stopImmediatePropagation() {
      stopped++;
    },
    preventDefault() {
      prevented++;
    },
    get stopped() {
      return stopped;
    },
    get prevented() {
      return prevented;
    },
  };
}

console.log('== 注入时序（body 未就绪）==');
{
  const env = makeEnv({ withBody: false });
  check('body 未出现时不装探针', env.doc.activeElement === null, env.doc.activeElement);
  env.attachBody();
  env.doc.readyState = 'interactive';
  env.triggerDoc('DOMContentLoaded');
  const probe = env.doc.querySelector('input[data-gardendless-keyboard]');
  check('DOMContentLoaded 后建探针并聚焦', !!probe && env.doc.activeElement === probe);
  check('聚焦成功才标记 primed', env.win.__gardendlessKeyboardPrimed === true);
}

console.log('== 按键校正（code 为空）==');
{
  const env = makeEnv();
  const probe = env.doc.querySelector('input[data-gardendless-keyboard]');

  const first = nativeEvent({
    target: env.canvas,
    code: '',
    key: '1',
    keyCode: 49,
  });
  env.win.__gardendlessKeyboardNormalize(first);
  check(
    '目标是画布 + code 为空：重派发 Digit1',
    env.dispatched.length === 1 && env.dispatched[0].code === 'Digit1',
    JSON.stringify(env.dispatched[0] && env.dispatched[0].code),
  );
  check('原生事件被截住，不会双份', first.stopped === 1 && first.prevented === 1);

  const correct = nativeEvent({
    target: env.canvas,
    code: 'Digit2',
    key: '2',
    keyCode: 50,
  });
  env.win.__gardendlessKeyboardNormalize(correct);
  check(
    'code 正确：不重派发',
    env.dispatched.length === 1 && correct.stopped === 0,
  );

  const onProbe = nativeEvent({
    target: probe,
    code: '',
    key: '1',
    keyCode: 49,
  });
  env.win.__gardendlessKeyboardNormalize(onProbe);
  check(
    '目标还是探针：重派发到画布',
    env.dispatched.length === 2 &&
      env.dispatched[1].code === 'Digit1' &&
      onProbe.stopped === 1,
  );

  const realInput = {
    tagName: 'INPUT',
    nodeType: 1,
    id: 'player-name',
    isContentEditable: false,
  };
  const typing = nativeEvent({
    target: realInput,
    code: '',
    key: 'a',
    keyCode: 65,
  });
  env.win.__gardendlessKeyboardNormalize(typing);
  check(
    '真实输入框：不拦、不重派发',
    env.dispatched.length === 2 && typing.stopped === 0,
  );

  const letter = nativeEvent({
    target: env.canvas,
    code: 'Unidentified',
    key: 'q',
    keyCode: 81,
  });
  env.win.__gardendlessKeyboardNormalize(letter);
  check(
    '字母从 keyCode 还原 KeyQ',
    env.dispatched.length === 3 && env.dispatched[2].code === 'KeyQ',
  );

  env.win.__gardendlessKeyboardNormalize(env.dispatched[2]);
  check(
    '重派发事件带标记，二次校正不重复',
    env.dispatched.length === 3,
  );
}

console.log(`\n结果：${passed} 通过 / ${failed} 失败`);
if (failed > 0) process.exit(1);
