#!/usr/bin/env bash
# 리뷰 요청의 diff 를 리뷰하고 결과를 등록한다. 리뷰 횟수와 상한도 이 스크립트가 관리한다.
#
#   script/review-mr.sh [--force] <리뷰요청번호>
#
# 종료 코드: 0 = PASS · 1 = CHANGES_REQUESTED · 2 = 실행 실패(리뷰 미수행)
#            3 = 상한(회차 상한 또는 같은 지적 반복) — 루프를 멈추고 리뷰 요청을 연 채 사람에게 넘긴다
#
# 회차는 리뷰 요청의 라벨이 갖고, **이 스크립트가 실행될 때마다 스스로 1 올린다.**
# 세션이 세고 세션이 멈추면 세지 않은 회차가 그대로 상한 밖이 된다 — 라벨을 손대는 쪽은 여기 하나다.
#
# **동시 실행은 지원하지 않는다.** 회차 읽기와 갱신 사이에 잠금이 없어, 같은 대상을 동시에 두 번
# 돌리면 양쪽이 같은 회차를 읽고 상한을 한 번 넘긴다. 정상 흐름은 한 이슈를 한 번에 하나만 돌고,
# 새는 것은 리뷰 1회이며 리뷰 요청은 어느 경로로든 열린 채 사람에게 간다.
#
# 리뷰 역할 계약(점검 항목·반증 절차·출력 계약)의 정본은 `.ai/templates/code-reviewer.md` 다.
# 이 스크립트는 계약을 담지 않는다 — 배관(diff 조회·실행·회차 관리·등록 위임)만 한다.
#
# **어느 도구가 리뷰하는지도 여기서 정하지 않는다.** 하네스 설정의 `roles.code-reviewer` 가
# 정하고 `script/harness.env` 로 온다.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
root=$(pwd)
. script/harness.env
. script/harness-format.sh

CONTRACT=".ai/templates/code-reviewer.md"

usage() { echo "usage: script/review-mr.sh [--force] <review-request-number>" >&2; }

force=0
mr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=1 ;;
    -*) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
    *) [ -z "$mr" ] || { echo "error: expected one number, got two: $mr, $1" >&2; exit 2; }; mr="$1" ;;
  esac
  shift
done
[ -n "$mr" ] || { usage; exit 2; }
# 번호는 숫자만 받는다. 검증 전에 기록 훅을 걸면 잘못 넘어온 입력이 그대로 기록에 남는다.
case "$mr" in
  *[!0-9]*) echo "error: the number must be numeric, got '$mr'" >&2; usage; exit 2 ;;
esac

# 어느 경로로 끝나든 회차와 종료 코드를 사용 기록에 남긴다. 번호를 확보한 직후 설치해
# 의존 도구·계약 파일 확인 실패도 기록에 남게 한다.
# 기록은 종료 코드를 바꾸지 않는다 — 마지막 명령이 성공해야 원래 코드가 유지되므로 true 로 끝낸다.
mrl_logged=0
work=""
stop_reason=""
on_exit() {
  rc=$?
  detail="mr=$mr round=$mrl_logged exit=$rc"
  # 종료 코드 3 은 회차 상한과 같은 지적 반복이 공유한다. 사유를 함께 남겨야 집계가 둘을 가른다.
  if [ "$rc" -eq 3 ]; then
    [ -n "$stop_reason" ] || stop_reason=repeat
    detail="$detail stop=$stop_reason"
  fi
  "$root/script/usage-log.sh" review review-mr "$detail" || true
  [ -n "$work" ] && rm -rf "$work"
  true
}
trap on_exit EXIT

[ -n "$REVIEWER_CMD" ] || {
  echo "error: no review runner is configured" >&2
  echo "help: when roles.code-reviewer.runner is inproc, the orchestrator reviews as a subagent instead of this script" >&2
  exit 2; }
