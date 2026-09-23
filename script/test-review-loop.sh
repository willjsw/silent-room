#!/usr/bin/env bash
# 리뷰 루프 제어의 회귀 테스트 — 회차 라벨·상한·등급 판정·반복 지적·판정 선언 계약.
#
#   script/test-review-loop.sh
#
# 종료 코드: 0 = 전 케이스 통과 · 1 = 실패한 케이스 있음 · 2 = 실행 실패
#
# 원격도 리뷰 도구도 부르지 않는다. 임시 git 리포에 검사 대상 스크립트를 복사하고
# **forge 어댑터를 페이크로, 리뷰 도구를 PATH 앞의 스텁으로** 갈아끼워 종료 코드와 라벨
# 상태만 본다. 페이크가 지키는 것은 어댑터 계약(`script/forge/_common.sh` 상단)뿐이므로
# 어느 forge 를 쓰든 같은 테스트가 돈다 — 여기서 보는 것은 루프 제어 로직이다.
#
# **상한과 표지 문자열도 설정에서 읽는다.** 값을 픽스처에 박아 두면 설정을 바꿀 때마다
# 테스트가 깨지고, 그러면 값을 바꾸는 비용이 테스트 수정으로 돌아온다.
set -uo pipefail

command -v python3 >/dev/null || { echo "python3 is required to run this test" >&2; exit 2; }

repo_root=$(git rev-parse --show-toplevel) || exit 2
. "$repo_root/script/harness.env"
. "$repo_root/script/harness-format.sh"

# 이 테스트가 쓰는 상한. 실제 설정과 무관하게 고정해 기대값을 확정한다.
cap=5
repeat=3
# 누적 이력의 형식 판별자. 등록 스크립트가 갖는 값을 읽어 쓴다 — 박아 두면 둘이 갈린다.
hist_format=$(sed -n 's/^HIST_FORMAT = .\(#format [0-9]*\).*/\1/p' \
  "$repo_root/script/post-review.sh" | head -1)
[ -n "$hist_format" ] || { echo "could not read the history format marker" >&2; exit 2; }
ROUND=$REVIEW_ROUND_LABEL
reviewer_bin=${REVIEWER_CMD%% *}
[ -n "$reviewer_bin" ] || { echo "no review runner configured — cannot exercise the loop" >&2; exit 2; }

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

stub="$sandbox/bin"
work="$sandbox/repo"
state="$sandbox/state"
mkdir -p "$stub" "$state" "$work/script" "$work/.ai/templates"

cp "$repo_root/script/review-mr.sh" "$repo_root/script/post-review.sh" \
   "$repo_root/script/usage-log.sh" "$repo_root/script/usage-vocab.sh" \
   "$repo_root/script/harness-format.sh" "$work/script/"
cp "$repo_root/.ai/templates/code-reviewer.md" "$work/.ai/templates/"

# 상한만 이 테스트의 값으로 덮는다. 나머지는 실제 설정 그대로다.
sed -e "s/^REVIEW_MAX_ROUNDS=.*/REVIEW_MAX_ROUNDS=$cap/" \
    -e "s/^REVIEW_REPEAT_FILE_MAX=.*/REVIEW_REPEAT_FILE_MAX=$repeat/" \
    -e "s|^USAGE_LOG_PATH=.*|USAGE_LOG_PATH=off|" \
    "$repo_root/script/harness.env" > "$work/script/harness.env"
chmod +x "$work/script/"*.sh

# ── forge 페이크 ────────────────────────────────────────────────────────────
# 계약이 정한 정규화 JSON 만 돌려준다. 라벨 상태는 파일이 들고, 등록 호출은 기록만 한다.
cat > "$work/script/forge.sh" <<'FAKE'
#!/usr/bin/env sh
review_require()  { return 0; }
tracker_require() { return 0; }

review_mr_view() {
  python3 - "$(git rev-parse --abbrev-ref HEAD)" "$(git rev-parse HEAD)" \
           "$(cat "$FAKE_STATE/labels" 2>/dev/null || true)" \
           "$(cat "$FAKE_STATE/mr-description" 2>/dev/null || true)" <<'PY'
import json, sys
print(json.dumps({"iid": "1", "source_branch": sys.argv[1], "head_sha": sys.argv[2],
                  "description": sys.argv[4], "labels": sys.argv[3].split(),
                  "state": "opened"}, ensure_ascii=False))
PY
}

review_mr_diff() {
  printf 'diff --git a/script/review-mr.sh b/script/review-mr.sh\n+테스트 변경\n'
}

