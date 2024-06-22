# Copyright (c) 2024, David Rubin <daviru007@icloud.com>
#
# SPDX-License-Identifier: GPL-3.0-only

import struct
import matplotlib.pyplot as plt
import networkx as nx
import math

def get_offset_pos(pos, edges, offset_scale=0.03):
    offset_pos = {node: pos[node] for node in pos}
    for edge in edges:
        x1, y1 = pos[edge[0]]
        x2, y2 = pos[edge[1]]
        dx = x2 - x1
        dy = y2 - y1
        length = math.sqrt(dx*dx + dy*dy)
        if length == 0:
            continue
        offset_x = offset_scale * dy / length
        offset_y = -offset_scale * dx / length
        offset_pos[edge[0]] = (offset_pos[edge[0]][0] + offset_x, offset_pos[edge[0]][1] + offset_y)
        offset_pos[edge[1]] = (offset_pos[edge[1]][0] + offset_x, offset_pos[edge[1]][1] + offset_y)
    return offset_pos

def read_graph_binary(filename):
    nodes = []
    edges = []
    cfg_edges = []

    with open(filename, "rb") as file:
        while True:
            node_id_bytes = file.read(4)
            if not node_id_bytes:
                break
            node_id = struct.unpack("i", node_id_bytes)[0]
            if node_id == -1:
                break
            data_len = struct.unpack("Q", file.read(8))[0]
            data = file.read(data_len).decode("utf-8")
            nodes.append((node_id, data))

        while True:
            edge_from_bytes = file.read(4)
            if not edge_from_bytes:
                break
            edge_from = struct.unpack("i", edge_from_bytes)[0]
            if edge_from == -1:
                break
            edge_to = struct.unpack("i", file.read(4))[0]
            edges.append((edge_from, edge_to))

        while True:
            cfg_from_bytes = file.read(4)
            if not cfg_from_bytes:
                break
            cfg_from = struct.unpack("i", cfg_from_bytes)[0]
            cfg_to = struct.unpack("i", file.read(4))[0]
            cfg_edges.append((cfg_from, cfg_to))

    return nodes, edges, cfg_edges

nodes, edges, cfg_edges = read_graph_binary("graph.bin")

G = nx.DiGraph()

for node in nodes:
    G.add_node(node[0], label=node[1])

for edge in edges:
    G.add_edge(edge[0], edge[1])

predecessors = {cfg_edge[1] for cfg_edge in cfg_edges}
nodes_with_edges = [node for node in G.nodes if G.out_degree(node) > 0 or G.in_degree(node) > 0 and node in predecessors]

G_filtered = G.subgraph(nodes_with_edges).copy()

# Coloring the first and last nodes in the CFG
first_node = cfg_edges[0][0]
predecessors = {cfg_edge[1] for cfg_edge in cfg_edges}
nodes_with_no_successors = {node for node in G_filtered.nodes if all(cfg_edge[0] != node for cfg_edge in cfg_edges) and node in predecessors}

node_colors = ['green' if node == first_node else 'red' if node in nodes_with_no_successors else 'skyblue' for node in G_filtered.nodes]

pos = nx.nx_agraph.graphviz_layout(G_filtered, prog='neato')
plt.figure(figsize=(15, 10))
nx.draw(G_filtered, pos, with_labels=True, labels=nx.get_node_attributes(G_filtered, 'label'), node_color=node_colors, node_size=3000, font_size=10, font_color='black', font_weight='bold', edge_color='gray')

data_edges_pos = pos
cfg_edges_pos = get_offset_pos(pos, cfg_edges)

for edge in edges:
    if edge[0] in G_filtered and edge[1] in G_filtered:
        nx.draw_networkx_edges(G_filtered, data_edges_pos, edgelist=[edge], edge_color='gray', arrows=True)

scale = 4

for cfg_edge in cfg_edges:
    if cfg_edge[0] in G_filtered and cfg_edge[1] in G_filtered:
        x1, y1 = pos[cfg_edge[0]]
        x2, y2 = cfg_edges_pos[cfg_edge[1]]
        dx = x2 - x1
        dy = y2 - y1
        length = math.sqrt(dx*dx + dy*dy)
        if length == 0:
            continue
        offset_x = scale * dy / length
        offset_y = -scale * dx / length
        plt.arrow(x1 + offset_x, y1 + offset_y, dx, dy, color='red', linewidth=1, head_width=0.1, head_length=0.2)

plt.savefig("out.png")
