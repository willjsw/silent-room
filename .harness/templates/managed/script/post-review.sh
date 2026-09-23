#!/usr/bin/env bash
# 리뷰 본문을 리뷰 요청에 등록하고 판정을 종료 코드로 돌려준다.
#
#   script/post-review.sh <리뷰요청번호> <리뷰본문파일> [작성자표시] [리뷰한리비전]
#
# 종료 코드: 0 = PASS(blocker·major 0건) · 1 = CHANGES_REQUESTED · 2 = 등록·계약 실패
#            3 = 한 파일에 blocker·major 가 상한 회차 연속 — 코드가 아니라 명세를 다시 본다
#
# **판정은 발견 등급 집계로 한다.** 본문 마지막 줄의 판정 선언은 계약 준수 여부를 보는 용도이고,
# 루프를 끝낼지는 blocker·major 건수가 정한다 — minor 만 남았는데 루프가 계속 도는 일을 막는다.
#
# blocker·major 는 해당 diff 라인에 인라인으로, 전체 요약은 댓글 1건으로 등록한다.
# minor 는 인라인으로 달지 않는다 — 소음이 판정을 묻는다.
#
# 반복은 세션의 기억이 아니라 파일이 센다. 어느 파일에 blocker·major 가 나온 회차를
# `<git-dir>/work-loop/` 아래에 누적한다(커밋 대상 아님, 리뷰 요청 단위).
# **키는 파일 경로 하나이고, 연속한 회차만 센다.** 같은 뿌리의 결함은 회차마다 다른 문장으로
# 나오고 등급도 흔들려서, 요지나 심각도를 키에 넣으면 매 회차가 새 지적이 되어 상한이 발동하지
# 않는다. 서로 다른 파일의 독립 결함은 경로만으로 이미 갈린다. 줄 번호도 넣지 않는다 —
# 고칠 때마다 바뀐다. blocker·major 가 없던 회차도 자리표시자로 남긴다. 남기지 않으면 회차
# 번호가 멈춰, 깨끗하게 지나간 회차가 연속을 끊지 못한다.
#
# **이 카운트는 보조 상한이다.** 주 상한은 review-mr.sh 가 올리는 회차 라벨이고, 그건 원격에
# 있어 클론이 바뀌어도 유지된다. 반복 카운트는 "같은 지적이 반복되면 코드가 아니라 명세가
# 틀렸다" 를 **한 실행 환경 안에서** 잡는 신호라서, 다른 기기·새 클론에서 이어 돌리면 0 부터
# 다시 센다. 그래도 회차 상한이 루프를 끝낸다. 원격에서 복원하지 않는다 — 댓글을 파싱해
# 이력을 되살리는 방식은 형식 변경에 취약하고, 틀린 상한은 없는 것보다 나쁘다.
#
# 이 스크립트는 리뷰 본문의 형식을 읽기만 하고 계약을 새로 정의하지 않는다.
# 형식 문자열의 정본은 `script/harness-format.sh` 이고 계약 문서가 같은 값을 쓴다.
#
# **발견은 발견 절 안에서만 읽는다.** 판정이 등급 집계이므로 절 밖의 등급 형식 줄
# (잘된 점의 `- [major] …` 같은 것)을 세면 그대로 판정이 뒤집힌다. 절 제목은 수준까지 정확해야
# 한다. 절이 없거나 절 안에 발견도 없음 표기도 없으면 계약 위반이다 — 판정 선언 누락과 같이
# 등록하지 않고 종료 코드 2 다. 형식을 지키지 못한 출력은 발견 목록도 믿을 수 없으므로,
# 여기서 추측해 읽지 않고 리뷰를 다시 돌린다.
#
# 이 스크립트가 존재하는 이유: 등록에는 원격 쓰기 권한이 필요하지만 리뷰어는 읽기 전용이어야
# 한다. 등록을 여기로 분리해 리뷰 수행 주체에게 쓰기 도구를 주지 않는다.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. script/harness.env
. script/harness-format.sh
. script/forge.sh