review_mr_labels_set() { # <n> <붙일것> <뗄것>
  _add=$2; _rm=$3
  _kept=""
  for _l in $(cat "$FAKE_STATE/labels" 2>/dev/null || true); do
    _keep=1
    for _d in $_rm; do [ "$_l" = "$_d" ] && _keep=0; done
    [ "$_keep" = 1 ] && _kept="$_kept $_l"
  done
  printf '%s\n' $_kept $_add | sort -u | tr '\n' ' ' | sed 's/ *$//' > "$FAKE_STATE/labels"
}

# 실제 어댑터와 같이 시스템 메모를 걸러 정규화해 돌려준다.
review_mr_threads() {
  [ -f "$FAKE_STATE/threads.json" ] || { echo '[]'; return 0; }
  python3 - "$FAKE_STATE/threads.json" <<'PY'
import json, sys
out = []
for t in json.load(open(sys.argv[1], encoding='utf-8')):
    notes = [n for n in t.get("notes", []) if not n.get("system")]
    if not notes:
        continue
    out.append({"inline": bool(t.get("inline")), "path": t.get("path", ""),
                "line": t.get("line", ""),
                "notes": [{"body": n.get("body", ""), "created_at": n.get("created_at", "")}
                          for n in notes]})
json.dump(out, sys.stdout, ensure_ascii=False)
PY
}

review_mr_note_inline() {
  printf 'note: inline %s %s:%s %s\n' "$1" "$2" "$3" "$4" >> "$FAKE_STATE/notes"
}

review_mr_note_summary() {
  { printf 'note: summary %s\n' "$1"; cat "$2"; } >> "$FAKE_STATE/notes"
}

tracker_issue_view() { cat "$FAKE_STATE/issue.json" 2>/dev/null || echo '{}'; }
FAKE

git -C "$work" init -q >/dev/null 2>&1 || { echo "failed to create the temp repo" >&2; exit 2; }
git -C "$work" checkout -q -b mr-source >/dev/null 2>&1
git -C "$work" add -A
git -C "$work" -c core.hooksPath="$sandbox/nohooks" -c user.email=test@example.invalid \
  -c user.name=test commit -qm "init" || { echo "failed to commit in the temp repo" >&2; exit 2; }

# ── 리뷰 도구 스텁 ──────────────────────────────────────────────────────────
cat > "$stub/$reviewer_bin" <<'STUB'
#!/usr/bin/env bash
# 리뷰 도구 스텁. 호출 흔적과 받은 입력을 남기고 준비된 리뷰 본문을 결과 파일로 넘긴다.
set -uo pipefail
echo "called" >> "$FAKE_STATE/reviewer-calls"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "--output-last-message" ] && out="$a"
  prev="$a"
done
cat > "$FAKE_STATE/reviewer-input"   # stdin 으로 온 리뷰 입력
# 리뷰 도중 커밋이 생기는 상황을 재현한다. 기록되는 리비전이 리뷰한 것인지 보기 위한 것이다.
if [ -n "${STUB_COMMIT:-}" ]; then
  echo "리뷰 도중 변경" > "$STUB_COMMIT"
  git add -A
  git -c core.hooksPath=/nonexistent -c user.email=test@example.invalid -c user.name=test \
    commit -qm "during review"
fi
[ -n "$out" ] || { echo "stub: did not receive --output-last-message" >&2; exit 1; }
cp "$STUB_REVIEW" "$out"
STUB
chmod +x "$stub/$reviewer_bin"

# ── 리뷰 본문 ───────────────────────────────────────────────────────────────
cat > "$sandbox/clean.md" <<'MD'
## 요약

변경은 목적에 맞고 문제를 찾지 못했다.

## 발견 사항

발견 사항 없음

## 잘된 점

- 종료 코드 규약을 지켰다

REVIEW_VERDICT: PASS
MD

cat > "$sandbox/minor-only.md" <<'MD'
## 요약

동작에 문제는 없고 유지보수성 지적만 남았다.

## 발견 사항

- [minor] script/review-mr.sh:12 — 주석이 길다
  권고: 줄인다
- [minor] script/post-review.sh:30 — 변수명이 모호하다
  권고: 바꾼다

## 잘된 점

- 테스트가 붙었다

REVIEW_VERDICT: CHANGES_REQUESTED
MD

cat > "$sandbox/same-major.md" <<'MD'
## 요약

같은 결함이 남아 있다.

## 발견 사항

- [major] script/review-mr.sh:40 — 라벨 갱신 실패를 무시한다
  문제: 회차가 기록되지 않는다
  권고: 종료 코드 2 로 멈춘다

## 잘된 점

- 상한이 강제된다

REVIEW_VERDICT: CHANGES_REQUESTED
MD

cat > "$sandbox/no-verdict.md" <<'MD'
## 요약

판정 선언을 빠뜨린 리뷰다.

## 발견 사항

