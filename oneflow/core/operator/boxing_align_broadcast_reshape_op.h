#ifndef ONEFLOW_CORE_OPERATOR_BOXING_ALIGN_BROADCAST_RESHAPE_OP_H_
#define ONEFLOW_CORE_OPERATOR_BOXING_ALIGN_BROADCAST_RESHAPE_OP_H_

#include "oneflow/core/operator/operator.h"

namespace oneflow {

class BoxingAlignBroadcastReshapeOp final : public Operator {
 public:
  OF_DISALLOW_COPY_AND_MOVE(BoxingAlignBroadcastReshapeOp);
  BoxingAlignBroadcastReshapeOp() = default;
  ~BoxingAlignBroadcastReshapeOp() override = default;

  void InitFromOpConf() override;
  const PbMessage &GetCustomizedConf() const override;
  bool NeedInBlobWhenBackward() const override { return false; }
  bool NeedOutBlobWhenBackward() const override { return false; }
  void InferBlobDescs(std::function<BlobDesc *(const std::string &)> GetBlobDesc4BnInOp,
                      const ParallelContext *parallel_ctx) const override;
  void InferBwBufBlobDescs(std::function<BlobDesc *(const std::string &)> GetBlobDesc4BnInOp,
                           const ParallelContext *) const override;
};

}  // namespace oneflow

#endif  // ONEFLOW_CORE_OPERATOR_BOXING_ALIGN_BROADCAST_RESHAPE_OP_H_
