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

#pragma once

#include <cuml/tree/algo_helper.h>
#include <cuml/tree/flatnode.h>
#include <thrust/binary_search.h>
#include <common/grid_sync.cuh>
#include <cstdio>
#include <cub/cub.cuh>
#include <raft/cuda_utils.cuh>
#include "input.cuh"
#include "metrics.cuh"
#include "split.cuh"

namespace ML {
namespace DT {

// The range of instances belonging to a particular node
// This structure refers to a range in the device array input.rowids
struct InstanceRange {
  std::size_t begin;
  std::size_t count;
};

struct NodeWorkItem {
  size_t idx;  // Index of the work item in the tree
  int depth;
  InstanceRange instances;
};

/**
 * This struct has information about workload of a single threadblock of
 * computeSplit kernels of classification and regression
 */
template <typename IdxT>
struct WorkloadInfo {
  IdxT nodeid;        // Node in the batch on which the threadblock needs to work
  IdxT large_nodeid;  // counts only large nodes (nodes that require more than one block along x-dim
                      // for histogram calculation)
  IdxT offset_blockid;  // Offset threadblock id among all the blocks that are
                        // working on this node
  IdxT num_blocks;      // Total number of blocks that are working on the node
};

template <typename SplitT, typename DataT, typename IdxT>
HDI bool SplitNotValid(const SplitT& split,
                       DataT min_impurity_decrease,
                       IdxT min_samples_leaf,
                       std::size_t num_rows)
{
  return split.best_metric_val <= min_impurity_decrease || split.nLeft < min_samples_leaf ||
         (IdxT(num_rows) - split.nLeft) < min_samples_leaf;
}

/**
 * @brief Partition the samples to left/right nodes based on the best split
 * @return the position of the left child node in the nodes list. However, this
 *         value is valid only for threadIdx.x == 0.
 * @note this should be called by only one block from all participating blocks
 *       'smem' should be atleast of size `sizeof(IdxT) * TPB * 2`
 */
template <typename DataT, typename LabelT, typename IdxT, int TPB>
DI void partitionSamples(const Input<DataT, LabelT, IdxT>& input,
                         const Split<DataT, IdxT>& split,
                         const NodeWorkItem& work_item,
                         char* smem)
{
  typedef cub::BlockScan<int, TPB> BlockScanT;
  __shared__ typename BlockScanT::TempStorage temp1, temp2;
  volatile auto* rowids = reinterpret_cast<volatile IdxT*>(input.rowids);
  // for compaction
  size_t smemSize  = sizeof(IdxT) * TPB;
  auto* lcomp      = reinterpret_cast<IdxT*>(smem);
  auto* rcomp      = reinterpret_cast<IdxT*>(smem + smemSize);
  auto range_start = work_item.instances.begin;
  auto range_len   = work_item.instances.count;
  auto* col        = input.data + split.colid * input.M;
  auto loffset = range_start, part = loffset + split.nLeft, roffset = part;
  auto end  = range_start + range_len;
  int lflag = 0, rflag = 0, llen = 0, rlen = 0, minlen = 0;
  auto tid = threadIdx.x;
  while (loffset < part && roffset < end) {
    // find the samples in the left that belong to right and vice-versa
    auto loff = loffset + tid, roff = roffset + tid;
    if (llen == minlen) lflag = loff < part ? col[rowids[loff]] > split.quesval : 0;
    if (rlen == minlen) rflag = roff < end ? col[rowids[roff]] <= split.quesval : 0;
    // scan to compute the locations for each 'misfit' in the two partitions
    int lidx, ridx;
    BlockScanT(temp1).ExclusiveSum(lflag, lidx, llen);
    BlockScanT(temp2).ExclusiveSum(rflag, ridx, rlen);
    __syncthreads();
    minlen = llen < rlen ? llen : rlen;
    // compaction to figure out the right locations to swap
    if (lflag) lcomp[lidx] = loff;
    if (rflag) rcomp[ridx] = roff;
    __syncthreads();
    // reset the appropriate flags for the longer of the two
    if (lidx < minlen) lflag = 0;
    if (ridx < minlen) rflag = 0;
    if (llen == minlen) loffset += TPB;
    if (rlen == minlen) roffset += TPB;
    // swap the 'misfit's
    if (tid < minlen) {
      auto a             = rowids[lcomp[tid]];
      auto b             = rowids[rcomp[tid]];
      rowids[lcomp[tid]] = b;
      rowids[rcomp[tid]] = a;
    }
  }
}
template <typename DataT, typename LabelT, typename IdxT, typename ObjectiveT, int TPB>
__global__ void nodeSplitKernel(IdxT max_depth,
                                IdxT min_samples_leaf,
                                IdxT min_samples_split,
                                IdxT max_leaves,
                                DataT min_impurity_decrease,
                                Input<DataT, LabelT, IdxT> input,
                                NodeWorkItem* work_items,
                                const Split<DataT, IdxT>* splits)
{
  extern __shared__ char smem[];
  const auto work_item = work_items[blockIdx.x];
  const auto split     = splits[blockIdx.x];
  if (SplitNotValid(
        split, min_impurity_decrease, min_samples_leaf, IdxT(work_item.instances.count))) {
    return;
  }
  partitionSamples<DataT, LabelT, IdxT, TPB>(input, split, work_item, (char*)smem);
}

template <typename InputT, typename NodeT, typename ObjectiveT, typename DataT>
__global__ void leafKernel(ObjectiveT objective,
                           InputT input,
                           const NodeT* tree,
                           const InstanceRange* instance_ranges,
                           DataT* leaves)
{
  using BinT = typename ObjectiveT::BinT;
  extern __shared__ char shared_memory[];
  auto histogram = reinterpret_cast<BinT*>(shared_memory);
  auto node_id   = blockIdx.x;
  auto& node     = tree[node_id];
  auto range     = instance_ranges[node_id];
  if (!node.IsLeaf()) return;
  auto tid = threadIdx.x;
  for (int i = tid; i < input.numOutputs; i += blockDim.x) {
    histogram[i] = BinT();
  }
  __syncthreads();
  for (auto i = range.begin + tid; i < range.begin + range.count; i += blockDim.x) {
    auto label = input.labels[input.rowids[i]];
    BinT::IncrementHistogram(histogram, 1, 0, label);
  }
  __syncthreads();
  if (tid == 0) {
    ObjectiveT::SetLeafVector(histogram, input.numOutputs, leaves + input.numOutputs * node_id);
  }
}

/* Returns 'input' rounded up to a correctly-aligned pointer of type OutT* */
template <typename OutT, typename InT>
__device__ OutT* alignPointer(InT input)
{
  return reinterpret_cast<OutT*>(raft::alignTo(reinterpret_cast<size_t>(input), sizeof(OutT)));
}

// 32-bit FNV1a hash
// Reference: http://www.isthe.com/chongo/tech/comp/fnv/index.html
const uint32_t fnv1a32_prime = uint32_t(16777619);
const uint32_t fnv1a32_basis = uint32_t(2166136261);

HDI uint32_t fnv1a32(uint32_t hash, uint32_t txt)
{
  hash ^= (txt >> 0) & 0xFF;
  hash *= fnv1a32_prime;
  hash ^= (txt >> 8) & 0xFF;
  hash *= fnv1a32_prime;
  hash ^= (txt >> 16) & 0xFF;
  hash *= fnv1a32_prime;
  hash ^= (txt >> 24) & 0xFF;
  hash *= fnv1a32_prime;
  return hash;
}

/**
 * @brief For a given values of (treeid, nodeid, seed), this function generates
 *        a unique permutation of [0, N - 1] values and returns 'k'th entry in
 *        from the permutation.
 * @return The 'k'th value from the permutation
 * @note This function does not allocated any temporary buffer, all the
 *       necessary values are recomputed.
 */
template <typename IdxT>
DI IdxT select(IdxT k, IdxT treeid, uint32_t nodeid, uint64_t seed, IdxT N)
{
  __shared__ int blksum;
  uint32_t pivot_hash;
  int cnt = 0;

  if (threadIdx.x == 0) { blksum = 0; }
  // Compute hash for the 'k'th index and use it as pivote for sorting
  pivot_hash = fnv1a32_basis;
  pivot_hash = fnv1a32(pivot_hash, uint32_t(k));
  pivot_hash = fnv1a32(pivot_hash, uint32_t(treeid));
  pivot_hash = fnv1a32(pivot_hash, uint32_t(nodeid));
  pivot_hash = fnv1a32(pivot_hash, uint32_t(seed >> 32));
  pivot_hash = fnv1a32(pivot_hash, uint32_t(seed));

  // Compute hash for rest of the indices and count instances where i_hash is
  // less than pivot_hash
  uint32_t i_hash;
  for (int i = threadIdx.x; i < N; i += blockDim.x) {
    if (i == k) continue;  // Skip since k is the pivote index
    i_hash = fnv1a32_basis;
    i_hash = fnv1a32(i_hash, uint32_t(i));
    i_hash = fnv1a32(i_hash, uint32_t(treeid));
    i_hash = fnv1a32(i_hash, uint32_t(nodeid));
    i_hash = fnv1a32(i_hash, uint32_t(seed >> 32));
    i_hash = fnv1a32(i_hash, uint32_t(seed));

    if (i_hash < pivot_hash)
      cnt++;
    else if (i_hash == pivot_hash && i < k)
      cnt++;
  }
  __syncthreads();
  if (cnt > 0) atomicAdd(&blksum, cnt);
  __syncthreads();
  return blksum;
}

/**
 * @brief For every block, converts the smem pdf-histogram to
 *        cdf-histogram inplace using inclusive block-sum-scan and returns
 *        the total_sum
 * @return The total sum aggregated over the sumscan,
 *         as well as the modified cdf-histogram pointer
 */
template <typename BinT, typename IdxT, int TPB>
DI BinT pdf_to_cdf(BinT* shared_histogram, IdxT nbins)
{
  // Blockscan instance preparation
  typedef cub::BlockScan<BinT, TPB> BlockScan;
  __shared__ typename BlockScan::TempStorage temp_storage;

  // variable to accumulate aggregate of sumscans of previous iterations
  BinT total_aggregate = BinT();

  for (IdxT tix = threadIdx.x; tix < raft::ceildiv(nbins, TPB) * TPB; tix += blockDim.x) {
    BinT result;
    BinT block_aggregate;
    BinT element = tix < nbins ? shared_histogram[tix] : BinT();
    BlockScan(temp_storage).InclusiveSum(element, result, block_aggregate);
    __syncthreads();
    if (tix < nbins) { shared_histogram[tix] = result + total_aggregate; }
    total_aggregate += block_aggregate;
  }
  // return the total sum
  return total_aggregate;
}

template <typename DataT, typename IdxT>
HDI IdxT lower_bound(DataT* sbins, IdxT nbins, DataT d)
{
  IdxT start = 0;
  IdxT end   = nbins - 1;
  IdxT mid;
  while (start < end) {
    mid = (start + end) / 2;
    if (sbins[mid] < d) {
      start = mid + 1;
    } else {
      end = mid;
    }
  }
  return start;
}

template <typename DataT,
          typename LabelT,
          typename IdxT,
          int TPB,
          typename ObjectiveT,
          typename BinT>
__global__ void computeSplitKernel(BinT* hist,
                                   IdxT nbins,
                                   IdxT max_depth,
                                   IdxT min_samples_split,
                                   IdxT max_leaves,
                                   Input<DataT, LabelT, IdxT> input,
                                   const NodeWorkItem* work_items,
                                   IdxT colStart,
                                   int* done_count,
                                   int* mutex,
                                   volatile Split<DataT, IdxT>* splits,
                                   ObjectiveT objective,
                                   IdxT treeid,
                                   const WorkloadInfo<IdxT>* workload_info,
                                   uint64_t seed)
{
  extern __shared__ char smem[];
  // Read workload info for this block
  WorkloadInfo<IdxT> workload_info_cta = workload_info[blockIdx.x];
  IdxT nid                             = workload_info_cta.nodeid;
  IdxT large_nid                       = workload_info_cta.large_nodeid;
  const auto work_item                 = work_items[nid];
  auto range_start                     = work_item.instances.begin;
  auto range_len                       = work_item.instances.count;

  IdxT offset_blockid = workload_info_cta.offset_blockid;
  IdxT num_blocks     = workload_info_cta.num_blocks;

  auto end                  = range_start + range_len;
  auto shared_histogram_len = nbins * objective.NumClasses();
  auto* shared_histogram    = alignPointer<BinT>(smem);
  auto* sbins               = alignPointer<DataT>(shared_histogram + shared_histogram_len);
  auto* sDone               = alignPointer<int>(sbins + nbins);
  IdxT stride               = blockDim.x * num_blocks;
  IdxT tid                  = threadIdx.x + offset_blockid * blockDim.x;

  // obtaining the feature to test split on
  IdxT col;
  if (input.nSampledCols == input.N) {
    col = colStart + blockIdx.y;
  } else {
    IdxT colIndex = colStart + blockIdx.y;
    col           = select(colIndex, treeid, work_item.idx, seed, input.N);
  }

  // populating shared memory with initial values
  for (IdxT i = threadIdx.x; i < shared_histogram_len; i += blockDim.x)
    shared_histogram[i] = BinT();
  for (IdxT b = threadIdx.x; b < nbins; b += blockDim.x)
    sbins[b] = input.quantiles[col * nbins + b];

  // synchronizing above changes across block
  __syncthreads();

  // compute pdf shared histogram for all bins for all classes in shared mem
  auto coloffset = col * input.M;
  for (auto i = range_start + tid; i < end; i += stride) {
    // each thread works over a data point and strides to the next
    auto row   = input.rowids[i];
    auto d     = input.data[row + coloffset];
    auto label = input.labels[row];

    IdxT start = lower_bound(sbins, nbins, d);
    BinT::IncrementHistogram(shared_histogram, nbins, start, label);
  }

  // synchronizing above changes across block
  __syncthreads();
  if (num_blocks > 1) {
    // update the corresponding global location
    auto histOffset = ((large_nid * gridDim.y) + blockIdx.y) * shared_histogram_len;
    for (IdxT i = threadIdx.x; i < shared_histogram_len; i += blockDim.x) {
      BinT::AtomicAdd(hist + histOffset + i, shared_histogram[i]);
    }

    __threadfence();  // for commit guarantee
    __syncthreads();

    // last threadblock will go ahead and compute the best split
    bool last = MLCommon::signalDone(
      done_count + nid * gridDim.y + blockIdx.y, num_blocks, offset_blockid == 0, sDone);
    // if not the last threadblock, exit
    if (!last) return;

    // store the complete global histogram in shared memory of last block
    for (IdxT i = threadIdx.x; i < shared_histogram_len; i += blockDim.x)
      shared_histogram[i] = hist[histOffset + i];

    __syncthreads();
  }

  // PDF to CDF inplace in shared memory pointed by shist
  for (IdxT c = 0; c < objective.NumClasses(); ++c) {
    /** left to right scan operation for scanning
     *  lesser-than-or-equal-to-bin counts **/
    // offsets to pdf and cdf shist pointers
    auto offset_pdf = nbins * c;
    // converting pdf to cdf
    BinT total_sum = pdf_to_cdf<BinT, IdxT, TPB>(shared_histogram + offset_pdf, nbins);
  }

  // create a split instance to test current feature split
  __syncthreads();

  // calculate the best candidate bins (one for each block-thread) in current feature and
  // corresponding information gain for splitting
  Split<DataT, IdxT> sp = objective.Gain(shared_histogram, sbins, col, range_len, nbins);

  __syncthreads();

  // calculate best bins among candidate bins per feature using warp reduce
  // then atomically update across features to get best split per node
  // (in split[nid])
  sp.evalBestSplit(smem, splits + nid, mutex + nid);
}

}  // namespace DT
}  // namespace ML