- [major] script/post-review.sh:40 — 마지막 줄에 판정이 없다
  문제: 계약이 요구하는 선언이 빠졌다
  권고: 계약대로 선언한다

## 잘된 점

- 발견 형식은 지켰다
MD

cat > "$sandbox/no-location.md" <<'MD'
## 요약

위치를 특정하지 않은 지적이다.

## 발견 사항

- [major] 스크립트 전반 — 입력 검증이 없다
  문제: 파일:라인으로 가리킬 수 있는 지점이 아니다
  권고: 진입점에서 한 번 검증한다

## 잘된 점

- 요지는 분명하다

REVIEW_VERDICT: CHANGES_REQUESTED
MD

cat > "$sandbox/praise-looks-like-finding.md" <<'MD'
## 요약

발견은 없고, 잘된 점에 등급 형식을 닮은 줄이 있다.

## 발견 사항

발견 사항 없음

## 잘된 점

- [major] 등급 발견은 인라인으로 분리했다
- 종료 코드 규약을 지켰다

REVIEW_VERDICT: PASS
MD

cat > "$sandbox/finding-with-praise-noise.md" <<'MD'
## 요약

발견 사항 안의 major 와, 잘된 점의 등급 형식 줄이 함께 있다.

## 발견 사항

- [major] script/post-review.sh:87 — 섹션 밖 줄을 집계한다
  문제: 잘된 점의 항목이 발견으로 세어진다
  권고: 발견 사항 섹션 안에서만 파싱한다

## 잘된 점

- [blocker] 이 줄은 발견이 아니다

REVIEW_VERDICT: CHANGES_REQUESTED
MD

cat > "$sandbox/tail-example.md" <<'MD'
## 요약

재현 절차에 등급 형식 예시를 담은 발견이다.

## 발견 사항

- [major] script/post-review.sh:87 — 섹션 밖 줄을 집계한다
  재현: 아래 줄을 잘된 점에 넣으면 major 로 센다
    - [major] 등급 발견은 인라인으로 분리했다
  권고: 발견 사항 섹션 안에서만 파싱한다

## 잘된 점

- 재현 절차가 구체적이다

REVIEW_VERDICT: CHANGES_REQUESTED
MD

cat > "$sandbox/no-findings-section.md" <<'MD'
## 요약

발견 사항 섹션을 통째로 빠뜨린 리뷰다.

- [major] script/post-review.sh:87 — 섹션 없이 나열한 발견
  권고: 계약대로 섹션을 둔다

## 잘된 점

- 요약은 있다

REVIEW_VERDICT: CHANGES_REQUESTED
MD

cat > "$sandbox/empty-findings-section.md" <<'MD'
## 요약

발견 사항 섹션이 비어 있다.

## 발견 사항

## 잘된 점

- 요약은 있다

REVIEW_VERDICT: PASS
MD

cat > "$sandbox/h1-findings-section.md" <<'MD'
## 요약

발견 사항 제목을 `#` 한 수준으로 쓴 리뷰다.

# 발견 사항

- [major] script/post-review.sh:109 — 제목 수준을 강제하지 않는다
  문제: 계약이 요구하지 않은 수준의 제목이 절로 받아들여진다
  권고: 정확히 `## 발견 사항` 만 절로 받는다

## 잘된 점

- 발견 형식 자체는 지켰다

REVIEW_VERDICT: CHANGES_REQUESTED
MD

cat > "$sandbox/h3-findings-section.md" <<'MD'
## 요약

발견 사항 제목을 `###` 세 수준으로 쓴 리뷰다.

### 발견 사항

- [major] script/post-review.sh:109 — 제목 수준을 강제하지 않는다
  문제: 계약이 요구하지 않은 수준의 제목이 절로 받아들여진다
  권고: 정확히 `## 발견 사항` 만 절로 받는다

## 잘된 점

- 발견 형식 자체는 지켰다

REVIEW_VERDICT: CHANGES_REQUESTED
MD

cat > "$sandbox/h2-findings-section.md" <<'MD'
## 요약

같은 내용을 계약대로 `## 발견 사항` 으로 쓴 리뷰다.

## 발견 사항

- [major] script/post-review.sh:109 — 제목 수준을 강제하지 않는다
  문제: 계약이 요구하지 않은 수준의 제목이 절로 받아들여진다
  권고: 정확히 `## 발견 사항` 만 절로 받는다

## 잘된 점

- 발견 형식 자체는 지켰다

REVIEW_VERDICT: CHANGES_REQUESTED
MD

cat > "$sandbox/praise-as-subheading.md" <<'MD'
## 요약

잘된 점 제목을 하위 수준으로 쓴 리뷰다.

## 발견 사항

발견 사항 없음

### 잘된 점

- [major] 등급 발견은 인라인으로 분리했다

REVIEW_VERDICT: PASS
MD

