# scripts 디렉터리 설명

이 디렉터리에는 SWE-bench Verified 연습 환경을 위한 로컬 보조 파일만 둔다.
SWE-bench 공식 저장소에서 복사해 온 파일은 없다. 이 파일들은 `swebench-play`
repo에 포함되는 관리 대상이다.

각 shell script는 기본적으로 자신의 위치를 기준으로 프로젝트 root를 계산한다.
다른 root를 명시하고 싶으면 `SWE_PLAY_ROOT` 환경변수를 사용할 수 있다.

## 파일 목록

- `bootstrap.sh`
  - 공식 SWE-bench 저장소를 `PROJECT_ROOT/SWE-bench` 아래에 clone한다.
  - `SWE-bench/.venv`가 없으면 새 Python virtualenv를 만든다.
  - `pip`, `setuptools`, `wheel`을 갱신하고 SWE-bench를 editable install한다.
  - 설치 후 `swebench` import 확인을 실행한다.
  - `SWE_BENCH_REPO_URL` 환경변수로 clone URL을 바꿀 수 있다.

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
  - `INSTANCES_DIR` 환경변수로 instance 생성 위치를 바꿀 수 있다.
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

- `codex_baseline_prompt.md`
  - 자동 baseline 실행에서 `codex exec`에 전달하는 프롬프트다.
  - 사람 승인 대기 없이 한 번의 비대화 실행으로 issue를 읽고, production code를
    수정하고, 가능한 범위의 검증을 수행하도록 지시한다.
  - gold patch, test patch, 정답 PR 확인 금지와 테스트 파일 수정 금지 원칙을
    포함한다.

