#!/bin/bash
# Copyright (c) 2022-2023, NVIDIA CORPORATION.

set -euo pipefail

source rapids-env-update

export CMAKE_GENERATOR=Ninja

rapids-print-env

CPP_CHANNEL=$(rapids-download-conda-from-s3 cpp)

PY_VER=${RAPIDS_PY_VERSION//./}

LIBRMM_CHANNEL=$(rapids-get-artifact ci/rmm/pull-request/1241/1fd0b84/rmm_conda_cpp_cuda11_$(arch).tar.gz)
RMM_CHANNEL=$(rapids-get-artifact ci/rmm/pull-request/1241/1fd0b84/rmm_conda_python_cuda11__${PY_VER}_$(arch).tar.gz)

rapids-logger "Begin py build"

# TODO: Remove `--no-test` flags once importing on a CPU
# node works correctly
rapids-mamba-retry mambabuild \
  --no-test \
  --channel "${CPP_CHANNEL}" \
  --channel "${LIBRMM_CHANNEL}" \
  --channel "${RMM_CHANNEL}" \
  conda/recipes/pylibcugraph

rapids-mamba-retry mambabuild \
  --no-test \
  --channel "${CPP_CHANNEL}" \
  --channel "${LIBRMM_CHANNEL}" \
  --channel "${RMM_CHANNEL}" \
  --channel "${RAPIDS_CONDA_BLD_OUTPUT_DIR}" \
  conda/recipes/cugraph

rapids-mamba-retry mambabuild \
  --no-test \
  --channel "${CPP_CHANNEL}" \
  --channel "${LIBRMM_CHANNEL}" \
  --channel "${RMM_CHANNEL}" \
  --channel "${RAPIDS_CONDA_BLD_OUTPUT_DIR}" \
  conda/recipes/cugraph-service

rapids-mamba-retry mambabuild \
  --no-test \
  --channel "${CPP_CHANNEL}" \
  --channel "${RAPIDS_CONDA_BLD_OUTPUT_DIR}" \
  --channel "${LIBRMM_CHANNEL}" \
  --channel "${RMM_CHANNEL}" \
  --channel pyg \
  --channel pytorch \
  --channel pytorch-nightly \
  conda/recipes/cugraph-pyg

rapids-mamba-retry mambabuild \
  --no-test \
  --channel "${CPP_CHANNEL}" \
  --channel "${RAPIDS_CONDA_BLD_OUTPUT_DIR}" \
  --channel "${LIBRMM_CHANNEL}" \
  --channel "${RMM_CHANNEL}" \
  --channel dglteam \
  --channel pytorch \
  --channel pytorch-nightly \
  conda/recipes/cugraph-dgl

rapids-upload-conda-to-s3 python