# ── 실행 도우미 ─────────────────────────────────────────────────────────────
pass=0; fail=0
check() { # <ID> <무엇> <기대> <실제>
  if [ "$3" = "$4" ]; then
    echo "  ok   $1 $2 → $4"; pass=$((pass + 1))
  else
    echo "  FAIL $1 $2 → expected '$3', actual '$4'" >&2; fail=$((fail + 1))
  fi
}

labels() { cat "$state/labels" 2>/dev/null || true; }
reviewer_calls() { [ -f "$state/reviewer-calls" ] && wc -l < "$state/reviewer-calls" | tr -d ' ' || echo 0; }
note_hits() { # <패턴> — 등록된 댓글 중 패턴에 걸리는 줄 수. 파일이 없으면 0.
  local c
  c=$(grep -c "$1" "$state/notes" 2>/dev/null)
  echo "${c:-0}"
}
input_hits() { # <패턴> — 리뷰 도구가 받은 입력 중 패턴에 걸리는 줄 수. 파일이 없으면 0.
  local c
  c=$(grep -c "$1" "$state/reviewer-input" 2>/dev/null)
  echo "${c:-0}"
}
input_line() { # <패턴> — 리뷰 입력에서 패턴이 처음 걸린 줄 번호. 없으면 0.
  local n
  n=$(grep -n "$1" "$state/reviewer-input" 2>/dev/null | head -1 | cut -d: -f1)
  echo "${n:-0}"
}
log_hits() { # <패턴> — 마지막 실행 로그에서 패턴에 걸리는 줄 수. 파일이 없으면 0.
  local c
  c=$(grep -c "$1" "$state/last.log" 2>/dev/null)
  echo "${c:-0}"
}
incr_hits() { # <패턴> — 증분 diff 절 안에서 패턴에 걸리는 줄 수
  local c
  c=$(sed -n '/^## 증분 diff/,/^## 누적 diff/p' "$state/reviewer-input" 2>/dev/null | grep -c "$1")
  echo "${c:-0}"
}
before() { # <앞 패턴> <뒤 패턴> — 둘 다 있고 순서가 맞으면 yes
  local a b
  a=$(input_line "$1"); b=$(input_line "$2")
  { [ "$a" -gt 0 ] && [ "$b" -gt "$a" ]; } && echo yes || echo no
}

run_review() { # <리뷰본문> [옵션…]
  local body="$1"; shift
  ( cd "$work" && PATH="$stub:$PATH" FAKE_STATE="$state" STUB_REVIEW="$body" \
      STUB_COMMIT="${STUB_COMMIT:-}" script/review-mr.sh "$@" 1 >"$state/last.log" 2>&1 )
  echo $?
}

run_post() { # <MR번호> <리뷰본문> [리뷰한리비전]
  ( cd "$work" && PATH="$stub:$PATH" FAKE_STATE="$state" \
      script/post-review.sh "$1" "$2" "테스트" ${3:+"$3"} >"$state/last.log" 2>&1 )
  echo $?
}

echo "UT-01 each review run bumps the round label by 1"
rm -f "$state/labels" "$state/reviewer-calls"
check UT-01 "round 1 exit code" 0 "$(run_review "$sandbox/clean.md")"
check UT-01 "round 1 label" "$ROUND:1" "$(labels)"
check UT-01 "round 2 exit code" 0 "$(run_review "$sandbox/clean.md")"
check UT-01 "round 2 label — previous one removed" "$ROUND:2" "$(labels)"

echo "UT-02 at the cap no review runs"
echo "$ROUND:$cap" > "$state/labels"
rm -f "$state/reviewer-calls"
check UT-02 "exit code" 3 "$(run_review "$sandbox/clean.md")"
check UT-02 "review tool calls" 0 "$(reviewer_calls)"
check UT-02 "label unchanged" "$ROUND:$cap" "$(labels)"

echo "UT-03 --force runs past the cap"
echo "$ROUND:$cap" > "$state/labels"
rm -f "$state/reviewer-calls"
check UT-03 "exit code" 0 "$(run_review "$sandbox/clean.md" --force)"
check UT-03 "review tool calls" 1 "$(reviewer_calls)"
check UT-03 "label" "$ROUND:$((cap + 1))" "$(labels)"

echo "UT-04 minor findings only is a PASS"
check UT-04 "exit code" 0 "$(run_post 2 "$sandbox/minor-only.md")"

echo "UT-05 major on the same file for the repeat cap in a row stops the loop"
rm -f "$state/notes"
check UT-05 "round 1 exit code" 1 "$(run_post 3 "$sandbox/same-major.md")"
check UT-05 "round 2 exit code" 1 "$(run_post 3 "$sandbox/same-major.md")"
check UT-05 "round 3 exit code" 3 "$(run_post 3 "$sandbox/same-major.md")"
check UT-05 "file path and round count in the summary" 1 "$(note_hits "${repeat}회차 연속: .script/review-mr.sh.")"

