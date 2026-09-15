# A1 작업 인수인계 (context handoff)

이 문서는 A1(교차 프로토콜 공격, ISO측 담당) 재설계의 전체 맥락·결정·현재 상태·다음 단계를 담습니다.
다른 컴퓨터/새 Claude Code 세션/팀원이 이걸 읽고 그대로 이어갈 수 있게 정리했습니다.
(새 Claude Code 세션에서 자동 로드되게 하려면 이 파일을 저장소 루트에 `CLAUDE.md`로 복사해도 됩니다.)

## 0. 환경 제약 (필독 — 위반 금지)
공유 연구실 서버(Ubuntu 24.04)에서 작업한다. 아래는 절대 규칙이다:
- **`sudo` 절대 사용 금지.** 어떤 명령도 sudo로 실행하지 않는다.
- **시스템/전역에 설치·삭제·수정 금지.** `apt`, `/usr`, `/etc`, `/opt` 등 시스템 경로를 건드리지 않는다.
- **모든 것은 `/home/seohyunk` 안에서만.** 툴체인·라이브러리는 micromamba conda env `everest`에만 설치한다: `micromamba install -n everest -c conda-forge <pkg>`. pip/npm도 홈 prefix로만.
- **막힌 의존성은 conda로 해결하거나 해당 모듈을 빌드에서 제외**한다(예: sd-bus는 conda에 없어 RAUC 모듈 제외로 우회했음). conda에 없다고 sudo/apt로 설치하지 말 것.
- **`sudo`가 필요한 상황(예: `ip link add ev0`가 CAP_NET_ADMIN 요구)** 이 나오면 임의로 실행하지 말고 **사용자에게 보고**하고 지시를 기다린다.
- GPU는 이 작업에 쓰지 않는다(EVerest·sklearn 모두 CPU). GPU 설정 불필요.

## 1. 논문·문제
- 논문: "Cross-Protocol Observation for Intrusion Detection in EV Charging (ISO 15118 + OCPP 2.0.1)", EVerest SIL 테스트베드.
- 핵심 주장: **단일 채널로는 원리적으로 못 잡고 교차 관측이 필요한 공격이 실재한다.**
- 문제: 기존 A1·A2·A3(RV01~06)는 **전부 단일 채널로 탐지됨**(코드로 재확인) → 주장 미증명. A1 담당이 ISO측 존재증명을 새로 설계.
- 역할 분담: **A1 = ISO측 거짓말(본 문서)**, A3(팀원) = OCPP측 거짓말(A3-MV 전류·전력·에너지 동일비율 축소 / A3-SC SoC 축소). A2는 손대지 않음.

## 2. 최종 공격 설계 — coherent ISO 저보고
침해된 충전기가 **실제로는 정상 공급**하면서, EV에게 보내는 ISO 15118-2 계량값
(`EVSEPresentCurrent`, `MeterInfo.MeterReading`)만 **같은 비율 k(<1, 기본 0.8)로 낮춰** 보고.
관제(OCPP MeterValues)와 파워미터는 **진짜값** 유지.

단일 채널 blind가 성립하는 3조건(모두 동시 충족해야 함):
1. **내림 방향** — present < target. `present ≤ target`은 정상 derating이라 ISO 내부 모순 없음. (기존 공격은 위로 부풀려서 present>target → 잡힘)
2. **일관성(coherent)** — 전류·에너지를 같은 k로(전압 유지) → 에너지 = ∫(present 전력)이 ISO 내부에서 성립. (에너지만 위조하면 ∫검산에 걸림 — 스모크에서 비율 0.81로 FAIL 확인)
3. **범위 내** — k≈0.8, setpoint 랜덤화 → 정상 분포 안, 이상치 아님.

→ ISO 단독·OCPP 단독 blind, **ISO↔OCPP 값 대조(RV04·에너지 일관성)로만** 탐지.

## 3. 실기 타당성 (원고/보고에 명시)
- 위조 가능: 충전기가 EV로 보내는 present·meter는 충전기가 100% 생성. ISO 계량 서명(OCMF 포함)도 침해 충전기가 위조값에 유효 서명 → 단일채널 검증 통과.
- `present ≤ target`은 규격이 전제하는 정상 동작 — 램프업, 열/그리드/전력공유 derating, 케이블 한계, 테이퍼. ISO 15118-2의 `EVSECurrentLimitAchieved` 플래그가 그 증거. EVerest도 `config-sil-ac-temp-derating.yaml` 제공.
- 한계(정직히): EV BMS는 실제 전류를 자체 측정하므로 EV 로컬에선 알 수 있음. 단 IDS/CSMS는 그 사설 측정을 못 봄 → "충전기 경계에서 두 보고를 보는 IDS" 위협모델 안에서 성립.
- 방어책: ISO 계량과 OCPP 보고를 하나의 서명계측으로 바인딩(OCMF + MeterInfo 서명 바인딩). 미배치 환경의 탐지 수단이 교차 IDS.

