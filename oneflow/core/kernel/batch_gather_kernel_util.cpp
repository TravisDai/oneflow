/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include "oneflow/core/kernel/batch_gather_kernel_util.h"
#include "oneflow/core/rocm/atomic_rocm.h"
#include <assert.h>
namespace oneflow {

namespace {

Shape GetFlatShape(const ShapeView& shape, const int64_t axis) {
  CHECK_GT(shape.NumAxes(), 0);
  CHECK_GE(axis, 0);
  CHECK_LT(axis, shape.NumAxes());
  return Shape({shape.Count(0, axis), shape.At(axis), shape.Count(axis + 1)});
}

template<DeviceType device_type, typename T, typename K>
void BatchGatherForward(DeviceCtx* ctx, const Blob* in, const Blob* indices, Blob* out) {
  const int64_t axis = indices->shape().NumAxes() - 1;
  const Shape flat_out_shape = GetFlatShape(out->shape(), axis);
  BatchGatherKernelUtilImpl<device_type, T, K>::Forward(ctx, in->dptr<T>(), indices->dptr<K>(),
                                                        flat_out_shape, in->shape().At(axis),
                                                        out->mut_dptr<T>());
}

template<DeviceType device_type, typename T, typename K>
void BatchGatherBackward(DeviceCtx* ctx, const Blob* out_diff, const Blob* indices, Blob* in_diff) {
  Memset<device_type>(ctx, in_diff->mut_dptr<T>(), 0, in_diff->ByteSizeOfBlobBody());
  const int64_t axis = indices->shape().NumAxes() - 1;
  const Shape flat_out_diff_shape = GetFlatShape(out_diff->shape(), axis);
  BatchGatherKernelUtilImpl<device_type, T, K>::Backward(
      ctx, out_diff->dptr<T>(), indices->dptr<K>(), flat_out_diff_shape, in_diff->shape().At(axis),
      in_diff->mut_dptr<T>());
}

template<DeviceType device_type, typename T>
struct BatchGatherSwitchUtil final {
#define MAKE_BATCH_GATHER_SWITCH_ENTRY(func_name, K) func_name<device_type, T, K>
#define DEFINE_BATCH_GATHER_STATIC_SWITCH_FUNC(func_name)                    \
  DEFINE_STATIC_SWITCH_FUNC(void, func_name, MAKE_BATCH_GATHER_SWITCH_ENTRY, \
                            MAKE_DATA_TYPE_CTRV_SEQ(INT_DATA_TYPE_SEQ));
  DEFINE_BATCH_GATHER_STATIC_SWITCH_FUNC(BatchGatherForward);
  DEFINE_BATCH_GATHER_STATIC_SWITCH_FUNC(BatchGatherBackward);
#undef DEFINE_BATCH_GATHER_STATIC_SWITCH_FUNC
#undef MAKE_BATCH_GATHER_SWITCH_ENTRY
};

}  // namespace

template<DeviceType device_type, typename T>
void BatchGatherKernelUtil<device_type, T>::Forward(DeviceCtx* ctx, const Blob* in,
                                                    const Blob* indices, Blob* out) {
  BatchGatherSwitchUtil<device_type, T>::SwitchBatchGatherForward(SwitchCase(indices->data_type()),
                                                                  ctx, in, indices, out);
}

template<DeviceType device_type, typename T>
void BatchGatherKernelUtil<device_type, T>::Backward(DeviceCtx* ctx, const Blob* out_diff,
                                                     const Blob* indices, Blob* in_diff) {
  BatchGatherSwitchUtil<device_type, T>::SwitchBatchGatherBackward(SwitchCase(indices->data_type()),
                                                                   ctx, out_diff, indices, in_diff);
}

template<typename T, typename K>
struct BatchGatherKernelUtilImpl<DeviceType::kCPU, T, K> final {
  static void Forward(DeviceCtx* ctx, const T* in, const K* indices, const Shape& flat_out_shape,
                      int64_t gather_dim_size, T* out);
  static void Backward(DeviceCtx* ctx, const T* out_diff, const K* indices,
                       const Shape& flat_out_diff_shape, int64_t gather_dim_size, T* in_diff);
};

template<typename T, typename K>
void BatchGatherKernelUtilImpl<DeviceType::kCPU, T, K>::Forward(DeviceCtx* ctx, const T* in,
                                                                const K* indices,
                                                                const Shape& flat_out_shape,
                                                                const int64_t gather_dim_size,
                                                                T* out) {
  const int64_t batch_num = flat_out_shape.At(0);
  const int64_t indices_num = flat_out_shape.At(1);
  const int64_t instance_size = flat_out_shape.At(2);
  FOR_RANGE(int64_t, batch_idx, 0, batch_num) {
    FOR_RANGE(int64_t, i, 0, indices_num) {
      const K idx = indices[batch_idx * indices_num + i];
      CHECK(idx >= 0 && idx < gather_dim_size);
      const T* from = in + batch_idx * gather_dim_size * instance_size + idx * instance_size;
      T* to = out + batch_idx * indices_num * instance_size + i * instance_size;
      std::copy(from, from + instance_size, to);
    }
  }
}

template<typename T, typename K>
void BatchGatherKernelUtilImpl<DeviceType::kCPU, T, K>::Backward(DeviceCtx* ctx, const T* out_diff,
                                                                 const K* indices,
                                                                 const Shape& flat_out_diff_shape,
                                                                 const int64_t gather_dim_size,
                                                                 T* in_diff) {
  const int64_t batch_num = flat_out_diff_shape.At(0);
  const int64_t indices_num = flat_out_diff_shape.At(1);
  const int64_t instance_size = flat_out_diff_shape.At(2);
  FOR_RANGE(int64_t, batch_idx, 0, batch_num) {
    FOR_RANGE(int64_t, i, 0, indices_num) {
      const int64_t idx = indices[batch_idx * indices_num + i];
      CHECK(idx >= 0 && idx < gather_dim_size);
      const T* from = out_diff + batch_idx * indices_num * instance_size + i * instance_size;
      T* to = in_diff + batch_idx * gather_dim_size * instance_size + idx * instance_size;
      std::transform(from, from + instance_size, to, to, std::plus<T>());
    }
  }
}

#define INSTANTIATE_BATCH_GATHER_KERNEL_UTIL_IMPL_CPU(in_type_pair, index_type_pair)          \
  template struct BatchGatherKernelUtilImpl<DeviceType::kCPU, OF_PP_PAIR_FIRST(in_type_pair), \
                                            OF_PP_PAIR_FIRST(index_type_pair)>;
OF_PP_SEQ_PRODUCT_FOR_EACH_TUPLE(INSTANTIATE_BATCH_GATHER_KERNEL_UTIL_IMPL_CPU,
                                 FLOATING_DATA_TYPE_SEQ, INT_DATA_TYPE_SEQ);
#undef INSTANTIATE_BATCH_GATHER_KERNEL_UTIL_IMPL_CPU

#define INSTANTIATE_BATCH_GATHER_KERNEL_UTIL(device_type, in_type_pair) \
  template struct BatchGatherKernelUtil<device_type, OF_PP_PAIR_FIRST(in_type_pair)>;
OF_PP_SEQ_PRODUCT_FOR_EACH_TUPLE(INSTANTIATE_BATCH_GATHER_KERNEL_UTIL, DEVICE_TYPE_SEQ,
                                 FLOATING_DATA_TYPE_SEQ);
#undef INSTANTIATE_BATCH_GATHER_KERNEL_UTIL


#if defined(WITH_ROCM)
namespace {

template<typename K>
__device__ int64_t GetInOffset(const int64_t out_offset, const K* indices,
                               const int64_t indices_num, const int64_t instance_size,
                               const int64_t gather_dim_size) {
  const int64_t batch_idx = out_offset / (indices_num * instance_size);
  const int64_t indices_idx = out_offset % (indices_num * instance_size) / instance_size;
  const int64_t inner_idx = out_offset % instance_size;
  const int64_t idx = indices[batch_idx * indices_num + indices_idx];
  assert(idx >= 0 && idx < gather_dim_size);
  return batch_idx * gather_dim_size * instance_size + idx * instance_size + inner_idx;
}

template<typename T, typename K>
__global__ void BatchGatherForwardGpu(const int64_t elem_cnt, const T* in, const K* indices,
                                      const int64_t indices_num, const int64_t instance_size,
                                      const int64_t gather_dim_size, T* out) {
  ROCM_1D_KERNEL_LOOP(i, elem_cnt) {
    out[i] = in[GetInOffset<K>(i, indices, indices_num, instance_size, gather_dim_size)];
  }
}

template<typename T, typename K>
__global__ void BatchGatherBackwardGpu(const int64_t elem_cnt, const T* out_diff, const K* indices,
                                       const int64_t indices_num, const int64_t instance_size,
                                       const int64_t gather_dim_size, T* in_diff) {
  ROCM_1D_KERNEL_LOOP(i, elem_cnt) {
    rocm::atomic::Add(
        in_diff + GetInOffset<K>(i, indices, indices_num, instance_size, gather_dim_size),
        out_diff[i]);
  }
}

}  // namespace

template<typename T, typename K>
struct BatchGatherKernelUtilImpl<DeviceType::kGPU, T, K> final {
  static void Forward(DeviceCtx* ctx, const T* in, const K* indices, const Shape& flat_out_shape,
                      const int64_t gather_dim_size, T* out);
  static void Backward(DeviceCtx* ctx, const T* out_diff, const K* indices,
                       const Shape& flat_out_diff_shape, const int64_t gather_dim_size, T* in_diff);
};

template<typename T, typename K>
void BatchGatherKernelUtilImpl<DeviceType::kGPU, T, K>::Forward(DeviceCtx* ctx, const T* in,
                                                                const K* indices,
                                                                const Shape& flat_out_shape,
                                                                const int64_t gather_dim_size,
                                                                T* out) {
  const int64_t batch_num = flat_out_shape.At(0);
  const int64_t indices_num = flat_out_shape.At(1);
  const int64_t instance_size = flat_out_shape.At(2);
  const int64_t elem_cnt = batch_num * indices_num * instance_size;
  BatchGatherForwardGpu<T, K>
      <<<BlocksNum4ThreadsNum(elem_cnt), kRocmThreadsNumPerBlock, 0, ctx->rocm_stream()>>>(
          elem_cnt, in, indices, indices_num, instance_size, gather_dim_size, out);
}

template<typename T, typename K>
void BatchGatherKernelUtilImpl<DeviceType::kGPU, T, K>::Backward(DeviceCtx* ctx, const T* out_diff,
                                                                 const K* indices,
                                                                 const Shape& flat_out_diff_shape,
                                                                 const int64_t gather_dim_size,
                                                                 T* in_diff) {
  const int64_t batch_num = flat_out_diff_shape.At(0);
  const int64_t indices_num = flat_out_diff_shape.At(1);
  const int64_t instance_size = flat_out_diff_shape.At(2);
  const int64_t elem_cnt = batch_num * indices_num * instance_size;
  BatchGatherBackwardGpu<T, K>
      <<<BlocksNum4ThreadsNum(elem_cnt), kRocmThreadsNumPerBlock, 0, ctx->rocm_stream()>>>(
          elem_cnt, out_diff, indices, indices_num, instance_size, gather_dim_size, in_diff);
}

#define INSTANTIATE_BATCH_GATHER_KERNEL_UTIL_IMPL_GPU(in_type_pair, index_type_pair)          \
  template struct BatchGatherKernelUtilImpl<DeviceType::kGPU, OF_PP_PAIR_FIRST(in_type_pair), \
                                            OF_PP_PAIR_FIRST(index_type_pair)>;
OF_PP_SEQ_PRODUCT_FOR_EACH_TUPLE(INSTANTIATE_BATCH_GATHER_KERNEL_UTIL_IMPL_GPU,
                                 FLOATING_DATA_TYPE_SEQ, INT_DATA_TYPE_SEQ);
#undef INSTANTIATE_BATCH_GATHER_KERNEL_UTIL_IMPL_GPU

#endif

}  // namespace oneflow
