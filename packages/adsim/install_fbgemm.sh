#!/bin/bash
# shellcheck disable=SC2086,SC1091,SC2034
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.
#
# Modified to use system packages instead of Miniconda/conda.
# The adsim FBGEMM build only needs the C++ shared library, not the Python
# GPU package, so no Python venv or PyTorch is required.

################################################################################
# Global Configuration Variables
################################################################################

# Version of FBGEMM to install
FBGEMM_VERSION=v1.2.0

# Python version (used only for version-tagged paths if needed)
PYTHON_VERSION=3.13


################################################################################
# Platform Specific Variables
################################################################################
# shellcheck disable=SC2155
export KERN_NAME="$(uname -s)"
# shellcheck disable=SC2155
export MACHINE_NAME="$(uname -m)"
# shellcheck disable=SC2155
export PLATFORM_NAME="$KERN_NAME-$MACHINE_NAME"
# shellcheck disable=SC2155
export KERN_NAME_LC="$(echo "$KERN_NAME" | awk '{print tolower($0)}')"
# shellcheck disable=SC2155
export MACHINE_NAME_LC="$(echo "$MACHINE_NAME" | awk '{print tolower($0)}')"
# shellcheck disable=SC2155
export PLATFORM_NAME_LC="$KERN_NAME_LC-$MACHINE_NAME_LC"


################################################################################
# Utility Functions
################################################################################

exec_with_retries () {
  local max_retries="$1"
  local delay_secs=2
  local retcode=0

  for i in $(seq 0 ${max_retries}); do
    # shellcheck disable=SC2145
    echo "[EXEC] [ATTEMPT ${i}/${max_retries}]    + ${@:2}"

    if "${@:2}"; then
      local retcode=0
      break
    else
      local retcode=$?
      echo "[EXEC] [ATTEMPT ${i}/${max_retries}] Command attempt failed."
      echo ""

      if [ "$i" -ne "$max_retries" ]; then
        sleep $delay_secs
      fi
    fi
  done

  if [ $retcode -ne 0 ]; then
    echo "[EXEC] The command has failed after ${max_retries} + 1 attempts; aborting."
  fi

  return $retcode
}

test_network_connection () {
  exec_with_retries 3 wget -q --timeout 1 pypi.org -O /dev/null
  local exit_status=$?

  if [ $exit_status == 0 ]; then
    echo "[CHECK] Network does not appear to be blocked."
  else
    echo "[CHECK] Network check exit status: ${exit_status}"
    echo "[CHECK] Network appears to be blocked or suffering from poor connection."
    return 1
  fi
}

print_exec () {
  echo "+ $*"
  echo ""

  if eval "$*"; then
    local retcode=0
  else
    local retcode=$?
  fi

  echo ""
  return $retcode
}


################################################################################
# Setup Functions
################################################################################

setup_directories() {
  echo "[SETUP] Setting up directories for FBGEMM build..."

  rm -rf ${FBGEMM_STAGING_DIR}
  mkdir -p ${FBGEMM_STAGING_DIR}

  echo "[SETUP] Changing to build directory..."
  pushd ${FBGEMM_STAGING_DIR} || exit 1

  echo "[SETUP] Directory setup complete."
}

clone_fbgemm_repo() {
  echo "################################################################################"
  echo "# Clone FBGEMM Repository (${FBGEMM_VERSION})"
  echo "#"
  echo "# [$(date --utc +%FT%T.%3NZ)] + ${FUNCNAME[0]} ${*}"
  echo "################################################################################"
  echo ""

  test_network_connection || return 1

  echo "[SETUP] Cloning repository with submodules..."
  git clone --recursive -b ${FBGEMM_VERSION} https://github.com/pytorch/FBGEMM.git fbgemm

  # Disable the postbuild script to prevent race conditions during linking
  echo "[SETUP] Disabling postbuild script..."
  echo "#!/bin/bash" > fbgemm/.github/scripts/fbgemm_gpu_postbuild.bash

  echo "[SETUP] FBGEMM repository setup complete."
}


################################################################################
# Build Functions
################################################################################