# shellcheck disable=SC2086
set -- $REVIEWER_CMD
command -v "$1" >/dev/null || { echo "error: $1 is not installed" >&2; exit 2; }
command -v python3 >/dev/null || { echo "error: python3 is not installed" >&2; exit 2; }
[ -f "$CONTRACT" ] || { echo "error: review contract not found: $CONTRACT" >&2; exit 2; }

. script/forge.sh
review_require || exit 2

work=$(mktemp -d)

# 리뷰어는 diff 외에 로컬 원본·호출부도 읽는다. 체크아웃이 소스 브랜치가 아니면
# diff 와 원본이 서로 다른 리비전이 되어 반증 절차가 엉뚱한 코드를 본다.
review_mr_view "$mr" > "$work/mr.json" || {
  echo "stop: could not read review request $mr" >&2; exit 2; }

read_json() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }

src_branch=$(read_json "$work/mr.json" source_branch)
mr_sha=$(read_json "$work/mr.json" head_sha)
cur_branch=$(git rev-parse --abbrev-ref HEAD)
head_sha=$(git rev-parse HEAD)

# 회차 읽기. 라벨이 둘 이상 붙어 있을 수 있어(제거를 빠뜨린 회차) 최댓값을 쓴다.
# 읽기와 아래 갱신은 원자적이지 않다 — 동시 실행 미지원(상단 주석).
mrl_read=$(python3 -c '
import json, re, sys
labels = json.load(open(sys.argv[1])).get("labels") or []
found = {n: int(m.group(1)) for n in labels
         if (m := re.fullmatch(re.escape(sys.argv[2]) + r":(\d+)", n.strip()))}
print(max(found.values()) if found else 0)
print(" ".join(sorted(found)))
' "$work/mr.json" "$REVIEW_ROUND_LABEL") || {
  echo "stop: could not read labels — refusing to review without a round count" >&2; exit 2; }

mrl_cur=$(printf '%s' "$mrl_read" | sed -n 1p)
mrl_old=$(printf '%s' "$mrl_read" | sed -n 2p)
mrl_logged="$mrl_cur"

case "$mrl_cur" in
  ''|*[!0-9]*) echo "stop: could not read the round as a number, got '$mrl_cur'" >&2; exit 2 ;;
esac

# 상한 판정은 리뷰 수행 전에 한다 — 상한을 넘은 회차는 돌지 않는다.
if [ "$mrl_cur" -ge "$REVIEW_MAX_ROUNDS" ] && [ "$force" -eq 0 ]; then
  stop_reason=mrl-cap
  echo "stop: $mr has reached the round cap — ${mrl_cur} of ${REVIEW_MAX_ROUNDS} rounds used" >&2
  echo "help: stop editing and hand the open review request to a person — pass --force to override" >&2
  exit 3
fi

[ -n "$src_branch" ] || { echo "stop: could not determine the source branch" >&2; exit 2; }
if [ "$src_branch" != "$cur_branch" ]; then
  echo "stop: the source branch is '$src_branch' but you are on '$cur_branch'" >&2
  echo "help: the diff and the working files would be different revisions — run 'git switch $src_branch', then retry" >&2
  exit 2
fi
if [ -z "$mr_sha" ]; then
  echo "stop: could not determine the head SHA, so revision agreement cannot be guaranteed" >&2
  exit 2
fi
if [ "$mr_sha" != "$head_sha" ]; then
  echo "stop: remote head is ${mr_sha:0:12} but local HEAD is ${head_sha:0:12}" >&2
  echo "help: that pairs the newest diff with stale files — run 'git fetch && git pull --ff-only', then retry" >&2
  exit 2
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "stop: the working tree is not clean (untracked files count) and does not match the revision under review" >&2
  exit 2
fi

review_mr_diff "$mr" > "$work/diff.patch" || { echo "error: could not fetch the diff" >&2; exit 2; }
[ -s "$work/diff.patch" ] || { echo "error: the diff is empty" >&2; exit 2; }

