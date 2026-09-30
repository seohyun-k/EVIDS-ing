# A1 (cross-protocol ISO under-report) — self-contained EVerest SIL + collection
# image. Builds the PATCHED everest-core and installs every runtime dep we found
# the hard way, so `collect_a1.sh` runs a real ISO 15118 DC charging session and
# produces attackable meter values.
#
# WHY A CONTAINER (and not the bare host): ISO 15118 HLC uses SDP link-local
# multicast for the in-host SECC (EvseV2G) and EVCC (PyEvJosev) to discover each
# other. Only a *dummy* interface loops that multicast back; a docker bridge / lo
# does not, so charging stalls at PrepareCharging and every meter value stays 0.
# Creating a dummy needs CAP_NET_ADMIN, which a locked-down shared host denies.
# Inside a container run with `--cap-add=NET_ADMIN`, we can create `ev0` and pin
# both ISO modules to it (see Attack/A1/collect_a1.sh: IFACE / device: ev0).
#
# Build (Apple M3 = arm64, native):   docker build -t evids-a1 Attack/A1/macbook
# Run (creates ev0, collects+analyzes): see Attack/A1/macbook/run_all.sh
#
# The EVerest compile is heavy (tens of minutes even native). conda-forge has
# arm64 builds of every dep below; if a package ever misses arm64, rebuild with
# `--platform linux/amd64` (slower, emulated).

FROM ubuntu:24.04
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive \
    MAMBA_ROOT_PREFIX=/opt/micromamba \
    ENVBIN=/opt/micromamba/envs/everest/bin

