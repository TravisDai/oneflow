#include "oneflow/core/device/cudnn_util.h"
#include "oneflow/core/framework/framework.h"
#include "oneflow/core/ndarray/ndarray_util.h"
#include "oneflow/core/ep/cuda/cuda_stream.h"
#include "oneflow/core/cuda/layer_norm.cuh"


namespace oneflow{

namespace {

// TODO add AFFINE STORE

template<typename SRC, typename DST, bool affine>
struct AffineStore{
    AffineStore(DST* y, int64_t row_size, int64_t channel_size, int64_t spatial_size, const DST* gamma, const DST* beta)
    : y(y), row_size(row_size), channel_size(channel_size), spatial_size(spatial_size), gamma(gamma), beta(beta) {}

    template<int PackSize>
    __device__ void store(const SRC* src, int64_t row, int64_t col){
        cuda::layer_norm::Pack<DST, PackSize> y_pack;
        const int64_t offset = row * row_size + col; 
        const int64_t packed_offset = offset / PackSize;
        const int64_t gamma_beta_offset = (offset / spatial_size) % channel_size;
        DST gamma_val = gamma[gamma_beta_offset]; 
        DST beta_val = beta[gamma_beta_offset]; 

    #pragma unroll
        for (int i = 0; i < PackSize; ++i) {
            DST normalized_i = static_cast<DST>(src[i]);
            if(affine){
                y_pack.elem[i] = normalized_i * gamma_val + beta_val;
            } else {
                // Direct Store. 
                y_pack.elem[i] = normalized_i; 
            }
        }
        *(reinterpret_cast<cuda::layer_norm::PackType<DST, PackSize>*>(y) + packed_offset) = y_pack.storage;
    }

    DST* y;
    int64_t row_size;
    int64_t channel_size;
    int64_t spatial_size;
    const DST* gamma;
    const DST* beta;
}; 

template<typename SRC, typename DST, bool affine>
struct ScaleLoad {
  ScaleLoad(const SRC* src, const SRC* gamma, int64_t row_size, int64_t channel_size, int64_t spatial_size)
      : src(src), gamma(gamma), row_size(row_size), channel_size(channel_size), spatial_size(spatial_size) {}
  template<int PackSize>
  __device__ void load(DST* dst, int64_t row, int64_t col) const {
    cuda::layer_norm::Pack<SRC, PackSize> src_pack;
    cuda::layer_norm::Pack<SRC, PackSize> gamma_pack;

    const int64_t offset = row * row_size + col; 
    const int64_t packed_offset = offset / PackSize;
    const int64_t gamma_offset = (offset / spatial_size) % channel_size;

    src_pack.storage = *(reinterpret_cast<const cuda::layer_norm::PackType<SRC, PackSize>*>(src) + packed_offset);
    SRC gamma_val = static_cast<SRC>(1.0); 
    if (affine) {
      gamma_val = gamma[gamma_offset]; 
    } 
#pragma unroll
    for (int i = 0; i < PackSize; ++i) {
      dst[i] = static_cast<DST>(src_pack.elem[i] * gamma_val);
    }
  }
  const SRC* src;
  const SRC* gamma;
  int64_t row_size;
  int64_t channel_size;
  int64_t spatial_size;
};

template<typename LOAD, typename STORE, typename ComputeType>
struct DispatchGroupNormWarpImplPackSize {
  cudaError_t operator()(cudaStream_t stream, LOAD load, STORE store, const int64_t rows,
                         const int64_t cols, const int64_t spatial_size, const double epsilon, ComputeType* mean,
                         ComputeType* inv_variance) {
    if (spatial_size % 4 == 0) {
      return cuda::layer_norm::DispatchLayerNormWarpImplCols<LOAD, STORE, ComputeType, 4>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    } else if (spatial_size % 2 == 0) {
      return cuda::layer_norm::DispatchLayerNormWarpImplCols<LOAD, STORE, ComputeType, 2>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    } else {
      return cuda::layer_norm::DispatchLayerNormWarpImplCols<LOAD, STORE, ComputeType, 1>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    }
  }
};

template<typename LOAD, typename STORE, typename ComputeType>
inline cudaError_t DispatchGroupNormWarpImpl(cudaStream_t stream, 
                                             LOAD load, STORE store,
                                             const int64_t rows, const int64_t cols,
                                             const int64_t spatial_size, 
                                             const double epsilon, ComputeType* mean,
                                             ComputeType* inv_variance) {
  return DispatchGroupNormWarpImplPackSize<LOAD, STORE, ComputeType>()(
      stream, load, store, rows, cols, spatial_size, epsilon, mean, inv_variance);
}


template<typename LOAD, typename STORE, typename ComputeType>
struct TryDispatchGroupNormBlockSMemImplPackSize {
  cudaError_t operator()(cudaStream_t stream, LOAD load, STORE store, const int64_t rows,
                         const int64_t cols, const int64_t spatial_size, const double epsilon, ComputeType* mean,
                         ComputeType* inv_variance, bool* success) {
    if (spatial_size % 4 == 0) {
      return cuda::layer_norm::TryDispatchLayerNormBlockSMemImplBlockSize<LOAD, STORE, ComputeType, 4>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance, success);
    } else if (spatial_size % 2 == 0) {
      return cuda::layer_norm::TryDispatchLayerNormBlockSMemImplBlockSize<LOAD, STORE, ComputeType, 2>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance, success);
    } else {
      return cuda::layer_norm::TryDispatchLayerNormBlockSMemImplBlockSize<LOAD, STORE, ComputeType, 1>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance, success);
    }
  }
};

