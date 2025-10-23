# Quantum ESPRESSO 7.5 + Intel oneAPI (MKL/MPI) in Docker

Reproducible, containerized build of Quantum ESPRESSO **7.5** compiled with **Intel oneAPI** (Fortran compiler runtime, **Intel MPI**, **MKL** with ScaLAPACK).  
Designed for **MPI-only** single-host runs (e.g., **20 CPUs**) with sensible defaults, detached job control, and easy progress monitoring.

- Base: Ubuntu 24.04
- Toolchain: Intel oneAPI (ifx/ifort runtime), Intel MPI 2021, MKL (BLAS/LAPACK/ScaLAPACK)
- Built targets: `pw.x`, `neb.x`
- Compose defaults: 20 CPUs, `OMP_NUM_THREADS=1`, Intel MPI pinning (compact), OFI over TCP (`I_MPI_OFI_PROVIDER=tcp`)
- Shared memory size: configurable (default **4 GB**)

> **Repo:** https://github.com/malakhovks/Intel_MPI_MKL_QE_Docker

---

## Contents

- `Dockerfile` – builds QE 7.5 with oneAPI/MKL/MPI and puts `pw.x`/`neb.x` on `PATH`.
- `docker-compose.yml` – runs the container with CPU limits, shared memory, and tuned env vars.
- `workspace/` – bind-mounted working directory for inputs, pseudopotentials, and outputs.

Suggested workspace layout:
```
workspace/
├─ fe_c_fcc_neb_fixed.in      # NEB input (example)
├─ pw_1.in, pw_2.in           # example SCF/relax inputs (optional)
├─ pseudos/                   # UPF files (set pseudo_dir='./pseudos')
├─ runs/                      # logs/output
└─ tmp/                       # QE scratch (e.g., outdir='./tmp')
```

---

## Requirements

- Linux host with Docker Engine 24+ and Docker Compose v2
- ~20 CPU cores available (or adjust in compose)
- RAM: ≥8 GB (more is better; example host has 60 GB)
- Internet access to build the image

---

## Quick Start

```bash
# 1) Clone
git clone https://github.com/malakhovks/Intel_MPI_MKL_QE_Docker.git
cd Intel_MPI_MKL_QE_Docker

# 2) Prepare workspace
mkdir -p workspace/pseudos workspace/runs workspace/tmp
# Copy your UPF pseudopotentials into workspace/pseudos
# and set pseudo_dir='./pseudos' in QE input files

# 3) Build the image
docker compose build --no-cache

# 4) Start the container (detached)
docker compose up -d

# 5) Sanity check (inside the container)
docker compose exec qe bash -lc 'pw.x -h | head -n 12; echo; neb.x -h | head -n 12'
```

---

## docker-compose defaults (excerpt)

The compose file already provides tuned defaults. Key bits are shown below:

```yaml
services:
  qe:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        QE_TAG: "qe-7.5"
        MAKEJ: "20"
    image: qe:7.5-oneapi-mkl

    # Limit to 20 CPUs (adjust to your host)
    cpus: "20"

    # Optional: large shared memory for MPI
    shm_size: "4g"

    volumes:
      - ./workspace:/workspace
    working_dir: /workspace

    environment:
      # MPI-only defaults: one OpenMP thread per rank
      OMP_NUM_THREADS: "1"
      OMP_PROC_BIND: "close"
      OMP_PLACES: "cores"
      MKL_NUM_THREADS: "1"
      MKL_DYNAMIC: "FALSE"

      # Intel MPI: use shared memory + OFI over TCP (single-host)
      I_MPI_FABRICS: "shm:ofi"
      I_MPI_OFI_PROVIDER: "tcp"
      FI_TCP_IFACE: "eth0"

      # Rank pinning (compact, core-level)
      I_MPI_PIN: "1"
      I_MPI_PIN_DOMAIN: "core"    # switch to "omp" when OMP_NUM_THREADS>1
      I_MPI_PIN_ORDER: "compact"

    ulimits:
      nofile: 1048576
      stack: 67108864

    stdin_open: true
    tty: true
```

