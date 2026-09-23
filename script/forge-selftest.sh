#!/usr/bin/env bash
# forge 어댑터가 계약을 지키는지 **실제 forge 를 상대로** 확인한다.
#
#   script/forge-selftest.sh <리뷰요청번호> [이슈번호]           읽기 전용 9종
#   script/forge-selftest.sh --write <리뷰요청번호> [이슈번호]    + 쓰기 3종
#   script/forge-selftest.sh --create-issue <리뷰요청번호> <이슈번호>  + 이슈 생성 1종
#
# 종료 코드: 0 = 전 항목 통과 · 1 = 실패한 항목 있음 · 2 = 실행 실패
#
# **회귀 테스트와 다른 것을 본다.** `test-*.sh` 는 페이크 어댑터로 루프 제어를 검사하므로
# 실제 어댑터는 한 줄도 타지 않는다. 여기서 보는 것은 어댑터가 정규화 JSON 계약
# (`script/forge/_common.sh` 상단)을 실제 응답으로 지키는가다.
#
# **되돌릴 수 없는 동작은 따로 승인받는다.**
#
# | 단계 | 무엇이 남나 | 되돌리기 |
# |---|---|---|
# | (기본) | 아무것도 남지 않는다 | — |
# | `--write` | 댓글 2건 | 사람이 지운다 |
# | `--create-issue` | 이슈 1건 | 삭제를 금지한 프로젝트에서는 **불가** |
#
# 그러므로 `--write` 이상은 **버려도 되는 리뷰 요청**에만 쓴다. 대상 번호를 인수로 받는 이유가
# 그것이다 — 스크립트가 고르면 실사용 중인 것을 건드릴 수 있다.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
. script/harness.env
. script/harness-format.sh
. script/forge.sh

usage() {
  echo "usage: script/forge-selftest.sh [--write|--create-issue] <review-request-number> [issue-number]" >&2
  exit 2
}

mode=read
while [ $# -gt 0 ]; do
  case "$1" in
    --write)        mode=write; shift ;;
    --create-issue) mode=issue; shift ;;
    -*) echo "error: unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || usage
mr="$1"
issue="${2:-}"
[ "$mode" != issue ] || [ -n "$issue" ] || { echo "error: --create-issue needs an issue number to inherit from" >&2; usage; }

command -v python3 >/dev/null || { echo "error: python3 is not installed" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0; fail=0; skip=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s — %s\n' "$1" "$2" >&2; }
note() { skip=$((skip + 1)); printf '  skip  %s — %s\n' "$1" "$2"; }

# 정규화 JSON 이 계약의 키를 갖췄는지 본다. 키가 없으면 호출부가 빈 값을 받고 조용히 어긋난다.
shape() { # <label> <file> <object|array> <required-keys...>
  local what=$1 file=$2 kind=$3; shift 3
  local msg
  msg=$(python3 - "$file" "$kind" "$@" <<'PY'
import json, sys
path, kind = sys.argv[1], sys.argv[2]
keys = sys.argv[3:]
try:
    v = json.load(open(path, encoding="utf-8"))
except Exception as e:
    print("not JSON: %s" % e); raise SystemExit(0)
if kind == "array":
    if not isinstance(v, list):
        print("not an array: %s" % type(v).__name__); raise SystemExit(0)
    items = v[:1]          # 비어 있으면 형태를 볼 수 없다 — 그건 실패가 아니다
else:
    if not isinstance(v, dict):
        print("not an object: %s" % type(v).__name__); raise SystemExit(0)
    items = [v]
for it in items:
    missing = [k for k in keys if k not in it]
    if missing:
        print("missing keys: %s" % ", ".join(missing)); raise SystemExit(0)
PY
)
  if [ -z "$msg" ]; then ok "$what"; else bad "$what" "$msg"; fi
}

jq_get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }

echo "forge adapter selftest — tracker=$FORGE_TRACKER · review_host=$FORGE_REVIEW_HOST"
echo

# ── 읽기 전용 ───────────────────────────────────────────────────────────────
echo "1. reads — nothing is left behind"

if forge_require 2>"$work/err"; then ok "forge_require"; else bad "forge_require" "$(head -1 "$work/err")"; fi

user=$(tracker_current_user 2>"$work/err")
if [ -n "$user" ]; then ok "tracker_current_user → $user"
else bad "tracker_current_user" "empty ($(head -1 "$work/err"))"; fi