template<typename LOAD, typename STORE, typename ComputeType>
inline cudaError_t TryDispatchGroupNormBlockSMemImpl(cudaStream_t stream, LOAD load, STORE store,
                                                     const int64_t rows, const int64_t cols, 
                                                     const int64_t spatial_size, 
                                                     const double epsilon, ComputeType* mean,
                                                     ComputeType* inv_variance, bool* success) {
  return TryDispatchGroupNormBlockSMemImplPackSize<LOAD, STORE, ComputeType>()(
      stream, load, store, rows, cols, spatial_size, epsilon, mean, inv_variance, success);
}

template<typename LOAD, typename STORE, typename ComputeType>
struct DispatchGroupNormBlockUncachedImplPackSize {
  cudaError_t operator()(cudaStream_t stream, LOAD load, STORE store, const int64_t rows,
                         const int64_t cols, const int64_t spatial_size, const double epsilon, ComputeType* mean,
                         ComputeType* inv_variance) {
    if (spatial_size % 4 == 0) {
      return cuda::layer_norm::LaunchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType, 4>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    } else if (spatial_size % 2 == 0) {
      return cuda::layer_norm::LaunchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType, 2>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    } else {
      return cuda::layer_norm::LaunchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType, 1>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    }
  }
};

template<typename LOAD, typename STORE, typename ComputeType>
inline cudaError_t DispatchGroupNormBlockUncachedImpl(cudaStream_t stream, LOAD load, STORE store,
                                                      const int64_t rows, const int64_t cols,
                                                      const int64_t spatial_size, 
                                                      const double epsilon, ComputeType* mean,
                                                      ComputeType* inv_variance) {
  return DispatchGroupNormBlockUncachedImplPackSize<LOAD, STORE, ComputeType>()(
      stream, load, store, rows, cols, spatial_size, epsilon, mean, inv_variance);
}


template<typename LOAD, typename STORE, typename ComputeType>
inline typename std::enable_if<!std::is_same<ComputeType, double>::value, cudaError_t>::type
DispatchGroupNorm(cudaStream_t stream, LOAD load, STORE store, const int64_t rows,
                  const int64_t cols, const int64_t spatial_size, const double epsilon, ComputeType* mean,
                  ComputeType* inv_variance) {
  if (cols <= 1024) {
    return DispatchGroupNormWarpImpl<LOAD, STORE, ComputeType>(stream, load, store, rows, cols, spatial_size, 
                                                               epsilon, mean, inv_variance);
  } else {
    // TODO
    bool dispatch_smem_impl_success;
    {
      cudaError_t err = TryDispatchGroupNormBlockSMemImpl<LOAD, STORE, ComputeType>(
          stream, load, store, rows, cols, spatial_size, epsilon, mean, inv_variance,
          &dispatch_smem_impl_success);
      if (err != cudaSuccess) { return err; }
    }
    if (!dispatch_smem_impl_success) {
      return DispatchGroupNormBlockUncachedImpl<LOAD, STORE, ComputeType>(
          stream, load, store, rows, cols, spatial_size, epsilon, mean, inv_variance);
    }
    return cudaSuccess;
  }
}

