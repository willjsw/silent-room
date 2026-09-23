#!/usr/bin/env bash
# PreToolUse 가드의 회귀 테스트 — 케이스 표의 명령을 훅에 흘려 종료 코드가 기대와 같은지 본다.
#
#   script/test-bash-guard.sh
#
# 종료 코드: 0 = 전 케이스 통과 · 1 = 실패한 케이스 있음 · 2 = 실행 실패
#
# 원격도 forge 도 부르지 않는다. 보호 브랜치 commit 은 브랜치 이름에 따라 판정이 갈리므로
# 임시 git 리포를 만들어 그 안에서 돌린다. 사용 기록은 남기지 않는다.
#
# **케이스 표의 값은 설정에서 온다.** 브랜치·보호 문서·forge CLI 를 바꿔도 이 표가 그대로
# 따라온다 — 값을 박아 두면 설정을 바꿀 때마다 테스트가 깨진다.
#
# 마지막 두 검사는 **가드를 일부러 망가뜨린 사본**에 차단 케이스 표를 그대로 돌린다.
# 망가뜨린 가드의 케이스가 통과로 뒤집히고 나머지 계열은 그대로 차단이어야 한다 —
# 뒤집히지 않으면 표가 무력화를 못 잡는 것이고, 다른 계열까지 뚫리면 판정이 얽힌 것이다.
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel) || exit 2
. "$repo_root/script/harness.env"
eval "export $USAGE_ENV_VAR=off"

# 설정에서 케이스 값을 뽑는다.
set -- $PROTECTED_BRANCHES
protected_a=$1
protected_b=${2:-$1}
forge_cli=${FORGE_CLIS%% *}
doc=$PROTECTED_DOCS_SAMPLE
work_branch="feat/100-x"
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

pass=0
fail=0

# probe <훅경로> <명령> → 훅의 종료 코드
probe() {
  local hook=$1 cmd=$2 esc
  # 줄바꿈은 JSON 문자열에 그대로 올 수 없으므로 하네스가 보내는 대로 \n 으로 이스케이프한다.
  esc=$(printf '%s' "$cmd" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' |
    awk '{ printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }')
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$esc" | "$hook" >/dev/null 2>&1
  echo $?
}