if [ $# -lt 2 ]; then echo "usage: script/post-review.sh <review-request-number> <review-body-file> [author-label] [reviewed-revision]" >&2; exit 2; fi
mr="$1"
body="$2"
label="${3:-자동 리뷰}"
reviewed="${4:-}"

review_require || exit 2
command -v python3 >/dev/null || { echo "error: python3 is not installed" >&2; exit 2; }
[ -s "$body" ] || { echo "error: the review body is empty: $body" >&2; exit 2; }

# 리뷰한 리비전을 받았으면 형식을 확인한다. 틀린 값을 그대로 적으면 다음 회차가 없는 커밋을
# 기준으로 증분을 만들거나, 기준을 읽지 못해 조용히 누적 diff 로 물러난다.
if [ -n "$reviewed" ] && ! printf '%s' "$reviewed" | grep -qE '^[0-9a-f]{7,40}$'; then
  echo "error: the reviewed revision is not a SHA, got '$reviewed'" >&2
  echo "help: nothing was posted — a wrong baseline would misalign the next round incremental diff" >&2
  exit 2
fi

# 계약: 마지막 비공백 줄이 정확히 판정 문자열이어야 한다. 본문 중간의 언급은 판정이 아니다.
declared=$(grep -v '^[[:space:]]*$' "$body" | tail -1 | tr -d '\r' || true)
case "$declared" in
  "$FMT_VERDICT_PASS"|"$FMT_VERDICT_CHANGES") ;;
  *)
    echo "contract violation: the last line is not a verdict declaration, got '$declared'" >&2
    echo "help: nothing was posted — the raw review follows" >&2
    cat "$body" >&2
    exit 2
    ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 이번 리뷰가 본 리비전. 다음 회차가 증분 diff 의 기준으로 읽으므로 요약 노트에 남긴다.
# **부르는 쪽이 넘긴 값이 우선이다** — 리뷰 도중 커밋이 생기면 지금 HEAD 는 리뷰하지 않은
# 리비전이고, 그것을 기준으로 적으면 그 커밋의 변경이 다음 회차의 증분에서 빠진다.
head_sha="$reviewed"
[ -n "$head_sha" ] || head_sha=$(git rev-parse HEAD 2>/dev/null || true)

# 이력은 로컬 git 디렉터리에 둔다 — 클론이 바뀌면 초기화된다(상단 주석: 보조 상한).
hist_dir="$(git rev-parse --git-dir)/work-loop"
hist="$hist_dir/review-findings-$mr.tsv"
mkdir -p "$hist_dir"

# 본문을 한 번만 읽어 인라인 대상·등급 집계·반복 횟수를 함께 낸다. 파서가 둘이면
# "발견 하나"의 기준이 갈라져 인라인과 판정이 서로 다른 것을 센다.
parse_rc=0
python3 - "$body" "$hist" "$REVIEW_REPEAT_FILE_MAX" "$work" \
         "$FMT_FINDINGS_HEADING" "$FMT_FINDINGS_LEVEL" "$FMT_NO_FINDINGS" "$FMT_NO_LOCATION" \
         "$FMT_INLINE_SEVERITIES" <<'PY' || parse_rc=$?
import os, re, sys

(body_path, hist_path, repeat_max, work,
 section_heading, section_level, no_findings, no_location, inline_sev) = sys.argv[1:10]
repeat_max = int(repeat_max)
section_level = int(section_level)
section = section_heading.lstrip('#').strip()
inline_sev = inline_sev.split()

# 누적 파일 첫 줄의 형식 판별자. 반복 키 구성이 바뀌면 숫자를 올린다 — 옛 형식 줄은 새 키와
# 비교할 수 없어, 이어 쓰면 회수가 틀린다. 판별자가 다르면 이전 기록을 버리고 다시 센다.
HIST_FORMAT = '#format 1'
# blocker·major 가 없던 회차의 자리표시자. 회차 번호를 잇고 연속을 끊는 역할만 한다.
NO_FINDING = '-'

heading = re.compile(r'^(#{1,6})\s+(.*?)\s*#*\s*$')
# 머리글은 행 첫 칸에서 시작한다. 들여쓴 줄은 앞 발견의 설명이지 새 발견이 아니다 —
# 재현 절차에 담은 등급 형식 예시가 발견으로 세어지는 것을 막는다.
head = re.compile(r'^-\s*\[(blocker|major|minor)\]\s*(.*)$')
loc = re.compile(r'^`?([^`\s:]+):(\d+)`?\s*[—\-–]\s*(.*)$')
none_mark = re.compile(r'^-?\s*%s[.]?$' % re.escape(no_findings))

lines = open(body_path, encoding='utf-8').read().splitlines()

