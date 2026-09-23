# AI 하네스 구조

이 리포에서 AI 에이전트가 어떻게 일하는지를 사람이 읽기 위한 문서다.

| 문서 | 무엇을 답하나 |
|---|---|
| **README.md** (이 파일) | 무엇이 어디에 있나. 왜 이렇게 나눴나 |
| [flow.md](flow.md) | 어떤 순서로 도나. 사람은 어디서 개입하나 |
| [changing.md](changing.md) | 바꾸려면 어디를 고치나 |

---

## 한 장으로 보는 구조

```
harness.toml                       설정 정본 — 규칙 값은 전부 여기
    │
    │  harness render
    ▼
.ai/AI_AGENT.md                    규칙 (생성)          ─┐
.ai/forge.md · .ai/adr.md          forge·결정 기록 (생성) │  에이전트가 읽는다
.claude/agents/ · .codex/agents/   역할 어댑터 (생성)     │
script/githooks/ · harness.env     훅·상수 (생성)        │
.claude/settings.json              권한 (생성)          ─┘

.ai/project/       프로젝트 사실 (소유)   ← 사람이 쓴다. 갱신이 덮지 않는다
.ai/workflows/     작업 절차 (관리)      ─┐
.ai/templates/     역할 계약·양식 (관리)  │  하네스 것. 갱신이 덮는다
script/*.sh        배관 (관리)          ─┘
```

## 파일은 세 부류다

| 부류 | 어디 | 고치는 법 |
|---|---|---|
| **생성** | `.ai/AI_AGENT.md`, `.ai/forge.md`, `.ai/adr.md`, `.claude/`, `.codex/`, `script/githooks/`, `script/harness.env`, `script/forge.sh`, `CLAUDE.md`, `AGENTS.md` | 고치지 않는다. `harness.toml` 을 고치고 `harness render` |
| **관리** | `.ai/workflows/`, `.ai/templates/`, `script/` 의 나머지, `docs/workflow/` | 하네스 것이다. 고치려면 하네스 리포에서 고치고 버전을 올려 받는다 |
| **소유** | `.ai/project/`, `script/verify-project.sh` | 이 프로젝트 것이다. 하네스 갱신이 건드리지 않는다 |

한 파일 안에 두 부류가 섞이면 갱신할 방법이 없다. 그래서 프로젝트 사실은 규칙 문서 안에
직접 쓰지 않고 `.ai/project/` 에 두며, 규칙 문서가 그 본문을 포함해 생성된다.

## 핵심 원칙 셋

**1. 값의 정본은 `harness.toml` 하나다.**
브랜치 이름·커밋 형식·리뷰 상한·역할별 모델·보호 문서 목록은 설정이 갖고, 그것을 쓰는 파일은
전부 거기서 생성된다. 같은 값이 여러 파일에 산문으로 박혀 있으면 반드시 어긋난다.

**2. 계약은 자기가 누구인지 모른다.**
`.ai/templates/<역할>.md` 는 자기가 어느 모델로 도는지, 결과를 누가 받는지 모른다.
그건 스크립트와 어댑터가 정한다. 덕분에 **도구를 바꿔도 계약은 그대로**다.

**3. 사람이 승인하는 지점은 코드가 막는다.**
머지·보호 브랜치 push·보호 문서 수정은 AI 가 하지 않는다. 문서로만 금지하는 게 아니라
git 훅과 권한 설정과 명령 가드가 함께 막는다. → [flow.md](flow.md)

## 왜 정본과 어댑터를 나눴나

하네스마다 자동으로 읽는 파일이 다르다.

| 하네스 | 자동으로 읽는 것 | 정본에 닿는 방법 |
|---|---|---|
| Claude Code | `CLAUDE.md` | `@.ai/AI_AGENT.md` — 기계적 import |
| Codex CLI | 루트 `AGENTS.md` | 거기 적힌 지시를 읽고 따라감 |

`.ai/` 아래 파일은 누군가 "읽으라" 고 지시해야 열린다. 그래서 루트의 두 파일이 관문 역할만 하고
규칙은 담지 않는다. 규칙을 관문에 복사하면 사본이 정본 개정을 따라가지 못한다.

## 자주 헷갈리는 것

| 질문 | 답 |
|---|---|
| 리뷰 상한을 바꾸려면? | `harness.toml` 의 `review.max_rounds`. 그 뒤 `harness render` |
| 이 프로젝트의 아키텍처 규칙은 어디 적나? | `.ai/project/architecture.md`. 규칙 문서가 그 본문을 담아 생성된다 |
| 리뷰는 누가 하나? | `harness.toml` 의 `roles.code-reviewer` 가 정한다. 구현한 모델이 자기 코드를 리뷰하지 않게 |
| 다른 forge 로 옮기려면? | `harness.toml` 의 `[forge]` 두 줄. 어댑터는 `script/forge/` 에 이미 있다 |
| 결정 기록을 다른 방식으로 쓰려면? | `harness.toml` 의 `[adr]`. 절차는 바뀌지 않는다 |
| `.ai/AI_AGENT.md` 를 직접 고치면? | 다음 `harness render` 가 덮고, 그전에 `harness check` 가 커밋을 막는다 |
