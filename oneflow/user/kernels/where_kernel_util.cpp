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
#include "oneflow/user/kernels/where_kernel_util.h"
#include "oneflow/core/rocm/elementwise_rocm.h"

namespace oneflow {

template<typename T, typename CondT>
struct WhereKernelUtil<DeviceType::kCPU, T, CondT> {
  static void Where(DeviceCtx* ctx, const int64_t elem_cnt, const CondT* cond, const T* lhs,
                    const T* rhs, T* out) {
    FOR_RANGE(int64_t, i, 0, elem_cnt) { out[i] = static_cast<bool>(cond[i]) ? lhs[i] : rhs[i]; }
  }
};

OF_PP_SEQ_PRODUCT_FOR_EACH_TUPLE(INSTANTIATE_WHERE_FUNCTOR, (DeviceType::kCPU),
                                 ARITHMETIC_DATA_TYPE_SEQ, INT_DATA_TYPE_SEQ)

#if defined(WITH_ROCM)

namespace {

template<typename T, typename CondT>
struct WhereFunctor {
  OF_DEVICE_FUNC T operator()(CondT cond, T lhs, T rhs) const {
    return static_cast<bool>(cond) ? lhs : rhs;
  }
};

}  // namespace

template<typename T, typename CondT>
struct WhereKernelUtil<DeviceType::kGPU, T, CondT> {
  static void Where(DeviceCtx* ctx, const int64_t elem_cnt, const CondT* cond, const T* lhs,
                    const T* rhs, T* out) {
    rocm::elementwise::Ternary(WhereFunctor<T, CondT>(), elem_cnt, out, cond, lhs, rhs,
                               ctx->rocm_stream());
  }
};

OF_PP_SEQ_PRODUCT_FOR_EACH_TUPLE(INSTANTIATE_WHERE_FUNCTOR, (DeviceType::kGPU),
                                 ARITHMETIC_DATA_TYPE_SEQ FLOAT16_DATA_TYPE_SEQ, INT_DATA_TYPE_SEQ)

#endif

}  // namespace oneflow