if review_mr_view "$mr" > "$work/mr.json" 2>"$work/err"; then
  shape "review_mr_view shape" "$work/mr.json" object iid source_branch head_sha description labels state
  sha=$(jq_get "$work/mr.json" head_sha)
  case "$sha" in
    [0-9a-f]*) [ ${#sha} -ge 7 ] && ok "review_mr_view head_sha" || bad "review_mr_view head_sha" "too short: $sha" ;;
    *) bad "review_mr_view head_sha" "not a SHA: '$sha'" ;;
  esac
  [ -n "$(jq_get "$work/mr.json" source_branch)" ] \
    && ok "review_mr_view source_branch" || bad "review_mr_view source_branch" "empty"
else
  bad "review_mr_view" "$(head -1 "$work/err")"
fi

if review_mr_diff "$mr" > "$work/diff.patch" 2>"$work/err"; then
  if grep -q '^diff --git' "$work/diff.patch"; then ok "review_mr_diff"
  else bad "review_mr_diff" "not a unified diff"; fi
else
  bad "review_mr_diff" "$(head -1 "$work/err")"
fi

if review_mr_threads "$mr" > "$work/threads.json" 2>"$work/err"; then
  shape "review_mr_threads shape" "$work/threads.json" array inline path line notes
else
  bad "review_mr_threads" "$(head -1 "$work/err")"
fi

if review_mr_list_open > "$work/open.json" 2>"$work/err"; then
  shape "review_mr_list_open shape" "$work/open.json" array iid source_branch description
else
  bad "review_mr_list_open" "$(head -1 "$work/err")"
fi

if [ -n "$issue" ]; then
  if tracker_issue_view "$issue" > "$work/issue.json" 2>"$work/err"; then
    shape "tracker_issue_view shape" "$work/issue.json" object iid title state description labels assignee milestone
    [ "$(jq_get "$work/issue.json" iid)" = "$issue" ] \
      && ok "tracker_issue_view iid matches" \
      || bad "tracker_issue_view iid matches" "asked for $issue, got $(jq_get "$work/issue.json" iid)"
  else
    bad "tracker_issue_view" "$(head -1 "$work/err")"
  fi

  if tracker_issue_list > "$work/issues.json" 2>"$work/err"; then
    shape "tracker_issue_list shape" "$work/issues.json" array iid title state
    # 전 페이지를 도는지 본다. 첫 페이지만 돌면 멱등 검사가 옛 이슈를 못 찾아 중복을 만든다.
    if python3 -c '
import json, sys
ids = [x["iid"] for x in json.load(open(sys.argv[1]))]
sys.exit(0 if sys.argv[2] in ids else 1)' "$work/issues.json" "$issue"; then
      ok "tracker_issue_list contains the target issue ($(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$work/issues.json") total)"
    else
      bad "tracker_issue_list" "target issue $issue is absent — the adapter may not paginate to the end"
    fi
  else
    bad "tracker_issue_list" "$(head -1 "$work/err")"
  fi

  found=$(harness_issue_open_mrs "$issue" 2>"$work/err")
  rc=$?
  if [ $rc -eq 0 ]; then
    case " $found " in
      *" $mr "*) ok "harness_issue_open_mrs finds this review request" ;;
      *) bad "harness_issue_open_mrs" "did not find $mr from issue $issue (got '$found')
        the branch must be named '<tag>/$issue-...' or the body must carry '$FMT_MR_CLOSES $issue'" ;;
    esac
  else
    bad "harness_issue_open_mrs" "$(head -1 "$work/err")"
  fi
else
  note "tracker_* (4 functions)" "no issue number was given"
fi

# ── 쓰기 ────────────────────────────────────────────────────────────────────
if [ "$mode" = read ]; then
  echo
  echo "2. writes — skipped (enable with --write)"
  note "review_mr_labels_set · note_inline · note_summary" "read-only mode"
  note "tracker_issue_create" "read-only mode"