template<typename T, bool affine>
void GroupNormForwardGpu(ep::Stream* stream, const int64_t num_instances, 
                        const int64_t norm_size, 
                        const int64_t channel_size, 
                        const int64_t spatial_size, 
                        const double epsilon, const T* x_ptr, const T* gamma_ptr,
                        const T* beta_ptr, T* y_ptr, user_op::Tensor* mean,
                        user_op::Tensor* inv_variance) {
    using ComputeType = typename cuda::layer_norm::DefaultComputeType<T>::type;
    cuda::layer_norm::DirectLoad<T, ComputeType> load(x_ptr, norm_size);
    AffineStore<ComputeType, T, affine> store(y_ptr, norm_size, channel_size, spatial_size, gamma_ptr, beta_ptr);

    DispatchGroupNorm<decltype(load), decltype(store), ComputeType>(
        stream->As<ep::CudaStream>()->cuda_stream(), load, store, num_instances, norm_size, spatial_size, 
        epsilon, mean->mut_dptr<ComputeType>(), inv_variance->mut_dptr<ComputeType>());
}

template<typename T>
void DispatchGroupNormForwardGpu(ep::Stream* stream, const int64_t num_instances,
                                 const int64_t norm_size, 
                                 const int64_t channel_size, 
                                 const int64_t spatial_size, 
                                 const double epsilon, const T* x_ptr,
                                 const T* gamma_ptr, const T* beta_ptr, T* y_ptr,
                                 user_op::Tensor* mean, user_op::Tensor* inv_variance) {
  if (gamma_ptr != nullptr && beta_ptr != nullptr) {
    GroupNormForwardGpu<T, true>(stream, num_instances, norm_size, channel_size, spatial_size, epsilon, x_ptr, gamma_ptr,
                                       beta_ptr, y_ptr, mean, inv_variance);
  } else {
    GroupNormForwardGpu<T, false>(stream, num_instances, norm_size, channel_size, spatial_size, epsilon, x_ptr,
                                         gamma_ptr, beta_ptr, y_ptr, mean, inv_variance);
  }
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
struct DispatchGroupNormGradWarpImplPackSize {
  cudaError_t operator()(cudaStream_t stream, LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy,
                         STORE store, const ComputeType* mean, const ComputeType* inv_variance,
                         const int64_t rows, const int64_t cols, const int64_t spatial_size) {
    if (spatial_size % 2 == 0) {
      return cuda::layer_norm::DispatchLayerNormGradWarpImplCols<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, 2>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
    } else {
      return cuda::layer_norm::DispatchLayerNormGradWarpImplCols<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, 1>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
    }
  }
};

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
inline cudaError_t DispatchGroupNormGradWarpImpl(cudaStream_t stream, LOAD_X load_x,
                                                 LOAD_SCALED_DY load_scaled_dy, STORE store,
                                                 const ComputeType* mean,
                                                 const ComputeType* inv_variance,
                                                 const int64_t rows, const int64_t cols, 
                                                 const int64_t spatial_size) {
  return DispatchGroupNormGradWarpImplPackSize<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType>()(
      stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols, spatial_size);
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
struct TryDispatchGroupNormGradBlockSMemImplPackSize {
  cudaError_t operator()(cudaStream_t stream, LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy,
                         STORE store, const ComputeType* mean, const ComputeType* inv_variance,
                         const int64_t rows, const int64_t cols, const int64_t spatial_size, 
                         bool* success) {
    if (spatial_size % 2 == 0) {
      return cuda::layer_norm::TryDispatchLayerNormGradBlockSMemImplBlockSize<LOAD_X, LOAD_SCALED_DY, STORE,
                                                            ComputeType, 2>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols, success);
    } else {
      return cuda::layer_norm::TryDispatchLayerNormGradBlockSMemImplBlockSize<LOAD_X, LOAD_SCALED_DY, STORE,
                                                            ComputeType, 1>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols, success);
    }
  }
};