# case <기대코드> <명령> [설명]
case_is() {
  local expect=$1 cmd=$2 note=${3:-} rc
  rc=$(probe "$repo_root/script/hooks/bash-guard.sh" "$cmd")
  if [ "$rc" = "$expect" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "fail: want=$expect got=$rc  $cmd ${note:+($note)}" >&2
  fi
}

# 차단되어야 하는 케이스는 표로 모은다. 같은 표를 망가뜨린 가드 사본에도 돌려,
# 가드가 무력화되면 이 표가 실제로 알아채는지 확인한다.
protected_cases=(
  "git push origin $protected_a"
  "git push origin $protected_b"
  "git push -u origin $protected_b"
  "git push --set-upstream origin $protected_a"
  "git push origin HEAD:$protected_a"
  "git push origin $work_branch:$protected_b"
  "git push origin HEAD:refs/heads/$protected_b"
  "git -c advice.detachedHead=false push origin $protected_b"
  "git -C /tmp push origin $protected_a"
  "git push -o ci.skip origin $protected_b"
  "git push --repo origin $protected_b"
  'git push --all origin'
)

force_cases=(
  "git push --force origin $work_branch"
  "git push -f origin $work_branch"
  "git push --force-with-lease origin $work_branch"
  "git push --force-with-lease=$work_branch origin $work_branch"
  "git push origin +$work_branch:$work_branch"
  "git push origin --delete $work_branch"
  "git -c push.default=current push --force origin $work_branch"
  "git push -o ci.skip --force origin $work_branch"
)

verify_cases=(
  "git push --no-verify origin $work_branch"
  'git commit --no-verify -m "요약"'
  'git commit -n -m "요약"'
  'git -c core.hooksPath=/dev/null commit --no-verify -m "요약"'
)

remote_delete_cases=(
  "$forge_cli issue delete 100"
  "$forge_cli mr delete 7"
)

arch_cases=(
  "echo \"x\" >> $doc"
  "sed -i \"\" \"s/a/b/\" $doc"
  "cat > $doc <<EOF"
)

for c in "${protected_cases[@]}" "${force_cases[@]}" "${verify_cases[@]}" \
  "${remote_delete_cases[@]}" "${arch_cases[@]}"; do
  case_is 2 "$c"
done

# ── 읽기·정상 git 표기는 통과 ──────────────────────────────────────────────
case_is 0 "sed -n 1,20p $doc"
case_is 0 "grep -n 범위 $doc"

# ── 통과해야 하는 정상 명령 ────────────────────────────────────────────────
case_is 0 "git push origin $work_branch"
case_is 0 "git push -u origin $work_branch"
case_is 0 "git push -o ci.skip origin $work_branch"
case_is 0 "git -c advice.detachedHead=false push origin $work_branch"
case_is 0 'git fetch -p origin'
case_is 0 "$forge_cli issue view 100"
case_is 0 "$forge_cli mr create --title \"요약\" --target-branch $BASE_BRANCH"
case_is 0 'script/run-lint-test.sh'
case_is 0 'ls -la script/hooks'

# ── 다른 프로그램의 인수로 적힌 말은 실행이 아니다 ─────────────────────────
case_is 0 "echo git push origin $protected_b"
case_is 0 "echo \"git push --force origin $work_branch\""
case_is 0 'grep -n "git commit --no-verify" script/hooks/_guards.sh'
case_is 0 "echo $forge_cli issue delete 100"

# ── 래퍼·환경변수 대입 뒤의 git 은 실행 자리다 ─────────────────────────────
case_is 2 "env GIT_TRACE=1 git push origin $protected_a"
case_is 2 "git fetch -p origin; git push origin $protected_b"

# ── 명령을 꺼내지 못하는 입력은 통과 ───────────────────────────────────────
rc=$(printf '{"tool_name":"Read"}' | "$repo_root/script/hooks/bash-guard.sh" >/dev/null 2>&1; echo $?)
if [ "$rc" = 0 ]; then pass=$((pass + 1)); else
  fail=$((fail + 1))
  echo "fail: input with no command must pass — got=$rc" >&2
fi

# ── 브랜치에 따라 갈리는 commit 판정 ───────────────────────────────────────
work="$sandbox/repo"
mkdir -p "$work"
if git -C "$work" init -q -b "$protected_a" >/dev/null 2>&1 &&
  git -C "$work" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init >/dev/null 2>&1; then
  rc=$(cd "$work" && probe "$repo_root/script/hooks/bash-guard.sh" 'git commit -m "요약"')
  if [ "$rc" = 2 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    echo "fail: a commit on a protected branch must be blocked — got=$rc" >&2
  fi
  rc=$(cd "$work" && probe "$repo_root/script/hooks/bash-guard.sh" 'git push origin --tags')
  if [ "$rc" = 0 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    echo "fail: --tags sends no branch, so it must pass — got=$rc" >&2
  fi
  rc=$(cd "$work" && probe "$repo_root/script/hooks/bash-guard.sh" 'git push origin')
  if [ "$rc" = 2 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    echo "fail: a push with no destination on a protected branch must be blocked — got=$rc" >&2
  fi
  git -C "$work" checkout -q -b "$work_branch"
  # 작업 브랜치에서의 commit 은 전부 통과다. 훅을 우회하는 표기만 걸린다.
  for c in 'git commit -m "요약"' \
           'git commit -am "요약"' \
           'git commit --amend --no-edit' \
           'git commit -F - <<EOF
요약

- --no-verify 로 훅을 우회하는 명령을 차단
EOF'; do
    rc=$(cd "$work" && probe "$repo_root/script/hooks/bash-guard.sh" "$c")
    if [ "$rc" = 0 ]; then pass=$((pass + 1)); else
      fail=$((fail + 1))
      echo "fail: a commit on a work branch must pass — got=$rc  $c" >&2
    fi
  done
else
  fail=$((fail + 1))
  echo "fail: could not create the temp repo, so the commit rulings went unchecked" >&2
fi

# ── 망가진 가드를 이 표가 잡는가 ───────────────────────────────────────────
# force push 가드만 무력화한 사본에 차단 케이스 표를 그대로 돌린다.
# force 케이스가 전부 통과(코드 0)로 뒤집히고 다른 계열은 그대로 차단이어야,
# 이 표가 무력화를 잡아내며 그 감지가 해당 가드에 한정된다고 말할 수 있다.
# 사본은 같은 레이아웃이어야 한다 — 훅이 자기 위치에서 설정을 찾으므로,
# 설정을 함께 깔지 않으면 가드 로직이 아니라 설정 부재를 검사하게 된다.
broken="$sandbox/broken/script/hooks"
mkdir -p "$broken"
cp "$repo_root/script/hooks/bash-guard.sh" "$repo_root/script/hooks/_guards.sh" "$broken/"
cp "$repo_root/script/harness.env" "$sandbox/broken/script/"
chmod +x "$broken"/*.sh
sed -i.bak 's/^guard_force_push() {$/guard_force_push() { return 0;/' "$broken/_guards.sh"

broken_missed=0
broken_wrong=""
for c in "${force_cases[@]}"; do
  rc=$(probe "$broken/bash-guard.sh" "$c")
  if [ "$rc" = 2 ]; then
    # 보호 브랜치 가드가 대신 잡는 케이스는 force 가드 무력화의 증거가 되지 못한다.
    broken_wrong+="  still blocked: $c"$'\n'
  else
    broken_missed=$((broken_missed + 1))
  fi
done
if [ "$broken_missed" -gt 0 ] && [ -z "$broken_wrong" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "fail: the table did not catch the broken force push guard (${broken_missed} case(s) missed)" >&2
  [ -n "$broken_wrong" ] && printf '%s' "$broken_wrong" >&2
fi

broken_side=0
for c in "${protected_cases[@]}" "${verify_cases[@]}" "${remote_delete_cases[@]}" "${arch_cases[@]}"; do
  rc=$(probe "$broken/bash-guard.sh" "$c")
  [ "$rc" = 2 ] || {
    broken_side=$((broken_side + 1))
    echo "  a case unrelated to the force guard got through: $c (got=$rc)" >&2
  }
done
if [ "$broken_side" -eq 0 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "fail: only one guard was broken, yet other families passed too — the rulings are entangled" >&2
fi

echo "PreToolUse guard regression test: ${pass} of $((pass + fail)) passed, ${fail} failed"
[ "$fail" -eq 0 ]
