You are solving one SWE-bench Verified instance as an automatic baseline run.

Goal:
- Read `SWE_ISSUE.md`.
- Implement a minimal production-code fix for that issue.
- Leave a final `git diff` in the working tree.

Rules:
- Do not inspect or ask for gold patch, test_patch, or the upstream answer PR.
- Do not modify test files.
- Do not add unrelated refactors, formatting churn, dependency changes, or public interface changes unless required by the issue.
- Prefer the smallest coherent fix that addresses the issue.
- You may inspect the codebase, run focused local tests, and edit production files.
- If local tests are expensive or hard to configure, run the most targeted practical checks and state what was not run.
- The SWE-bench harness result is the final judgment.

Workflow:
1. Read `SWE_ISSUE.md`.
2. Locate the relevant code path.
3. Patch the production code.
4. Run targeted validation if practical.
5. Finish with a concise summary of changed files, validation, and remaining risk.