## 4. 관련연구 대비 — SMDEVC (원고 [13], Applied Sci. 2026, 16, 5605)
원문(28p) 확인 결과: 12개 행위규칙(BR-1~12)은 포트·스캔·호스트·타이밍·시퀀스·인증만 다루고 **계량값 대조가 전혀 없음**. 두 프로토콜을 함께 봐도 인증 상태 플래그만. (CICEVSE2024 네트워크 데이터셋 + OCPP 1.6 기반)
→ (a) 우리 gap(값-수준 교차대조) 실재, (b) 우리 A1 공격은 BR-8~12를 전부 통과(evade). derating 규칙은 SMDEVC에 없음.

## 5. ⚠️ 실험 타당성 조건 — 정상 데이터에 derating 필수
EVerest SIL 공급기는 이상적 pass-through라 기본 정상 데이터는 항상 present=target(비율 1.0).
이 상태면 ISO 단독 모델이 공격의 비율 0.8을 "정상에서 못 본 값"으로 잡아 **실험 무효(아티팩트)**.
해결: 정상 세션 일부(`NORMAL_DERATE_FRAC`, 기본 0.5)를 **합법적 derating**(공급 max_current를 target 아래로 cap → present<target, 이때 OCPP도 그 낮은 값 실측 → ISO=OCPP)으로 수집.
그러면 정상 derating과 공격이 ISO 채널에선 동일, 교차에서만 갈림.
- 이 이슈는 **A1(ISO측)에만** 해당. A3(OCPP측)는 target 짝이 없어 비율 누수 없음 → 무관.
- 기존 정상 데이터는 버리지 않고 derating 세션 **보강**. 재수집은 A1에 한정.

## 6. 현재 저장소 상태 (브랜치 A1_attack, `Attack/A1/`)
- `patches/A1_iso-coherent-underreport.patch` — SECC(`iso_server.cpp` `handle_iso_current_demand`)에서 `EVSEPresentCurrent`·`MeterInfo.MeterReading`를 k로 저보고. env `A1_ATTACK`/`A1_FACTOR`/`A1_TARGET`. clean everest-core에 `git apply -p1` 통과 확인.
- `collect_a1.sh` — 정상+공격 수집. setpoint 랜덤화 + **derating 정상 세션 구현 완료**(`NORMAL_DERATE_FRAC`/`DERATE_MIN`/`DERATE_MAX`, DCSupplySimulator max_current cap). config 주입 YAML 검증 완료. 라벨은 meta.json(주입로그)에서만.
- `analysis/extract_features.py`, `analysis/evaluate.py` — ISO단독/OCPP단독/concat/cross + count-only ablation. `--self-test`로 신호 재현(테스트베드 불필요).
- `analysis/smoke_forge.cpp` — forge 산술·불변식 스모크. coherent k=0.8 전부 PASS, energy-only는 ∫검산 FAIL 확인.
- `README.md` — 설계·근거·명령. 이 `HANDOFF.md`.

**검증된 것:** 패치 적용, forge 로직 스모크, 스코프 self-test 신호, derating config 주입, conda 의존성 env solve. **아직 안 된 것:** 실제 EVerest 빌드에서의 라이브 수집·실데이터 스코프 결과.

## 7. 다음 단계 (서버, sudo 없이 /home/seohyunk 안에서)
1. micromamba 설치(홈) → conda env `everest` 생성(검증된 목록: python cxx-compiler c-compiler cmake ninja make pkg-config boost-cpp openssl sqlite libcurl libcap nodejs mosquitto rsync git).
2. EVIDS-ing 클론 → `A1_attack` 체크아웃 → `cd everest-core && git apply -p1 ../Attack/A1/patches/A1_iso-coherent-underreport.patch`.
3. EVerest 네이티브 빌드 → `build/dist` 생성. (ev-cli 등 python 툴 필요, CPM 의존성 fetch — 에러 나오면 하나씩 해결)
4. 수집: `A1_FACTOR=0.8 A1_TARGET=coherent NORMAL_DERATE_FRAC=0.5 ./Attack/A1/collect_a1.sh`.
5. 분석: `extract_features.py --sessions ... --out features.csv` → `evaluate.py --features ... --by-factor`.
6. 실측 파서 확인: 실제 로그 스키마에 맞게 `extract_features.py` 상단 CONTRACT(iso/ocpp/powermeter 파싱 키) 조정 필요할 수 있음.
7. 기대 결과: ISO단독/OCPP단독 near-chance, cross 높음, count-only chance. 나오면 원고 §II(SMDEVC)·§III-D·§IV-B·Discussion 재작성.

