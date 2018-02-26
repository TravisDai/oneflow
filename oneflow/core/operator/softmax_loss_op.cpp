#include "oneflow/core/operator/softmax_loss_op.h"
#include "oneflow/core/common/data_type.h"

namespace oneflow {

void SoftmaxLossOp::InitFromOpConf() {
  CHECK(op_conf().has_softmax_loss_conf());
  EnrollInputBn("prediction");
  EnrollInputBn("label", false);
  EnrollDataTmpBn("prob");
  EnrollDataTmpBn("tmp_1D");
  EnrollOutputBn("loss", false);
}

void SoftmaxLossOp::VirtualGenKernelConf(
    std::function<const BlobDesc*(const std::string&)> GetBlobDesc4BnInOp,
    const ParallelContext* parallel_ctx, KernelConf* kernel_conf) const {
  auto conf = kernel_conf->mutable_softmax_loss_conf();
  conf->set_prediction_type(GetBlobDesc4BnInOp("prediction")->data_type());
  conf->set_label_type(GetBlobDesc4BnInOp("label")->data_type());
}

const PbMessage& SoftmaxLossOp::GetCustomizedConf() const {
  return op_conf().softmax_loss_conf();
}

void SoftmaxLossOp::InferBlobDescs(
    std::function<BlobDesc*(const std::string)> GetBlobDesc4BnInOp,
    const ParallelContext* parallel_ctx) const {
  const BlobDesc* pred_blob_desc = GetBlobDesc4BnInOp("prediction");
  const BlobDesc* label_blob_desc = GetBlobDesc4BnInOp("label");
  CHECK_EQ(pred_blob_desc->has_data_id_field(),
           label_blob_desc->has_data_id_field());
  CHECK(IsIntegral(label_blob_desc->data_type()));
  CHECK_GE(pred_blob_desc->shape().NumAxes(), 2);
  CHECK_EQ(label_blob_desc->shape(), Shape({pred_blob_desc->shape().At(0)}));
  // loss
  BlobDesc* loss_blob_desc = GetBlobDesc4BnInOp("loss");
  loss_blob_desc->mut_shape() = Shape({pred_blob_desc->shape().At(0)});
  loss_blob_desc->set_data_type(pred_blob_desc->data_type());
  loss_blob_desc->set_has_data_id_field(pred_blob_desc->has_data_id_field());
  // tmp_1D
  BlobDesc* tmp_1D_blob_desc = GetBlobDesc4BnInOp("tmp_1D");
  tmp_1D_blob_desc->mut_shape() = Shape({pred_blob_desc->shape().At(0)});
  tmp_1D_blob_desc->set_data_type(pred_blob_desc->data_type());
  // prob
  BlobDesc* prob_blob_desc = GetBlobDesc4BnInOp("prob");
  prob_blob_desc->mut_shape() = Shape(pred_blob_desc->shape());
  prob_blob_desc->set_data_type(pred_blob_desc->data_type());
}

REGISTER_OP(OperatorConf::kSoftmaxLossConf, SoftmaxLossOp);

}  // namespace oneflow