template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
inline cudaError_t TryDispatchGroupNormGradBlockSMemImpl(cudaStream_t stream, LOAD_X load_x,
                                                         LOAD_SCALED_DY load_scaled_dy, STORE store,
                                                         const ComputeType* mean,
                                                         const ComputeType* inv_variance,
                                                         const int64_t rows, const int64_t cols,
                                                         const int64_t spatial_size, 
                                                         bool* success) {
  return TryDispatchGroupNormGradBlockSMemImplPackSize<LOAD_X, LOAD_SCALED_DY, STORE,
                                                       ComputeType>()(
      stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols, spatial_size, success);
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
struct DispatchGroupNormGradBlockUncachedImplPackSize {
  cudaError_t operator()(cudaStream_t stream, LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy,
                         STORE store, const ComputeType* mean, const ComputeType* inv_variance,
                         const int64_t rows, const int64_t cols, const int64_t spatial_size) {
    if (spatial_size % 2 == 0 && spatial_size > cuda::layer_norm::kWarpSize) {
      return cuda::layer_norm::LaunchLayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, 2>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
    } else {
      return cuda::layer_norm::LaunchLayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, 1>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
    }
  }
};

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
inline cudaError_t DispatchGroupNormGradBlockUncachedImpl(cudaStream_t stream, LOAD_X load_x,
                                                          LOAD_SCALED_DY load_scaled_dy,
                                                          STORE store, const ComputeType* mean,
                                                          const ComputeType* inv_variance,
                                                          const int64_t rows, const int64_t cols, 
                                                          const int64_t spatial_size) {
  return DispatchGroupNormGradBlockUncachedImplPackSize<LOAD_X, LOAD_SCALED_DY, STORE,
                                                        ComputeType>()(
      stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols, spatial_size);
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
inline typename std::enable_if<!std::is_same<ComputeType, double>::value, cudaError_t>::type
DispatchGroupNormGrad(cudaStream_t stream, LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy,
                      STORE store, const ComputeType* mean, const ComputeType* inv_variance,
                      const int64_t rows, const int64_t cols, const int64_t spatial_size) {
  if (cols <= 1024) {
    return DispatchGroupNormGradWarpImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType>(
        stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols, spatial_size);
  } else {
    bool dispatch_smem_impl_success;
    {
      cudaError_t err =
          TryDispatchGroupNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType>(
              stream, load_x, load_scaled_dy, store, mean, inv_variance, 
              rows, cols, spatial_size, 
              &dispatch_smem_impl_success);
      if (err != cudaSuccess) { return err; }
    }
    if (!dispatch_smem_impl_success) {
      return DispatchGroupNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols, spatial_size);
    }
    return cudaSuccess;
  }
}


template<typename T, bool affine>
void GroupNormBackwardGpu(ep::Stream* stream, const int64_t num_instances, 
                          const int64_t norm_size, const int64_t channel_size, const int64_t spatial_size, 
                          const T* dy_ptr, const T* x_ptr, const user_op::Tensor* mean,
                          const user_op::Tensor* inv_variance, const T* gamma_ptr,
                          T* dx_ptr) {
  using ComputeType = typename cuda::layer_norm::DefaultComputeType<T>::type;
  cuda::layer_norm::DirectLoad<T, ComputeType> load_x(x_ptr, norm_size);
  ScaleLoad<T, ComputeType, affine> load_scaled_dy(dy_ptr, gamma_ptr, norm_size, channel_size, spatial_size);
  cuda::layer_norm::DirectStore<ComputeType, T> store(dx_ptr, norm_size);
  OF_CUDA_CHECK((DispatchGroupNormGrad<decltype(load_x), decltype(load_scaled_dy),
                                       decltype(store), ComputeType>(
      stream->As<ep::CudaStream>()->cuda_stream(), load_x, load_scaled_dy, store,
      mean->dptr<ComputeType>(), inv_variance->dptr<ComputeType>(), num_instances, norm_size, spatial_size)));
}

template<typename T>
void LaunchGroupNormBackward(ep::Stream* stream, const int64_t num_instances,
                             const int64_t norm_size, const int64_t channel_size, 
                             const int64_t spatial_size, 
                             const T* dy_ptr, const T* x_ptr,
                             const user_op::Tensor* mean, const user_op::Tensor* inv_variance,
                             const T* gamma_ptr, T* dx_ptr) {
  if (gamma_ptr != nullptr) {
    GroupNormBackwardGpu<T, true>(stream, num_instances, norm_size, channel_size, 
                                  spatial_size, dy_ptr, x_ptr, mean,
                                  inv_variance, gamma_ptr, dx_ptr);
  } else {
    printf("Here not affine. \n"); 
    GroupNormBackwardGpu<T, false>(stream, num_instances, norm_size, channel_size, spatial_size, 
                                    dy_ptr, x_ptr, mean,
                                    inv_variance, gamma_ptr, dx_ptr);
  }
}


} // namespace 