> **Note:** Avoid setting `FI_PROVIDER` to a list (e.g., `tcp;shm`). If present, either unset it or set `FI_PROVIDER=tcp` to prevent libfabric selection errors.

---

## Sanity Checks

**Pinning & CPU quota:**

```bash
# 4 ranks, each pinned to a distinct core
docker compose exec qe bash -lc 'mpirun -np 4 bash -lc "echo RANK=$PMI_RANK on $(hostname); taskset -pc $$"'

# Verify CPU limit (20 CPUs -> 2,000,000 / 100,000)
docker compose exec qe bash -lc 'cat /sys/fs/cgroup/cpu.max'
# Expected: "2000000 100000"  -> 2.0 CPU-seconds per 0.1s = 20 CPUs
```

**Optional tiny SCF test (ensure a matching UPF exists):**
```bash
docker compose exec qe bash -lc '
  cd /workspace; mkdir -p tmp runs;
  cat > Si.scf.in <<EOF
&control
  calculation = "scf",
  prefix = "si",
  outdir = "./tmp",
  pseudo_dir = "./pseudos"
/
&system
  ibrav = 2, celldm(1) = 10.20, nat = 2, ntyp = 1,
  ecutwfc = 40.0
/
&electrons
  conv_thr = 1.0d-8
/
ATOMIC_SPECIES
  Si  28.0855  Si.pbe-n-kjpaw_psl.1.0.0.UPF
ATOMIC_POSITIONS (alat)
  Si  0.00 0.00 0.00
  Si  0.25 0.25 0.25
K_POINTS automatic
  6 6 6 0 0 0
EOF
  mpirun -np 2 pw.x -in Si.scf.in |& tee runs/Si.scf.out
  grep -m1 "!    total energy" runs/Si.scf.out || true
'
```

---

## Run NEB (detached) from the host

Assuming your NEB input is `./workspace/fe_c_fcc_neb_fixed.in`, the following launches **20 MPI ranks** and streams output to a timestamped run folder:

```bash
RUN_ID=fe_c_fcc_neb_fixed-$(date +%F-%H%M%S)
docker compose exec -d qe bash -lc "
  set -euo pipefail
  cd /workspace
  mkdir -p runs/$RUN_ID tmp
  mpirun -np 20 neb.x -in fe_c_fcc_neb_fixed.in \
    |& tee runs/$RUN_ID/neb.out
"
```

**Optimized hybrid launch (10 MPI ranks × 2 threads on 20 AVX-512 cores):**

```bash
RUN_ID=fe_c_fcc_neb_fixed-hybrid-$(date +%F-%H%M%S)
docker compose exec \
  -e OMP_NUM_THREADS=2 \
  -e OMP_PROC_BIND=spread \
  -e OMP_PLACES=cores \
  -e I_MPI_PIN_DOMAIN=omp \
  -e I_MPI_PIN_ORDER=compact \
  -e MKL_NUM_THREADS=1 \
  -d qe bash -lc "
    set -euo pipefail
    cd /workspace
    mkdir -p runs/$RUN_ID tmp
    export OMP_DISPLAY_ENV=VERBOSE
    mpirun -np 10 neb.x -in fe_c_fcc_neb_fixed.in \
      |& tee runs/$RUN_ID/neb.out
  "
```

> `OMP_DISPLAY_ENV=VERBOSE` prints the effective hybrid pinning at launch so you can confirm ranks/threads land on distinct cores. Drop it for production once you are satisfied with the placement.

**Monitor progress:**
```bash
# Live tail
tail -f workspace/runs/$RUN_ID/neb.out

# Recent iterations / energies
grep -E 'neb: iter|image +[0-9]+.* e =' workspace/runs/$RUN_ID/neb.out | tail -n 20

# Convergence markers
grep -E 'JOB DONE|PATH CONVERGED' workspace/runs/$RUN_ID/neb.out
```

