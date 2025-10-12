# QE 7.3.1 with Intel MPI + MKL on Ubuntu 24.04
FROM intel/oneapi-hpckit:2025.2.2-0-devel-ubuntu24.04

# Use bash for RUN so "source" works
SHELL ["/bin/bash", "-lc"]

# Base tools + FFTW3 headers (QE uses FFTW3 interface)
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git build-essential pkg-config ca-certificates \
      libfftw3-dev && \
    rm -rf /var/lib/apt/lists/*

# Make oneAPI env auto-load in interactive shells (nice to have)
RUN echo 'source /opt/intel/oneapi/setvars.sh > /dev/null' >> /etc/bash.bashrc

# Build environment
ENV MKLROOT=/opt/intel/oneapi/mkl/latest
ENV PATH="/opt/intel/oneapi/mpi/latest/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/intel/oneapi/mpi/latest/lib/release:/opt/intel/oneapi/mpi/latest/libfabric/lib:/opt/intel/oneapi/mkl/latest/lib/intel64:/opt/intel/oneapi/compiler/latest/lib/intel64_lin:${LD_LIBRARY_PATH}"
ENV LIBRARY_PATH="/opt/intel/oneapi/mpi/latest/lib/release:/opt/intel/oneapi/mkl/latest/lib/intel64:/opt/intel/oneapi/compiler/latest/lib/intel64_lin:${LIBRARY_PATH}"
ENV CC=mpiicc \
    CXX=mpiicpc \
    FC=mpiifort \
    MPIF90=mpiifort

# Aggressive but safe CPU opts for Intel compilers
ENV CFLAGS="-O3 -xHost" \
    CXXFLAGS="-O3 -xHost" \
    FCFLAGS="-O3 -xHost -qopenmp" \
    FFLAGS="-O3 -xHost -qopenmp"

# FFTW include/libs (system FFTW)
ENV FFTW_INCLUDE="/usr/include" \
    FFTW_LIBS="-lfftw3 -lfftw3_threads"

# MKL BLAS/LAPACK + ScaLAPACK/BLACS (Intel MPI interface)
# Use the recommended start/end-group to resolve symbols
ENV MKL_GROUP="-Wl,--start-group -lmkl_intel_lp64 -lmkl_core -lmkl_intel_thread -Wl,--end-group -liomp5 -lpthread -lm -ldl"
ENV BLAS_LIBS="-L${MKLROOT}/lib/intel64 ${MKL_GROUP}"
ENV LAPACK_LIBS="${BLAS_LIBS}"
ENV SCALAPACK_LIBS="-L${MKLROOT}/lib/intel64 -lmkl_scalapack_lp64 -lmkl_blacs_intelmpi_lp64 ${MKL_GROUP}"

# Where we'll put QE
WORKDIR /opt

# Get QE 7.3.1 and build everything with -j 20
RUN source /opt/intel/oneapi/setvars.sh && \
    git clone --depth 1 --branch qe-7.3.1 https://github.com/QEF/q-e.git q-e && \
    cd q-e && \
    ./configure --enable-parallel --with-scalapack && \
    make -j 20 all

# Default working dir and PATH to QE binaries
WORKDIR /opt/q-e
ENV PATH="/opt/q-e/bin:${PATH}"

# Reasonable runtime defaults (tune at 'docker run' if you like)
ENV OMP_NUM_THREADS=2 \
    MKL_NUM_THREADS=1 \
    MKL_DYNAMIC=FALSE \
    I_MPI_PIN=1 \
    I_MPI_PIN_DOMAIN=core \
    I_MPI_PIN_ORDER=compact \
    I_MPI_FABRICS=shm

# Drop into a shell by default
CMD ["/bin/bash"]