# 본문 전체가 아니라 절 안만 본다. 판정이 등급 집계라서, 요약·잘된 점의 등급 형식 줄을 세면
# 그것만으로 PASS 가 CHANGES_REQUESTED 로 바뀌고 반복 지적 이력까지 남는다.
start = end = None
for i, ln in enumerate(lines):
    m = heading.match(ln)
    if not m:
        continue
    lv, title = len(m.group(1)), m.group(2).strip()
    if title == section and lv != section_level:
        sys.stderr.write(
            f"contract violation: the findings heading must be '{section_heading}', "
            f"got '{'#' * lv} {title}'\n")
        sys.exit(2)
    if start is None:
        if title == section:
            start = i + 1
    elif end is None:
        end = i

if start is None:
    sys.stderr.write(f"contract violation: no '{section_heading}' section, so the findings have no boundary\n")
    sys.exit(2)

body_lines = lines[start:end if end is not None else len(lines)]

# 발견 하나 = 머리글 줄 + 뒤따르는 들여쓴 줄. 들여쓰지 않은 줄에서 끊는다.
findings, cur = [], None
for ln in body_lines:
    m = head.match(ln)
    if m:
        if cur:
            findings.append(cur)
        cur = {'sev': m.group(1), 'rest': m.group(2).strip(), 'tail': []}
    elif cur is not None:
        if ln.strip() == '' or ln[:1] in (' ', '\t'):
            cur['tail'].append(ln.strip())
        else:
            findings.append(cur)
            cur = None
if cur:
    findings.append(cur)

# 발견도 없음 표기도 없는 절은 계약 위반이다. 형식이 어긋나 발견을 놓친 것과
# 정말 발견이 없는 것을 구분할 수 없고, 구분하지 못한 채 PASS 를 내면 루프가 조용히 끝난다.
if not findings and not any(none_mark.match(ln.strip()) for ln in body_lines):
    sys.stderr.write(f"contract violation: the '{section_heading}' section has neither findings nor the '{no_findings}' marker\n")
    sys.exit(2)


def repeat_key(f):
    """반복 판정에 쓰는 키 — 파일 경로 하나."""
    m = loc.match(f['rest'])
    return m.group(1) if m else no_location


counts = {'blocker': 0, 'major': 0, 'minor': 0}
inline, keys = [], []
for f in findings:
    counts[f['sev']] += 1
    if f['sev'] not in inline_sev:
        continue
    keys.append(repeat_key(f))
    m = loc.match(f['rest'])
    if m:  # 형식을 어긴 발견은 인라인에서 빠지되 요약 본문에는 그대로 남는다.
        note = f"**[{f['sev']}]** " + "\n".join([m.group(3).strip()] + f['tail']).strip()
        inline.append((m.group(1), m.group(2), note))

with open(os.path.join(work, 'inline'), 'w', encoding='utf-8') as fp:
    for file, line, note in inline:
        fp.write(f"{file}\t{line}\t{note}\0")

with open(os.path.join(work, 'counts'), 'w', encoding='utf-8') as fp:
    fp.write("{blocker} {major} {minor}\n".format(**counts))

# 회차별 누적. 이번 회차의 같은 키는 중복을 접어 한 번만 센다.
hist_lines = []
if os.path.exists(hist_path):
    hist_lines = open(hist_path, encoding='utf-8').read().splitlines()
compatible = bool(hist_lines) and hist_lines[0].strip() == HIST_FORMAT

prev, last_run = {}, 0
for ln in (hist_lines[1:] if compatible else []):
    run, _, key = ln.partition('\t')
    if not key:
        continue
    try:
        run = int(run)
    except ValueError:
        continue
    last_run = max(last_run, run)
    prev.setdefault(key, set()).add(run)

this_run = last_run + 1
with open(os.path.join(work, 'append'), 'w', encoding='utf-8') as fp:
    if not compatible:
        fp.write(HIST_FORMAT + "\n")
    for key in (list(dict.fromkeys(keys)) or [NO_FINDING]):
        fp.write(f"{this_run}\t{key}\n")

if not compatible:
    # 누적은 등록에 성공한 뒤에만 한다. 여기서는 갈아엎어야 한다는 사실만 남긴다.
    open(os.path.join(work, 'reset'), 'w', encoding='utf-8').close()