# 요지가 매 회차 달라도 파일이 같으면 같은 뿌리로 본다 — 문구 비교를 쓰지 않는다.
for n in 1 2 3; do
  sed "s/라벨 갱신 실패를 무시한다/서로 다른 지적 $n/" "$sandbox/same-major.md" > "$sandbox/other-major-$n.md"
done
check UT-05 "different wording — round 1 exit code" 1 "$(run_post 4 "$sandbox/other-major-1.md")"
check UT-05 "different wording — round 2 exit code" 1 "$(run_post 4 "$sandbox/other-major-2.md")"
check UT-05 "different wording — round 3 exit code" 3 "$(run_post 4 "$sandbox/other-major-3.md")"

# 중간에 그 파일이 깨끗하면 연속이 끊긴다 — 직전 수정이 파일을 닫았다는 뜻이다.
check UT-05 "streak round 1 exit code" 1 "$(run_post 22 "$sandbox/same-major.md")"
check UT-05 "streak round 2 exit code" 1 "$(run_post 22 "$sandbox/same-major.md")"
check UT-05 "clean round exit code" 0 "$(run_post 22 "$sandbox/clean.md")"
check UT-05 "exit code after the streak breaks" 1 "$(run_post 22 "$sandbox/same-major.md")"
check UT-05 "recounted round 2 exit code" 1 "$(run_post 22 "$sandbox/same-major.md")"
check UT-05 "recounted round 3 exit code" 3 "$(run_post 22 "$sandbox/same-major.md")"

# 판정 선언은 등급 집계로 바뀐 뒤에도 계약 준수 확인용으로 남는다 — 선언이 없으면 등록하지 않는다.
echo "UT-06 no verdict declaration means nothing is posted"
rm -f "$state/notes"
check UT-06 "exit code" 2 "$(run_post 5 "$sandbox/no-verdict.md")"
check UT-06 "post calls" 0 "$(note_hits 'note:')"

echo "UT-07 a declaration that disagrees with the tally is noted in the summary"
rm -f "$state/notes"
check UT-07 "minor only — exit code" 0 "$(run_post 6 "$sandbox/minor-only.md")"
check UT-07 "mismatch recorded" 1 "$(note_hits '리뷰 본문의 선언은')"
rm -f "$state/notes"
check UT-07 "declaration agrees — exit code" 0 "$(run_post 7 "$sandbox/clean.md")"
check UT-07 "no mismatch recorded" 0 "$(note_hits '리뷰 본문의 선언은')"

echo "UT-08 the repeat key looks at the file path only"
# 파일이 다르면 독립 결함이다 — 요지가 같고 몰아서 3회 나와도 상한에 걸리지 않는다.
for n in 1 2 3; do
  sed "s#script/review-mr.sh:40#script/file-$n.sh:$((n * 10))#" "$sandbox/same-major.md" > "$sandbox/other-file-$n.md"
  check UT-08 "different file — round ${n} exit code" 1 "$(run_post 8 "$sandbox/other-file-$n.md")"
done
# 같은 파일이면 줄 번호가 달라도 같은 뿌리로 센다(코드가 밀리면 줄은 바뀐다).
for n in 1 2; do
  sed "s#review-mr.sh:40#review-mr.sh:$((n * 100))#" "$sandbox/same-major.md" > "$sandbox/moved-$n.md"
  check UT-08 "same file, moved line — round ${n} exit code" 1 "$(run_post 9 "$sandbox/moved-$n.md")"
done
check UT-08 "same file — round 3 exit code" 3 "$(run_post 9 "$sandbox/same-major.md")"
# 심각도가 달라도 같은 파일이면 연속을 잇는다 — 같은 뿌리가 등급만 바뀌어 돌아오는 것을 센다.
sed 's#\[major\]#[blocker]#' "$sandbox/same-major.md" > "$sandbox/same-file-blocker.md"
check UT-08 "major — round 1 exit code" 1 "$(run_post 10 "$sandbox/same-major.md")"
check UT-08 "major — round 2 exit code" 1 "$(run_post 10 "$sandbox/same-major.md")"
check UT-08 "blocker — round 3 exit code" 3 "$(run_post 10 "$sandbox/same-file-blocker.md")"

echo "UT-09 findings without file:line share one slot"
check UT-09 "round 1 exit code" 1 "$(run_post 11 "$sandbox/no-location.md")"
check UT-09 "round 2 exit code" 1 "$(run_post 11 "$sandbox/no-location.md")"
check UT-09 "round 3 exit code" 3 "$(run_post 11 "$sandbox/no-location.md")"

