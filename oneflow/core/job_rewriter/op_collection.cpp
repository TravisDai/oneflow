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
#include "oneflow/core/framework/config_def.h"

namespace oneflow {

namespace {

REGISTER_SCOPE_CONFIG_DEF().String(
    "op_collection", "forward",
    "a label for ops under this scope. Possible values: forward|backward|optimizer");

DEFINE_CONFIG_CONSTANT()
    .String("OP_COLLECTION_FORWARD", "forward")
    .String("OP_COLLECTION_BACKWARD", "backward")
    .String("OP_COLLECTION_OPTIMIZER", "optimizer");

}  // namespace

}  // namespace oneflow