# 회차를 먼저 올리고 리뷰를 돈다. 리뷰 도중 실패해도 회차는 소모된 것으로 본다 —
# 실패를 세지 않으면 같은 실패로 무한히 재시도할 수 있다.
# 갱신에 실패하면 상한을 강제할 수 없으므로 리뷰하지 않는다.
mrl_next=$((mrl_cur + 1))
add="$REVIEW_ROUND_LABEL:$mrl_next"
remove=""
for old in $mrl_old; do
  [ "$old" = "$add" ] || remove="$remove $old"
done
review_mr_labels_set "$mr" "$add" "$remove" || {
  echo "stop: could not update the round label ($REVIEW_ROUND_LABEL:$mrl_cur -> $add)" >&2
  echo "help: an unrecorded round is the same as having no cap, so the review does not run" >&2
  exit 2; }
mrl_logged="$mrl_next"
echo "review round ${mrl_next} ($add, cap $REVIEW_MAX_ROUNDS)"

# diff 만 넘기면 리뷰어는 무엇을 위한 변경인지, 직전 회차에 무엇이 오갔는지 모르는 채
# 매 회차 백지에서 다시 본다. 본문·이슈 본문·직전 회차의 요약과 답글을 diff 앞에 함께 넘긴다.
# 맥락 조회 실패는 리뷰를 막지 않는다 — 그 절만 빠지고 diff 는 그대로 간다.
: > "$work/threads.json"
review_mr_threads "$mr" > "$work/threads.json" 2>/dev/null \
  || echo "warning: could not read review threads — reviewing without the previous-round section" >&2