# 연속한 회차만 센다. 중간에 한 회차라도 그 파일에서 blocker·major 가 나오지 않았으면
# 직전 수정이 그 파일을 닫았다는 뜻이라, 다시 1 회차부터다.
with open(os.path.join(work, 'repeat'), 'w', encoding='utf-8') as fp:
    for key in dict.fromkeys(keys):
        runs = prev.get(key, set()) | {this_run}
        streak = 0
        while this_run - streak in runs:
            streak += 1
        if streak >= repeat_max:
            fp.write(f"{streak}\t{key}\n")
PY

if [ "$parse_rc" -ne 0 ]; then
  echo "help: nothing was posted — the raw review follows" >&2
  cat "$body" >&2
  exit 2
fi

read -r n_blocker n_major n_minor < "$work/counts"
blocking=$((n_blocker + n_major))
if [ "$blocking" -gt 0 ]; then computed="CHANGES_REQUESTED"; else computed="PASS"; fi

inline_ok=0
inline_fail=0
while IFS=$'\t' read -r -d '' file line note; do
  if err=$(review_mr_note_inline "$mr" "$file" "$line" "$note" 2>&1 >/dev/null); then
    inline_ok=$((inline_ok + 1))
  else
    # 이번 diff 에 없는 줄이면 실패한다. 줄 번호를 추측해 재시도하지 않는다 —
    # 해당 발견은 아래 요약 본문에 그대로 남는다.
    inline_fail=$((inline_fail + 1))
    echo "warning: inline comment failed (it still appears in the summary): $file:$line — $(printf '%s' "$err" | tr -d '\n' | tail -c 200)" >&2
  fi
done < "$work/inline"

{
  echo "$FMT_SUMMARY_HEADING ($label)"
  echo
  echo "> \`script/post-review.sh\` 가 등록했다. 판정은 참고용이며 머지 승인은 사람이 한다."
  echo ">"
  echo "> 발견 blocker $n_blocker · major $n_major · minor $n_minor → **판정 $computed**"
  echo "> (minor 는 판정에 넣지 않는다.)"
  # 다음 회차의 증분 기준. 로컬이 아니라 원격 노트에 남겨야 클론이 바뀌어도 살아남는다.
  if [ -n "$head_sha" ]; then
    echo ">"
    echo "> $FMT_REVIEWED_HEAD \`$head_sha\`"
  fi
  if [ "$declared" != "REVIEW_VERDICT: $computed" ]; then
    echo ">"
    echo "> 리뷰 본문의 선언은 \`$declared\` 였다. 판정은 발견 등급 집계를 따른다."
  fi
  if [ -s "$work/repeat" ]; then
    echo ">"
    echo "> **한 파일에 blocker·major 가 ${REVIEW_REPEAT_FILE_MAX}회차 연속 나왔다. 루프를 여기서 멈춘다** — 코드가 아니라 명세를 다시 본다."
    while IFS=$'\t' read -r seen key; do
      echo "> - ${seen}회차 연속: \`$key\`"
    done < "$work/repeat"
  fi
  if [ "$inline_fail" -gt 0 ]; then
    echo ">"
    echo "> 인라인 $inline_fail 건은 해당 줄이 이번 diff 에 없어 달지 못했다. 아래 본문을 참조한다."
  fi
  echo
  cat "$body"
} > "$work/note.md"

review_mr_note_summary "$mr" "$work/note.md" \
  || { echo "error: posting the summary failed — the review body follows:" >&2; cat "$work/note.md" >&2; exit 2; }

# 등록에 성공한 회차만 누적한다. 등록 실패는 리뷰가 남지 않았으므로 회차로 세지 않는다.
if [ -f "$work/reset" ]; then : > "$hist"; fi
cat "$work/append" >> "$hist"

echo "posted to $mr: $inline_ok inline, 1 summary · blocker $n_blocker · major $n_major · minor $n_minor -> $computed"

if [ -s "$work/repeat" ]; then
  echo "stop: the same file drew a blocker or major ${REVIEW_REPEAT_FILE_MAX} rounds running — more edits will not fix this" >&2
  while IFS=$'\t' read -r seen key; do echo "  - $seen rounds running: $key" >&2; done < "$work/repeat"
  echo "help: stop editing, propose returning to the spec stage, and hand off" >&2
  exit 3
fi

[ "$computed" = "PASS" ] && exit 0 || exit 1
