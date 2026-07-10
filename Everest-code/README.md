# EVerest A1 공격 재현 환경

국민대학교 MoSE Lab — EV 충전 인프라 Cross-Protocol IDS 연구

---

## 포함 파일

```
EVIDS_A1/
├── README.md
├── Dockerfile
├── config/
│   └── config-sil-dc-ocpp201.yaml     ← DC+OCPP2.0.1 통합 설정 파일
├── patches/
│   └── iso_server.patch               ← A1 공격 코드 패치
└── scripts/
    └── run-sil-dc-ocpp201.sh          ← 실행 스크립트
```

---

## A1 공격 개요

| 항목 | 내용 |
|---|---|
| 공격 대상 | EVerest `EvseV2G` 모듈 (`iso_server.cpp`) |
| 수정 지점 1 | `ChargeParameterDiscoveryRes` — EVSEMaximumCurrentLimit = 250A로 거짓 협상 |
| 수정 지점 2 | `CurrentDemandRes` — EVSEPresentCurrent *= 8 (8배 부풀림) |
| 탐지 근거 | ISO 15118 보고값(160A) vs OCPP MeterValues(20A) 불일치 → RV04 규칙 위반 |

---

## 실행 방법

### 방법 1 — Docker로 실행 (권장)

```bash
# 1. 이미지 빌드
docker build -t everest-a1 .

# 2. 컨테이너 실행
# 1883: MQTT 브로커 / 8080: EVerest API
docker run -it --rm \
  -p 1883:1883 \
  -p 8080:8080 \
  everest-a1

# 3. (선택) MQTT 전체 로그 수집
mosquitto_sub -h localhost -t "#" -v | tee mqtt_session.log
```

### 방법 2 — 기존 EVerest 빌드 환경에 직접 적용

```bash
# iso_server.cpp 패치 적용
cd ~/everest-core
git apply /path/to/iso_server.patch

# config 파일 복사
cp /path/to/config-sil-dc-ocpp201.yaml ~/everest-core/config/

# 빌드
cd build && ninja -j4

# 실행
./run-scripts/run-sil-dc-ocpp201.sh
```

---

## A1 공격 효과 확인

실행 후 터미널을 2개 열어 아래를 동시에 확인.

```bash
# 터미널 1 — OCPP MeterValues (실측값, 조작 안 됨)
mosquitto_sub -h localhost -t "everest/+/ocpp/#" -v

# 터미널 2 — ISO 15118 CurrentDemandRes (조작됨)
mosquitto_sub -h localhost -t "everest/iso15118_charger/#" -v
```

### 기대 결과

| 데이터 소스 | 값 | 비고 |
|---|---|---|
| DC 파워미터 (실측) | 20A | 실제 공급 전류 |
| OCPP MeterValues | 20A | CSMS에 정확히 보고 |
| ISO 15118 CurrentDemandRes | 160A | EV에 8배 거짓 보고 |

→ 두 값의 8배 불일치 = A1 공격 성공