**Stop gracefully (if needed):**
```bash
# Send SIGINT to neb.x (preferred)
docker compose exec qe bash -lc "pkill -INT -f '/opt/qe/src/bin/neb.x' || pkill -INT -f mpirun || true"

# Force kill if it refuses to stop
docker compose exec qe bash -lc "pkill -9 -f '/opt/qe/src/bin/neb.x|mpirun' || true"
```

---

## Tuning

**MPI-only (default):**
- `OMP_NUM_THREADS=1` (one OpenMP thread per rank)
- Rank pinning compact to cores: `I_MPI_PIN=1`, `I_MPI_PIN_ORDER=compact`, `I_MPI_PIN_DOMAIN=core`
- `OMP_PROC_BIND=close`, `OMP_PLACES=cores`
- MKL confined to one thread: `MKL_NUM_THREADS=1`, `MKL_DYNAMIC=FALSE`

**Hybrid MPI+OpenMP (example 10 ranks × 2 threads):**
- In compose env set:
  - `OMP_NUM_THREADS=2`
  - `I_MPI_PIN_DOMAIN=omp`
  - `OMP_PROC_BIND=spread`
  - `OMP_PLACES=cores`
- Launch with: `mpirun -np 10 ...`

**Shared memory:**
- `shm_size: "4g"` is set; increase if you see shared-memory pressure.

**CPU limit:**
- `cpus: "20"` limits the container to 20 logical CPUs; adjust per your host.

---

## Troubleshooting

**OFI provider error (e.g., `fi_getinfo() failed: No data available`):**
- Ensure these are set (compose already does):
  - `I_MPI_FABRICS=shm:ofi`
  - `I_MPI_OFI_PROVIDER=tcp`
  - `FI_TCP_IFACE=eth0`
- Avoid `FI_PROVIDER` with multiple values; if present: `unset FI_PROVIDER` or set `FI_PROVIDER=tcp`.

**Unexpected threading / oversubscription:**
- Confirm `OMP_NUM_THREADS=1`, `MKL_NUM_THREADS=1`.
- Verify CPU quota inside the container:
  ```bash
  docker compose exec qe bash -lc 'cat /sys/fs/cgroup/cpu.max'
  ```

**Pinning sanity:**
```bash
docker compose exec qe bash -lc 'mpirun -np 4 bash -lc "echo RANK=$PMI_RANK; taskset -pc $$"'
```

**Build problems:**
- Rebuild with `docker compose build --no-cache`.
- Ensure network access to Intel oneAPI repository during build.

---

## Citations

If you use this setup in research, please cite Quantum ESPRESSO as requested by the project:

- P. Giannozzi *et al.*, *J. Phys.: Condens. Matter* **21**, 395502 (2009)  
- P. Giannozzi *et al.*, *J. Phys.: Condens. Matter* **29**, 465901 (2017)  
- P. Giannozzi *et al.*, *J. Chem. Phys.* **152**, 154105 (2020)  
- https://www.quantum-espresso.org

---

## License

This repository contains build/configuration files. Quantum ESPRESSO and Intel oneAPI components retain their respective licenses. See upstream projects for details.

---

## TL;DR

```bash
git clone https://github.com/malakhovks/Intel_MPI_MKL_QE_Docker.git
cd Intel_MPI_MKL_QE_Docker
mkdir -p workspace/pseudos workspace/runs workspace/tmp
docker compose build
docker compose up -d

RUN_ID=fe_c_fcc_neb_fixed-$(date +%F-%H%M%S)
docker compose exec -d qe bash -lc "cd /workspace; mkdir -p runs/$RUN_ID tmp; \
  mpirun -np 20 neb.x -in fe_c_fcc_neb_fixed.in |& tee runs/$RUN_ID/neb.out"

tail -f workspace/runs/$RUN_ID/neb.out
```
