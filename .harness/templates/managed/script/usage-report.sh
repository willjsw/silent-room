#!/usr/bin/env bash
# 사용 기록(usage-log.sh 가 남긴 로그)을 집계해 마크다운 표와 KEY=VALUE 를 낸다. 회고의 지표 절 입력.
#
#   script/usage-report.sh [--since YYYY-MM-DD] [로그파일|디렉터리 ...]
#
# 인자를 생략하면 설정 `usage.log_path` 가 정한 기록 하나를 읽고,
# 기간도 생략하면 최근 4주만 집계한다 — 오래된 기록이 현재 마찰 신호에 섞이지 않게 한다.
# 디렉터리를 주면 그 아래 *.log 전부 — 여러 사람이 내보낸 기록을 한 폴더에 모아 집계한다.
#
# 종료 코드: 0 = 집계 출력(기록이 없으면 "미수집" 표기) · 2 = 실행 실패
# **기록이 없는 것은 오류가 아니다.** 수집 경로가 아직 돌지 않은 것과 마찰이 없는 것을 구별할 수
# 없으므로 0 을 세지 않고 미수집으로 표기한다.
# 단 **유효한 기록이 기간 밖에만 있는 것은 미수집이 아니다** — 수집 경로는 돌고 있다.
# 기간 필터 전 유효 기록 수를 KEPT 로 내고, 그 경우를 PERIOD_EMPTY=yes 로 따로 표기한다.
#
# 회차 상한 값은 여기서 정하지 않고 review-mr.sh 에서 읽는다 — 상한을 두 곳에 적으면 한쪽이 낡는다.
# 상한 도달은 회차 숫자가 아니라 상한 때문에 리뷰가 수행되지 않은 실행으로 센다.
# 마지막 허용 회차가 통과로 끝난 것과 루프가 수렴하지 못한 것은 다르다.
# **종료 코드 3 만으로는 사유를 가릴 수 없다** — 한 파일 반복으로 멈춘 실행도 3 이라서,
# 기록의 stop 값이 mrl-cap 인 것만 회차 상한 도달로 센다. 반복으로 멈춘 것은 따로 센다.
#
# 입력 로그는 다른 사람·다른 기계에서 온 파일일 수 있어 기록 시점의 필터를 거쳤다고 보지 않는다.
# 형식과 어휘(script/usage-vocab.sh)에 맞지 않는 줄은 집계에서 제외하고 건수만 표기한다.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
. script/harness.env

. script/usage-vocab.sh

since=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || { echo "error: --since needs a YYYY-MM-DD date" >&2; exit 2; }
             since="$2"; shift 2 ;;
    -*) echo "error: unknown option: $1" >&2
        echo "usage: script/usage-report.sh [--since YYYY-MM-DD] [log-file|directory ...]" >&2
        exit 2 ;;
    *) break ;;
  esac
done

