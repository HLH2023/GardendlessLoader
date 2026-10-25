#!/usr/bin/env bash
# 接力校验器：status / verify / new-task / seal
#
# 设计原则：把「交接是否完整」变成可执行断言，而不是靠人眼看一遍。
#   - 文件齐备（HANDOFF/docs/prompts/skills）
#   - state.json 结构与状态机合法、回执字段完整、测试数字自洽
#   - 敏感信息扫描（服务器域名、令牌字面量）
#
# 用法：
#   bash tools/handoff.sh status
#   bash tools/handoff.sh verify
#   bash tools/handoff.sh new-task --id R-20261026-01 --title "标题"
#   bash tools/handoff.sh seal
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/.handoff"
STATE="$H/state.json"
PASS=0; FAIL=0; WARN=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
warn() { WARN=$((WARN+1)); printf '  \033[33mwarn\033[0m %s\n' "$1"; }
sec()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

py() { python3 -c "$@"; }

cmd_status() {
  sec "接力状态"
  [ -f "$STATE" ] || { bad "state.json 不存在"; return; }
  py "
import json
s=json.load(open('$STATE'))
r=s['release']; t=s['task']
print('  版本      :', r['versionName'], '(code', str(r['versionCode'])+')')
print('  任务      :', t['id'], '-', t['title'])
print('  状态      :', t['status'])
print('  分发方    :', t.get('dispatchedBy'), '@', t.get('dispatchedAt'))
print('  认领方    :', t.get('acceptedBy'), '@', t.get('acceptedAt'))
print('  测试基线  :', s['tests']['total'], '项（服务端', s['tests']['server'], '+ 客户端', s['tests']['client'], '）')
print('  回执数    :', len(s.get('receipts') or []))
"
}