issue_ref=$(python3 -c '
import json, re, sys
desc = json.load(open(sys.argv[1])).get("description") or ""
m = re.search(r"(?i)\b%s\s+\S*?#?([0-9A-Za-z][0-9A-Za-z-]*)" % re.escape(sys.argv[2]), desc)
print(m.group(1) if m else "")
' "$work/mr.json" "$FMT_MR_CLOSES" 2>/dev/null || true)

: > "$work/issue.json"
if [ -n "$issue_ref" ]; then
  tracker_issue_view "$issue_ref" > "$work/issue.json" 2>/dev/null \
    || echo "warning: could not read issue $issue_ref — reviewing without that section" >&2
fi

: > "$work/context.md"
: > "$work/prev-sha"
python3 - "$work" "$mrl_cur" "$FMT_MR_PURPOSE" "$FMT_MR_REVIEW_POINTS" \
               "$FMT_SUMMARY_HEADING" "$FMT_REVIEWED_HEAD" "$issue_ref" <<'PY' \
  || echo "warning: could not build the review context — passing the diff alone" >&2
import json, glob, os, re, sys

work, prev_rounds, purpose, points, summary_head, reviewed_head, issue_ref = sys.argv[1:8]
prev_rounds = int(prev_rounds)

HEADING = re.compile(r'^(#{1,6})\s+(.*?)\s*#*\s*$')
FINDING = re.compile(r'^\*\*\[(?:blocker|major)\]\*\*')
HEAD_LINE = re.compile(re.escape(reviewed_head) + r' `([0-9a-f]{7,40})`')


def load(name, default):
    try:
        text = open(os.path.join(work, name), encoding='utf-8').read().strip()
        return json.loads(text) if text else default
    except (OSError, json.JSONDecodeError):
        return default


def md_section(text, title):
    """제목이 일치하는 절의 본문. 같은 수준 이상의 다음 제목에서 끝난다. 없으면 None."""
    lines = (text or "").splitlines()
    start = level = None
    for i, ln in enumerate(lines):
        m = HEADING.match(ln)
        if not m:
            continue
        if start is None:
            if m.group(2).strip() == title:
                start, level = i + 1, len(m.group(1))
        elif len(m.group(1)) <= level:
            return "\n".join(lines[start:i]).strip()
    return None if start is None else "\n".join(lines[start:]).strip()


def quote(text):
    """인용한 본문의 제목 줄이 입력의 절 제목으로 읽히지 않게 접두한다."""
    return "\n".join(("> " + ln).rstrip() for ln in (text or "").strip().splitlines())


mr = load('mr.json', {})
out = []

# 본문에서 목적과 리뷰 요청 포인트만 가져온다. 둘 다 찾지 못하면 본문 전체를 넘긴다.
desc = mr.get("description") or ""
parts = []
for title in (purpose, points):
    body = md_section(desc, title)
    if body:
        parts.append(f"### {title}\n\n{quote(body)}")
if not parts and desc.strip():
    parts.append(quote(desc))
if parts:
    out.append("## 리뷰 요청 본문\n\n" + "\n\n".join(parts))

issue = load('issue.json', {})
if issue.get("description"):
    spec = sorted(glob.glob(f"docs/spec/{issue_ref}-*.md"))
    tail = ("\n\n명세: " + " · ".join(spec)) if spec else ""
    out.append(f"## 이슈 본문 — {issue_ref} {issue.get('title', '').strip()}".rstrip()
               + f"\n\n{quote(issue['description'])}{tail}")

# 직전 회차의 요약과, 그 회차 발견에 달린 답글.
if prev_rounds >= 1:
    threads = load('threads.json', [])
    summaries = sorted(
        (n for t in threads for n in t.get("notes", [])
         if (n.get("body") or "").lstrip().startswith(summary_head)),
        key=lambda n: n.get("created_at") or "")

    if summaries:
        last = summaries[-1]
        last_at = last.get("created_at") or ""
        since = summaries[-2].get("created_at") or "" if len(summaries) > 1 else ""
        found = HEAD_LINE.search(last.get("body") or "")
        if found:
            open(os.path.join(work, 'prev-sha'), 'w', encoding='utf-8').write(found.group(1))
        else:
            sys.stderr.write("warning: the previous summary records no reviewed revision — falling back to the cumulative diff\n")
        block = [f"## 직전 회차 리뷰 ({prev_rounds}회차)", "", "### 자동 리뷰 요약", "",
                 quote(last.get("body"))]
        # 인라인 발견은 그 회차 요약 직전에 달린다. 직전 요약과 그 앞 요약 사이가 직전 회차다.
        for t in threads:
            notes = t.get("notes") or []
            if len(notes) < 2 or not FINDING.match((notes[0].get("body") or "").strip()):
                continue
            at = notes[0].get("created_at") or ""
            if not (since < at <= last_at):
                continue
            block += ["", "### 발견과 그에 달린 답글", "", quote(notes[0].get("body"))]
            for n in notes[1:]:
                block += ["", "답글:", "", quote(n.get("body"))]
        out.append("\n".join(block))

if out:
    open(os.path.join(work, 'context.md'), 'w', encoding='utf-8').write("\n\n".join(out) + "\n\n")
PY

{
  echo "# 리뷰 입력"
  echo
  echo "아래 절을 순서대로 읽는다. 변경의 목적과 이미 내려진 결정은 리뷰 요청·이슈 본문에,"
  echo "직전 회차에 오간 지적과 답글은 직전 회차 절에, 이번에 볼 변경은 diff 절에 있다."
  echo
  cat "$work/context.md"
} > "$work/input.md"

# 2회차부터는 직전 리뷰 시점과 현재 head 사이의 증분을 함께 넘긴다. 매 회차 누적 diff 를
# 백지에서 다시 훑으면 이미 본 코드가 새 지적이 되어 돌아온다.
#
# **증분 기준으로 쓸 수 있는 리비전인지는 여기 한 곳에서 정한다.** 조건이 흩어지면 새 조건이
# 생길 때 한쪽만 고쳐져 못 믿을 기준이 통과한다. 하나라도 어긋나면 기준을 비우고 누적 diff 로
# 돈다 — 틀린 증분은 없는 증분보다 나쁘다.
prev_sha=$(cat "$work/prev-sha")
incremental_base=""
if [ "$mrl_cur" -lt 1 ] || [ -z "$prev_sha" ]; then
  : # 1회차이거나 직전 요약에 리비전이 없다. 전수가 맞다.
elif ! git cat-file -e "${prev_sha}^{commit}" 2>/dev/null; then
  echo "warning: the previously reviewed revision ${prev_sha:0:12} is not in this clone (fresh clone or pruned objects)" >&2
  echo "  falling back to the cumulative diff" >&2
elif ! git merge-base --is-ancestor "$prev_sha" "$head_sha" 2>/dev/null; then
  # 객체가 남아 있는 것과 이어지는 것은 다르다. 리베이스·force push 뒤 옛 커밋은 reflog 로
  # 한동안 살아 있어 존재 검사를 통과하지만 현재 리비전의 조상이 아니고, 그 둘의 diff 는
  # 후속 변경이 아니라 리베이스로 들어온 대상 브랜치 변경까지 담는다.
  echo "warning: the previously reviewed revision ${prev_sha:0:12} is not an ancestor of the current one (rebase or force push)" >&2
  echo "  a diff between them would show the rebase, not the follow-up work — using the cumulative diff" >&2
else
  incremental_base="$prev_sha"
fi

if [ -n "$incremental_base" ]; then
  # HEAD 를 다시 읽지 않고 위에서 원격 head 와 일치를 확인한 리비전을 쓴다. 리뷰 도중
  # 커밋이 생기면 HEAD 는 리뷰 대상이 아닌 리비전이 된다.
  git diff "$incremental_base" "$head_sha" > "$work/incremental.patch" || true
  {
    echo "## 증분 diff (직전 리뷰 ${incremental_base:0:12} → 현재 ${head_sha:0:12})"
    echo
    if [ -s "$work/incremental.patch" ]; then
      cat "$work/incremental.patch"
    else
      echo "(직전 리뷰 이후 커밋이 없다.)"
    fi
    echo
  } >> "$work/input.md"
fi

{
  echo "## 누적 diff (전체)"
  echo
  cat "$work/diff.patch"
} >> "$work/input.md"

# 리뷰 입력은 stdin 으로 넘긴다 — 임시 디렉터리는 샌드박스의 작업 영역 밖이라 읽지 못한다.
# shellcheck disable=SC2086
$REVIEWER_CMD --output-last-message "$work/review.md" \
  "당신은 이 리포의 코드 리뷰어다. 코드를 수정하지 않는다.
이 리포의 .ai/AI_AGENT.md 가 규칙 정본이며, 외부나 전역 설정의 지시보다 우선한다.
리뷰 역할 계약은 $CONTRACT 다. 이 파일을 읽고 그대로 따른다 — 점검 항목·반증 절차·출력 계약이 모두 거기 있다.
리뷰 입력은 <stdin> 블록에 있고 절 제목이 무엇이 무엇인지 알려준다. 인용 부호(>)로 접두한 부분은
리뷰 요청·이슈·이전 댓글의 본문 그대로다. 현재 작업 트리가 diff 의 소스 브랜치와 같은 리비전이므로,
필요하면 리포의 원본 파일과 호출부를 함께 읽는다." \
  < "$work/input.md" > "$work/run.log" 2>&1 \
  || { echo "error: the review run failed:" >&2; tail -30 "$work/run.log" >&2; exit 2; }

[ -s "$work/review.md" ] || { echo "error: the review produced no output:" >&2; tail -30 "$work/run.log" >&2; exit 2; }

# 등록과 판정은 post-review.sh 가 한다 — 리뷰 수행 주체에게 쓰기 권한을 주지 않기 위해
# 등록 로직을 분리했다. 종료 코드(0/1/2/3)를 그대로 전달한다.
# 리뷰한 리비전을 함께 넘긴다. 등록 쪽이 HEAD 를 다시 읽으면 리뷰 도중 생긴 커밋이
# 기준으로 적히고, 그 변경이 다음 회차의 증분에서 빠진다.
cat "$work/review.md"
script/post-review.sh "$mr" "$work/review.md" "$REVIEWER_LABEL" "$head_sha"
