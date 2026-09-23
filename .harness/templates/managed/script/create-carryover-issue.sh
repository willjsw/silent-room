#!/usr/bin/env bash
# 리뷰에서 범위 밖으로 넘긴 지적을 받을 이슈를 만든다.
#
#   script/create-carryover-issue.sh <원본이슈번호> <제목> <본문파일> [--dry-run]
#
# 종료 코드: 0 = 생성 완료 또는 같은 제목이 이미 있음 · 2 = 실행 실패
#
# 원본 이슈는 이 지적이 나온 리뷰 요청이 닫는 이슈다. 필수 필드를 거기서 물려받고,
# 본문이 그 이슈를 참조하는지도 이 번호로 확인한다.
#
# 본문을 인수가 아니라 파일로 받는다. 지적마다 내용이 다르고 줄바꿈·표·코드블록이 들어가서
# 셸 인수로 넘기면 따옴표 처리에서 깨진다.
#
# **본문이 비었거나 채워지지 않았으면 만들지 않는다.** 이슈 삭제를 금지한 프로젝트에서
# 빈 이슈는 닫힌 채 영구히 남고, 나중에 그것을 채우는 사람은 지적의 맥락을 갖고 있지 않다.
# 세 가지를 본다 — 내용이 있는가, task 이슈 양식 원문 그대로가 아닌가, 작업 내용 절과
# 상위 참조가 채워졌는가.
#
# 제목으로 기존 이슈를 찾아 **있으면 만들지 않고 그 번호를 돌려준다.** 두 번 돌려도 중복이
# 생기지 않는다 — 단 **순차 실행 기준이다.** 동시 실행은 지원하지 않는다.
#
# 출력은 `#42 created` 또는 `#42 skip(opened)` 한 줄. 구현자는 이 번호를 리뷰 답글에 남긴다.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. script/harness.env
. script/harness-format.sh
. script/forge.sh

usage() { echo "usage: script/create-carryover-issue.sh <source-issue-number> <title> <body-file> [--dry-run]" >&2; exit 2; }

# 네 번째 인수를 느슨하게 받으면 `--dryrun` 같은 오타가 조용히 실제 생성 모드가 된다.
[ $# -ge 3 ] && [ $# -le 4 ] || usage
case "${4:-}" in ""|--dry-run) ;; *) echo "error: unknown option: $4" >&2; usage ;; esac
parent="$1"; title="$2"; bodyfile="$3"; dry="${4:-}"

[ -f "$bodyfile" ] || { echo "error: body file not found: $bodyfile" >&2; exit 2; }

# 제목은 커밋 제목과 같은 태그 어휘를 쓴다. 태그가 없거나 모르는 태그면 이 이슈로 만든 커밋이
# 나중에 훅에 막힌다 — 만들기 전에 잡는다.
case "$title" in
  *:\ *) ;;
  *) echo "stop: title has no tag — expected '<tag>: <summary>', got '$title'" >&2; exit 2 ;;
esac
if ! printf '%s' "${title%%:*}" | grep -qxE "$COMMIT_TAGS"; then
  echo "stop: unknown tag '${title%%:*}' — allowed tags: $COMMIT_TAGS_HUMAN" >&2
  exit 2
fi
tracker_require || exit 2
command -v python3 >/dev/null || { echo "error: python3 is not installed" >&2; exit 2; }

ref() { printf '%s' "$ISSUE_REF_DISPLAY" | sed "s|{id}|$1|"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tracker_issue_view "$parent" > "$work/parent.json" || {
  echo "stop: could not read source issue $parent" >&2; exit 2; }
tracker_issue_list > "$work/issues.json" || {
  echo "stop: could not list issues — refusing to create any without a duplicate check" >&2; exit 2; }

template=.ai/templates/issue-task.md
[ -f "$template" ] || template=/dev/null

existing=$(python3 - "$parent" "$title" "$bodyfile" "$work" "$template" \
                    "$ISSUE_REQUIRED_FIELDS" "$FMT_ISSUE_WORK" "$FMT_ISSUE_RELATES" <<'PY'
import json, re, sys

parent, title, bodyfile, work, template, required, work_sec, relates = sys.argv[1:9]


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


meta = json.load(open(f"{work}/parent.json", encoding="utf-8"))
issues = json.load(open(f"{work}/issues.json", encoding="utf-8"))
body = open(bodyfile, encoding="utf-8").read()

if not body.strip():
    die("stop: the body is empty — an empty issue survives without the context that made it")

try:
    original = open(template, encoding="utf-8").read()
except OSError:
    original = ""
if original.strip() and body.strip() == original.strip():
    die("stop: the body is still the unfilled task-issue template — write the finding into it")


def section(name):
    """`## <이름>` 절의 본문. 다음 제목에서 끝난다."""
    m = re.search(r"^#{1,6}\s+%s\s*$" % re.escape(name), body, re.M)
    if not m:
        return None
    rest = body[m.end():]
    nxt = re.search(r"^#{1,6}\s+", rest, re.M)
    return (rest[:nxt.start()] if nxt else rest)


filled = section(work_sec)
if filled is None:
    die("stop: the body has no '%s' section" % work_sec)
if not re.sub(r"<!--.*?-->", "", filled, flags=re.S).strip(" \n\t-"):
    die("stop: the '%s' section is empty — state the finding and the files it touches" % work_sec)

if not re.search(r"%s\s+\S*%s(?![0-9A-Za-z])" % (re.escape(relates), re.escape(parent)), body):
    die("stop: the body does not point back at source issue %s with '%s'" % (parent, relates))

missing = [f for f in required.split() if not (meta.get(f) or "").strip()]
if missing:
    die("stop: source issue %s has no %s, and a carryover issue must inherit it\n"
        "help: set it on the source issue first, then rerun" % (parent, ", ".join(missing)))

hit = next((x for x in issues if (x.get("title") or "").strip() == title.strip()), None)
print(hit["iid"] if hit else "")
PY
) || exit 2

if [ -n "$existing" ]; then
  state=$(python3 -c '
import json, sys
hit = next(x for x in json.load(open(sys.argv[1])) if x["iid"] == sys.argv[2])
print(hit.get("state") or "")' "$work/issues.json" "$existing")
  echo "$(ref "$existing") skip($state)"
  exit 0
fi

if [ "$dry" = "--dry-run" ]; then
  # 만들기 전에 무엇이 들어가는지 보여 준다. 검사를 전부 통과한 뒤라야 의미가 있다.
  echo "(dry-run) create  $title"
  echo "--- body ---"
  cat "$bodyfile"
  exit 0
fi

assignee=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["assignee"])' "$work/parent.json")
milestone=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["milestone"])' "$work/parent.json")

new=$(tracker_issue_create "$title" "$bodyfile" "$ISSUE_LABEL_TASK" "$assignee" "$milestone") || {
  echo "stop: issue creation failed — $title" >&2; exit 2; }
[ -n "$new" ] || { echo "stop: could not read the number of the issue just created — $title" >&2; exit 2; }
echo "$(ref "$new") created"