## 7b. 실제 빌드 성공 레시피 (Ubuntu 24.04, sudo 없이, /home/seohyunk) — 검증됨
```bash
# 0) micromamba (홈에)
curl -sL https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-linux-64 -o ~/bin/micromamba && chmod +x ~/bin/micromamba
export PATH=~/bin:$PATH; export MAMBA_ROOT_PREFIX=~/micromamba
eval "$(~/bin/micromamba shell hook -s bash)"
# 1) 의존성 env (libpcap·libevent 포함 — 각각 EvseV2G/PacketSniffer가 요구)
micromamba create -y -n everest -c conda-forge \
  python=3.11 pip cxx-compiler c-compiler cmake ninja make pkg-config \
  boost-cpp openssl sqlite libcurl libcap nodejs mosquitto rsync git libpcap libevent
micromamba activate everest
# 2) edm (ev-cli는 빌드가 venv에 자동 설치하므로 수동설치 불필요)
python -m pip install "git+https://github.com/EVerest/everest-dev-environment.git#subdirectory=dependency_manager"
# 3) 코드 + A1 패치 (git apply가 "Skipped"로 조용히 실패 → classic patch 도구 사용)
cd ~ && git clone https://github.com/seohyun-k/EVIDS-ing.git
cd EVIDS-ing && git checkout A1_attack && git pull
cd everest-core && patch -p1 < ../Attack/A1/patches/A1_iso-coherent-underreport.patch
grep -c "A1-ATTACK" modules/EVSE/EvseV2G/iso_server.cpp   # 4 = 적용됨(주석1+dlog3)
# 4) configure (불필요 모듈 sd-bus 제외 + cmake4 정책우회)
cmake -S . -B build -G Ninja \
  -DCMAKE_INSTALL_PREFIX="$PWD/build/dist" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DBUILD_TESTING=OFF -Deverest-core_USE_PYTHON_VENV=ON \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DEVEREST_EXCLUDE_MODULES="Linux_Systemd_Rauc" -DEVEREST_DEPENDENCY_ENABLED_SDBUS_CPP=OFF
# 5) build
ninja -C build install     # -> build/dist/bin/manager
```
막혔던 것들과 해결: sdbus-cpp(RAUC 모듈, SIL 불필요) → 제외 + `EVEREST_DEPENDENCY_ENABLED_SDBUS_CPP=OFF`; libpcap(PacketSniffer)·libevent(EvseV2G) → conda 설치. Doxygen/ZLIB/cJSON/radvd "not found"은 경고(무시).

## 7c. 수집 실행
```bash
micromamba activate everest
cd ~/EVIDS-ing
# 먼저 1세션 스모크로 파이프라인 확인 (ev0 인터페이스 생성이 sudo 없이 되는지 등)
N_NORMAL=1 N_ATTACK=1 NORMAL_DERATE_FRAC=1 A1_FACTOR=0.8 A1_TARGET=coherent \
  ./Attack/A1/collect_a1.sh
# 세션 폴더에 mqtt.log/csms.log/manager.log/meta.json 생기고, 공격 세션 manager.log에
# "[A1-ATTACK] ISO ..." 라인이 보이면 정상. 그다음 본수집:
N_NORMAL=60 N_ATTACK=30 FACTORS="0.75 0.80 0.90" NORMAL_DERATE_FRAC=0.5 \
  ./Attack/A1/collect_a1.sh
python3 Attack/A1/analysis/extract_features.py --sessions Attack/A1/Attack_data --out Attack/A1/analysis/features.csv
python3 Attack/A1/analysis/evaluate.py --features Attack/A1/analysis/features.csv --by-factor
```
분석엔 python 패키지 필요: `python -m pip install scikit-learn numpy` (xgboost는 선택).
**주의(ev0):** collect 스크립트가 `ip link add ev0 type dummy`로 더미 인터페이스를 만드는데 이게 CAP_NET_ADMIN(보통 sudo)을 요구할 수 있음. 스모크에서 세션이 안 서면 이 지점 의심 → 관리자에게 ev0 1회 생성 요청하거나 대체 구성 필요.
**주의(파서):** 실제 로그 스키마가 `extract_features.py` 상단 CONTRACT의 파싱 키와 다르면 조정 필요 — 스모크 로그(mqtt.log/csms.log) 샘플을 보고 iso/ocpp/powermeter 값 위치를 맞출 것.

## 8. 열린 이슈 / 주의
- 실기 관측점: EVerest는 res 값을 버스에 publish 안 함 → 패치가 `[A1-ATTACK]` 로그로 방출, collector가 파싱. 실기에선 ISO 평문 탭.
- 완전 airtight를 원하면 present 전류·전압·에너지를 같은 k로 함께(스케일) — 현재는 전류+에너지(전압 유지)로 충분(∫검산 통과).
- 표본 확대·다배치 LOBO로 배치 confound 재확인 필요.