else
  echo
  echo "2. writes — this leaves traces on review request $mr"

  # 라벨은 붙였다 떼면 되돌아간다. 회차 관리가 이 함수 하나에 걸려 있다.
  probe="$REVIEW_ROUND_LABEL:selftest"
  if review_mr_labels_set "$mr" "$probe" "" 2>"$work/err"; then
    review_mr_view "$mr" > "$work/mr2.json" 2>/dev/null
    if grep -q "$probe" "$work/mr2.json"; then ok "review_mr_labels_set add"
    else bad "review_mr_labels_set add" "the label does not come back on read — this forge may require it to exist first"; fi
    review_mr_labels_set "$mr" "" "$probe" 2>/dev/null
    review_mr_view "$mr" > "$work/mr3.json" 2>/dev/null
    if grep -q "$probe" "$work/mr3.json"; then bad "review_mr_labels_set remove" "the label is still there — remove it by hand: $probe"
    else ok "review_mr_labels_set remove"; fi
  else
    bad "review_mr_labels_set" "$(head -1 "$work/err")"
  fi

  # 인라인은 diff 안의 줄에만 달린다. 대상 줄을 diff 에서 직접 고른다.
  target=$(python3 - "$work/diff.patch" <<'PY'
import re, sys
path = line = None
n = 0
for ln in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if ln.startswith("+++ b/"):
        path, n = ln[6:].strip(), 0
    elif ln.startswith("@@"):
        m = re.search(r"\+(\d+)", ln)
        n = int(m.group(1)) - 1 if m else 0
    elif path and ln.startswith("+") and not ln.startswith("+++"):
        n += 1
        print("%s\t%d" % (path, n))
        break
    elif path and (ln.startswith(" ") or ln.startswith("-")):
        if not ln.startswith("-"):
            n += 1
PY
)
  if [ -n "$target" ]; then
    file=${target%%	*}; line=${target##*	}
    body="selftest probe — checking the adapter contract. Safe to delete."
    if review_mr_note_inline "$mr" "$file" "$line" "$body" >/dev/null 2>"$work/err"; then
      review_mr_threads "$mr" > "$work/threads2.json" 2>/dev/null
      if python3 -c '
import json, sys
for t in json.load(open(sys.argv[1])):
    if t.get("inline") and any(sys.argv[2] in n.get("body","") for n in t.get("notes",[])):
        raise SystemExit(0)
raise SystemExit(1)' "$work/threads2.json" "selftest probe"; then
        ok "review_mr_note_inline appears inline in threads"
      else
        bad "review_mr_note_inline" "it posted, but threads does not report it as inline"
      fi
    else
      bad "review_mr_note_inline" "$(head -1 "$work/err")"
    fi
    # diff 밖 줄은 실패해야 한다. 성공하면 엉뚱한 자리에 지적이 달린다.
    if review_mr_note_inline "$mr" "$file" 999999 "$body" >/dev/null 2>&1; then
      bad "review_mr_note_inline out of range" "it attached to a line that is not in the diff"
    else
      ok "review_mr_note_inline fails outside the diff range"
    fi
  else
    note "review_mr_note_inline" "could not pick a target line from the diff"
  fi

  printf 'selftest summary — checking the adapter contract. Safe to delete.\n' > "$work/note.md"
  if review_mr_note_summary "$mr" "$work/note.md" >/dev/null 2>"$work/err"; then
    review_mr_threads "$mr" > "$work/threads3.json" 2>/dev/null
    if grep -q 'selftest summary' "$work/threads3.json"; then
      ok "review_mr_note_summary appears in threads"
    else
      bad "review_mr_note_summary" "it posted, but does not come back in threads"
    fi
  else
    bad "review_mr_note_summary" "$(head -1 "$work/err")"
  fi
fi

# ── 이슈 생성 ───────────────────────────────────────────────────────────────
if [ "$mode" != issue ]; then
  echo
  echo "3. issue creation — skipped (enable with --create-issue)"
  [ "$mode" = write ] && note "tracker_issue_create" "gated separately because it cannot be undone"
else
  echo
  echo "3. issue creation — this cannot be undone"
  [ "$ISSUE_DELETE_FORBIDDEN" = 1 ] &&
    echo "  warning: this project forbids deleting issues — whatever is created stays forever" >&2

  assignee=$(jq_get "$work/issue.json" assignee)
  milestone=$(jq_get "$work/issue.json" milestone)
  printf '## %s\n\n- 어댑터 자체 검사가 만든 이슈다. 닫아도 된다.\n\n## %s\n\n- %s %s\n' \
    "$FMT_ISSUE_WORK" "상위" "$FMT_ISSUE_RELATES" "$issue" > "$work/body.md"
  new=$(tracker_issue_create "자체 검사 — 어댑터 계약 확인" "$work/body.md" \
          "$ISSUE_LABEL_TASK" "$assignee" "$milestone" 2>"$work/err")
  if [ -n "$new" ]; then
    ok "tracker_issue_create → $new"
    # 돌려준 값이 곧바로 조회에 쓰이는 식별자여야 한다. URL 이나 빈 값이면 호출부가 멈춘다.
    if tracker_issue_view "$new" > "$work/new.json" 2>/dev/null &&
       [ "$(jq_get "$work/new.json" iid)" = "$new" ]; then
      ok "tracker_issue_create returns an identifier that reads back"
    else
      bad "tracker_issue_create" "the returned value '$new' does not read back"
    fi
    echo "  a person closes the issue it created: $new"
  else
    bad "tracker_issue_create" "$(head -1 "$work/err")"
  fi
fi

# ── 판정 ────────────────────────────────────────────────────────────────────
echo
echo "pass ${pass} · fail ${fail} · skip ${skip}"
if [ "$fail" -gt 0 ]; then
  echo "the adapter does not honour the contract — do not use this forge until it is fixed" >&2
  exit 1
fi
if [ "$skip" -gt 0 ]; then
  echo "some checks were skipped — the adapter counts as verified only once all of them run"
  exit 0
fi
echo "all 13 contract functions checked — clear the unverified note in the adapter header:"
for a in $(printf '%s\n%s\n' "$FORGE_TRACKER" "$FORGE_REVIEW_HOST" | sort -u); do
  echo "   script/forge/$a.sh"
done