# Minimal apt layer: fetch tools + iproute2 (dummy iface) + patch/git. Everything
# else (compilers, cmake, boost, openssl, mosquitto, ...) comes from conda-forge
# so this matches the sudo-free host recipe exactly.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates bzip2 git patch iproute2 procps binutils && \
    rm -rf /var/lib/apt/lists/*

# micromamba, arch-aware (arm64 -> aarch64, amd64 -> 64)
RUN set -eux; case "${TARGETARCH:-amd64}" in \
      arm64) MARCH=aarch64;; amd64|"") MARCH=64;; *) MARCH=64;; esac; \
    curl -sL "https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-linux-${MARCH}" \
      -o /usr/local/bin/micromamba && chmod +x /usr/local/bin/micromamba

# Verified dependency env (libpcap/libevent are required by PacketSniffer/EvseV2G)
RUN micromamba create -y -n everest -c conda-forge \
      python=3.11 pip cxx-compiler c-compiler cmake ninja make pkg-config \
      boost-cpp openssl sqlite libcurl libcap nodejs mosquitto rsync git \
      libpcap libevent && \
    micromamba clean -ay

# edm (EVerest dependency manager); ev-cli is installed into the build venv automatically.
RUN $ENVBIN/python -m pip install --no-cache-dir \
      "git+https://github.com/EVerest/everest-dev-environment.git#subdirectory=dependency_manager"

# Source + A1 patch. Cloned from GitHub so the image is fully self-contained; the
# patch is applied to pristine upstream (iso_server.cpp is NOT committed patched).
ARG REPO=https://github.com/seohyun-k/EVIDS-ing.git
ARG BRANCH=A1_attack
# Bump CACHEBUST (e.g. --build-arg CACHEBUST=$(date +%s)) to force a fresh clone
# after pushing new commits; keeps the apt/conda layers above cached.
ARG CACHEBUST=0
RUN git clone --depth 1 --branch "$BRANCH" "$REPO" /opt/EVIDS-ing
WORKDIR /opt/EVIDS-ing/everest-core
RUN patch -p1 < ../Attack/A1/patches/A1_iso-coherent-underreport.patch && \
    test "$(grep -c 'A1-ATTACK' modules/EVSE/EvseV2G/iso_server.cpp)" -ge 4

# Configure + build (RAUC/sdbus-cpp excluded — not needed for SIL; cmake4 policy
# shim). `micromamba run` activates the env so conda's CC/CXX are used.
RUN micromamba run -n everest cmake -S . -B build -G Ninja \
      -DCMAKE_INSTALL_PREFIX="$PWD/build/dist" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DBUILD_TESTING=OFF -Deverest-core_USE_PYTHON_VENV=ON \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DEVEREST_EXCLUDE_MODULES="Linux_Systemd_Rauc" \
      -DEVEREST_DEPENDENCY_ENABLED_SDBUS_CPP=OFF && \
    micromamba run -n everest ninja -j2 -C build install

# josev runtime deps (pydantic==1.*, environs, cryptography, ...) are NOT pulled
# by the build; PyEvJosev crashes at import without them. Install into BOTH the
# build venv AND the conda env (the manager's fallback interpreter), plus the
# analysis deps.
# Runtime system deps, installed post-compile to preserve the build cache:
#  - tzdata: EVerest's date lib needs an IANA zoneinfo dir or core modules
#    (api/evse_manager/evse_security) abort with "discover_tz_dir failed ...".
#  - default-jre-headless: josev's ISO 15118 EXI codec (exificient) shells out
#    to `java`; iso15118_car crashes without it (also provides keytool).
RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    apt-get install -y --no-install-recommends tzdata default-jre-headless && \
    rm -rf /var/lib/apt/lists/*
RUN micromamba run -n everest $ENVBIN/python -m pip install --no-cache-dir -r build/_deps/josev-src/requirements.txt && \
    micromamba run -n everest ./build/venv/bin/python -m pip install --no-cache-dir -r build/_deps/josev-src/requirements.txt && \
    micromamba run -n everest $ENVBIN/python -m pip install --no-cache-dir scikit-learn numpy websockets ocpp && \
    micromamba run -n everest $ENVBIN/python -c "import pydantic; assert pydantic.VERSION.startswith('1.'), pydantic.VERSION"

# EV-IDS canonical collection parameters (team Notion "핵심 파라미터" §7), applied
# to the installed dist post-compile so the heavy build layer stays cached:
#   - charge 180s (iso_wait_for_stop) + auto_exec_infinite: true  -> ev_manager_1
#   - OCPP201 MeterValues intervals 10s (TxUpdatedInterval 120->10,
#     AlignedDataCtrlr.Interval 900->10) so each session yields ~40 MeterValues.
# The device_model DB is built fresh from these JSONs at runtime (no stale DB in
# the image / --rm containers), so editing the JSON is sufficient. device: auto
# stays as-is; collect_a1.sh rewrites it to ev0 per session.
RUN set -eux; D="$PWD/build/dist"; \
    for CFG in "$D/etc/everest/config-sil-dc-ocpp201.yaml" "$PWD/config/config-sil-dc-ocpp201.yaml"; do \
      [ -f "$CFG" ] || continue; \
      sed -i 's/iso_wait_for_stop 60/iso_wait_for_stop 180/' "$CFG"; \
      grep -q 'auto_exec_infinite' "$CFG" || sed -i '/auto_exec: true/a\      auto_exec_infinite: true' "$CFG"; \
    done; \
    STD="$D/share/everest/modules/OCPP201/component_config/standardized"; \
    micromamba run -n everest python -c 'import json,sys; s=sys.argv[1]; \
p=s+"/SampledDataCtrlr.json"; d=json.load(open(p)); n1=[a.update(value=10) for v in d["properties"].values() if isinstance(v,dict) and v.get("variable_name")=="TxUpdatedInterval" for a in v.get("attributes",[]) if a.get("type")=="Actual"]; json.dump(d,open(p,"w"),indent=2); \
q=s+"/AlignedDataCtrlr.json"; e=json.load(open(q)); n2=[a.update(value=10) for v in e["properties"].values() if isinstance(v,dict) and v.get("variable_name")=="Interval" for a in v.get("attributes",[]) if a.get("type")=="Actual"]; json.dump(e,open(q,"w"),indent=2); \
assert len(n1)==1 and len(n2)==1, ("interval edit missed", len(n1), len(n2)); print("OCPP MeterValues intervals -> 10s")' "$STD"

WORKDIR /opt/EVIDS-ing
COPY docker-entrypoint.sh /usr/local/bin/a1-entrypoint
RUN chmod +x /usr/local/bin/a1-entrypoint
ENTRYPOINT ["/usr/local/bin/a1-entrypoint"]
CMD ["collect"]
