#!/usr/bin/env sh
# forge 어댑터 — GitHub / gh. 계약은 `script/forge/_common.sh` 상단이 정본이다.
#
# 검증 상태: `script/forge-selftest.sh --create-issue` 전 단계 통과 (gh 2.93.0).
# 어댑터를 고치면 다시 돌린다 — 회귀 테스트는 페이크를 쓰므로 이 파일을 타지 않는다.
#
# GitHub 에서 다른 점 셋. 어댑터가 흡수하므로 호출부는 알지 않는다.
#   - 라벨이 리포에 미리 있어야 붙는다. GitLab 은 붙이는 순간 만들어 주므로, 여기서 먼저 만들어
#     같은 동작으로 맞춘다. 만들지 않으면 회차 기록과 이슈 생성이 라벨 때문에 실패한다.
#   - 인라인 리뷰 댓글은 `gh pr comment` 로 달 수 없어 REST 를 직접 쓴다. commit_id 가 필요하다.
#   - 스레드는 `notes` 배열이 아니라 `in_reply_to_id` 로 이어진다. 여기서 묶어 준다.
#   - 이슈↔PR 연결을 직접 주는 API 가 없다. `_common.sh` 의 문법 기반 기본 구현을 그대로 쓴다.
#
# **함수군은 따로 켜진다.** 이슈 트래커와 리뷰 호스트를 서로 다른 forge 로 고를 수 있어야 하므로,
# `script/forge.sh` 가 `_FORGE_WANT_TRACKER` / `_FORGE_WANT_REVIEW` 를 세우고 이 파일을 source 한다.
# 그렇지 않으면 뒤에 source 된 어댑터가 앞 어댑터의 함수를 덮는다.
#
# 이 파일은 source 전용이다. 직접 실행하지 않는다.
set -u

GITHUB_CLI=gh

_gh_norm_issue='
import json, sys
def one(d):
    return {
        "iid": str(d.get("number") or ""),
        "title": d.get("title") or "",
        "state": (d.get("state") or "").lower(),
        "description": d.get("body") or "",
        "labels": [l.get("name") if isinstance(l, dict) else str(l) for l in (d.get("labels") or [])],
        "assignee": ((d.get("assignees") or [{}])[0] or {}).get("login") or "",
        "milestone": (d.get("milestone") or {}).get("title") or "",
    }
v = json.load(sys.stdin)
json.dump([one(x) for x in v] if isinstance(v, list) else one(v), sys.stdout, ensure_ascii=False)
'

_gh_norm_mr='
import json, sys
def one(d):
    return {
        "iid": str(d.get("number") or ""),
        "source_branch": d.get("headRefName") or "",
        "head_sha": d.get("headRefOid") or "",
        "description": d.get("body") or "",
        "labels": [l.get("name") if isinstance(l, dict) else str(l) for l in (d.get("labels") or [])],
        "state": (d.get("state") or "").lower(),
    }
v = json.load(sys.stdin)
json.dump([one(x) for x in v] if isinstance(v, list) else one(v), sys.stdout, ensure_ascii=False)
'

# 라벨이 없으면 붙이기가 실패한다. 이미 있으면 실패해도 무시한다 — 멱등하게 쓴다.
_gh_ensure_label() {
  for _l in "$@"; do
    [ -n "$_l" ] || continue
    "$GITHUB_CLI" label create "$_l" --color ededed >/dev/null 2>&1 || true
  done
}

_GH_PR_FIELDS=number,headRefName,headRefOid,body,labels,state
_GH_ISSUE_FIELDS=number,title,state,body,labels,assignees,milestone

# ── 이슈 트래커 ──────────────────────────────────────────────────────────────

if [ "${_FORGE_WANT_TRACKER:-0}" = 1 ]; then

tracker_require() {
  command -v "$GITHUB_CLI" >/dev/null || { echo "error: $GITHUB_CLI is not installed" >&2; return 2; }
}

tracker_issue_view() {
  "$GITHUB_CLI" issue view "$1" --json "$_GH_ISSUE_FIELDS" | python3 -c "$_gh_norm_issue"
}

tracker_issue_list() {
  "$GITHUB_CLI" issue list --state all --limit 1000 --json "$_GH_ISSUE_FIELDS" \
    | python3 -c "$_gh_norm_issue"
}

