# silent-room — Claude Code

프로젝트 개요·컨벤션·금지 사항의 정본은 `.ai/AI_AGENT.md` 다.
이 파일은 **Claude Code 전용 자산 지도**만 담는다.

## 공통 규칙 (정본)

@.ai/AI_AGENT.md

> 규칙을 바꿀 때는 이 파일이 아니라 `harness.toml` 또는 `.ai/project/` 를 고치고
> `harness render` 를 돌린다. `.ai/AI_AGENT.md` 자체도 생성물이다.

## Claude Code 전용 자산

| 자산 | 역할 |
|---|---|
| `.claude/agents/code-reviewer.md` | 변경분 리뷰 → 결과 출력. **`/work` 루프의 리뷰 수단이 아니다** — 루프는 `script/review-mr.sh` 하나만 쓴다 |
| `.claude/agents/developer.md` | 이슈 하나의 작업 전부 구현 + 테스트 + 리뷰 요청 1건 |
| `.claude/agents/docs-writer.md` | 머지된 변경 근거로 현재형 문서 정리 |
| `.claude/agents/planner.md` | 명세 → task 분해(`docs/plan/<번호>/`) |
| `.claude/agents/requirement-analyzer.md` | 이슈 하나 → 결정이 필요한 쟁점만 보고. **파일을 만들지 않는다** |
| `.claude/agents/spec-writer.md` | 이슈 하나 → `docs/spec/` 명세 작성·갱신 |
| `.claude/commands/prework.md` | `/prework <이슈번호>` — 요구사항 검토 → 결정 게이트 → 명세 → task 분해 → spec+plan 리뷰 요청 |
| `.claude/commands/work.md` | `/work <이슈번호>` — 착수 판정 → 구현 → 리뷰 요청 → 리뷰 루프 |
| `.claude/settings.json` | 보호 브랜치 push·보호 문서 수정 차단, 명령 실행 전 가드 |
| `.claude/settings.local.json` | 개인 환경 허용 목록. 커밋 대상 아님 |

에이전트 6종은 **명시 호출 전용**이다. 자동으로 위임되지 않는다.
각 에이전트의 입력·절차·출력 계약은 `.ai/templates/<역할>.md` 에 있다.

커맨드 2종은 여러 에이전트를 순서대로 엮는다. **절차 정본은 `.ai/workflows/` 이고 커맨드 파일은
위임 어댑터다.** 둘 다 사용자가 직접 타이핑할 때만 돈다.

```
/prework <이슈>  →  requirement-analyzer  →  (사람 결정)  →  spec-writer  →  planner
                                                                    ↓
                                                     spec+plan 리뷰 요청  →  (사람 승인)
/work <이슈>  →  work-preflight.sh  →  [분해 있음] sync-task-issues.sh ┐
                                                                       ├→  developer  ⇄  리뷰
                                       [분해 없음] ────────────────────┘        (review-mr.sh)
```

## 이 하네스에서의 실행 수단

- 이슈·리뷰 요청 조회·조작: `.ai/forge.md` 의 명령. 쓰기는 사용자가 명시적으로 요청한 턴에서만.
- 검증: `script/run-lint-test.sh` 를 Bash 로. 결과를 요약하지 말고 실패 출력을 그대로 보고한다.
- 하네스 설정 변경: `harness.toml` 을 고치고 `.harness/bin/harness render`.
- 커밋·push: `.ai/AI_AGENT.md` 의 "금지 사항" 이 우선한다. 지시 없이 실행하지 않는다.

<!-- 이 파일은 harness.toml 에서 생성된다. 직접 고치지 않는다. -->
