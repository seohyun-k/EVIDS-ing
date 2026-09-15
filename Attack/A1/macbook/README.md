# A1 collection on a Mac (Apple M3) — from a clean machine

This runs the **entire A1 pipeline** — patched EVerest SIL, ISO 15118 DC charging
sessions, the coherent ISO under-report attack, feature extraction, and the
scope comparison — inside a Linux container on your Mac. Nothing is installed on
macOS itself except Docker.

## Why a container?

ISO 15118 HLC needs the in-host SECC (EvseV2G) and EVCC (PyEvJosev) to find each
other via **SDP link-local multicast**. Only a *dummy* network interface loops
that multicast back to the host; `device: auto` picks a docker bridge that does
**not**, so charging stalls at `PrepareCharging` and every meter value stays 0
(no values for the attack to forge). Creating a dummy interface needs
`CAP_NET_ADMIN`, which the shared lab server denies (no sudo). A container run
with `--cap-add=NET_ADMIN` can create `ev0` and pin both ISO modules to it —
that is the one privilege the bare host was missing.

macOS itself can't do this: `ip link ... type dummy` is a Linux kernel feature
and EVerest targets Linux. The container supplies a Linux kernel with the one
capability we need.

## 0. Install Docker (once)

Apple Silicon (M1–M4). Pick either:

- **Docker Desktop** — https://www.docker.com/products/docker-desktop (choose
  "Apple Silicon"). Launch it once so the daemon runs.
- **or colima** (lighter, CLI-only):
  ```bash
  brew install colima docker
  colima start --cpu 4 --memory 8 --disk 40
  ```

Verify:
```bash
docker info >/dev/null && echo "docker OK"
```
Give the VM at least **4 CPUs / 8 GB RAM** — EVerest is a big C++ compile.

## 1. Get the code

```bash
git clone -b A1_attack https://github.com/seohyun-k/EVIDS-ing.git
cd EVIDS-ing
```

## 2. Smoke test (fast, do this first)

Builds the image (first time: **tens of minutes** — it compiles everest-core),
then runs 1 normal + 1 attack session end-to-end:

```bash
./Attack/A1/macbook/run_all.sh smoke
```

Success looks like: sessions complete (not "exited early"), and
`A1-ATTACK spoof lines present` is printed. Results appear under
`Attack/A1/Attack_data/run_*/`.

## 3. Full collection + analysis

```bash
./Attack/A1/macbook/run_all.sh
```

Defaults (HANDOFF §7c): `N_NORMAL=60 N_ATTACK=30 FACTORS="0.75 0.80 0.90"
NORMAL_DERATE_FRAC=0.5`. Override any:

```bash
N_NORMAL=40 N_ATTACK=20 FACTORS="0.80" ./Attack/A1/macbook/run_all.sh
```

When it finishes it prints, and writes to `Attack/A1/Attack_data/run_*/`:
- `features.csv` — per-session scope-tagged features
- `eval_report.txt` — the ISO-only / OCPP-only / concat / cross / count-only table

**Existence proof (what to look for):** ISO-only and OCPP-only F1 near chance,
**cross** high, count-only at chance. That is the whole claim: single-channel
detection is blind in principle; only cross observation catches it.

## 4. Poke around inside the container (optional)

```bash
docker run --rm -it --cap-add=NET_ADMIN evids-a1 shell
# then, inside:
micromamba activate everest
IFACE=ev0 N_NORMAL=1 N_ATTACK=1 NORMAL_DERATE_FRAC=1 ./Attack/A1/collect_a1.sh
```

## Troubleshooting

- **"cannot create dummy 'ev0'"** — you dropped `--cap-add=NET_ADMIN`. `run_all.sh`
  already passes it; only happens with a hand-written `docker run`.
- **Build fails on an arm64 conda package** — force x86 emulation (slower):
  ```bash
  PLATFORM=linux/amd64 ./Attack/A1/macbook/run_all.sh
  ```
- **Sessions "exited early"** — read the newest
  `Attack/A1/Attack_data/run_*/session_*/manager.log`; it names the module that
  died (this is how the josev/pydantic and schema issues were found originally).
- **Rebuild after editing code** — push to `A1_attack`, then rerun `run_all.sh`
  (the image clones the branch at build time). For local edits without pushing,
  mount the repo over the image or `git clone` into the build context instead.
- **Disk** — the image is a few GB (toolchain + build). `docker image prune` to
  reclaim.

## What this reproduces from the lab-server debugging

The container bakes in every fix found while bringing this up sudo-free on the
shared server:
1. mosquitto broker lives in `$CONDA_PREFIX/sbin` (not on PATH) — `collect_a1.sh`
   auto-detects it.
2. `dc_target_current` is schema type **integer** — setpoints are whole numbers.
3. josev runtime deps (`pydantic==1.*`, environs, cryptography, …) are missing
   from the build — installed into both the venv and the conda env.
4. `device: auto` fails SDP — a dummy `ev0` is created and both ISO modules are
   pinned to it (`IFACE`).