template<typename T>
class GroupNormGpuKernel final : public user_op::OpKernel{

public: 
    GroupNormGpuKernel() = default; 
    ~GroupNormGpuKernel() = default; 

private: 
    using user_op::OpKernel::Compute; 
    bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
    void Compute(user_op::KernelComputeContext* ctx) const override {
        const user_op::Tensor* x = ctx->Tensor4ArgNameAndIndex("x", 0); 
        user_op::Tensor* y = ctx->Tensor4ArgNameAndIndex("y", 0); 
        user_op::Tensor* mean = ctx->Tensor4ArgNameAndIndex("mean", 0);
        user_op::Tensor* inv_variance = ctx->Tensor4ArgNameAndIndex("inv_variance", 0);
        const double epsilon = ctx->Attr<double>("epsilon");
        const int32_t num_groups = ctx->Attr<int32_t>("num_groups"); 
        CHECK_GE(epsilon, CUDNN_BN_MIN_EPSILON);
        const int64_t num_instances = mean->shape().elem_cnt();  // N*num_groups
        const int64_t norm_size = x->shape().elem_cnt() / num_instances;
        const int64_t batch_size = x->shape().At(0); 
        const int64_t channel_size = x->shape().At(1); 
        const int64_t spatial_size = x->shape().elem_cnt() / batch_size / channel_size; 
        printf("B x num_groups = %d \n", batch_size*num_groups); 
        printf("num instance is: %d \n", num_instances); 
        printf("Spatial size is: %d \n", spatial_size); 
        printf("CHannel size is: %d \n", channel_size); 
        const T* gamma_ptr = nullptr;
        const T* beta_ptr = nullptr;
        if (ctx->has_input("gamma", 0) && ctx->has_input("beta", 0)) {
          const user_op::Tensor* gamma = ctx->Tensor4ArgNameAndIndex("gamma", 0);
          gamma_ptr = gamma->dptr<T>();
          CHECK_EQ(gamma->shape().elem_cnt(), channel_size);
          const user_op::Tensor* beta = ctx->Tensor4ArgNameAndIndex("beta", 0); 
          beta_ptr = ctx->Tensor4ArgNameAndIndex("beta", 0)->dptr<T>();
          CHECK_EQ(beta->shape().elem_cnt(), channel_size);
        }
        DispatchGroupNormForwardGpu<T>(ctx->stream(), 
                                       num_instances, norm_size, 
                                       channel_size, 
                                       spatial_size, epsilon, 
                                       x->dptr<T>(),
                                       gamma_ptr, beta_ptr, y->mut_dptr<T>(), mean, inv_variance);

    }

}; 

#define REGISTER_GROUP_NORM_CUDA_KERNEL(dtype)                         \
  REGISTER_USER_KERNEL("group_norm")                                   \
      .SetCreateFn<GroupNormGpuKernel<dtype>>()                        \
      .SetIsMatchedHob((user_op::HobDeviceType() == DeviceType::kCUDA) \
                       && (user_op::HobDataType("x", 0) == GetDataType<dtype>::value));

// REGISTER_GROUP_NORM_CUDA_KERNEL(half)
REGISTER_GROUP_NORM_CUDA_KERNEL(float)
// REGISTER_GROUP_NORM_CUDA_KERNEL(double)

template<typename T>
class GroupNormGradGpuKernel final : public user_op::OpKernel {
 public:
  GroupNormGradGpuKernel() = default;
  ~GroupNormGradGpuKernel() = default;

 private:
  using user_op::OpKernel::Compute;
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* dy = ctx->Tensor4ArgNameAndIndex("dy", 0);
    const user_op::Tensor* x = ctx->Tensor4ArgNameAndIndex("x", 0);
    const user_op::Tensor* mean = ctx->Tensor4ArgNameAndIndex("mean", 0);
    const user_op::Tensor* inv_variance = ctx->Tensor4ArgNameAndIndex("inv_variance", 0);
    user_op::Tensor* dx = ctx->Tensor4ArgNameAndIndex("dx", 0);
    const int64_t num_instances = mean->shape().elem_cnt();
    const int64_t norm_size = x->shape().elem_cnt() / num_instances;
    const int64_t batch_size = x->shape().At(0); 
    const int64_t channel_size = x->shape().At(1); 
    const int64_t spatial_size = x->shape().elem_cnt() / batch_size / channel_size; 
    const T* gamma_ptr = nullptr;
    if (ctx->has_input("gamma", 0)) {
      gamma_ptr = ctx->Tensor4ArgNameAndIndex("gamma", 0)->dptr<T>();
    }
    LaunchGroupNormBackward<T>(ctx->stream(), num_instances, norm_size, channel_size, spatial_size, 
                               dy->dptr<T>(), x->dptr<T>(),
                               mean, inv_variance, gamma_ptr, dx->mut_dptr<T>());
  };
};

#define REGISTER_GROUP_NORM_GRAD_CUDA_KERNEL(dtype)                                        \
  REGISTER_USER_KERNEL("group_norm_grad")                                                  \
      .SetCreateFn<GroupNormGradGpuKernel<dtype>>()                                        \
      .SetIsMatchedHob((user_op::HobDeviceType() == DeviceType::kCUDA)                     \
                       && (user_op::HobDataType("dy", 0) == GetDataType<dtype>::value));


REGISTER_GROUP_NORM_GRAD_CUDA_KERNEL(float)

} // namespace oneflow 