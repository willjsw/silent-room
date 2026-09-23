# 바꾸려면 어디를 고치나

**값을 바꾸는 일은 거의 전부 `harness.toml` 한 파일이다.** 고친 뒤 `harness render` 를 돌리면
그 값을 쓰는 파일이 전부 따라 바뀐다. 아래 표에 없는 파일은 건드리지 않아도 된다.

```bash
vim harness.toml
.harness/bin/harness render
```

---

## 설정으로 바꾸는 것

| 바꾸고 싶은 것 | 설정 키 | 따라 바뀌는 것 |
|---|---|---|
| 통합 브랜치 이름 | `branches.base` | 훅, 권한 deny, 착수 판정의 fetch 대상, 규칙 문서, forge 사전 |
| 보호 브랜치 목록 | `branches.protected` | pre-push, 명령 가드, 권한 deny, 규칙 문서 |
| 커밋 태그 | `commit.tags` | commit-msg 검사식과 **안내문**, 규칙 문서의 태그 표 |
| 커밋 제목 형식 | `commit.issue_ref`, `commit.ticket_key` | 위와 같은 곳 + task 이슈 제목 |
| 리뷰 회차 상한 | `review.max_rounds` | 리뷰 스크립트, 집계 스크립트 |
| 한 파일 반복 상한 | `review.repeat_file_max` | 등록 스크립트 |
| 회차 라벨 접두 | `review.round_label` | 리뷰 스크립트 |
| **어느 도구가 어느 역할을 맡나** | `roles.<역할>.runner` | 에이전트 정의 6종(양쪽 하네스), 리뷰 실행 명령 |
| **역할별 모델** | `roles.<역할>.model` | 〃 |
| 역할별 권한 | `roles.<역할>.access`, `.tools` | 〃 |
| 이슈 추적·리뷰 호스트 | `forge.tracker`, `forge.review_host` | forge 어댑터 선택, forge 명령 사전 |
| 이슈 라벨·필수 필드 | `issues.labels`, `issues.required_fields` | 이슈 생성 스크립트, 규칙 문서 |
| 이슈 삭제 금지 여부 | `issues.deletion_forbidden` | 명령 가드, 이슈 생성 검사 |
| 담당자·리뷰어 기본값 | `mr.default_assignee`, `.default_reviewer` | forge 명령 사전, 작성 요령 |
| 결정 기록 방식 | `adr.style`, `adr.tool`, `adr.dir` | 결정 기록 사전, 템플릿, 디렉터리 |
| 보호 문서 목록 | `docs.protected` | 권한 deny, 명령 가드, 규칙 문서 |
| 사용 기록 위치 | `usage.log_path`, `usage.env_var` | 기록·집계 스크립트, 회고 절차 |

**어긋날 수 없다.** 생성 파일을 손으로 고치면 `harness check` 가 커밋을 막는다.

---

## 프로젝트가 쓰는 것 (소유 파일)

하네스 갱신이 덮지 않는다. 사람이 판단해 쓰는 산문이라 설정으로 뺄 수 없다.

| 바꾸고 싶은 것 | 고칠 파일 |
|---|---|
| 담당 범위·인접 모듈 경계 | `.ai/project/scope.md` |
| 용어·폐기된 별칭 | `.ai/project/glossary.md` |
| 빌드·테스트·포맷 명령 | `.ai/project/commands.md` |
| 스택 | `.ai/project/stack.md` |
| 계층·의존 규칙·아키텍처 특성 | `.ai/project/architecture.md` |
| 테스트 지침 | `.ai/project/testing.md` |
| 접속 정보 취득 경로 | `.ai/project/environment.md` |
| 이 리포 고유의 리뷰 점검 | `.ai/project/review-checks.md` |
| 검증 명령 구현 | `script/verify-project.sh` |

**`.ai/project/` 를 고치면 `harness render` 를 돌린다.** 규칙 문서가 그 본문을 담아 생성되므로,
돌리지 않으면 `harness check` 가 커밋을 막는다.

`.ai/project/commands.md` 와 `script/verify-project.sh` 는 **같이 고친다.** 한쪽만 고치면
문서가 말하는 명령과 실제로 도는 검증이 달라진다.

---

## 하네스 자체를 바꾸는 것

역할 계약·절차·배관은 **관리 파일**이다. 이 리포에서 고치면 다음 갱신이 덮는다.
고쳐야 하면 하네스 리포에서 고치고 버전을 올려 받는다.

| 바꾸고 싶은 것 | 하네스 리포에서 고칠 곳 |
|---|---|
| 역할이 무엇을 판단하나 | `.ai/templates/<역할>.md` — **한 곳** |
| 작업 순서·중단 조건 | `.ai/workflows/<이름>.md` — **한 곳** |
| 리뷰·이슈 본문의 표지 문자열 | `script/harness-format.sh` + 해당 계약·양식 |
| forge 함수 구현 | `script/forge/<kind>.sh` — **한 곳** |
| 가드 판정 | `script/hooks/_guards.sh` + 테스트 케이스 |

**가드를 고치면 테스트 케이스를 함께 늘린다.** 가드는 망가져도 통과만 하므로 실패가 눈에
띄지 않는다. 그 표가 훅의 동작을 붙들어 두는 유일한 자리다.

---

## 역할을 추가·삭제한다

### 추가

1. `harness.toml` 의 `[roles.<이름>]` — 러너·권한·모델
2. 하네스 리포의 `templates/agents/<이름>.md` — 어댑터 본문과 설명
3. 하네스 리포의 `templates/managed/.ai/templates/<이름>.md` — 역할 계약 정본
4. 절차에 끼우려면 `.ai/workflows/` 에 **역할 이름으로** 추가하고, 커맨드 위임표에 매핑

에이전트 정의 파일과 frontmatter 는 `harness render` 가 만든다. 손으로 쓰지 않는다.

### 삭제

1. `harness.toml` 에서 `[roles.<이름>]` 제거 → render 하면 정의 파일과 역할 계약이 사라진다
2. 절차·커맨드에 남은 참조 제거 — 이걸 빼먹으면 없는 역할을 부른다

**남은 참조는 `harness doctor` 가 찾는다.** 지운 역할을 아직 부르는 파일과 줄 번호를 낸다.

---

## 고치면 안 되는 것

| 경로 | 이유 |
|---|---|
| 생성 파일 전부 | 설정에서 나온다. `harness check` 가 커밋을 막는다 |
| `.harness/` | 하네스 사본이다. 버전을 올려 받는다 |
| `docs/adr/` 기존 본문 | 기록은 로그다. **틀린 결정도 그대로 둔다** — 번복은 새 기록으로 |
| `.claude/settings.local.json` | 개인 환경. 커밋 대상 아님 |

---

## 바꾼 뒤 확인

```bash
script/run-lint-test.sh   # 생성물 일치 + 회귀 테스트 + 프로젝트 검증
harness doctor            # 끊긴 참조 + 비어 있는 자리 + 도구·훅
```

`doctor` 의 **references** 절이 손으로 돌리던 grep 을 대신한다. 지운 역할을 아직 부르는
자리와, 문서가 가리키는데 없는 파일을 낸다. 문서가 언급하는 파일은 **반드시 실재해야 한다** —
새 자산을 문서에 적었으면 파일부터 만든다. git 이 무시하는 경로는 없는 것이 정상이므로 세지 않는다.
