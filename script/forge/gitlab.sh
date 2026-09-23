#!/usr/bin/env sh
# forge 어댑터 — GitLab / glab. 계약은 `script/forge/_common.sh` 상단이 정본이다.
#
# **검증 상태: 미검증.** 정규화 JSON 계약에 맞춰 다시 쓴 뒤 실제 리포에서 돌려보지 않았다.
# `script/forge-selftest.sh <리뷰요청번호> <이슈번호>` 를 전 단계까지 통과시키면 이 줄을 지운다.
#
# **함수군은 따로 켜진다.** 이슈 트래커와 리뷰 호스트를 서로 다른 forge 로 고를 수 있어야 하므로,
# `script/forge.sh` 가 `_FORGE_WANT_TRACKER` / `_FORGE_WANT_REVIEW` 를 세우고 이 파일을 source 한다.
# 그렇지 않으면 뒤에 source 된 어댑터가 앞 어댑터의 함수를 덮는다.
#
# 이 파일은 source 전용이다. 직접 실행하지 않는다.
set -u

GITLAB_CLI=glab

_gl_norm_issue='
import json, sys
def one(d):
    a = (d.get("assignees") or [{}])[0] if d.get("assignees") else {}
    return {
        "iid": str(d.get("iid") or ""),
        "title": d.get("title") or "",
        "state": d.get("state") or "",
        "description": d.get("description") or "",
        "labels": [l.get("name") if isinstance(l, dict) else str(l) for l in (d.get("labels") or [])],
        "assignee": a.get("username") or "",
        "milestone": (d.get("milestone") or {}).get("title") or "",
    }
v = json.load(sys.stdin)
json.dump([one(x) for x in v] if isinstance(v, list) else one(v), sys.stdout, ensure_ascii=False)
'

_gl_norm_mr='
import json, sys
def one(d):
    refs = d.get("diff_refs") or {}
    return {
        "iid": str(d.get("iid") or ""),
        "source_branch": d.get("source_branch") or "",
        "head_sha": refs.get("head_sha") or d.get("sha") or "",
        "description": d.get("description") or "",
        "labels": [l.get("name") if isinstance(l, dict) else str(l) for l in (d.get("labels") or [])],
        "state": d.get("state") or "",
    }
v = json.load(sys.stdin)
json.dump([one(x) for x in v] if isinstance(v, list) else one(v), sys.stdout, ensure_ascii=False)
'

# 목록 API 는 한 번에 한 페이지만 준다. per_page 를 키우는 것만으로는 부족하다 —
# 마지막 페이지가 가득 차면 다음 페이지에 남은 것이 있을 수 있다.
_gl_paged() {
  _path="$1"
  _page=1
  printf '['
  _first=1
  while :; do
    _batch=$("$GITLAB_CLI" api "${_path}?per_page=100&page=${_page}") || return 1
    _n=$(printf '%s' "$_batch" | python3 -c 'import json,sys; v=json.load(sys.stdin); print(len(v) if isinstance(v,list) else -1)') || return 1
    [ "$_n" -ge 0 ] || { echo "error: list response is not an array: $_path" >&2; return 1; }
    [ "$_n" -eq 0 ] && break
    [ "$_first" -eq 1 ] || printf ','
    _first=0
    printf '%s' "$_batch" | python3 -c 'import json,sys; s=json.dumps(json.load(sys.stdin),ensure_ascii=False); sys.stdout.write(s[1:-1])'
    [ "$_n" -lt 100 ] && break
    _page=$((_page + 1))
  done
  printf ']'
}

# ── 이슈 트래커 ──────────────────────────────────────────────────────────────

if [ "${_FORGE_WANT_TRACKER:-0}" = 1 ]; then

tracker_require() {
  command -v "$GITLAB_CLI" >/dev/null || { echo "error: $GITLAB_CLI is not installed" >&2; return 2; }
}

tracker_issue_view() {
  "$GITLAB_CLI" api "projects/:id/issues/$1" | python3 -c "$_gl_norm_issue"
}