cmd_verify() {
  sec "文件齐备"
  local required=(
    "$H/PROTOCOL.md" "$H/HANDOFF.md" "$STATE"
    "$H/docs/01-architecture.md" "$H/docs/02-branches.md" "$H/docs/03-versioning.md"
    "$H/docs/04-build.md" "$H/docs/05-deployment.md" "$H/docs/06-testing.md"
    "$H/docs/07-backlog.md" "$H/docs/08-handoff-log.md"
    "$H/prompts/01-start.md" "$H/prompts/02-return.md"
    "$H/skills/gardendless-dev/SKILL.md"
  )
  for f in "${required[@]}"; do
    [ -s "$f" ] && ok "存在 ${f#$ROOT/}" || bad "缺失 ${f#$ROOT/}"
  done

  sec "state.json 结构"
  py "
import json,sys
p='$STATE'
try: s=json.load(open(p))
except Exception as e:
    print('PARSE_FAIL',e); sys.exit(1)
errs=[]
for k in ('schemaVersion','project','release','branches','tests','task','receipts','handoffLog'):
    if k not in s: errs.append('缺少字段 '+k)
st=s.get('task',{}).get('status')
allowed={'draft','dispatched','accepted','in_progress','blocked','review','done'}
if st not in allowed: errs.append('非法状态 '+str(st))
for k in ('upstream','origin','private'):
    if k not in s.get('branches',{}): errs.append('缺少分支定义 '+k)
te=s.get('tests',{})
if te.get('total') != te.get('server',0)+te.get('client',0):
    errs.append('tests.total 与 server+client 不相等')
sm=sum(x.get('count',0) for x in te.get('suites',[]))
if sm and sm != te.get('total'):
    errs.append(f'suites 计数之和 {sm} != total {te.get(\"total\")}')
if errs:
    print('STRUCT_FAIL'); [print('  -',e) for e in errs]; sys.exit(1)
print('OK', st, 'suites=', len(te.get('suites',[])), 'total=', te.get('total'))
" > /tmp/handoff_struct.out 2>&1
  if grep -q '^OK' /tmp/handoff_struct.out; then ok "$(grep '^OK' /tmp/handoff_struct.out)"; else bad "结构非法：$(tr '\n' ' ' < /tmp/handoff_struct.out)"; fi

  sec "回执完整性"
  py "
import json,sys
s=json.load(open('$STATE')); rs=s.get('receipts') or []
if not rs:
    print('NONE'); sys.exit(0)
need=['taskId','by','at','status','readBack','changed','commands','tests','remaining']
bad=[]
for r in rs:
    miss=[k for k in need if k not in r]
    if miss: bad.append(r.get('taskId','?')+' 缺 '+','.join(miss))
    rb=r.get('readBack') or {}
    for k in ('taskTitle','versionBefore','testsBaseline'):
        if not rb.get(k): bad.append(r.get('taskId','?')+' readBack 缺 '+k)
    if not (r.get('commands') or []): bad.append(r.get('taskId','?')+' commands 为空')
    t=r.get('tests') or {}
    if t.get('total') is None: bad.append(r.get('taskId','?')+' tests.total 缺失')
if bad:
    print('RECEIPT_FAIL'); [print('  -',b) for b in bad]; sys.exit(1)
print('OK', len(rs), '条回执字段完整')
" > /tmp/handoff_receipt.out 2>&1
  if grep -q '^OK' /tmp/handoff_receipt.out; then ok "$(grep '^OK' /tmp/handoff_receipt.out)"
  elif grep -q '^NONE' /tmp/handoff_receipt.out; then warn "还没有回执（状态 $(py "import json;print(json.load(open('$STATE'))['task']['status'])")）"
  else bad "回执不完整：$(tr '\n' ' ' < /tmp/handoff_receipt.out)"; fi

  sec "敏感信息扫描（.handoff + AGENTS.md + tools/handoff.sh）"
  local hits
  hits=$(grep -rnE 'greatbox\.top|pvz_[A-Za-z0-9]{8,}|Bearer [A-Za-z0-9._-]{12,}|192\.168\.[0-9]+\.[0-9]+|127\.0\.0\.1:[0-9]{2,5}|[A-Za-z0-9._%+-]+@192\.168' \
    "$H" "$ROOT/AGENTS.md" "$ROOT/tools/handoff.sh" 2>/dev/null | grep -v '工具变量名\|变量名\|环境变量\|占位' || true)
  if [ -z "$hits" ]; then ok "未发现服务器地址/令牌字面量"; else bad "发现敏感字面量："; printf '%s\n' "$hits" | head -10; fi

  sec "源码敏感扫描（lib/tool/android/.github/pubspec）"
  local src_hits
  src_hits=$(cd "$ROOT" && grep -rnE 'greatbox\.top|pvz_[A-Za-z0-9]{8,}|Bearer [A-Za-z0-9._-]{12,}' \
    lib tool android .github pubspec.yaml 2>/dev/null | grep -v '<server>' || true)
  if [ -z "$src_hits" ]; then ok "源码与配置未出现服务器地址/令牌"; else bad "源码里有字面量："; printf '%s\n' "$src_hits" | head -5; fi

  sec "AGENTS.md 只放持久信息"
  local volatile
  volatile=$(grep -nE '[0-9]+\.[0-9]+\.[0-9]+-hlh\.[0-9]+|R-20[0-9]{6}-[0-9]+|[0-9]+ 项全绿|sha256.*[0-9a-f]{16,}' \
    "$ROOT/AGENTS.md" 2>/dev/null || true)
  if [ -z "$volatile" ]; then ok "未出现版本号/任务号/测试数字/哈希等易变事实"
  else bad "AGENTS.md 里混入了易变事实（应改为「怎么查」）："; printf '%s\n' "$volatile" | head -5; fi

  sec "短提示词长度"
  local lines; lines=$(grep -cve '^$' "$H/prompts/01-start.md" 2>/dev/null || echo 99)
  [ "$lines" -le 14 ] && ok "01-start.md 共 $lines 行（≤14）" || warn "01-start.md 有 $lines 行，偏长"

  sec "技能安装"
  if [ -e "$HOME/.config/opencode/skills/gardendless-dev" ]; then
    ok "已装入 opencode 全局 skills"
  else
    warn "未装入 ~/.config/opencode/skills/（agent 会在仓库内 .opencode/skills/ 找到）"
  fi

  printf '\n\033[1m结果：%d 通过 / %d 失败 / %d 警告\033[0m\n' "$PASS" "$FAIL" "$WARN"
  [ "$FAIL" -eq 0 ]
}

cmd_new_task() {
  local id="" title=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id="$2"; shift 2;;
      --title) title="$2"; shift 2;;
      *) shift;;
    esac
  done
  [ -n "$id" ] && [ -n "$title" ] || { echo "用法: bash tools/handoff.sh new-task --id R-YYYYMMDD-NN --title '标题'"; exit 2; }
  py "
import json,datetime
p='$STATE'; s=json.load(open(p))
now=datetime.datetime.now().astimezone().isoformat(timespec='seconds')
s['task'].update({'id':'$id','title':'$title','status':'draft','dispatchedAt':now,
                  'dispatchedBy':'hermes','acceptedAt':None,'acceptedBy':None})
s['receipts']=[]
s['updatedAt']=now; s['updatedBy']='hermes'
s['handoffLog'].append({'at':now,'by':'hermes','event':'new-task','task':'$id','note':'$title'})
json.dump(s,open(p,'w'),ensure_ascii=False,indent=2)
print('已切换到', '$id', '状态 draft')
"
}

cmd_seal() {
  local out="$H/.seal"
  {
    date '+sealedAt: %Y-%m-%dT%H:%M:%S%z'
    find "$H" -type f \( -name '*.md' -o -name '*.json' \) -print0 | sort -z | xargs -0 sha256sum
  } > "$out"
  echo "已写入 $out（$(grep -c '^[0-9a-f]' "$out") 个文件）"
}

case "${1:-status}" in
  status) cmd_status;;
  verify) cmd_verify;;
  new-task) shift; cmd_new_task "$@";;
  seal) cmd_seal;;
  *) echo "用法: bash tools/handoff.sh {status|verify|new-task|seal}"; exit 2;;
esac
