# Copyright (c) 2023, NVIDIA CORPORATION.
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

import pytest
import cudf
import cupy
import cugraph
from cugraph.experimental.datasets import karate
from cugraph.experimental.gnn import BulkSampler

import tempfile
import os


@pytest.mark.sg
@pytest.mark.skip("work in progress")
def test_bulk_sampler_simple():
    el = karate.get_edgelist().reset_index().rename(columns={"index": "eid"})
    el["eid"] = el["eid"].astype("int32")
    el["etp"] = cupy.int32(0)

    G = cugraph.Graph(directed=True)
    G.from_cudf_edgelist(
        el,
        source="src",
        destination="dst",
        edge_attr=["wgt", "eid", "etp"],
        legacy_renum_only=True,
    )

    tempdir_object = tempfile.TemporaryDirectory()
    bs = BulkSampler(
        batch_size=2,
        output_path=tempdir_object.name,
        graph=G,
        fanout_vals=[2, 2],
        with_replacement=False,
    )

    batches = cudf.DataFrame(
        {
            "start": cudf.Series([0, 5, 10, 15], dtype="int32"),
            "batch": cudf.Series([0, 0, 1, 1], dtype="int32"),
        }
    )

    bs.add_batches(batches, start_col_name="start", batch_col_name="batch")
    bs.flush()

    recovered_samples = cudf.read_parquet(os.path.join(tempdir_object.name, "rank=0"))

    for b in batches["batch"].unique().values_host.tolist():
        assert b in recovered_samples["batch_id"].values_host.tolist()


@pytest.mark.sg
def test_bulk_sampler_remainder():
    el = karate.get_edgelist().reset_index().rename(columns={"index": "eid"})
    el["eid"] = el["eid"].astype("int32")
    el["etp"] = cupy.int32(0)

    G = cugraph.Graph(directed=True)
    G.from_cudf_edgelist(
        el,
        source="src",
        destination="dst",
        edge_attr=["wgt", "eid", "etp"],
        legacy_renum_only=True,
    )

    tempdir_object = tempfile.TemporaryDirectory()
    bs = BulkSampler(
        batch_size=2,
        output_path=tempdir_object.name,
        graph=G,
        seeds_per_call=7,
        batches_per_partition=2,
        fanout_vals=[2, 2],
        with_replacement=False,
    )

    # Should process batch (0, 1, 2) then (3, 4, 5) then 6

    batches = cudf.DataFrame(
        {
            "start": cudf.Series(
                [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13], dtype="int32"
            ),
            "batch": cudf.Series(
                [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6], dtype="int32"
            ),
        }
    )

    bs.add_batches(batches, start_col_name="start", batch_col_name="batch")
    bs.flush()

    tld = os.path.join(tempdir_object.name, "rank=0")
    recovered_samples = cudf.read_parquet(tld)
    print(os.listdir(tld))

    for b in batches["batch"].unique().values_host.tolist():
        assert b in recovered_samples["batch_id"].values_host.tolist()

    for x in range(0, 6, 2):
        subdir = f"{x}-{x+1}"
        df = cudf.read_parquet(os.path.join(tld, f"batch={subdir}.parquet"))

        assert ((df.batch_id == x) | (df.batch_id == (x + 1))).all()
        assert ((df.hop_id == 0) | (df.hop_id == 1)).all()

    assert (
        cudf.read_parquet(os.path.join(tld, "batch=6-6.parquet")).batch_id == 6
    ).all()


@pytest.mark.sg
@pytest.mark.skip("work in progress")
def test_bulk_sampler_large_batch_size():
    el = karate.get_edgelist().reset_index().rename(columns={"index": "eid"})
    el["eid"] = el["eid"].astype("int32")
    el["etp"] = cupy.int32(0)

    G = cugraph.Graph(directed=True)
    G.from_cudf_edgelist(
        el,
        source="src",
        destination="dst",
        edge_attr=["wgt", "eid", "etp"],
        legacy_renum_only=True,
    )

    tempdir_object = tempfile.TemporaryDirectory()
    bs = BulkSampler(
        batch_size=5120,
        output_path=tempdir_object.name,
        graph=G,
        fanout_vals=[2, 2],
        with_replacement=False,
    )

    batches = cudf.DataFrame(
        {
            "start": cudf.Series([0, 5, 10, 15], dtype="int32"),
            "batch": cudf.Series([0, 0, 1, 1], dtype="int32"),
        }
    )

    bs.add_batches(batches, start_col_name="start", batch_col_name="batch")
    bs.flush()

    recovered_samples = cudf.read_parquet(os.path.join(tempdir_object.name, "rank=0"))

    for b in batches["batch"].unique().values_host.tolist():
        assert b in recovered_samples["batch_id"].values_host.tolist()