tracker_issue_list() {
  _gl_paged "projects/:id/issues" | python3 -c "$_gl_norm_issue"
}

tracker_issue_create() {
  # <제목> <본문파일> <라벨> <담당자> <마일스톤>
  _cmd_title="$1"; _cmd_body="$2"; _cmd_label="$3"; _cmd_assignee="$4"; _cmd_ms="$5"
  _out=$(
    set -- issue create --title "$_cmd_title" --description "$(cat "$_cmd_body")"
    [ -n "$_cmd_label" ]    && set -- "$@" --label "$_cmd_label"
    [ -n "$_cmd_assignee" ] && set -- "$@" --assignee "$_cmd_assignee"
    [ -n "$_cmd_ms" ]       && set -- "$@" --milestone "$_cmd_ms"
    "$GITLAB_CLI" "$@"
  ) || return 1
  # glab 은 만든 이슈의 URL 을 낸다. 번호는 그 끝이다.
  printf '%s\n' "$_out" | sed -n 's|.*/\([0-9][0-9]*\)[^0-9]*$|\1|p' | tail -1
}

tracker_issue_note() {
  "$GITLAB_CLI" issue note create "$1" -m "$2" >/dev/null
}

tracker_current_user() {
  "$GITLAB_CLI" api user | python3 -c 'import json,sys; print(json.load(sys.stdin).get("username",""))'
}

fi

# ── 리뷰 호스트 ──────────────────────────────────────────────────────────────

if [ "${_FORGE_WANT_REVIEW:-0}" = 1 ]; then

review_require() {
  command -v "$GITLAB_CLI" >/dev/null || { echo "error: $GITLAB_CLI is not installed" >&2; return 2; }
}

review_mr_view() {
  "$GITLAB_CLI" mr view "$1" -F json | python3 -c "$_gl_norm_mr"
}

review_mr_diff() {
  "$GITLAB_CLI" mr diff "$1" --color=never
}

review_mr_labels_set() {
  # <n> <붙일것> <뗄것> — 공백 구분
  _mr="$1"; _add="$2"; _rm="$3"
  set -- mr update "$_mr"
  for _l in $_add; do set -- "$@" --label "$_l"; done
  for _l in $_rm; do set -- "$@" --unlabel "$_l"; done
  "$GITLAB_CLI" "$@" >/dev/null
}

review_mr_threads() {
  _gl_paged "projects/:id/merge_requests/$1/discussions" | python3 -c '
import json, sys
out = []
for d in json.load(sys.stdin):
    notes = [n for n in (d.get("notes") or []) if isinstance(n, dict) and not n.get("system")]
    if not notes:
        continue
    pos = notes[0].get("position") or {}
    out.append({
        "inline": d.get("individual_note") is False and bool(pos),
        "path": pos.get("new_path") or pos.get("old_path") or "",
        "line": pos.get("new_line") or pos.get("old_line") or "",
        "notes": [{"body": n.get("body") or "", "created_at": n.get("created_at") or ""} for n in notes],
    })
json.dump(out, sys.stdout, ensure_ascii=False)
'
}

# `--unique` 는 `--file` 과 배타적이라 인라인에는 쓸 수 없다. 재리뷰 시 같은 지적이 다시 달릴 수 있다.
review_mr_note_inline() {
  "$GITLAB_CLI" mr note create "$1" --file "$2" --line "$3" -m "$4"
}

review_mr_note_summary() {
  "$GITLAB_CLI" mr note create "$1" --resolvable=false -m "$(cat "$2")"
}

review_mr_list_open() {
  "$GITLAB_CLI" api "projects/:id/merge_requests?state=opened&per_page=100" | python3 -c "$_gl_norm_mr"
}

# 이슈↔MR 연결을 직접 준다. 기본 구현(브랜치·본문 문법 매칭)보다 정확하므로 덮어쓴다.
harness_issue_open_mrs() {
  _gl_paged "projects/:id/issues/$1/related_merge_requests" | python3 -c '
import json, sys
print(" ".join(str(m.get("iid")) for m in json.load(sys.stdin) if m.get("state") == "opened"))
'
}

fi