echo "UT-10 history in the old format is not continued"
hist="$work/.git/work-loop/review-findings-12.tsv"
mkdir -p "$(dirname "$hist")"
printf '#format 2\n1\t[major] script/review-mr.sh — 라벨 갱신 실패를 무시한다\n2\t[major] script/review-mr.sh — 라벨 갱신 실패를 무시한다\n' > "$hist"
check UT-10 "exit code after two old records" 1 "$(run_post 12 "$sandbox/same-major.md")"
check UT-10 "format marker" "$hist_format" "$(head -1 "$hist")"
check UT-10 "history line count — marker plus this round" 2 "$(wc -l < "$hist" | tr -d ' ')"
check UT-10 "this round's number — old rounds not continued" 1 "$(sed -n '2p' "$hist" | cut -f1)"

echo "UT-11 severity-shaped lines outside the findings section are not counted"
rm -f "$state/notes"
check UT-11 "major in the praise section — exit code" 0 "$(run_post 13 "$sandbox/praise-looks-like-finding.md")"
check UT-11 "major in the praise section — tally" 1 "$(note_hits '발견 blocker 0 · major 0 · minor 0')"
rm -f "$state/notes"
check UT-11 "major inside the section — exit code" 1 "$(run_post 14 "$sandbox/finding-with-praise-noise.md")"
check UT-11 "major inside the section — tally" 1 "$(note_hits '발견 blocker 0 · major 1 · minor 0')"
# 발견의 들여쓴 재현 절차에 등급 형식 예시가 있어도 새 발견으로 세지 않는다.
rm -f "$state/notes"
check UT-11 "indented example — exit code" 1 "$(run_post 15 "$sandbox/tail-example.md")"
check UT-11 "indented example — tally" 1 "$(note_hits '발견 blocker 0 · major 1 · minor 0')"

echo "UT-12 no findings section means nothing is posted"
rm -f "$state/notes"
check UT-12 "missing section — exit code" 2 "$(run_post 16 "$sandbox/no-findings-section.md")"
check UT-12 "missing section — post calls" 0 "$(note_hits 'note:')"
rm -f "$state/notes"
check UT-12 "empty section — exit code" 2 "$(run_post 17 "$sandbox/empty-findings-section.md")"
check UT-12 "empty section — post calls" 0 "$(note_hits 'note:')"

echo 'UT-13 the findings heading must be exactly ## (level 2)'
rm -f "$state/notes"
check UT-13 "h1 heading — exit code" 2 "$(run_post 18 "$sandbox/h1-findings-section.md")"
check UT-13 "h1 heading — post calls" 0 "$(note_hits 'note:')"
rm -f "$state/notes"
check UT-13 "h3 heading — exit code" 2 "$(run_post 19 "$sandbox/h3-findings-section.md")"
check UT-13 "h3 heading — post calls" 0 "$(note_hits 'note:')"
# 같은 본문을 계약대로 쓰면 정상 집계된다 — 제목 수준만이 차이임을 보인다.
rm -f "$state/notes"
check UT-13 "h2 heading — exit code" 1 "$(run_post 20 "$sandbox/h2-findings-section.md")"
check UT-13 "h2 heading — tally" 1 "$(note_hits '발견 blocker 0 · major 1 · minor 0')"
# 절은 다음 제목에서 끝난다 — 뒤 제목이 하위 수준이어도 그 내용은 발견이 아니다.
rm -f "$state/notes"
check UT-13 "praise as a subheading — exit code" 0 "$(run_post 21 "$sandbox/praise-as-subheading.md")"
check UT-13 "praise as a subheading — tally" 1 "$(note_hits '발견 blocker 0 · major 0 · minor 0')"

echo "UT-14 the review input carries the MR body, issue body and previous round"
cat > "$state/mr-description" <<'MD'
## 관련 이슈

Closes #42

## 변경 목적

리뷰어가 맥락 없이 매 회차 백지에서 본다.

## 변경 사항

- 이 줄은 넘기지 않는다

## 리뷰 요청 포인트

증분 경계를 특히 본다.
MD
cat > "$state/issue.json" <<'JSON'
{"iid": 42, "title": "chore: 리뷰 루프 수렴",
 "description": "## 작업 내용\n\n이슈 본문에만 있는 문장이다."}
JSON
cat > "$state/threads.json" <<'JSON'
[{"notes": [{"body": "assigned to someone", "system": true,
             "created_at": "2026-09-22T10:00:00.000+09:00"}]},
 {"notes": [{"body": "**[major]** script/review-mr.sh:10 — 맥락이 없다", "system": false,
             "created_at": "2026-09-22T10:10:00.000+09:00"},
            {"body": "직전 회차 답글에만 있는 문장이다.", "system": false,
             "created_at": "2026-09-22T10:20:00.000+09:00"}]},
 {"notes": [{"body": "## 자동 리뷰 결과 (테스트)\n\n직전 요약에만 있는 문장이다.", "system": false,
             "created_at": "2026-09-22T10:11:00.000+09:00"}]}]
