# Quantum ESPRESSO 7.5 + Intel oneAPI (MKL + Intel MPI) on Ubuntu 24.04
# Builds pw.x and neb.x with -j 20, logs to console and /var/log/qe-build.log

FROM intel/oneapi-hpckit:2025.2.2-0-devel-ubuntu24.04
SHELL ["/bin/bash", "-lc"]

ARG QE_TAG=qe-7.5
ARG MAKEJ=20

# Central in-image build log (we also stream to console)
ENV BUILD_LOG=/var/log/qe-build.log

# 1) Disable the broken Intel GPU repo (must be before first apt update) — logged
RUN set -euxo pipefail; \
    mkdir -p /var/log; : > "$BUILD_LOG"; \
    exec > >(tee -a "$BUILD_LOG") 2>&1; \
    echo "=== disable Intel GPU apt repo ==="; \
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do \
      [ -f "$f" ] || continue; \
      sed -i -E 's|^([[:space:]]*deb(\s+\[.*\])?[[:space:]]+https?://repositories\.intel\.com/gpu/.*)$|# \1|g' "$f" || true; \
    done; \
    rm -f /etc/apt/sources.list.d/*intel*gpu*.list /etc/apt/sources.list.d/*gpu*.list || true

# 2) Minimal build deps — logged
RUN set -euxo pipefail; \
    exec > >(tee -a "$BUILD_LOG") 2>&1; \
    echo "=== apt-get update/install ==="; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential gfortran git pkg-config ca-certificates file; \
    rm -rf /var/lib/apt/lists/*

# 3) oneAPI env + wrappers (use icx/ifx only; avoid classic icc/ifort)
ENV ONEAPI_ROOT=/opt/intel/oneapi
ENV MKLROOT=${ONEAPI_ROOT}/mkl
ENV I_MPI_ROOT=${ONEAPI_ROOT}/mpi
ENV PATH="${I_MPI_ROOT}/latest/bin:${PATH}"
ENV LD_LIBRARY_PATH="${MKLROOT}/lib/intel64:${I_MPI_ROOT}/latest/lib/release:${I_MPI_ROOT}/latest/libfabric/lib:${LD_LIBRARY_PATH}"

# Force MPI wrappers to use LLVM compilers
ENV I_MPI_F90=ifx I_MPI_FC=ifx I_MPI_CC=icx I_MPI_CXX=icpx

# Select wrappers explicitly (icx/ifx)
ENV CC=mpiicx CXX=mpiicpx FC=mpiifort F90=mpiifort F77=mpiifort MPIF90=mpiifort

# Optimization flags + OpenMP
ENV CFLAGS="-O3 -xHost" \
    CXXFLAGS="-O3 -xHost" \
    FCFLAGS="-O3 -xHost -qopenmp" \
    FFLAGS="-O3 -xHost -qopenmp"

# MKL + ScaLAPACK + BLACS (Intel MPI flavor) + iomp5
ENV MKL_LINK="-L${MKLROOT}/lib/intel64 -lmkl_intel_lp64 -lmkl_core -lmkl_intel_thread -liomp5 -lpthread -ldl -lm"
ENV BLAS_LIBS="${MKL_LINK}"
ENV LAPACK_LIBS="${MKL_LINK}"
ENV SCALAPACK_LIBS="-L${MKLROOT}/lib/intel64 -lmkl_scalapack_lp64 -lmkl_blacs_intelmpi_lp64 ${MKL_LINK}"
ENV FFT_LIBS=""
ENV FFTW_INCLUDE=""

# 4) Fetch QE — logged
WORKDIR /opt/qe
RUN set -euxo pipefail; \
    exec > >(tee -a "$BUILD_LOG") 2>&1; \
    echo "=== git clone QE ${QE_TAG} ==="; \
    git clone --depth 1 --branch "${QE_TAG}" https://gitlab.com/QEF/q-e.git src

WORKDIR /opt/qe/src

# 5) Toolchain sanity + configure + build — logged (errors always printed)
RUN set -euxo pipefail; \
    exec > >(tee -a "$BUILD_LOG") 2>&1; \
    echo "=== source oneAPI setvars (safely) ==="; \
    { set +u; . ${ONEAPI_ROOT}/setvars.sh --force || true; set -u; }; \
    echo "=== probe compilers & wrappers ==="; \
    which mpiifort || true; which mpiicx || true; which mpiicpx || true; \
    (mpiifort -V || mpiifort --version || true); \
    (icx --version || true); (icpx --version || true); \
    echo "program t; print *, 'toolchain-ok'; end program t" > t.f90; \
    mpiifort ${FCFLAGS} t.f90 -o t; ./t || true; \
    echo "int main(){return 0;}" > t.c; \
    mpiicx ${CFLAGS} t.c -o tc && file tc || true; \
    echo "=== QE configure (explicit icx/ifx wrappers) ==="; \
    ./configure --enable-parallel --with-scalapack \
        FC=${FC} MPIF90=${MPIF90} F90=${F90} F77=${F77} \
        CC=${CC} CXX=${CXX} \
    || { echo '*** ERROR: ./configure failed; listing tree and any logs:'; ls -la; \
         (find . -maxdepth 2 -name config.log -print -exec sh -c "echo '--- {} ---'; cat {}" \;) || true; \
         exit 2; }; \
    test -f make.inc || { echo '*** ERROR: configure did not generate make.inc'; \
         (find . -maxdepth 2 -name config.log -print -exec sh -c "echo '--- {} ---'; cat {}" \;) || true; \
         exit 2; }; \
    echo "=== configure summary (install/configure.msg) ==="; \
    cat install/configure.msg || true; \
    echo "=== make (attempt: pw.x neb.x) ==="; \
    (make -j ${MAKEJ} V=1 pw.x neb.x || (echo "==== retry with canonical targets: pw neb ====" && make -j ${MAKEJ} V=1 pw neb)); \
    echo "=== built executables ==="; ls -l bin

# 6) Runtime knobs for hybrid MPI/OpenMP
ENV OMP_NUM_THREADS=2 OMP_PROC_BIND=close OMP_PLACES=cores \
    MKL_NUM_THREADS=1 MKL_DYNAMIC=FALSE

# 7) Put QE on PATH
ENV PATH="/opt/qe/src/bin:${PATH}"

CMD ["/bin/bash"]