tracker_issue_create() {
  _cmd_title="$1"; _cmd_body="$2"; _cmd_label="$3"; _cmd_assignee="$4"; _cmd_ms="$5"
  _gh_ensure_label "$_cmd_label"
  _out=$(
    set -- issue create --title "$_cmd_title" --body-file "$_cmd_body"
    [ -n "$_cmd_label" ]    && set -- "$@" --label "$_cmd_label"
    [ -n "$_cmd_assignee" ] && set -- "$@" --assignee "$_cmd_assignee"
    [ -n "$_cmd_ms" ]       && set -- "$@" --milestone "$_cmd_ms"
    "$GITHUB_CLI" "$@"
  ) || return 1
  printf '%s\n' "$_out" | sed -n 's|.*/\([0-9][0-9]*\)[^0-9]*$|\1|p' | tail -1
}

tracker_issue_note() {
  "$GITHUB_CLI" issue comment "$1" --body "$2" >/dev/null
}

tracker_current_user() {
  "$GITHUB_CLI" api user -q .login
}

fi

# ── 리뷰 호스트 ──────────────────────────────────────────────────────────────

if [ "${_FORGE_WANT_REVIEW:-0}" = 1 ]; then

review_require() {
  command -v "$GITHUB_CLI" >/dev/null || { echo "error: $GITHUB_CLI is not installed" >&2; return 2; }
}

review_mr_view() {
  "$GITHUB_CLI" pr view "$1" --json "$_GH_PR_FIELDS" | python3 -c "$_gh_norm_mr"
}

review_mr_diff() {
  "$GITHUB_CLI" pr diff "$1"
}

# 회차를 기록하지 못하면 상한이 없는 것과 같으므로 라벨을 먼저 만들어 둔다.
review_mr_labels_set() {
  _mr="$1"; _add="$2"; _rm="$3"
  # shellcheck disable=SC2086
  _gh_ensure_label $_add
  set -- pr edit "$_mr"
  for _l in $_add; do set -- "$@" --add-label "$_l"; done
  for _l in $_rm; do set -- "$@" --remove-label "$_l"; done
  "$GITHUB_CLI" "$@" >/dev/null
}

review_mr_threads() {
  {
    "$GITHUB_CLI" api "repos/{owner}/{repo}/pulls/$1/comments?per_page=100" --paginate
    printf '\036'
    "$GITHUB_CLI" api "repos/{owner}/{repo}/issues/$1/comments?per_page=100" --paginate
  } | python3 -c '
import json, sys

raw = sys.stdin.read().split("\036")


def loads(text):
    """--paginate 는 페이지마다 배열을 이어 붙여 낸다. 하나씩 읽어 합친다."""
    out, dec, i = [], json.JSONDecoder(), 0
    text = text.strip()
    while i < len(text):
        v, i = dec.raw_decode(text, i)
        out += v if isinstance(v, list) else [v]
        while i < len(text) and text[i] in " \t\r\n":
            i += 1
    return out


review = loads(raw[0]) if raw and raw[0].strip() else []
issue = loads(raw[1]) if len(raw) > 1 and raw[1].strip() else []

# 인라인은 in_reply_to_id 로 이어진다. 루트마다 답글을 모은다.
roots, replies = {}, {}
for c in review:
    parent = c.get("in_reply_to_id")
    if parent:
        replies.setdefault(parent, []).append(c)
    else:
        roots[c["id"]] = c

out = []
for cid, c in roots.items():
    notes = [c] + sorted(replies.get(cid, []), key=lambda n: n.get("created_at") or "")
    out.append({
        "inline": True,
        "path": c.get("path") or "",
        "line": c.get("line") or c.get("original_line") or "",
        "notes": [{"body": n.get("body") or "", "created_at": n.get("created_at") or ""} for n in notes],
    })
for c in issue:
    out.append({
        "inline": False, "path": "", "line": "",
        "notes": [{"body": c.get("body") or "", "created_at": c.get("created_at") or ""}],
    })
json.dump(out, sys.stdout, ensure_ascii=False)
'
}

review_mr_note_inline() {
  _sha=$("$GITHUB_CLI" pr view "$1" --json headRefOid -q .headRefOid) || return 1
  "$GITHUB_CLI" api "repos/{owner}/{repo}/pulls/$1/comments" \
    -f "path=$2" -F "line=$3" -f "side=RIGHT" -f "commit_id=$_sha" -f "body=$4"
}

review_mr_note_summary() {
  "$GITHUB_CLI" pr comment "$1" --body-file "$2"
}

review_mr_list_open() {
  "$GITHUB_CLI" pr list --state open --limit 200 --json "$_GH_PR_FIELDS" | python3 -c "$_gh_norm_mr"
}

fi