# Build FBGEMM C++ shared library using system compilers (clang from config.sh)
# This replaces the previous approach of using a conda environment with
# conda-installed GCC and gtest headers.
install_fbgemm() {
  echo "################################################################################"
  echo "# Build FBGEMM C++ Shared Library"
  echo "#"
  echo "# [$(date --utc +%FT%T.%3NZ)] + ${FUNCNAME[0]} ${*}"
  echo "################################################################################"
  echo ""

  pushd fbgemm || exit 1
  mkdir -p build
  pushd build || exit 1

  # Configure FBGEMM with CMake using system compilers
  # NOTE: The original script used -I${FBGEMM_STAGING_DIR}/miniconda/include to
  # pick up gtest headers from conda. Since build-deps.sh already installs
  # libgtest-dev via apt, system include paths are sufficient.
  echo "[BUILD] Configuring FBGEMM with CMake..."
  cmake \
    -DFBGEMM_CPU_ONLY=ON \
    -DFBGEMM_BUILD_BENCHMARKS=OFF \
    -DFBGEMM_BUILD_TESTS=OFF \
    -DCMAKE_INSTALL_PREFIX="${ADSIM_STAGING_DIR}" \
    -DFBGEMM_LIBRARY_TYPE=shared \
    -DCMAKE_CXX_COMPILER="${ADSIM_CXX_COMPILER:-clang++}" \
    -DCMAKE_C_COMPILER="${ADSIM_C_COMPILER:-clang}" \
    -DCMAKE_CXX_FLAGS="-fopenmp=libomp -Wno-undef" \
    -DCMAKE_C_FLAGS="-fopenmp=libomp -Wno-undef" \
    ..

  # Determine parallelism
  local jobs
  jobs=$(nproc 2>/dev/null || echo 4)

  # Build the library
  echo "[BUILD] Building FBGEMM (parallelism: ${jobs})..."
  make -j "${jobs}" VERBOSE=1

  # Manually copy cmake config files and library to staging directory
  # This is needed because 'make install' may fail due to gtest warnings
  echo "[BUILD] Copying FBGEMM files to staging directory..."
  mkdir -p "${ADSIM_STAGING_DIR}/share/cmake/fbgemm"
  mkdir -p "${ADSIM_STAGING_DIR}/lib"
  mkdir -p "${ADSIM_STAGING_DIR}/include"

  # Copy cmake config files
  EXPORT_DIR=$(find CMakeFiles/Export -type d -name "*" | head -2 | tail -1)
  cp "${EXPORT_DIR}"/fbgemmLibraryConfig*.cmake \
    "${ADSIM_STAGING_DIR}/share/cmake/fbgemm/" 2>/dev/null || true

  # Copy library
  cp libfbgemm.so* "${ADSIM_STAGING_DIR}/lib/" 2>/dev/null || true

  # Copy headers from source
  cp -r ../include/fbgemm "${ADSIM_STAGING_DIR}/include/" 2>/dev/null || true

  echo "[BUILD] FBGEMM files copied to staging directory"

  # Try make install but don't fail if it errors
  make install 2>/dev/null || \
    echo "[WARNING] make install failed, using manual copy instead"

  popd || exit 1  # exit build/
  popd || exit 1  # exit fbgemm/

  # Also copy from the top-level build output (for backward compat with old paths)
  echo "[BUILD] Copying FBGEMM cmake config to staging directory..."
  find "${FBGEMM_STAGING_DIR}/fbgemm/build" -name "fbgemmLibraryConfig*.cmake" \
    -exec cp {} "${ADSIM_STAGING_DIR}/share/cmake/fbgemm/" \; 2>/dev/null || true

  cp "${FBGEMM_STAGING_DIR}/fbgemm/build/libfbgemm.so"* \
    "${ADSIM_STAGING_DIR}/lib/" 2>/dev/null || true

  cp -r "${FBGEMM_STAGING_DIR}/fbgemm/include/fbgemm" \
    "${ADSIM_STAGING_DIR}/include/" 2>/dev/null || true

  echo "[BUILD] FBGEMM installation complete."
}

cleanup() {
  echo "[CLEANUP] Returning to original directory..."
  popd || true

  echo "[CLEANUP] Cleanup complete."
}


################################################################################
# Main Function
################################################################################

main() {
  echo "################################################################################"
  echo "# Starting FBGEMM Installation for AdSim"
  echo "# $(date)"
  echo "# Platform: ${PLATFORM_NAME}"
  echo "################################################################################"

  # Set up the staging directory
  echo "[MAIN] Setting up directories..."
  setup_directories

  # Clone the FBGEMM repository
  echo "[MAIN] Cloning FBGEMM repository..."
  clone_fbgemm_repo

  # Build FBGEMM C++ shared library
  echo "[MAIN] Building FBGEMM..."
  install_fbgemm

  # Return to original directory
  echo "[MAIN] Cleaning up..."
  cleanup

  echo "################################################################################"
  echo "# FBGEMM Installation Complete"
  echo "# Library installed to: ${ADSIM_STAGING_DIR}/lib/"
  echo "# Headers installed to: ${ADSIM_STAGING_DIR}/include/fbgemm/"
  echo "# $(date)"
  echo "################################################################################"
}


main
