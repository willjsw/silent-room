#!/usr/bin/env bash
# 사용 기록 수집·집계의 회귀 테스트 — 기록에 남기지 않는 것, 상한 신호, 기록 없음 처리.
#
#   script/test-usage-log.sh
#
# 종료 코드: 0 = 전 케이스 통과 · 1 = 실패한 케이스 있음 · 2 = 실행 실패
#
# 원격을 부르지 않는다. 임시 로그 파일에 직접 기록을 남기고 집계 출력만 본다.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
root=$(pwd)
. "$root/script/harness.env"

# 기록 위치는 환경변수로 덮는다. 이름은 설정이 정하므로 그 값을 읽어 쓴다 —
# 이름을 박아 두면 설정을 바꿀 때 테스트가 조용히 다른 파일을 본다.
with_log() { # <로그경로> <명령...>
  _p=$1; shift
  env "$USAGE_ENV_VAR=$_p" "$@"
}

sandbox=$(mktemp -d) || exit 2
trap 'rm -rf "$sandbox"' EXIT

log="$sandbox/usage.log"
pass=0
fail=0

check() {
  local id="$1" name="$2" want="$3" got="$4"
  if [ "$want" = "$got" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "fail [$id] $name — want '$want', got '$got'" >&2
  fi
}

log_it() { with_log "$log" script/usage-log.sh "$@"; }
report() { with_log "$log" script/usage-report.sh "$@"; }

echo "UT-01 the usage log keeps no command content"
: > "$log"
body='MR 본문 전체를 여기에 붙였다'
log_it note test-caller "glab mr create -d \"$body\" --title 제목"
check UT-01 "one log line" 1 "$(grep -c . "$log")"
check UT-01 "no body text" 0 "$(grep -c '본문' "$log" || true)"
check UT-01 "no quotes" 0 "$(grep -c '"' "$log" || true)"
# 명령 이름·하위 명령처럼 형식만 라벨을 닮은 토큰도 허용 목록에 없으면 남지 않는다.
check UT-01 "no command name" 0 "$(grep -c 'glab' "$log" || true)"
check UT-01 "no subcommand" 0 "$(grep -c 'create' "$log" || true)"
: > "$log"
log_it note test-caller "deploy prod token=abcd1234"
check UT-01 "no label outside the allowlist" 0 "$(grep -c 'deploy\|prod' "$log" || true)"
check UT-01 "no key outside the allowlist" 0 "$(grep -c 'token' "$log" || true)"
# 출처도 허용 목록으로 제한한다.
: > "$log"
log_it note 'hong.gildong@example.com' standalone
check UT-01 "unknown caller becomes other" 1 "$(grep -c '|other|standalone|' "$log")"
check UT-01 "no raw caller" 0 "$(grep -c 'example.com' "$log" || true)"
# 고정 라벨과 키=값 토큰은 남는다 — 남기지 않는 것은 자유 문장이다.
: > "$log"
log_it review review-mr "mr=42 round=5 exit=3 stop=mrl-cap"
check UT-01 "key=value token kept" 1 "$(grep -c 'round=5' "$log")"
check UT-01 "stop reason token kept" 1 "$(grep -c 'stop=mrl-cap' "$log")"
# 허용된 키라도 값이 그 키의 형식에 맞지 않으면 버린다 — 잘못 넘어온 이름이 남지 않게 한다.
: > "$log"
log_it review review-mr "mr=hong.gildong round=one exit=ok stop=elsewhere"
check UT-01 "no value that breaks its key's format" 0 "$(grep -c 'hong.gildong\|one\|ok\|elsewhere' "$log" || true)"
check UT-01 "a malformed value leaves the detail empty" 1 "$(grep -c '|review|review-mr||' "$log")"
: > "$log"
log_it preflight work-preflight standalone
check UT-01 "fixed label kept" 1 "$(grep -c '|standalone|' "$log")"
# 체크아웃 디렉터리 이름은 기록하지 않는다 — 경로에 사람 이름·이메일이 있어도 남지 않아야 한다.
: > "$log"
named_checkout="$sandbox/hong.gildong@example.com"
mkdir -p "$named_checkout" && git -C "$named_checkout" init -q >/dev/null 2>&1
(cd "$named_checkout" && with_log "$log" "$root/script/usage-log.sh" block pre-push protected-branch)
check UT-01 "no checkout directory name" 0 "$(grep -c 'example.com' "$log" || true)"
check UT-01 "five fields per record" 5 "$(awk -F'|' 'END{print NF}' "$log")"
# 기록이 불가능해도 부른 쪽의 종료 코드를 바꾸지 않는다.
check UT-01 "exit code when logging is impossible" 0 "$(with_log "$sandbox/nodir/x/usage.log" script/usage-log.sh note test-caller x; echo $?)"
check UT-01 "exit code when logging is off" 0 "$(with_log "$sandbox/nodir/x/usage.log" script/usage-log.sh note test-caller x; echo $?)"

echo "UT-01 the report drops records that fail the format or the vocabulary"
: > "$log"
printf '%s\n' \
  "2026-09-01T10:00:00|block|pre-push|protected-branch|feat" \
  "2026-09-01T10:01:00|block|hong.gildong@example.com|protected-branch|feat" \
  "2026-09-01T10:02:00|block|pre-push|hong.gildong@example.com|feat" \
  "2026-09-01T10:03:00|block|pre-push|glab mr create -d 본문|feat" \
  >> "$log"
out=$(report --since 2026-09-01)
check UT-01 "only well-formed records counted" 1 "$(printf '%s\n' "$out" | sed -n 's/^TOTAL=//p')"
check UT-01 "dropped count" 3 "$(printf '%s\n' "$out" | sed -n 's/^DROPPED=//p')"
check UT-01 "no email in the report" 0 "$(printf '%s\n' "$out" | grep -c 'example.com' || true)"
check UT-01 "no command in the report" 0 "$(printf '%s\n' "$out" | grep -c 'mr create' || true)"

echo "UT-04 the review script logs a precondition failure too"
if command -v codex >/dev/null && [ "$(command -v codex)" = "/usr/bin/codex" ]; then
  echo "skip [UT-04] codex is inside the minimal PATH — cannot stage its absence" >&2
else
  : > "$log"
  rc=$(with_log "$log" env PATH="/usr/bin:/bin" script/review-mr.sh 999 >/dev/null 2>&1; echo $?)
  check UT-04 "exit code 2" 2 "$rc"
  check UT-04 "one review record" 1 "$(grep -c '|review|review-mr|mr=999 round=0 exit=2|' "$log")"
fi

echo "UT-04 the review script rejects a non-numeric MR number and logs nothing"
: > "$log"
rc=$(with_log "$log" script/review-mr.sh not-a-number >/dev/null 2>&1; echo $?)
check UT-04 "exit code 2" 2 "$rc"
check UT-04 "nothing logged" 0 "$(grep -c . "$log" || true)"

echo "UT-02 the report flags MRs that hit the review round cap"
# 상한 값은 설정이 갖는다. 스크립트 본문을 긁어 읽으면 변수 선언 형식이 바뀔 때 조용히 깨진다.
cap=$REVIEW_MAX_ROUNDS
[ -n "$cap" ] || { echo "error: could not read the review round cap from the config" >&2; exit 2; }
: > "$log"
log_it review review-mr "mr=18 round=$cap exit=3 stop=mrl-cap"
log_it review review-mr "mr=19 round=1 exit=0"
# 마지막 허용 회차가 통과로 끝난 MR 은 상한 도달이 아니다 — 루프가 수렴했다.
log_it review review-mr "mr=20 round=$cap exit=0"
# 같은 지적 반복도 종료 코드 3 이지만 회차 상한 도달이 아니다 — 사유로 가른다.
log_it review review-mr "mr=21 round=3 exit=3 stop=repeat"
out=$(report)
check UT-02 "one MR at the cap" 1 "$(printf '%s\n' "$out" | sed -n 's/^MRL_CAP_HITS=//p')"
check UT-02 "one MR stopped by repeats" 1 "$(printf '%s\n' "$out" | sed -n 's/^REPEAT_STOPS=//p')"
check UT-02 "a repeat stop is not marked as hitting the cap" 1 "$(printf '%s\n' "$out" | grep -c '^| !21 | 1 | 3 | no |')"
check UT-02 "cap hit marked" 1 "$(printf '%s\n' "$out" | grep -c '^| !18 | 1 | '"$cap"' | yes |')"
check UT-02 "below the cap marked" 1 "$(printf '%s\n' "$out" | grep -c '^| !19 | 1 | 1 | no |')"
check UT-02 "a pass on the last round is not a cap hit" 1 "$(printf '%s\n' "$out" | grep -c '^| !20 | 1 | '"$cap"' | no |')"
check UT-02 "count in the signal section" 1 "$(printf '%s\n' "$out" | grep -c "MRs that hit the round cap ($cap): 1")"

echo "UT-02 the default window is the last 4 weeks"
old=$(date -d '35 days ago' +%Y-%m-%d 2>/dev/null) || old=$(date -v-35d +%Y-%m-%d 2>/dev/null) || old=""
[ -n "$old" ] || { echo "error: could not compute a past date for the test" >&2; exit 2; }
: > "$log"
printf '%s\n' "${old}T10:00:00|block|pre-push|protected-branch|feat" >> "$log"
log_it block pre-push protected-branch
out=$(report)
check UT-02 "the default window excludes records older than 4 weeks" 1 "$(printf '%s\n' "$out" | sed -n 's/^TOTAL=//p')"
check UT-02 "default-window flag" yes "$(printf '%s\n' "$out" | sed -n 's/^SINCE_DEFAULT=//p')"
out=$(report --since "$old")
check UT-02 "an explicit window is used as given" 2 "$(printf '%s\n' "$out" | sed -n 's/^TOTAL=//p')"
check UT-02 "explicit-window flag" no "$(printf '%s\n' "$out" | sed -n 's/^SINCE_DEFAULT=//p')"

echo "UT-02 records only outside the window read differently from nothing collected"
: > "$log"
printf '%s\n' "${old}T10:00:00|block|pre-push|protected-branch|feat" >> "$log"
out=$(report; echo "RC=$?")
check UT-02 "exit code 0" 1 "$(printf '%s\n' "$out" | grep -c '^RC=0$')"
check UT-02 "empty window heading" 1 "$(printf '%s\n' "$out" | grep -c '^## Usage report — no events in the window$')"
check UT-02 "not the nothing-collected heading" 0 "$(printf '%s\n' "$out" | grep -c '^## Usage report — nothing collected$')"
check UT-02 "collected flag" yes "$(printf '%s\n' "$out" | sed -n 's/^COLLECTED=//p')"
check UT-02 "empty-window flag" yes "$(printf '%s\n' "$out" | sed -n 's/^PERIOD_EMPTY=//p')"
check UT-02 "valid records before the window filter" 1 "$(printf '%s\n' "$out" | sed -n 's/^KEPT=//p')"
# 형식에 맞지 않는 줄만 있는 것은 유효 기록이 아니므로 기간과 무관하게 미수집이다.
: > "$log"
printf '%s\n' "${old}T10:00:00|block|pre-push|glab mr create -d 본문|feat" >> "$log"
out=$(report)
check UT-02 "only malformed lines reads as nothing collected" 1 "$(printf '%s\n' "$out" | grep -c '^## Usage report — nothing collected$')"
check UT-02 "only malformed lines is not collected" no "$(printf '%s\n' "$out" | sed -n 's/^COLLECTED=//p')"
# 기간 내 기록이 있으면 기간 내 0건이 아니다.
: > "$log"
log_it block pre-push protected-branch
out=$(report)
check UT-02 "a record inside the window is collected" yes "$(printf '%s\n' "$out" | sed -n 's/^COLLECTED=//p')"
check UT-02 "a record inside the window is not an empty window" no "$(printf '%s\n' "$out" | sed -n 's/^PERIOD_EMPTY=//p')"

echo "UT-03 no records reads as nothing collected"
: > "$log"
out=$(report; echo "RC=$?")
check UT-03 "exit code 0" 1 "$(printf '%s\n' "$out" | grep -c '^RC=0$')"
check UT-03 "nothing-collected heading" 1 "$(printf '%s\n' "$out" | grep -c '^## Usage report — nothing collected$')"
check UT-03 "collected flag" no "$(printf '%s\n' "$out" | sed -n 's/^COLLECTED=//p')"
check UT-03 "distinct from an empty window" no "$(printf '%s\n' "$out" | sed -n 's/^PERIOD_EMPTY=//p')"
# 파일 자체가 없어도 오류가 아니다.
out=$(with_log "$sandbox/absent.log" script/usage-report.sh; echo "RC=$?")
check UT-03 "missing file — exit code 0" 1 "$(printf '%s\n' "$out" | grep -c '^RC=0$')"
check UT-03 "missing file — nothing-collected heading" 1 "$(printf '%s\n' "$out" | grep -c '^## Usage report — nothing collected$')"

echo "UT-05 several log files are read together"
logdir="$sandbox/logs"
mkdir -p "$logdir" || exit 2
now=$(date +%Y-%m-%d)
# 앞 파일의 마지막 줄에 개행이 없어도 다음 파일 첫 줄과 합쳐지지 않는다.
printf '%s' "${now}T10:00:00|block|pre-push|protected-branch|" > "$logdir/a.log"
printf '%s\n' "${now}T11:00:00|block|pre-push|protected-branch|" > "$logdir/b.log"
out=$(script/usage-report.sh "$logdir")
check UT-05 "files read" 2 "$(printf '%s\n' "$out" | sed -n 's/^FILES=//p')"
check UT-05 "both events counted" 2 "$(printf '%s\n' "$out" | sed -n 's/^TOTAL=//p')"
check UT-05 "nothing dropped" 0 "$(printf '%s\n' "$out" | sed -n 's/^DROPPED=//p')"
check UT-05 "guard block count" 2 "$(printf '%s\n' "$out" | sed -n 's/^BLOCK=//p')"
# 파일 하나를 직접 줄 때도 같다.
out=$(script/usage-report.sh "$logdir/a.log")
check UT-05 "single file with no trailing newline" 1 "$(printf '%s\n' "$out" | sed -n 's/^TOTAL=//p')"
check UT-05 "single file with no trailing newline — nothing dropped" 0 "$(printf '%s\n' "$out" | sed -n 's/^DROPPED=//p')"
# 빈 파일이 섞여도 빈 줄이 늘지 않는다.
: > "$logdir/c.log"
out=$(script/usage-report.sh "$logdir")
check UT-05 "empty file in the mix — total" 2 "$(printf '%s\n' "$out" | sed -n 's/^TOTAL=//p')"
check UT-05 "empty file in the mix — nothing dropped" 0 "$(printf '%s\n' "$out" | sed -n 's/^DROPPED=//p')"

echo
if [ "$fail" -gt 0 ]; then
  echo "usage log test failed: $pass passed, $fail failed" >&2
  exit 1
fi
echo "usage log test passed: $pass cases"
