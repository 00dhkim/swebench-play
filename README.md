# SWE-bench Verified Codex 연습 환경

SWE-bench Verified 벤치마크는 엄선된 SW 문제 모음집이므로, 사용자가 codex와 함께 이 문제를 풀어가는 과정에서 Coding Agent 활용 능력을 기르고자 한다. SW계의 백준같은 것이다.

이 repo는 SWE-bench Verified 문제를 로컬 repo에서 Codex와 함께 풀고,
수정 patch를 SWE-bench harness로 평가하기 위한 연습 환경이다.

## 목적

SWE-bench Verified 문제는 실제 소프트웨어 이슈에 가까운 문제 모음이다.
이 환경의 목적은 Codex에게 한 번에 자동으로 많은 문제를 풀게 하는 것이 아니라,
사람이 Codex와 협업하면서 다음 과정을 반복 연습하는 것이다.

1. 문제별 로컬 repo를 준비한다.
2. Codex와 함께 issue를 읽고 코드를 수정한다.
3. 수정 결과를 `git diff` patch로 추출한다.
4. SWE-bench Docker harness에서 평가한다.
5. 실패 로그를 보고 다시 수정한다.

## 디렉터리 구조

```text
swebench-play/
  SWE-bench/   초기 설치 때 clone하는 공식 SWE-bench 저장소
  instances/   문제별 로컬 풀이 repo가 생성되는 위치
  scripts/     로컬 보조 스크립트와 Codex 프롬프트
```

`SWE-bench/`는 이 repo에 포함하지 않는다. 초기 설치 때 공식 저장소를 이 위치에
clone해서 사용한다.

```text
https://github.com/SWE-bench/SWE-bench.git
```

이 디렉터리에는 SWE-bench harness와 Python virtualenv가 들어간다. 가능한 한 공식
clone 상태를 유지하고, 연습용 glue code는 이 repo의 `scripts/` 아래에 둔다.

`instances/`는 실제 풀이 작업 공간이다. 디렉터리 자체만 repo에 남기고, 그 아래에
생성되는 문제별 repo는 커밋하지 않는다. `setup_instance.sh`를 실행하면
`instances/$INSTANCE_ID/` 아래에 해당 문제의 원본 repo가 clone되고,
dataset의 `base_commit`으로 checkout된다. Codex는 이 디렉터리에서 실행한다.

`scripts/`에는 문제 목록 조회, instance 준비, patch 평가, Codex 기본 프롬프트가
있다. 각 파일의 세부 설명은 `scripts/README.md`를 본다.

## 기본 전제

- Dataset: `princeton-nlp/SWE-bench_Verified`
- Split: `test`
- 평가는 SWE-bench 공식 harness로 실행한다.
- harness는 Docker 평가 환경을 사용한다.
- Codex는 `instances/$INSTANCE_ID` 안의 로컬 repo에서만 코드를 수정한다.
- 평가에는 `git diff`로 추출한 patch만 전달한다.
- gold patch, test patch, 정답 PR은 보지 않는다.
- 테스트 파일은 수정하지 않는다.

## 필요 도구

다른 PC에서 실행하려면 다음 도구가 필요하다.

- Linux 또는 Ubuntu 계열 환경
- Python 3.10 이상 권장
- Git
- Docker
- Codex CLI

Docker는 현재 사용자 권한으로 실행 가능해야 한다.

```bash
docker info
```

권한 문제가 있으면 Ubuntu 계열에서는 보통 다음 순서로 설정한다.

```bash
sudo usermod -aG docker "$USER"
newgrp docker
docker info
```

## 시작하기

먼저 이 repo를 clone한다.

```bash
git clone https://github.com/00dhkim/swebench-play.git
cd swebench-play
```

그 다음 공식 SWE-bench 저장소와 Python venv를 준비한다.

```bash
git clone https://github.com/SWE-bench/SWE-bench.git SWE-bench

cd SWE-bench
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip setuptools wheel
python -m pip install -e .
```

이미 `SWE-bench/`와 `.venv`가 준비되어 있다면 설치 과정은 다시 하지 않아도 된다.
단, PC가 바뀌면 `.venv`는 새 환경에서 다시 만드는 편이 안전하다.

설치 확인:

```bash
cd SWE-bench
source .venv/bin/activate
python - <<'PY'
import swebench
print("swebench import ok")
PY
```

## 사용 흐름

먼저 SWE-bench venv를 활성화한다.

```bash
cd SWE-bench
source .venv/bin/activate
```

문제 목록을 확인한다.

```bash
python ../scripts/list_instances.py 20
```

풀 문제를 고른 뒤 instance repo를 준비한다.

```bash
export INSTANCE_ID="선택한_instance_id"
../scripts/setup_instance.sh
```

생성된 instance repo로 이동해서 Codex를 실행한다.

```bash
cd ../instances/$INSTANCE_ID
codex
```

Codex 안에서는 `scripts/codex_prompt.md` 내용을 붙여넣고 작업을
시작한다.

수정이 끝나면 SWE-bench harness로 평가한다.

```bash
cd SWE-bench
../scripts/eval_patch.sh
```

스크립트는 기본적으로 자기 위치를 기준으로 `PROJECT_ROOT`를 찾는다. 다른 위치의
작업 공간을 명시하고 싶으면 `SWE_PLAY_ROOT`를 지정할 수 있다.

```bash
export SWE_PLAY_ROOT="/path/to/swebench-play"
```

## 자동 baseline 실행

단일 프롬프트로 바로 풀리는 문제는 학습용으로 적합하지 않을 수 있다. 그래서
먼저 자동 baseline을 실행해 보고, harness에서 실패한 문제를 사람이 Codex와 함께
풀 대상으로 삼는다.

자동 baseline은 `scripts/run_codex_baseline.sh`와 `scripts/codex_baseline_prompt.md`로
실행한다. 상세 사용법과 결과 파일 설명은 `scripts/README.md`를 본다.

## 평가 결과와 로그

`eval_patch.sh`는 실행할 때마다 run id를 만들고, patch와 prediction JSONL을
`SWE-bench/runs/` 아래에 저장한다. `SWE-bench/` 전체는 `.gitignore` 대상이므로
평가 산출물도 이 repo에 커밋되지 않는다.

평가 후에는 다음 위치를 출력한다.

- 생성된 patch
- prediction JSONL
- summary report
- instance별 `report.json`
- `test_output.txt`
- `run_instance.log`

실패하면 출력된 `report.json`, `test_output.txt`, `run_instance.log`를 요약해서 다시 Codex에 제공하면 된다.

## 주의사항

- SWE-bench harness 결과가 최종 판정이다.
- 로컬 테스트 결과와 harness 결과는 다를 수 있다.
- `setup_instance.sh`는 `problem_statement`만 저장한다.
- gold patch, test patch, 정답 PR은 워크플로에 포함하지 않는다.
- `eval_patch.sh`는 흔한 테스트 파일 경로가 diff에 포함되면 평가를 중단한다.
- 이번 환경은 사람이 Codex와 함께 한 문제씩 푸는 연습용이다. 여러 문제를
  단일 프롬프트로 자동 풀이한 결과는 쉬운 문제를 걸러내기 위한 baseline으로만
  사용한다.
