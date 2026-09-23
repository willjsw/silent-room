#!/usr/bin/env bash
# `docs/plan/<상위이슈>/task.md` 의 task 절을 이슈 트래커와 맞춘다.
#
#   script/sync-task-issues.sh <상위이슈번호> [--dry-run]
#
# 종료 코드: 0 = 동기화 완료 · 2 = 실행 실패(분해 없음·조회 실패·필수 값 누락 포함)
#
# 제목으로 기존 이슈를 찾아 **있으면 건너뛰고 없는 것만 만든다.** 두 번 돌려도 중복이 생기지
# 않는다 — 단 **순차 실행 기준이다.** 조회와 생성 사이에 잠금이 없어 같은 상위 이슈에 대해
# 동시에 두 번 돌리면 양쪽 다 "없음" 으로 보고 중복을 만든다. 동시 실행은 지원하지 않는다.
# 이슈 삭제를 금지한 프로젝트에서는 멱등이 아니면 잘못 만든 이슈가 닫힌 채 영구히 남는다.
#
# **분해는 로컬 작업 트리가 아니라 방금 fetch 한 원격의 통합 브랜치에서 읽는다.** 승인된
# 분해로만 이슈가 생긴다는 게이트를 스크립트 자신이 지킨다 — 미승인 브랜치에서 직접 돌려도
# 승인 전 task 이슈가 생기지 않는다.
#
# 출력은 `T1 #6 skip(opened)` 형식 한 줄씩. 구현자는 이 매핑으로 커밋 메시지의 이슈 번호를 정한다.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. script/harness.env
. script/harness-format.sh
. script/forge.sh

usage() { echo "usage: script/sync-task-issues.sh <parent-issue-number> [--dry-run]" >&2; exit 2; }

# 두 번째 인수를 느슨하게 받으면 `--dryrun` 같은 오타가 조용히 실제 생성 모드가 된다.
# 이슈 삭제가 금지된 프로젝트에서는 그 실수를 되돌릴 수 없다 — 모르는 인수는 거부한다.
[ $# -ge 1 ] && [ $# -le 2 ] || usage
case "${2:-}" in ""|--dry-run) ;; *) echo "error: unknown option: $2" >&2; usage ;; esac
parent="$1"
dry="${2:-}"

ref() { printf '%s' "$ISSUE_REF_DISPLAY" | sed "s|{id}|$1|"; }

tracker_require || exit 2
command -v python3 >/dev/null || { echo "error: python3 is not installed" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git fetch -q origin "$BASE_BRANCH" || {
  echo "stop: git fetch failed — refusing to create issues from a stale breakdown" >&2; exit 2; }
git show "FETCH_HEAD:docs/plan/$parent/task.md" > "$work/task.md" 2>/dev/null || {
  echo "stop: docs/plan/$parent/task.md is not on the remote integration branch" >&2
  echo "help: the breakdown is not approved and merged yet — rerun after it lands" >&2
  exit 2; }

tracker_issue_view "$parent" > "$work/parent.json" || {
  echo "stop: could not read parent issue $parent" >&2; exit 2; }
tracker_issue_list > "$work/issues.json" || {
  echo "stop: could not list issues — refusing to create any without a duplicate check" >&2; exit 2; }

# 계획을 먼저 세운다. 만들기 전에 전부 검사해, 절반만 만들어진 상태를 피한다.
python3 - "$parent" "$work" "$ISSUE_REF_DISPLAY" "$ISSUE_REQUIRED_FIELDS" "$FMT_TASK_HEADING" <<'PY' || exit 2
import json, os, re, sys

parent, work, ref_display, required, task_heading = sys.argv[1:6]


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


meta = json.load(open(f"{work}/parent.json", encoding="utf-8"))
issues = json.load(open(f"{work}/issues.json", encoding="utf-8"))
src = open(f"{work}/task.md", encoding="utf-8").read()

# 필수 필드는 상위 이슈에서 물려받는다. 하나라도 없으면 만들지 않는다 —
# 규칙을 깬 이슈는 삭제가 금지된 프로젝트에서 영구히 남는다.
missing = [f for f in required.split() if not (meta.get(f) or "").strip()]
if missing:
    die("stop: parent issue %s has no %s, and task issues must inherit it\n"
        "help: set it on the parent issue first, then rerun" % (parent, ", ".join(missing)))

parts = re.split(task_heading, src, flags=re.M)
if len(parts) < 4:
    die("stop: no task section found in %s (expected `## T<N> · <title>`)" % f"docs/plan/{parent}/task.md")

# split 결과는 [머리말, id, 제목, 본문, id, 제목, 본문, ...]
plan = []
for i in range(1, len(parts), 3):
    tid, head, body = parts[i], parts[i + 1].strip(), parts[i + 2]
    title = "%s(%s)" % (head, ref_display.format(id=parent))
    hit = next((x for x in issues if (x.get("title") or "").strip() == title), None)
    plan.append((tid, title, body.strip(), hit))

with open(f"{work}/plan.tsv", "w", encoding="utf-8") as fp:
    for n, (tid, title, body, hit) in enumerate(plan):
        if hit:
            fp.write("skip\t%s\t%s\t\t%s\n" % (tid, hit["iid"], hit.get("state") or ""))
            continue
        bodyfile = f"{work}/body-{n}.md"
        open(bodyfile, "w", encoding="utf-8").write(body + "\n")
        fp.write("create\t%s\t\t%s\t%s\n" % (tid, bodyfile, title))

print("breakdown tasks: %d  ·  to create: %d"
      % (len(plan), sum(1 for p in plan if not p[3])), file=sys.stderr)
PY

assignee=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["assignee"])' "$work/parent.json")
milestone=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["milestone"])' "$work/parent.json")

while IFS=$'\t' read -r action tid iid bodyfile extra; do
  case "$action" in
    skip)
      echo "$tid $(ref "$iid")  skip($extra)"
      ;;
    create)
      if [ "$dry" = "--dry-run" ]; then
        echo "$tid (dry-run) create  $extra"
        continue
      fi
      new=$(tracker_issue_create "$extra" "$bodyfile" "$ISSUE_LABEL_TASK" "$assignee" "$milestone") || {
        echo "stop: issue creation failed — $extra" >&2; exit 2; }
      [ -n "$new" ] || { echo "stop: could not read the number of the issue just created — $extra" >&2; exit 2; }
      echo "$tid $(ref "$new")  created"
      ;;
  esac
done < "$work/plan.tsv"
