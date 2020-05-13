/*
 * Copyright (c) 2019-2020, NVIDIA CORPORATION.  All rights reserved.
 *
 * NVIDIA CORPORATION and its licensors retain all intellectual property
 * and proprietary rights in and to this software, related documentation
 * and any modifications thereto.  Any use, reproduction, disclosure or
 * distribution of this software and related documentation without an express
 * license agreement from NVIDIA CORPORATION is strictly prohibited.
 *
 */

#include <cugraph.h>
#include <algorithm>
#include <iomanip>
#include <limits>
#include "bfs.cuh"
#include "rmm_utils.h"

#include "graph.hpp"

#include "bfs_kernels.cuh"
#include "traversal_common.cuh"
#include "utilities/graph_utils.cuh"

namespace cugraph {
namespace detail {
enum BFS_ALGO_STATE { TOPDOWN, BOTTOMUP };

template <typename IndexType>
void BFS<IndexType>::setup()
{
  // --- Initialize some of the parameters ---
  // Determinism flag, false by default
  deterministic = false;  // FIXME: It is currently not used

  // size of bitmaps for vertices
  vertices_bmap_size = (number_of_vertices / (8 * sizeof(int)) + 1);

  exclusive_sum_frontier_vertex_buckets_offsets_size =
    ((number_of_edges / TOP_DOWN_EXPAND_DIMX + 1) * NBUCKETS_PER_BLOCK + 2);

  d_counters_pad_size = 4;

  // --- Resize device vectors before computation ---
  // Working data
  // Each vertex can be in the frontier at most once
  frontier_vec.resize(number_of_vertices);

  // ith bit of visited_bmap is set <=> ith vertex is visited
  visited_bmap_vec.resize(vertices_bmap_size);

  // ith bit of isolated_bmap is set <=> degree of ith vertex = 0
  isolated_bmap_vec.resize(vertices_bmap_size);

  // vertices_degree[i] = degree of vertex i
  vertex_degree_vec.resize(number_of_vertices);

  // We will need (n+1) ints buffer for two differents things (bottom up or top down) - sharing it
  // since those uses are mutually exclusive
  buffer_np1_1_vec.resize(number_of_vertices + 1);
  buffer_np1_2_vec.resize(number_of_vertices + 1);

  // We use buckets of edges (32 edges per bucket for now, see exact macro in bfs_kernels).
  // frontier_vertex_degree_buckets_offsets[i] is the index k such as frontier[k] is the source of
  // the first edge of the bucket See top down kernels for more details
  exclusive_sum_frontier_vertex_buckets_offsets_vec.resize(
    exclusive_sum_frontier_vertex_buckets_offsets_size);

  // Init device-side counters
  // Those counters must be/can be reset at each bfs iteration
  // Keeping them adjacent in memory allow use call only one cudaMemset - launch latency is the
  // current bottleneck
  d_counters_pad_vec.resize(d_counters_pad_size);

  // --- Cub related work ---
  // NOTE: This operates a memory allocation, that we need to free in `clean`
  traversal::cub_exclusive_sum_alloc(
    number_of_vertices + 1, d_cub_exclusive_sum_storage, cub_exclusive_sum_storage_bytes);

  // --- Associate pointers to vectors ---
  frontier       = frontier_vec.data().get();
  visited_bmap   = visited_bmap_vec.data().get();
  isolated_bmap  = isolated_bmap_vec.data().get();
  vertex_degree  = vertex_degree_vec.data().get();
  d_counters_pad = d_counters_pad_vec.data().get();
  buffer_np1_1   = buffer_np1_1_vec.data().get();
  buffer_np1_2   = buffer_np1_2_vec.data().get();
  exclusive_sum_frontier_vertex_buckets_offsets =
    exclusive_sum_frontier_vertex_buckets_offsets_vec.data().get();

  // --- Associate pointers ---
  // We will update frontier during the execution
  // We need the orig to reset frontier, or ALLOC_FREE_TRY
  original_frontier = frontier;

  d_new_frontier_cnt   = &d_counters_pad[0];
  d_mu                 = &d_counters_pad[1];
  d_unvisited_cnt      = &d_counters_pad[2];
  d_left_unvisited_cnt = &d_counters_pad[3];

  // --- Using buffer:  top down ---
  // frontier_vertex_degree[i] is the degree of vertex frontier[i]
  frontier_vertex_degree = buffer_np1_1;
  // exclusive sum of frontier_vertex_degree
  exclusive_sum_frontier_vertex_degree = buffer_np1_2;

  // --- Using buffers : bottom up ---
  // contains list of unvisited vertices
  unvisited_queue = buffer_np1_1;
  // size of the "last" unvisited queue : size_last_unvisited_queue
  // refers to the size of unvisited_queue
  // which may not be up to date (the queue may contains vertices that are now visited)

  // We may leave vertices unvisited after bottom up main kernels - storing them here
  left_unvisited_queue = buffer_np1_2;

  // --- Computing isolated_bmap ---
  // Lets use this int* for the next 3 lines
  // Its dereferenced value is not initialized - so we dont care about what we put in it
  IndexType *d_nisolated = d_new_frontier_cnt;
  CUDA_TRY(cudaMemsetAsync(d_nisolated, 0, sizeof(IndexType), stream));

  // Only dependent on graph - not source vertex - done once
  traversal::flag_isolated_vertices(
    number_of_vertices, isolated_bmap, row_offsets, vertex_degree, d_nisolated, stream);
  CUDA_TRY(
    cudaMemcpyAsync(&nisolated, d_nisolated, sizeof(IndexType), cudaMemcpyDeviceToHost, stream));

  // We need nisolated to be ready to use
  CUDA_TRY(cudaStreamSynchronize(stream));
}

template <typename IndexType>
void BFS<IndexType>::configure(IndexType *_distances,
                               IndexType *_predecessors,
                               double *_sp_counters,
                               int *_edge_mask)
{
  distances    = _distances;
  predecessors = _predecessors;
  edge_mask    = _edge_mask;
  sp_counters  = _sp_counters;

  useEdgeMask         = (edge_mask != NULL);
  computeDistances    = (distances != NULL);
  computePredecessors = (predecessors != NULL);

  // We need distances to use bottom up
  if (directed && !computeDistances) {
    distances_vec.resize(number_of_vertices);
    distances = distances_vec.data().get();
  }

  // In case the shortest path counters is required, previous_bmap has to be allocated
  if (sp_counters) {
    previous_visited_bmap_vec.resize(vertices_bmap_size);
    previous_visited_bmap = previous_visited_bmap_vec.data().get();
  }
}

template <typename IndexType>
void BFS<IndexType>::traverse(IndexType source_vertex)
{
  // Init visited_bmap
  // If the graph is undirected, we not that
  // we will never discover isolated vertices (in degree = out degree = 0)
  // we avoid a lot of work by flagging them now
  // in g500 graphs they represent ~25% of total vertices
  // more than that for wiki and twitter graphs

  if (directed) {
    CUDA_TRY(cudaMemsetAsync(visited_bmap, 0, vertices_bmap_size * sizeof(int), stream));
  } else {
    CUDA_TRY(cudaMemcpyAsync(visited_bmap,
                             isolated_bmap,
                             vertices_bmap_size * sizeof(int),
                             cudaMemcpyDeviceToDevice,
                             stream));
  }

  // If needed, setting all vertices as undiscovered (inf distance)
  // We dont use computeDistances here
  // if the graph is undirected, we may need distances even if
  // computeDistances is false
  if (distances) {
    traversal::fill_vec(distances, number_of_vertices, traversal::vec_t<IndexType>::max, stream);
    CUDA_CHECK_LAST();
  }

  // If needed, setting all predecessors to non-existent (-1)
  if (computePredecessors) {
    CUDA_TRY(cudaMemsetAsync(predecessors, -1, number_of_vertices * sizeof(IndexType), stream));
  }

  if (sp_counters) {
    CUDA_TRY(cudaMemsetAsync(sp_counters, 0, number_of_vertices * sizeof(double), stream));
    double value = 1;
    CUDA_TRY(
      cudaMemcpyAsync(sp_counters + source_vertex, &value, sizeof(double), cudaMemcpyHostToDevice));
  }

  //
  // Initial frontier
  //

  frontier = original_frontier;

  if (distances) {
    CUDA_TRY(cudaMemsetAsync(&distances[source_vertex], 0, sizeof(IndexType), stream));
  }

  // Setting source_vertex as visited
  // There may be bit already set on that bmap (isolated vertices) - if the graph is undirected
  int current_visited_bmap_source_vert = 0;

  if (!directed) {
    CUDA_TRY(cudaMemcpyAsync(&current_visited_bmap_source_vert,
                             &visited_bmap[source_vertex / INT_SIZE],
                             sizeof(int),
                             cudaMemcpyDeviceToHost));
    // We need current_visited_bmap_source_vert
    CUDA_TRY(cudaStreamSynchronize(stream));
  }

  int m = (1 << (source_vertex % INT_SIZE));

  // In that case, source is isolated, done now
  if (!directed && (m & current_visited_bmap_source_vert)) {
    // Init distances and predecessors are done, (cf Streamsync in previous if)
    return;
  }

  m |= current_visited_bmap_source_vert;

  CUDA_TRY(cudaMemcpyAsync(
    &visited_bmap[source_vertex / INT_SIZE], &m, sizeof(int), cudaMemcpyHostToDevice, stream));

  // Adding source_vertex to init frontier
  CUDA_TRY(cudaMemcpyAsync(
    &frontier[0], &source_vertex, sizeof(IndexType), cudaMemcpyHostToDevice, stream));

  // mf : edges in frontier
  // nf : vertices in frontier
  // mu : edges undiscovered
  // nu : nodes undiscovered
  // lvl : current frontier's depth
  IndexType mf, nf, mu, nu;
  bool growing;
  IndexType lvl = 1;

  // Frontier has one vertex
  nf = 1;

  // all edges are undiscovered (by def isolated vertices have 0 edges)
  mu = number_of_edges;

  // all non isolated vertices are undiscovered (excepted source vertex, which is in frontier)
  // That number is wrong if source_vertex is also isolated - but it's not important
  nu = number_of_vertices - nisolated - nf;

  // Last frontier was 0, now it is 1
  growing = true;

  IndexType size_last_left_unvisited_queue = number_of_vertices;  // we just need value > 0
  IndexType size_last_unvisited_queue      = 0;                   // queue empty

  // Typical pre-top down workflow. set_frontier_degree + exclusive-scan
  traversal::set_frontier_degree(frontier_vertex_degree, frontier, vertex_degree, nf, stream);
  CUDA_CHECK_LAST();
  traversal::exclusive_sum(d_cub_exclusive_sum_storage,
                           cub_exclusive_sum_storage_bytes,
                           frontier_vertex_degree,
                           exclusive_sum_frontier_vertex_degree,
                           nf + 1,
                           stream);
  CUDA_CHECK_LAST();

  CUDA_TRY(cudaMemcpyAsync(&mf,
                           &exclusive_sum_frontier_vertex_degree[nf],
                           sizeof(IndexType),
                           cudaMemcpyDeviceToHost,
                           stream));

  // We need mf
  CUDA_TRY(cudaStreamSynchronize(stream));

  // At first we know we have to use top down
  BFS_ALGO_STATE algo_state = TOPDOWN;

  // useDistances : we check if a vertex is a parent using distances in bottom up - distances become
  // working data undirected g : need parents to be in children's neighbors

  // In case the shortest path counters need to be computeed, the bottom_up approach cannot be used
  bool can_use_bottom_up = (!sp_counters && !directed && distances);

  while (nf > 0 && nu > 0) {
    // Each vertices can appear only once in the frontierer array - we know it will fit
    new_frontier     = frontier + nf;
    IndexType old_nf = nf;
    resetDevicePointers();

    if (can_use_bottom_up) {
      // Choosing algo
      // Finite machine described in http://parlab.eecs.berkeley.edu/sites/all/parlab/files/main.pdf

      switch (algo_state) {
        case TOPDOWN:
          if (mf > mu / alpha) algo_state = BOTTOMUP;
          break;
        case BOTTOMUP:
          if (!growing && nf < number_of_vertices / beta) {
            // We need to prepare the switch back to top down
            // We couldnt keep track of mu during bottom up - because we dont know what mf is.
            // Computing mu here
            bfs_kernels::count_unvisited_edges(unvisited_queue,
                                               size_last_unvisited_queue,
                                               visited_bmap,
                                               vertex_degree,
                                               d_mu,
                                               stream);
            CUDA_CHECK_LAST();

            // Typical pre-top down workflow. set_frontier_degree + exclusive-scan
            traversal::set_frontier_degree(
              frontier_vertex_degree, frontier, vertex_degree, nf, stream);
            CUDA_CHECK_LAST();
            traversal::exclusive_sum(d_cub_exclusive_sum_storage,
                                     cub_exclusive_sum_storage_bytes,
                                     frontier_vertex_degree,
                                     exclusive_sum_frontier_vertex_degree,
                                     nf + 1,
                                     stream);
            CUDA_CHECK_LAST();

            CUDA_TRY(cudaMemcpyAsync(&mf,
                                     &exclusive_sum_frontier_vertex_degree[nf],
                                     sizeof(IndexType),
                                     cudaMemcpyDeviceToHost,
                                     stream));

            CUDA_TRY(cudaMemcpyAsync(&mu, d_mu, sizeof(IndexType), cudaMemcpyDeviceToHost, stream));

            // We will need mf and mu
            CUDA_TRY(cudaStreamSynchronize(stream));
            algo_state = TOPDOWN;
          }
          break;
      }
    }

    // Executing algo

    switch (algo_state) {
      case TOPDOWN:
        // This step is only required if sp_counters is not nullptr
        if (sp_counters) {
          CUDA_TRY(cudaMemcpyAsync(previous_visited_bmap,
                                   visited_bmap,
                                   vertices_bmap_size * sizeof(int),
                                   cudaMemcpyDeviceToDevice,
                                   stream));
          // We need to copy the visited_bmap before doing the traversal
          CUDA_TRY(cudaStreamSynchronize(stream));
        }
        traversal::compute_bucket_offsets(exclusive_sum_frontier_vertex_degree,
                                          exclusive_sum_frontier_vertex_buckets_offsets,
                                          nf,
                                          mf,
                                          stream);
        CUDA_CHECK_LAST();
        bfs_kernels::frontier_expand(row_offsets,
                                     col_indices,
                                     frontier,
                                     nf,
                                     mf,
                                     lvl,
                                     new_frontier,
                                     d_new_frontier_cnt,
                                     exclusive_sum_frontier_vertex_degree,
                                     exclusive_sum_frontier_vertex_buckets_offsets,
                                     previous_visited_bmap,
                                     visited_bmap,
                                     distances,
                                     predecessors,
                                     sp_counters,
                                     edge_mask,
                                     isolated_bmap,
                                     directed,
                                     stream,
                                     deterministic);
        CUDA_CHECK_LAST();

        mu -= mf;

        CUDA_TRY(cudaMemcpyAsync(
          &nf, d_new_frontier_cnt, sizeof(IndexType), cudaMemcpyDeviceToHost, stream));

        // We need nf
        CUDA_TRY(cudaStreamSynchronize(stream));

        if (nf) {
          // Typical pre-top down workflow. set_frontier_degree + exclusive-scan
          traversal::set_frontier_degree(
            frontier_vertex_degree, new_frontier, vertex_degree, nf, stream);
          CUDA_CHECK_LAST();
          traversal::exclusive_sum(d_cub_exclusive_sum_storage,
                                   cub_exclusive_sum_storage_bytes,
                                   frontier_vertex_degree,
                                   exclusive_sum_frontier_vertex_degree,
                                   nf + 1,
                                   stream);
          CUDA_CHECK_LAST();
          CUDA_TRY(cudaMemcpyAsync(&mf,
                                   &exclusive_sum_frontier_vertex_degree[nf],
                                   sizeof(IndexType),
                                   cudaMemcpyDeviceToHost,
                                   stream));

          // We need mf
          CUDA_TRY(cudaStreamSynchronize(stream));
        }
        break;

      case BOTTOMUP:
        bfs_kernels::fill_unvisited_queue(visited_bmap,
                                          vertices_bmap_size,
                                          number_of_vertices,
                                          unvisited_queue,
                                          d_unvisited_cnt,
                                          stream,
                                          deterministic);
        CUDA_CHECK_LAST();

        size_last_unvisited_queue = nu;

        bfs_kernels::bottom_up_main(unvisited_queue,
                                    size_last_unvisited_queue,
                                    left_unvisited_queue,
                                    d_left_unvisited_cnt,
                                    visited_bmap,
                                    row_offsets,
                                    col_indices,
                                    lvl,
                                    new_frontier,
                                    d_new_frontier_cnt,
                                    distances,
                                    predecessors,
                                    edge_mask,
                                    stream,
                                    deterministic);
        CUDA_CHECK_LAST();

        // The number of vertices left unvisited decreases
        // If it wasnt necessary last time, it wont be this time
        if (size_last_left_unvisited_queue) {
          CUDA_TRY(cudaMemcpyAsync(&size_last_left_unvisited_queue,
                                   d_left_unvisited_cnt,
                                   sizeof(IndexType),
                                   cudaMemcpyDeviceToHost,
                                   stream));
          // We need last_left_unvisited_size
          CUDA_TRY(cudaStreamSynchronize(stream));
          bfs_kernels::bottom_up_large(left_unvisited_queue,
                                       size_last_left_unvisited_queue,
                                       visited_bmap,
                                       row_offsets,
                                       col_indices,
                                       lvl,
                                       new_frontier,
                                       d_new_frontier_cnt,
                                       distances,
                                       predecessors,
                                       edge_mask,
                                       stream,
                                       deterministic);
          CUDA_CHECK_LAST();
        }
        CUDA_TRY(cudaMemcpyAsync(
          &nf, d_new_frontier_cnt, sizeof(IndexType), cudaMemcpyDeviceToHost, stream));

        // We will need nf
        CUDA_TRY(cudaStreamSynchronize(stream));
        break;
    }

    // Updating undiscovered edges count
    nu -= nf;

    // Using new frontier
    frontier = new_frontier;
    growing  = (nf > old_nf);

    ++lvl;
  }
}

template <typename IndexType>
void BFS<IndexType>::resetDevicePointers()
{
  CUDA_TRY(cudaMemsetAsync(d_counters_pad, 0, 4 * sizeof(IndexType), stream));
}

template <typename IndexType>
void BFS<IndexType>::clean()
{
  // the vectors have a destructor that takes care of cleaning
  // But we still need to deallocate what cub allocated
  ALLOC_FREE_TRY(d_cub_exclusive_sum_storage, nullptr);
}

template class BFS<int>;
}  // namespace detail

// NOTE: SP counter increase extremely fast on large graph
//       It can easily reach 1e40~1e70 on GAP-road.mtx
template <typename VT, typename ET, typename WT>
void bfs(experimental::GraphCSRView<VT, ET, WT> const &graph,
         VT *distances,
         VT *predecessors,
         double *sp_counters,
         const VT start_vertex,
         bool directed)
{
  CUGRAPH_EXPECTS(typeid(VT) == typeid(int), "Unsupported vertex id data type, please use int");
  CUGRAPH_EXPECTS(typeid(ET) == typeid(int), "Unsupported edge id data type, please use int");
  CUGRAPH_EXPECTS((typeid(WT) == typeid(float)) || (typeid(WT) == typeid(double)),
                  "Unsupported weight data type, please use float or double");

  VT number_of_vertices = graph.number_of_vertices;
  ET number_of_edges    = graph.number_of_edges;

  const VT *indices_ptr = graph.indices;
  const ET *offsets_ptr = graph.offsets;

  int alpha = 15;
  int beta  = 18;
  // FIXME: Use VT and ET in the BFS detail
  cugraph::detail::BFS<VT> bfs(
    number_of_vertices, number_of_edges, offsets_ptr, indices_ptr, directed, alpha, beta);
  bfs.configure(distances, predecessors, sp_counters, nullptr);
  bfs.traverse(start_vertex);
}

template void bfs<int, int, float>(experimental::GraphCSRView<int, int, float> const &graph,
                                   int *distances,
                                   int *predecessors,
                                   double *sp_counters,
                                   const int source_vertex,
                                   bool directed);
template void bfs<int, int, double>(experimental::GraphCSRView<int, int, double> const &graph,
                                    int *distances,
                                    int *predecessors,
                                    double *sp_counters,
                                    const int source_vertex,
                                    bool directed);

}  // namespace cugraph