JSON
echo "$ROUND:1" > "$state/labels"
rm -f "$state/reviewer-input"
check UT-14 "exit code" 0 "$(run_review "$sandbox/clean.md")"
check UT-14 "purpose section of the MR body" 1 "$(input_hits '리뷰어가 맥락 없이')"
check UT-14 "review points section of the MR body" 1 "$(input_hits '증분 경계를 특히 본다')"
check UT-14 "other sections are left out" 0 "$(input_hits '이 줄은 넘기지 않는다')"
check UT-14 "issue body" 1 "$(input_hits '이슈 본문에만 있는 문장')"
check UT-14 "previous round summary" 1 "$(input_hits '직전 요약에만 있는 문장')"
check UT-14 "reply on the previous round's finding" 1 "$(input_hits '직전 회차 답글에만 있는 문장')"
check UT-14 "system notes are left out" 0 "$(input_hits 'assigned to someone')"
check UT-14 "diff comes after the context" yes "$(before '^## 직전 회차 리뷰' '^## 누적 diff')"
check UT-14 "diff body" 1 "$(input_hits '^+테스트 변경')"

echo "UT-15 round 1 has neither a previous round nor an increment"
rm -f "$state/labels" "$state/reviewer-input" "$state/notes"
check UT-15 "round 1 exit code" 0 "$(run_review "$sandbox/clean.md")"
check UT-15 "no previous-round section" 0 "$(input_hits '^## 직전 회차 리뷰')"
check UT-15 "no incremental section" 0 "$(input_hits '^## 증분 diff')"
check UT-15 "cumulative diff is present" 1 "$(input_hits '^## 누적 diff')"
check UT-15 "reviewed revision recorded in the summary" 1 "$(note_hits '리뷰 시점 head')"

echo "UT-16 the incremental diff is based on the revision in the previous summary note"
reviewed=$(git -C "$work" rev-parse HEAD)
cat > "$state/threads.json" <<JSON
[{"notes": [{"body": "## 자동 리뷰 결과 (테스트)\n\n> 리뷰 시점 head \`$reviewed\`", "system": false,
             "created_at": "2026-09-22T11:00:00.000+09:00"}]}]
JSON
for n in 1 2; do
  echo "증분 $n" > "$work/incremental-$n.txt"
  git -C "$work" add -A
  git -C "$work" -c core.hooksPath="$sandbox/nohooks" -c user.email=test@example.invalid \
    -c user.name=test commit -qm "incremental $n"
done
echo "$ROUND:1" > "$state/labels"
rm -f "$state/reviewer-input"
check UT-16 "exit code" 0 "$(run_review "$sandbox/clean.md")"
check UT-16 "incremental section" 1 "$(input_hits '^## 증분 diff')"
check UT-16 "file 1 added after the previous review" 1 "$(incr_hits '^+증분 1')"
check UT-16 "file 2 added after the previous review" 1 "$(incr_hits '^+증분 2')"
check UT-16 "changes before the previous review are left out" 0 "$(incr_hits 'review-mr.sh')"
check UT-16 "cumulative diff unchanged" 1 "$(input_hits '^## 누적 diff')"

echo "UT-17 with no revision in the previous note it runs without an increment"
cat > "$state/threads.json" <<'JSON'
[{"notes": [{"body": "## 자동 리뷰 결과 (테스트)\n\n리비전을 적지 않던 옛 형식이다.", "system": false,
             "created_at": "2026-09-22T11:00:00.000+09:00"}]}]
JSON
echo "$ROUND:1" > "$state/labels"
rm -f "$state/reviewer-input"
check UT-17 "exit code" 0 "$(run_review "$sandbox/clean.md")"
check UT-17 "no incremental section" 0 "$(input_hits '^## 증분 diff')"
check UT-17 "previous-round section is present" 1 "$(input_hits '^## 직전 회차 리뷰')"
check UT-17 "cumulative diff is present" 1 "$(input_hits '^## 누적 diff')"

echo "UT-18 the revision left in the summary is the reviewed one even if HEAD moves mid-review"
rm -f "$state/labels" "$state/notes" "$state/threads.json" "$state/mr-description" "$state/issue.json"
reviewed=$(git -C "$work" rev-parse HEAD)
STUB_COMMIT="$work/during-review.txt"
check UT-18 "exit code" 0 "$(run_review "$sandbox/clean.md")"
STUB_COMMIT=""
moved=$(git -C "$work" rev-parse HEAD)
check UT-18 "HEAD moved during the review" yes "$([ "$moved" != "$reviewed" ] && echo yes || echo no)"
check UT-18 "summary carries the reviewed revision" 1 "$(note_hits "리뷰 시점 head .$reviewed")"
check UT-18 "the unreviewed revision is not recorded" 0 "$(note_hits "리뷰 시점 head .$moved")"

