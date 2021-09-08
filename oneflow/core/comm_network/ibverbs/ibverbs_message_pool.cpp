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
#include "oneflow/core/comm_network/ibverbs/ibverbs_message_pool.h"
#include "oneflow/core/comm_network/ibverbs/ibverbs_qp.h"

#if defined(WITH_RDMA) && defined(OF_PLATFORM_POSIX)

namespace oneflow {

IBVerbsMessagePool::IBVerbsMessagePool(ibv_pd* pd, uint32_t num_of_message)
    : pd_(pd), num_of_message_(num_of_message) {}

void IBVerbsMessagePool::RegisterMessagePool() {
  size_t actor_msg_size = sizeof(ActorMsg);
  size_t register_memory_size = actor_msg_size * (num_of_message_);
  char* addr = (char*)malloc(register_memory_size);
  ibv_mr* mr = ibv::wrapper.ibv_reg_mr_wrap(
      pd_, addr, register_memory_size,
      IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_READ);
  CHECK(mr);
  ibv_mr_buf_.push_front(mr);
  memory_buf_.push_front(addr);
  for (size_t i = 0; i < num_of_message_; i++) {
    char* split_addr = addr + actor_msg_size * i;
    ActorMsgMR* msg_mr = new ActorMsgMR(mr, split_addr, actor_msg_size);
    message_buf_.push_front(msg_mr);
  }
}

ActorMsgMR* IBVerbsMessagePool::GetMessage() {
  std::unique_lock<std::mutex> msg_buf_lck(message_buf_mutex_);
  if (IsEmpty() == false) {
    return GetMessageFromBuf();
  } else {
    RegisterMessagePool();
    return GetMessageFromBuf();
  }
}

ActorMsgMR* IBVerbsMessagePool::GetMessageFromBuf() {
  ActorMsgMR* msg_mr = message_buf_.front();
  message_buf_.pop_front();
  return msg_mr;
}

void IBVerbsMessagePool::PutMessage(ActorMsgMR* msg_mr) {
  std::unique_lock<std::mutex> msg_buf_lck(message_buf_mutex_);
  message_buf_.push_front(msg_mr);
}

bool IBVerbsMessagePool::IsEmpty() { return message_buf_.empty() == true; }

}  // namespace oneflow

#endif  // WITH_RDMA && OF_PLATFORM_POSIX
