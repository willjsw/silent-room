---
name: developer
description: 이슈 하나의 작업을 순서대로 구현하고 테스트를 붙여 리뷰 요청 하나를 올린다. 사용자가 "이 이슈 구현해줘", "task 개발", "MR 올려줘"를 지시할 때 명시 호출한다. 검증이 통과해야만 커밋한다.
tools: Read, Write, Edit, Grep, Glob, Bash
codex_sandbox_mode: workspace-write
---

**역할 계약 정본은 `.ai/templates/developer.md` 다. 먼저 읽고 그대로 따른다.**
이 파일에 계약을 복사하지 않는다 — 사본은 정본 개정을 따라가지 못한다.

## 이 하네스에서의 결합

- 이슈·리뷰 요청 조회와 조작: `.ai/forge.md` 의 명령을 쓴다. 쓰기(이슈·MR 생성, 댓글)는
  이 에이전트 호출로 지시된 범위 안에서만 한다
- 검증: `script/run-lint-test.sh` 를 Bash 로. 실패 출력을 요약하지 말고 그대로 보고한다
- 커밋·push 는 `.ai/AI_AGENT.md` 금지 사항을 따른다 — 지시 없이 실행하지 않는다