echo "UT-19 the reviewed revision is accepted only in SHA form"
rm -f "$state/notes"
check UT-19 "malformed — exit code" 2 "$(run_post 23 "$sandbox/clean.md" "not-a-sha")"
check UT-19 "malformed — post calls" 0 "$(note_hits 'note:')"
rm -f "$state/notes"
check UT-19 "records the passed revision as given" 0 "$(run_post 24 "$sandbox/clean.md" "0123456789abcdef")"
check UT-19 "recorded value" 1 "$(note_hits '리뷰 시점 head .0123456789abcdef')"

echo "UT-20 a revision that is not an ancestor is not used as the increment base"
# 리베이스·force push 를 재현한다 — 옛 리비전은 객체로 남지만 현재 리비전의 조상이 아니다.
rebased_away=$(git -C "$work" rev-parse HEAD)
git -C "$work" branch -q keep-rebased-away "$rebased_away"
git -C "$work" reset -q --hard HEAD~1
echo "리베이스로 들어온 변경" > "$work/after-rebase.txt"
git -C "$work" add -A
git -C "$work" -c core.hooksPath="$sandbox/nohooks" -c user.email=test@example.invalid \
  -c user.name=test commit -qm "after rebase"
cat > "$state/threads.json" <<JSON
[{"notes": [{"body": "## 자동 리뷰 결과 (테스트)\n\n> 리뷰 시점 head \`$rebased_away\`", "system": false,
             "created_at": "2026-09-22T12:00:00.000+09:00"}]}]
JSON
echo "$ROUND:1" > "$state/labels"
rm -f "$state/reviewer-input"
check UT-20 "the old revision object still exists" yes \
  "$(git -C "$work" cat-file -e "$rebased_away^{commit}" 2>/dev/null && echo yes || echo no)"
check UT-20 "exit code" 0 "$(run_review "$sandbox/clean.md")"
check UT-20 "no incremental section" 0 "$(input_hits '^## 증분 diff')"
check UT-20 "records the reason" 1 "$(log_hits 'not an ancestor')"
check UT-20 "cumulative diff is present" 1 "$(input_hits '^## 누적 diff')"
# 조상이면 그대로 증분을 만든다 — 차이가 조상 여부뿐임을 보인다.
ancestor=$(git -C "$work" rev-parse HEAD)
echo "리뷰 이후 변경" > "$work/after-review.txt"
git -C "$work" add -A
git -C "$work" -c core.hooksPath="$sandbox/nohooks" -c user.email=test@example.invalid \
  -c user.name=test commit -qm "after review"
cat > "$state/threads.json" <<JSON
[{"notes": [{"body": "## 자동 리뷰 결과 (테스트)\n\n> 리뷰 시점 head \`$ancestor\`", "system": false,
             "created_at": "2026-09-22T12:00:00.000+09:00"}]}]
JSON
echo "$ROUND:1" > "$state/labels"
rm -f "$state/reviewer-input"
check UT-20 "ancestor — exit code" 0 "$(run_review "$sandbox/clean.md")"
check UT-20 "ancestor — incremental section" 1 "$(input_hits '^## 증분 diff')"
check UT-20 "increment holds only the post-review change" 1 "$(incr_hits '^+리뷰 이후 변경')"
check UT-20 "the rebased-in change is left out" 0 "$(incr_hits '리베이스로 들어온 변경')"

echo "UT-21 marker strings agree between the contract document and the parser"
# 쓰는 쪽(역할 계약)과 읽는 쪽(파서)이 서로 다른 문자열을 보면, 리뷰는 정상인데 등록이
# 계약 위반으로 멈춘다. 둘을 잇는 것은 이 검사뿐이다.
contract="$work/.ai/templates/code-reviewer.md"
for m in "$FMT_FINDINGS_HEADING" "$FMT_NO_FINDINGS" "$FMT_VERDICT_PASS" "$FMT_VERDICT_CHANGES" \
         "$FMT_OUT_OF_SCOPE"; do
  check UT-21 "present in the contract: $m" 1 "$(grep -cF -- "$m" "$contract" >/dev/null 2>&1 && echo 1 || echo 0)"
done

echo
if [ "$fail" -gt 0 ]; then
  echo "review loop test failed: $pass passed, $fail failed" >&2
  echo "last run log:" >&2
  cat "$state/last.log" >&2
  exit 1
fi
echo "review loop test passed: $pass checks"