- `run_codex_baseline.sh`
  - 단일 프롬프트 자동 baseline을 실행한다.
  - 첫 번째 인자로 실행할 문제 개수 `COUNT`를 받는다.
  - `START_INDEX`로 dataset 시작 위치를 바꿀 수 있다.
  - 각 instance에 대해 `setup_instance.sh`, `codex exec`, patch 저장을 순차
    실행한 뒤, 기본값으로 harness 평가는 마지막에 batch로 한 번 실행한다.
  - batch 평가는 SWE-bench harness의 `--max_workers`를 사용한다.
    `MAX_WORKERS` 기본값은 `4`다.
  - `EVALUATE=0`이면 Codex 실행과 patch 저장까지만 수행한다.
  - `EVAL_ONLY=1`이면 기존 run directory의 `summary.tsv`에 기록된 row만
    대상으로 setup과 Codex 실행을 건너뛰고 batch 평가만 실행한다.
    이 옵션은 `RESUME_RUN_DIR`와 함께 써야 한다.
  - Codex quota/rate limit 계열 실패가 감지되면 기본값으로 Codex loop를 멈춘다.
    이때 `codex_status=codex_limit_failed`가 기록되고, 이미 생성된 patch 후보는
    batch 평가한다.
  - `RESUME_RUN_DIR`로 기존 run directory를 이어서 실행할 수 있다.
    이미 `summary.tsv`에 기록된 instance는 건너뛴다.
  - `RETRY_FAILED=1`을 함께 지정하면 resume 시 `failed`, `setup_failed`,
    `codex_limit_failed` row를 다시 시도한다.
  - 이미 `eval_status=ok`인 row는 기본값으로 재평가하지 않는다.
    다시 평가하려면 `REEVALUATE=1`을 지정한다.
  - `DRY_RUN=1`이면 실행 대상 instance id만 출력하고 종료한다.
  - 결과는 `PROJECT_ROOT/baseline-runs/codex_<timestamp>/` 아래에 저장한다.
  - `summary.tsv`에는 instance id, Codex 실행 상태, 평가 상태, resolved 여부,
    Codex 실행 시간, token 사용량, 비용 추정치, 로그 위치가 기록된다.
  - 비용 추정은 `codex exec --json`의 `turn.completed.usage`를 파싱해서 계산한다.
  - reasoning output token은 output token 비용에 속하는 것으로 보고 기록한다.
  - 기본 비용 추정 모델은 `COST_MODEL=${MODEL:-gpt-5.5}`다.
  - 지원 모델 기본 단가는 `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`,
    `gpt-5.3-codex`, `gpt-5.2`다.
  - 다른 모델이나 다른 단가를 쓰려면 `CODEX_INPUT_USD_PER_1M`,
    `CODEX_CACHED_INPUT_USD_PER_1M`, `CODEX_OUTPUT_USD_PER_1M`를 지정한다.

  사용 예:

  ```bash
  # 앞에서부터 5개 instance를 자동 풀이하고 기본값으로 harness 평가까지 실행한다.
  scripts/run_codex_baseline.sh 5

  # dataset index 20부터 10개 instance를 자동 풀이한다.
  START_INDEX=20 scripts/run_codex_baseline.sh 10

  # harness 평가 worker 수를 8로 올려 batch 평가한다.
  MAX_WORKERS=8 scripts/run_codex_baseline.sh 50

  # Codex 실행과 patch 저장까지만 수행하고 harness 평가는 건너뛴다.
  EVALUATE=0 scripts/run_codex_baseline.sh 10

  # (재개하는 경우) 기존 run에서 추가 codex exec는 하지 않고, 지금까지 Codex 실행이 끝난 row만 harness 평가한다.
  RESUME_RUN_DIR=baseline-runs/codex_20260503T100502Z EVAL_ONLY=1 scripts/run_codex_baseline.sh 500

  # 중단된 baseline run을 이어서 실행한다.
  RESUME_RUN_DIR=baseline-runs/codex_20260503T100502Z scripts/run_codex_baseline.sh 500

  # Codex 한도 실패 등 실패 row를 다시 시도하며 이어서 실행한다.
  RESUME_RUN_DIR=baseline-runs/codex_20260503T100502Z RETRY_FAILED=1 scripts/run_codex_baseline.sh 500

  # 이미 harness 평가가 끝난 row까지 다시 평가한다.
  RESUME_RUN_DIR=baseline-runs/codex_20260503T100502Z REEVALUATE=1 scripts/run_codex_baseline.sh 500

  # 실행 대상 instance id만 확인하고 setup, Codex 실행, 평가는 하지 않는다.
  DRY_RUN=1 scripts/run_codex_baseline.sh 5

  # 지정한 Codex model로 앞에서부터 5개 instance를 자동 풀이한다.
  MODEL="gpt-5.4" scripts/run_codex_baseline.sh 5

  # 단가를 직접 지정해서 비용을 추정한다.
  CODEX_INPUT_USD_PER_1M=2.5 CODEX_CACHED_INPUT_USD_PER_1M=0.25 CODEX_OUTPUT_USD_PER_1M=15 scripts/run_codex_baseline.sh 5
  ```

  결과 구조:

  ```text
  PROJECT_ROOT/baseline-runs/codex_<timestamp>/
    instance_ids.txt
    summary.tsv
    <INSTANCE_ID>/
      setup.log
      codex.log
      codex_final.md
      codex_usage.json
      model.patch
      eval.log
    batch_eval/
      <RUN_ID>/
        predictions.jsonl
        candidates.tsv
        eval_updates.tsv
        eval.log
        report/
    instances/
      <INSTANCE_ID>/
  ```

  `summary.tsv`에서 `resolved=false` 또는 `eval_status=failed`인 문제를 골라
  사람이 Codex와 함께 다시 풀면 된다. 이 문제들이 단일 프롬프트 baseline으로는
  해결되지 않은 학습 후보가 된다.

- `extract_codex_usage.py`
  - `codex exec --json`이 출력한 JSONL 로그에서 마지막 `turn.completed.usage`를
    읽는다.
  - input, cached input, output, reasoning output token 수를 추출한다.
  - 모델별 기본 단가 또는 환경변수로 전달한 단가를 사용해 USD 비용 추정치를
    계산한다.

- `eval_patch.sh`
  - `INSTANCE_ID` 환경변수가 필요하다.
  - `DATASET_NAME` 기본값은 `princeton-nlp/SWE-bench_Verified`다.
  - `SPLIT` 기본값은 `test`다.
  - 현재 instance repo의 `git diff --binary`를 patch로 저장한다.
  - 기본 instance 위치는 `PROJECT_ROOT/instances/$INSTANCE_ID`이고,
    `INSTANCE_DIR` 또는 `INSTANCES_DIR` 환경변수로 바꿀 수 있다.
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
