# scripts 디렉터리 설명

이 디렉터리에는 SWE-bench Verified 연습 환경을 위한 로컬 보조 파일만 둔다.
SWE-bench 공식 저장소에서 복사해 온 파일은 없다. 이 파일들은 `swebench-play`
repo에 포함되는 관리 대상이다.

각 shell script는 기본적으로 자신의 위치를 기준으로 프로젝트 root를 계산한다.
다른 root를 명시하고 싶으면 `SWE_PLAY_ROOT` 환경변수를 사용할 수 있다.

## 파일 목록

- `list_instances.py`
  - 기본값으로 `princeton-nlp/SWE-bench_Verified`의 `test` split을 로드한다.
  - 앞에서부터 N개 instance를 출력한다.
  - 출력 항목은 index, instance id, repo, problem statement 첫 줄이다.
  - 기본 N은 50개다.
  - `patch`, `test_patch`, 정답 PR 정보는 출력하거나 저장하지 않는다.

- `setup_instance.sh`
  - `INSTANCE_ID` 환경변수가 필요하다.
  - `DATASET_NAME` 기본값은 `princeton-nlp/SWE-bench_Verified`다.
  - `SPLIT` 기본값은 `test`다.
  - dataset에서 해당 instance를 찾는다.
  - `problem_statement`만 `issue.md`와 `SWE_ISSUE.md`로 저장한다.
  - 대상 GitHub repo를 `PROJECT_ROOT/instances/$INSTANCE_ID` 아래에 clone한다.
  - dataset의 `base_commit`으로 checkout한다.
  - gold patch나 test patch는 저장하지 않는다.

- `codex_prompt.md`
  - instance repo 안에서 Codex에 붙여넣기 위한 기본 프롬프트다.
  - Codex가 `SWE_ISSUE.md`를 읽고, 처음에는 수정하지 않고, 관련 파일과 함수
    후보를 찾도록 지시한다.
  - issue 요구사항과 실패 조건 요약, 최소 patch 계획 제시, 사용자 승인 전
    수정 금지 원칙을 포함한다.
  - 테스트 파일 수정 금지, 불필요한 리팩터링 금지, 정답 자료 확인 금지 원칙을
    포함한다.

- `eval_patch.sh`
  - `INSTANCE_ID` 환경변수가 필요하다.
  - `DATASET_NAME` 기본값은 `princeton-nlp/SWE-bench_Verified`다.
  - `SPLIT` 기본값은 `test`다.
  - 현재 instance repo의 `git diff --binary`를 patch로 저장한다.
  - SWE-bench prediction JSONL을 생성한다.
  - JSONL 필드는 `instance_id`, `model_name_or_path`, `model_patch`다.
  - `python -m swebench.harness.run_evaluation`을 실행한다.
  - `--max_workers 1`, `--cache_level env`, `--clean False`로 실행한다.
  - run id에는 instance id와 UTC timestamp를 포함한다.
  - 흔한 테스트 파일 경로가 patch에 포함되어 있으면 평가를 중단한다.
  - 평가 후 report와 로그 위치를 출력한다.

## 작성 출처

위 파일들은 모두 이 로컬 연습 환경을 위해 작성한 파일이다. 외부에서 clone한
공식 SWE-bench 코드는 `../SWE-bench/` 아래에 있으며, 이 디렉터리에는 두지 않는다.
