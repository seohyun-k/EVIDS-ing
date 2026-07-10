# EVerest A1 Attack Reproduction Environment
# -----------------------------------------------
# EVerest 소스를 클론 후 A1 패치를 적용해 빌드합니다.
# 빌드 시간: 약 30~40분 (초기 1회)
#
# [사용법]
#   docker build -t everest-a1 .
#   docker run -it --rm -p 1883:1883 -p 8080:8080 everest-a1

FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /home/everest

# 1. 빌드 의존성 설치
RUN apt-get update && apt-get install -y \
    git cmake ninja-build python3 python3-pip python3-dev \
    libboost-all-dev libssl-dev libcurl4-openssl-dev \
    libnl-3-dev libnl-route-3-dev libsqlite3-dev \
    libpcap-dev pkg-config \
    mosquitto mosquitto-clients \
    nodejs npm patch \
    && rm -rf /var/lib/apt/lists/*

# 2. EVerest 소스 클론
RUN git clone https://github.com/EVerest/everest-core.git \
    && cd everest-core \
    && git checkout 9f775a97 \
    && git submodule update --init --recursive

# 3. A1 공격 패치 적용
COPY patches/iso_server.patch /tmp/
RUN cd everest-core && git apply --ignore-whitespace --whitespace=nowarn /tmp/iso_server.patch

# 4. DC+OCPP2.0.1 설정 파일 추가
COPY config/config-sil-dc-ocpp201.yaml everest-core/config/

# 5. 빌드
RUN cd everest-core \
    && mkdir -p build && cd build \
    && cmake .. -GNinja \
       -DCMAKE_BUILD_TYPE=RelWithDebInfo \
       -DCMAKE_INSTALL_PREFIX=./dist \
    && ninja -j$(nproc) install

# 6. run 스크립트 추가
RUN mkdir -p everest-core/build/run-scripts
COPY scripts/run-sil-dc-ocpp201.sh everest-core/build/run-scripts/
RUN chmod +x everest-core/build/run-scripts/run-sil-dc-ocpp201.sh

EXPOSE 1883 8080

CMD ["/bin/bash", "/home/everest/everest-core/build/run-scripts/run-sil-dc-ocpp201.sh"]
