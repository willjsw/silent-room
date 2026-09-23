#!/usr/bin/env bash
# 이월 이슈 생성의 회귀 테스트 — 본문 검사·제목 검사·상속 값 누락·중복 제목·드라이런·인수 검증.
#
#   script/test-carryover-issue.sh
#
# 종료 코드: 0 = 전 케이스 통과 · 1 = 실패한 케이스 있음 · 2 = 실행 실패
#
# 원격을 부르지 않는다. 임시 리포에 검사 대상 스크립트를 복사하고 **forge 어댑터를 페이크로
# 갈아끼워** 종료 코드와 생성 호출 여부만 본다. 어느 forge 를 쓰든 같은 테스트가 돈다 —
# 페이크가 지키는 것은 `script/forge/_common.sh` 의 계약뿐이다.
#
# **실제 이슈를 만들지 않는 것이 이 테스트의 전제다** — 삭제가 금지된 프로젝트에서는 되돌릴 수 없다.
set -uo pipefail

command -v python3 >/dev/null || { echo "error: python3 is required to run this test" >&2; exit 2; }

repo_root=$(git rev-parse --show-toplevel) || exit 2
. "$repo_root/script/harness.env"
. "$repo_root/script/harness-format.sh"

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

work="$sandbox/repo"
state="$sandbox/state"
mkdir -p "$state" "$work/script" "$work/.ai/templates"

cp "$repo_root/script/create-carryover-issue.sh" "$work/script/"
cp "$repo_root/script/harness.env" "$repo_root/script/harness-format.sh" "$work/script/"
cp "$repo_root/.ai/templates/issue-task.md" "$work/.ai/templates/"
chmod +x "$work/script/"*.sh
git -C "$work" init -q >/dev/null 2>&1 || { echo "error: could not create the temp repo" >&2; exit 2; }

# ── forge 페이크 ────────────────────────────────────────────────────────────
# 계약(`script/forge/_common.sh` 상단)이 정한 정규화 JSON 을 상태 파일에서 돌려준다.
cat > "$work/script/forge.sh" <<'FAKE'
#!/usr/bin/env sh
tracker_require() { return 0; }
review_require()  { return 0; }
tracker_issue_view() { cat "$FAKE_STATE/meta.json"; }
tracker_issue_list() { cat "$FAKE_STATE/issues.json"; }
tracker_issue_create() {
  # 인수를 한 줄로 눌러 기록한다 — 호출 횟수를 줄 수로 센다.
  printf 'title=%s label=%s assignee=%s milestone=%s\n' "$1" "$3" "$4" "$5" >> "$FAKE_STATE/create-calls"
  echo 42
}
FAKE

# ── 조회 응답 (정규화 JSON) ─────────────────────────────────────────────────
echo '[]' > "$sandbox/issues-none.json"
printf '[{"iid":"7","title":"chore: 이월 대상 정리","state":"opened"}]\n' > "$sandbox/issues-dup.json"
printf '{"iid":"100","title":"원본","state":"opened","description":"","labels":[],"assignee":"user-a","milestone":"M1"}\n' > "$sandbox/meta-full.json"
# 필수 필드마다 그것만 비운 응답을 만든다. 목록은 설정이 갖는다 —
# 여기 박아 두면 필수 필드를 줄인 프로젝트에서 테스트가 거짓으로 실패한다.
for f in $ISSUE_REQUIRED_FIELDS; do
  python3 - "$sandbox/meta-no-$f.json" "$f" <<'PY'
import json, sys
meta = {"iid": "100", "title": "원본", "state": "opened", "description": "",
        "labels": [], "assignee": "user-a", "milestone": "M1"}
