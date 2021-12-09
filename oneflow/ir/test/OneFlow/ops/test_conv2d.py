"""
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
"""
# RUN: python3 %s
import os
import unittest
import numpy as np

import oneflow as flow
import oneflow.unittest

os.environ["ONEFLOW_MLIR_ENABLE_ROUND_TRIP"] = '1'
os.environ["ONEFLOW_MLIR_ENABLE_CODEGEN_FUSERS"] = '1'

@flow.unittest.skip_unless_1n1d()
class TestConv2DMLIR(oneflow.unittest.TestCase):
    def test_adaptive_pool1d_graph(test_case):
        data = np.random.randn(94, 32, 112, 122)
        x = flow.tensor(data, dtype=flow.float32)

        conv2d = flow.nn.Conv2d(32, 64, 3, stride=2)
        y_eager = conv2d(x)

        class Conv2DGraph(flow.nn.Graph):
            def __init__(self):
                super().__init__()
                self.conv2d = conv2d

            def build(self, x):
                return self.conv2d(x)

        conv2d_g = Conv2DGraph()
        y_lazy = conv2d_g(x)
        
        # for i in range(100):
        #     y_lazy = conv2d_g(x)

        test_case.assertTrue(np.array_equal(y_eager.numpy(), y_lazy.numpy()))


if __name__ == "__main__":
    unittest.main()
