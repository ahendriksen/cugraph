# Copyright (c) 2022-2023, NVIDIA CORPORATION.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from cugraph_pyg.sampler import CuGraphSampler

import cudf
import cupy

import pytest

from cugraph_pyg.data import CuGraphStore

from cugraph.utilities.utils import import_optional, MissingModule

torch = import_optional("torch")


@pytest.mark.cugraph_ops
@pytest.mark.skipif(isinstance(torch, MissingModule), reason="torch not available")
def test_neighbor_sample(basic_graph_1, dask_client):
    F, G, N = basic_graph_1
    cugraph_store = CuGraphStore(F, G, N, multi_gpu=True)

    sampler = CuGraphSampler(
        (cugraph_store, cugraph_store),
        num_neighbors=[-1],
        replace=True,
        directed=True,
        edge_types=[v.edge_type for v in cugraph_store._edge_types_to_attrs.values()],
    )

    out_dict = sampler.sample_from_nodes(
        (
            torch.arange(6, dtype=torch.int64),
            torch.tensor([0, 1, 2, 3, 4], dtype=torch.int64),
            None,
        )
    )

    if isinstance(out_dict, dict):
        noi_groups, row_dict, col_dict, _ = out_dict["out"]
        metadata = out_dict["metadata"]
    else:
        noi_groups = out_dict.node
        row_dict = out_dict.row
        col_dict = out_dict.col
        metadata = out_dict.metadata

    assert metadata.tolist() == list(range(6))

    for node_type, node_ids in noi_groups.items():
        actual_vertex_ids = torch.arange(N[node_type])

        assert node_ids.tolist() == actual_vertex_ids.tolist()

    for edge_type, ei in G.items():
        expected_df = cudf.DataFrame(
            {
                "src": cupy.asarray(ei[0]),
                "dst": cupy.asarray(ei[1]),
            }
        )

        results_df = cudf.DataFrame(
            {
                "src": cupy.asarray(row_dict[edge_type]),
                "dst": cupy.asarray(col_dict[edge_type]),
            }
        )

        expected_df = expected_df.drop_duplicates().sort_values(by=["src", "dst"])
        results_df = results_df.drop_duplicates().sort_values(by=["src", "dst"])
        assert (
            expected_df.src.values_host.tolist() == results_df.src.values_host.tolist()
        )
        assert (
            expected_df.dst.values_host.tolist() == results_df.dst.values_host.tolist()
        )


@pytest.mark.cugraph_ops
@pytest.mark.skipif(isinstance(torch, MissingModule), reason="torch not available")
def test_neighbor_sample_multi_vertex(multi_edge_multi_vertex_graph_1, dask_client):
    F, G, N = multi_edge_multi_vertex_graph_1
    cugraph_store = CuGraphStore(F, G, N, multi_gpu=True)

    sampler = CuGraphSampler(
        (cugraph_store, cugraph_store),
        num_neighbors=[-1],
        replace=True,
        directed=True,
        edge_types=[v.edge_type for v in cugraph_store._edge_types_to_attrs.values()],
    )

    out_dict = sampler.sample_from_nodes(
        (
            torch.arange(6, dtype=torch.int64),
            torch.tensor([0, 1, 2, 3, 4], dtype=torch.int64),
            None,
        )
    )

    if isinstance(out_dict, dict):
        noi_groups, row_dict, col_dict, _ = out_dict["out"]
        metadata = out_dict["metadata"]
    else:
        noi_groups = out_dict.node
        row_dict = out_dict.row
        col_dict = out_dict.col
        metadata = out_dict.metadata

    assert metadata.tolist() == list(range(6))

    for node_type, node_ids in noi_groups.items():
        actual_vertex_ids = torch.arange(N[node_type])

        assert node_ids.tolist() == actual_vertex_ids.tolist()

    for edge_type, ei in G.items():
        expected_df = cudf.DataFrame(
            {
                "src": cupy.asarray(ei[0]),
                "dst": cupy.asarray(ei[1]),
            }
        )

        results_df = cudf.DataFrame(
            {
                "src": cupy.asarray(row_dict[edge_type]),
                "dst": cupy.asarray(col_dict[edge_type]),
            }
        )

        expected_df = expected_df.drop_duplicates().sort_values(by=["src", "dst"])
        results_df = results_df.drop_duplicates().sort_values(by=["src", "dst"])
        assert (
            expected_df.src.values_host.tolist() == results_df.src.values_host.tolist()
        )
        assert (
            expected_df.dst.values_host.tolist() == results_df.dst.values_host.tolist()
        )