meta[sys.argv[2]] = ""
json.dump(meta, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PY
done
printf 'not json\n' > "$sandbox/broken.json"

# ── 본문 ────────────────────────────────────────────────────────────────────
cat > "$sandbox/good.md" <<'MD'
## 상위 Requirement

- relates to #100

## 작업 내용

- 등록 스크립트의 인라인 실패를 요약에만 남긴다 — 리뷰 7회차의 지적

## 브랜치

- 착수할 때 정한다

## 단위 테스트 항목

| ID | 테스트 내용 | 입력 | 기대 결과 |
| --- | --- | --- | --- |
| UT-01 | 착수 시 작성 | | |
MD

printf '\n   \n' > "$sandbox/empty.md"
printf '<!-- 주석만 있고 내용이 없다 -->\n' > "$sandbox/comment-only.md"
cp "$work/.ai/templates/issue-task.md" "$sandbox/template.md"

# 작업 내용 절이 빈 리스트 마커만 남은 본문 — 양식 원문과 같지는 않지만 채워지지 않았다.
python3 - "$sandbox/good.md" "$sandbox/no-work.md" "$FMT_ISSUE_WORK" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
out = re.sub(r"(## %s\n\n).*?\n\n" % re.escape(sys.argv[3]), r"\1-\n\n", src, count=1, flags=re.S)
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY

sed 's/relates to #100/relates to/'  "$sandbox/good.md" > "$sandbox/no-relates.md"
sed 's/relates to #100/relates to #101/' "$sandbox/good.md" > "$sandbox/other-relates.md"

# ── 실행 도우미 ─────────────────────────────────────────────────────────────
pass=0; fail=0
check() { # <ID> <무엇> <기대> <실제>
  if [ "$3" = "$4" ]; then
    pass=$((pass + 1))
  else
    echo "  FAIL $1 $2 → want '$3', got '$4'" >&2; fail=$((fail + 1))
  fi
}

setup() { # <목록응답> <원본이슈응답>
  cp "$1" "$state/issues.json"
  cp "$2" "$state/meta.json"
  rm -f "$state/create-calls"
}

create_calls() { [ -f "$state/create-calls" ] && wc -l < "$state/create-calls" | tr -d ' ' || echo 0; }

run() {
  ( cd "$work" && FAKE_STATE="$state" \
      script/create-carryover-issue.sh "$@" >"$state/last.out" 2>"$state/last.err" )
  echo $?
}

title="chore: 이월 대상 정리"

echo "UT-01 a filled body with inheritable values creates the issue"
setup "$sandbox/issues-none.json" "$sandbox/meta-full.json"
check UT-01 "exit code" 0 "$(run 100 "$title" "$sandbox/good.md")"
check UT-01 "output" "#42 created" "$(cat "$state/last.out")"
check UT-01 "create calls" 1 "$(create_calls)"
check UT-01 "task label" 1 "$(grep -c "label=$ISSUE_LABEL_TASK" "$state/create-calls")"
check UT-01 "assignee inherited" 1 "$(grep -c 'assignee=user-a' "$state/create-calls")"
check UT-01 "milestone inherited" 1 "$(grep -c 'milestone=M1' "$state/create-calls")"
# 상속은 필수 여부와 무관하게 값이 있으면 넘긴다. 위 둘은 원본에 둘 다 있는 경우다.

echo "UT-02 a same-titled issue is reported, not created again"
setup "$sandbox/issues-dup.json" "$sandbox/meta-full.json"
check UT-02 "exit code" 0 "$(run 100 "$title" "$sandbox/good.md")"
check UT-02 "output" "#7 skip(opened)" "$(cat "$state/last.out")"
check UT-02 "create calls" 0 "$(create_calls)"

echo "UT-03 a dry run creates nothing"
setup "$sandbox/issues-none.json" "$sandbox/meta-full.json"
check UT-03 "exit code" 0 "$(run 100 "$title" "$sandbox/good.md" --dry-run)"
check UT-03 "create calls" 0 "$(create_calls)"
check UT-03 "body preview" 1 "$(grep -c -- '--- body ---' "$state/last.out")"

echo "UT-04 an unfilled body is rejected"
for c in "empty body:$sandbox/empty.md" "comment only:$sandbox/comment-only.md" \
         "template verbatim:$sandbox/template.md" "empty work section:$sandbox/no-work.md" \
         "no parent reference:$sandbox/no-relates.md" "other issue reference:$sandbox/other-relates.md" \
         "missing file:$sandbox/nonexistent.md"; do
  setup "$sandbox/issues-none.json" "$sandbox/meta-full.json"
  check UT-04 "${c%%:*} — exit code" 2 "$(run 100 "$title" "${c#*:}")"
  check UT-04 "${c%%:*} — create calls" 0 "$(create_calls)"
done

echo "UT-05 a missing required field blocks creation (required: ${ISSUE_REQUIRED_FIELDS:-none})"
# 드라이런도 같은 조건으로 거부한다 — 만들기 전 확인이 성공으로 보이면 확인이 아니다.
for f in $ISSUE_REQUIRED_FIELDS; do
  setup "$sandbox/issues-none.json" "$sandbox/meta-no-$f.json"
  check UT-05 "$f missing — exit code" 2 "$(run 100 "$title" "$sandbox/good.md")"
  check UT-05 "$f missing — create calls" 0 "$(create_calls)"
  setup "$sandbox/issues-none.json" "$sandbox/meta-no-$f.json"
  check UT-05 "$f missing — dry run exit code too" 2 "$(run 100 "$title" "$sandbox/good.md" --dry-run)"
  check UT-05 "$f missing — no dry-run preview" 0 "$(grep -c -- '--- body ---' "$state/last.out")"
done
[ -n "$ISSUE_REQUIRED_FIELDS" ] || echo "  (no required fields — case skipped)"

echo "UT-06 a malformed title is rejected"
# 태그가 어긋나면 이 이슈로 만든 커밋이 나중에 훅에 막힌다. 만들기 전에 잡는다.
setup "$sandbox/issues-none.json" "$sandbox/meta-full.json"
check UT-06 "no tag — exit code" 2 "$(run 100 "이월 대상 정리" "$sandbox/good.md")"
check UT-06 "unknown tag — exit code" 2 "$(run 100 "task: 이월 대상 정리" "$sandbox/good.md")"
check UT-06 "create calls" 0 "$(create_calls)"

echo "UT-07 argument validation"
setup "$sandbox/issues-none.json" "$sandbox/meta-full.json"
check UT-07 "too few arguments — exit code" 2 "$(run 100 "$title")"
check UT-07 "mistyped option — exit code" 2 "$(run 100 "$title" "$sandbox/good.md" --dryrun)"
check UT-07 "create calls" 0 "$(create_calls)"

echo "UT-08 a malformed lookup response stops the run"
# 조회하지 못한 것을 "결과 없음" 으로 읽으면 같은 이슈를 다시 만든다.
setup "$sandbox/issues-none.json" "$sandbox/broken.json"
check UT-08 "source issue is not JSON — exit code" 2 "$(run 100 "$title" "$sandbox/good.md")"
setup "$sandbox/broken.json" "$sandbox/meta-full.json"
check UT-08 "issue list is not JSON — exit code" 2 "$(run 100 "$title" "$sandbox/good.md")"
check UT-08 "create calls" 0 "$(create_calls)"

echo
if [ "$fail" -gt 0 ]; then
  echo "carryover issue test failed: ${pass} passed, ${fail} failed" >&2
  echo "last run output:" >&2
  cat "$state/last.out" "$state/last.err" >&2
  exit 1
fi
echo "carryover issue test passed: ${pass} cases"