if [ $# -eq 0 ]; then
  eval "_override=\${$USAGE_ENV_VAR:-}"
  set -- "${_override:-$USAGE_LOG_PATH}"
fi

# 기본 기간은 최근 4주. GNU date 와 BSD date 의 상대 날짜 문법이 달라 둘 다 시도한다.
if [ -z "$since" ]; then
  since=$(date -d '28 days ago' +%Y-%m-%d 2>/dev/null) ||
    since=$(date -v-28d +%Y-%m-%d 2>/dev/null) || since=""
  [ -n "$since" ] || { echo "error: could not compute the start of the default window (last 4 weeks)" >&2; exit 2; }
  since_default=yes
else
  since_default=no
fi

cap=$REVIEW_MAX_ROUNDS
[ -n "$cap" ] || { echo "error: could not read the review round cap from script/harness.env" >&2; exit 2; }

tmp=$(mktemp) || exit 2
trap 'rm -f "$tmp"' EXIT

# 마지막 줄에 개행이 없는 파일이 있으면 다음 파일의 첫 줄과 한 줄로 합쳐져 두 이벤트가 모두
# 형식 불일치로 빠진다. 파일마다 레코드 경계를 보장한다.
append_log() {
  cat "$1" >> "$tmp"
  [ -s "$1" ] && [ "$(tail -c1 "$1" | wc -l)" -eq 0 ] && echo >> "$tmp"
  return 0
}

files=0
for a in "$@"; do
  if [ -d "$a" ]; then
    for f in "$a"/*.log; do
      [ -f "$f" ] || continue
      append_log "$f"
      files=$((files + 1))
    done
  elif [ -f "$a" ]; then
    append_log "$a"
    files=$((files + 1))
  fi
done

# 스키마·어휘 검증. 통과한 줄만 집계한다.
awk -F'|' -v events="$USAGE_EVENTS" -v sources="$USAGE_SOURCES" \
    -v labels="$USAGE_LABELS" -v keys="$USAGE_KEY_SPECS" '
  BEGIN {
    n = split(events, a, " ");  for (i = 1; i <= n; i++) ok_event[a[i]] = 1
    n = split(sources, a, " "); for (i = 1; i <= n; i++) ok_source[a[i]] = 1
    n = split(labels, a, " ");  for (i = 1; i <= n; i++) ok_label[a[i]] = 1
    n = split(keys, a, " ")
    for (i = 1; i <= n; i++) {
      p = index(a[i], ":")
      if (p > 0) key_re[substr(a[i], 1, p - 1)] = substr(a[i], p + 1)
    }
  }
  NF != 5 { next }
  $1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ { next }
  !($2 in ok_event) { next }
  !($3 in ok_source) { next }
  {
    n = split($4, t, " ")
    for (i = 1; i <= n; i++) {
      if (t[i] in ok_label) continue
      if (match(t[i], /^[A-Za-z0-9_-]+=/)) {
        k = substr(t[i], 1, RLENGTH - 1)
        v = substr(t[i], RLENGTH + 1)
        if ((k in key_re) && v ~ key_re[k]) continue
      }
      next
    }
    print
  }' "$tmp" > "$tmp.v"
read_lines=$(grep -c . "$tmp" || true)
kept_lines=$(grep -c . "$tmp.v" || true)
dropped=$((read_lines - kept_lines))
mv "$tmp.v" "$tmp"

if [ -n "$since" ]; then
  awk -F'|' -v s="$since" 'substr($1,1,10) >= s' "$tmp" > "$tmp.f" && mv "$tmp.f" "$tmp"
fi

total=$(grep -c . "$tmp" || true)
# 기간 밖의 정상 기록이 있는 것과 유효 기록이 아예 없는 것은 다르다. 앞쪽을 미수집으로 적으면
# 수집 경로가 도는데도 돌지 않았다고 읽힌다 — 기간 필터 전 유효 기록 수(kept_lines)로 가른다.
if [ "$total" -eq 0 ] && [ "$kept_lines" -gt 0 ]; then
  echo "## Usage report — no events in the window"
  echo
  echo "Window: since ${since}. Read ${files} log file(s), 0 events in the window (${dropped} dropped as malformed)."
  echo "${kept_lines} valid record(s) fall outside the window — collection is running, this window is just empty. Widen it with \`--since\`."
  echo
  echo "TOTAL=0"; echo "SINCE=$since"; echo "SINCE_DEFAULT=$since_default"; echo "FILES=$files"; echo "DROPPED=$dropped"; echo "KEPT=$kept_lines"; echo "COLLECTED=yes"; echo "PERIOD_EMPTY=yes"; echo "MRL_CAP_HITS=0"; echo "REPEAT_STOPS=0"; echo "REPEAT_BLOCK_GUARDS=0"
  exit 0
fi
if [ "$total" -eq 0 ]; then
  echo "## Usage report — nothing collected"
  echo
  echo "Window: since ${since}. Read ${files} log file(s), 0 events (${dropped} dropped as malformed). **Nothing collected** — there is nothing to report on."
  echo "The collecting paths (hooks, work-preflight.sh, review-mr.sh) have not run yet, or the records live elsewhere."
  echo
  echo "TOTAL=0"; echo "SINCE=$since"; echo "SINCE_DEFAULT=$since_default"; echo "FILES=$files"; echo "DROPPED=$dropped"; echo "KEPT=0"; echo "COLLECTED=no"; echo "PERIOD_EMPTY=no"; echo "MRL_CAP_HITS=0"; echo "REPEAT_STOPS=0"; echo "REPEAT_BLOCK_GUARDS=0"
  exit 0
fi

count_event() { awk -F'|' -v e="$1" '$2==e' "$tmp" | grep -c . || true; }
bl=$(count_event block)
pf=$(count_event preflight)
rv=$(count_event review)
cm=$(count_event command)

first=$(cut -d'|' -f1 "$tmp" | sort | head -1 | cut -c1-10)
last=$(cut -d'|' -f1 "$tmp" | sort | tail -1 | cut -c1-10)

echo "## Usage report ($first to $last, since $since, ${files} log file(s), ${total} events, ${dropped} dropped as malformed)"
echo
echo "| Kind | Count |"
echo "| --- | --- |"
echo "| Guard blocks | $bl |"
echo "| Start checks | $pf |"
echo "| Review runs | $rv |"
echo "| Command calls | $cm |"
echo
echo "### Blocks by guard"
echo
echo "| Guard | Count | Most common reason |"
echo "| --- | --- | --- |"
if [ "$bl" -eq 0 ]; then
  echo "| (none collected) | - | |"
else
  awk -F'|' '$2=="block"{c[$3]++; if(!($3 in d)) d[$3]=$4}
             END{for(k in c) printf "| %s | %d | %s |\n", k, c[k], d[k]}' "$tmp" | sort -t'|' -k3 -nr
fi
echo
echo "### Start-check outcomes"
echo
echo "| Outcome | Count |"
echo "| --- | --- |"
if [ "$pf" -eq 0 ]; then
  echo "| (none collected) | - |"
else
  awk -F'|' '$2=="preflight"{k=($4==""?"-":$4); c[k]++}
             END{for(k in c) printf "| %s | %d |\n", k, c[k]}' "$tmp" | sort -t'|' -k3 -nr
fi
echo
echo "### Review rounds (cap $cap)"
echo
echo "| MR | Runs | Max round | Hit cap |"
echo "| --- | --- | --- | --- |"
if [ "$rv" -eq 0 ]; then
  echo "| (none collected) | - | - | - |"
else
  awk -F'|' '
    $2=="review" {
      mr=""; round=0; ec=""; st=""
      n=split($4, t, " ")
      for (i=1; i<=n; i++) {
        if (t[i] ~ /^mr=/)    { mr = substr(t[i], 4) }
        if (t[i] ~ /^round=/) { r = substr(t[i], 7) + 0; if (r > round) round = r }
        if (t[i] ~ /^exit=/)  { ec = substr(t[i], 6) }
        if (t[i] ~ /^stop=/)  { st = substr(t[i], 6) }
      }
      if (mr == "") mr = "-"
      runs[mr]++
      if (round > max[mr]) max[mr] = round
      if (ec == "3" && st == "mrl-cap") hit[mr] = 1
    }
    END {
      for (k in runs) printf "| !%s | %d | %d | %s |\n", k, runs[k], max[k], (k in hit ? "yes" : "no")
    }' "$tmp" | sort -t'|' -k4 -nr
fi
echo

# 신호. 숫자는 이 집계만 쓴다 — 회고에서 모델이 따로 세지 않는다.
# 상한 도달은 회차 상한 때문에 리뷰를 수행하지 않고 멈춘 실행(exit=3 stop=mrl-cap)으로 센다.
# 마지막 허용 회차가 통과로 끝난 MR 과 한 파일 반복으로 멈춘 MR 은 여기 들어가지 않는다.
cap_hits=$(awk -F'|' '
  $2=="review" {
    mr=""; ec=""; st=""
    n=split($4, t, " ")
    for (i=1; i<=n; i++) {
      if (t[i] ~ /^mr=/)   { mr = substr(t[i], 4) }
      if (t[i] ~ /^exit=/) { ec = substr(t[i], 6) }
      if (t[i] ~ /^stop=/) { st = substr(t[i], 6) }
    }
    if (mr == "") mr = "-"
    if (ec == "3" && st == "mrl-cap") hit[mr] = 1
  }
  END { n=0; for (k in hit) n++; print n+0 }' "$tmp")
repeat_stops=$(awk -F'|' '
  $2=="review" {
    mr=""; st=""
    n=split($4, t, " ")
    for (i=1; i<=n; i++) {
      if (t[i] ~ /^mr=/)   { mr = substr(t[i], 4) }
      if (t[i] ~ /^stop=/) { st = substr(t[i], 6) }
    }
    if (mr == "") mr = "-"
    if (st == "repeat") hit[mr] = 1
  }
  END { n=0; for (k in hit) n++; print n+0 }' "$tmp")
repeat_guards=$(awk -F'|' '$2=="block"{c[$3]++} END{n=0; for(k in c) if(c[k]>=5) n++; print n+0}' "$tmp")
blocked_start=$(awk -F'|' '$2=="preflight" && $4!="plan" && $4!="standalone"' "$tmp" | grep -c . || true)

echo "### Signals"
echo
echo "- MRs that hit the round cap ($cap): ${cap_hits} — the loop did not converge. Look at the review contract (\`.ai/templates/code-reviewer.md\`) and the cap."
echo "- MRs stopped by one file repeating: ${repeat_stops} — a different cause than the round cap. Candidates for revisiting the spec, not the code."
echo "- Guards that blocked 5+ times: ${repeat_guards} — false-positive candidates. Look at that hook pattern and its \`script/test-review-loop.sh\` case."
echo "- Blocked or failed start checks: ${blocked_start} — when high, the pre-work state (open MRs, missing specs) is often wrong."
if [ "$cm" -eq 0 ]; then
  echo "- Command-call records: **none collected** — these logs alone cannot show the procedure being bypassed (\`glab\` or push without a command)."
fi
echo
echo "TOTAL=$total"
echo "FILES=$files"
echo "DROPPED=$dropped"
echo "KEPT=$kept_lines"
echo "COLLECTED=yes"
echo "PERIOD_EMPTY=no"
echo "BLOCK=$bl"
echo "PREFLIGHT=$pf"
echo "REVIEW=$rv"
echo "COMMAND=$cm"
echo "MRL_CAP=$cap"
echo "MRL_CAP_HITS=$cap_hits"
echo "REPEAT_STOPS=$repeat_stops"
echo "REPEAT_BLOCK_GUARDS=$repeat_guards"
echo "SINCE=$since"
echo "SINCE_DEFAULT=$since_default"
echo "FROM=$first"
echo "TO=$last"
