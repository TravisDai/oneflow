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
#include "oneflow/core/common/decorator.h"
#include "oneflow/core/framework/tensor.h"
#include "oneflow/core/framework/tensor_tuple.h"
#include "oneflow/core/framework/transport_token.h"
#include "oneflow/core/framework/tensor_consistent_id.h"

namespace oneflow {

namespace {

Maybe<std::shared_ptr<TransportToken>> RawGetMetaTransportToken() {
  const auto& token = JUST(TransportToken::NewTransportToken(kTransportTokenTypeMeta));
  return std::make_shared<TransportToken>(token);
}
static constexpr auto* GetMetaTransportToken = DECORATE(&RawGetMetaTransportToken, ThreadLocal);

}  // namespace

Maybe<TransportToken> NewTensorConsistentId() { return ++**JUST(GetMetaTransportToken()); }

namespace one {

int64_t* MutThreadLocalConsistentIdDepth() {
  static thread_local int64_t recursive_depth = 0;
  return &recursive_depth;
}

Maybe<void> InitConsistentId(TensorTuple* outputs) {
  for (const auto& output : *outputs) {
    CHECK_OR_RETURN(output);
    const auto& consistent_tensor = JUST(output->AsConsistentTensor());
    CHECK_OR_RETURN(consistent_tensor)
        << Error::UnimplementedError() << "consistent tensors suppported only.";
    const auto& transport_token = JUST(NewTensorConsistentId());
    JUST(consistent_tensor->mut_impl()->set_transport_token(transport_token));
  }
  return Maybe<void>::Ok();
}

}  // namespace one

}  // namespace oneflow
