/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <gtest/gtest.h>
#include <raft/cudart_utils.h>
#include <raft/linalg/cusolver_wrappers.h>
#include <iostream>
#include <label/classlabels.cuh>
#include <raft/cuda_utils.cuh>
#include <raft/linalg/reduce.cuh>
#include <raft/random/rng.hpp>
#include <raft/spatial/knn/knn.hpp>
#include <selection/knn.cuh>
#include <vector>
#include "test_utils.h"

#include <thrust/device_ptr.h>
#include <thrust/extrema.h>

namespace MLCommon {
namespace Selection {

struct KNNRegressionInputs {
  int rows;
  int cols;
  int n_labels;
  float cluster_std;
  int k;
};

void generate_data(
  float* out_samples, float* out_labels, int n_rows, int n_cols, cudaStream_t stream)
{
  raft::random::Rng r(0ULL, raft::random::GenTaps);

  r.uniform(out_samples, n_rows * n_cols, 0.0f, 1.0f, stream);

  raft::linalg::unaryOp<float>(
    out_samples,
    out_samples,
    n_rows,
    [=] __device__(float input) { return 2 * input - 1; },
    stream);

  raft::linalg::reduce(
    out_labels,
    out_samples,
    n_cols,
    n_rows,
    0.0f,
    true,
    true,
    stream,
    false,
    [=] __device__(float in, int n) { return in * in; },
    raft::Sum<float>(),
    [=] __device__(float in) { return sqrt(in); });

  thrust::device_ptr<float> d_ptr = thrust::device_pointer_cast(out_labels);
  float max = *(thrust::max_element(thrust::cuda::par.on(stream), d_ptr, d_ptr + n_rows));

  raft::linalg::unaryOp<float>(
    out_labels, out_labels, n_rows, [=] __device__(float input) { return input / max; }, stream);
}

class KNNRegressionTest : public ::testing::TestWithParam<KNNRegressionInputs> {
 protected:
  void basicTest()
  {
    raft::handle_t handle;
    cudaStream_t stream = handle.get_stream();

    cublasHandle_t cublas_handle;
    CUBLAS_CHECK(cublasCreate(&cublas_handle));

    cusolverDnHandle_t cusolverDn_handle;
    CUSOLVER_CHECK(cusolverDnCreate(&cusolverDn_handle));

    params = ::testing::TestWithParam<KNNRegressionInputs>::GetParam();

    raft::allocate(train_samples, params.rows * params.cols, stream);
    raft::allocate(train_labels, params.rows, stream);

    raft::allocate(pred_labels, params.rows, stream);

    raft::allocate(knn_indices, params.rows * params.k, stream);
    raft::allocate(knn_dists, params.rows * params.k, stream);

    generate_data(train_samples, train_labels, params.rows, params.cols, stream);

    std::vector<float*> ptrs(1);
    std::vector<int> sizes(1);
    ptrs[0]  = train_samples;
    sizes[0] = params.rows;

    raft::spatial::knn::brute_force_knn(handle,
                                        ptrs,
                                        sizes,
                                        params.cols,
                                        train_samples,
                                        params.rows,
                                        knn_indices,
                                        knn_dists,
                                        params.k);

    std::vector<float*> y;
    y.push_back(train_labels);

    knn_regress(pred_labels, knn_indices, y, params.rows, params.rows, params.k, stream);

    CUDA_CHECK(cudaStreamSynchronize(stream));
  }

  void SetUp() override { basicTest(); }

  void TearDown() override
  {
    CUDA_CHECK(cudaFree(train_samples));
    CUDA_CHECK(cudaFree(train_labels));

    CUDA_CHECK(cudaFree(pred_labels));

    CUDA_CHECK(cudaFree(knn_indices));
    CUDA_CHECK(cudaFree(knn_dists));
  }

 protected:
  KNNRegressionInputs params;

  float* train_samples;
  float* train_labels;

  float* pred_labels;

  int64_t* knn_indices;
  float* knn_dists;
};

typedef KNNRegressionTest KNNRegressionTestF;
TEST_P(KNNRegressionTestF, Fit)
{
  ASSERT_TRUE(devArrMatch(train_labels, pred_labels, params.rows, raft::CompareApprox<float>(0.3)));
}

const std::vector<KNNRegressionInputs> inputsf = {{100, 10, 2, 0.01f, 2},
                                                  {1000, 10, 5, 0.01f, 2},
                                                  {10000, 10, 5, 0.01f, 2},
                                                  {100, 10, 2, 0.01f, 10},
                                                  {1000, 10, 5, 0.01f, 10},
                                                  {10000, 10, 5, 0.01f, 10},
                                                  {100, 10, 2, 0.01f, 15},
                                                  {1000, 10, 5, 0.01f, 15},
                                                  {10000, 10, 5, 0.01f, 15}};

INSTANTIATE_TEST_CASE_P(KNNRegressionTest, KNNRegressionTestF, ::testing::ValuesIn(inputsf));

};  // end namespace Selection
};  // namespace MLCommon
