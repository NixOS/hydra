#!/usr/bin/env python3

"""Generate a Mermaid transitive reduction of intra-workspace crate dependencies."""

import json
import re
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
DEFAULT_DOC_FILE = ROOT / "subprojects" / "hydra-manual" / "src" / "architecture.md"
PREFIX = ""


def short(name: str) -> str:
    """Shorten crate names for readable node labels."""
    # Hydra crates don't have a uniform prefix, so just return as-is.
    return name.removeprefix(PREFIX)


def get_workspace_info(
    manifest_path: str | None = None,
) -> tuple[list[str], list[tuple[str, str]], list[tuple[str, str]]]:
    """Return (all member names, normal edges, dev edges) for intra-workspace deps."""
    cmd = ["cargo", "metadata", "--format-version=1", "--no-deps"]
    if manifest_path:
        cmd += ["--manifest-path", manifest_path]
    raw = subprocess.check_output(cmd, text=True)
    meta = json.loads(raw)
    members = {p["name"] for p in meta["packages"]}

    all_members = sorted(short(name) for name in members)

    normal_edges: list[tuple[str, str]] = []
    dev_edges: list[tuple[str, str]] = []
    for pkg in meta["packages"]:
        if pkg["name"] not in members:
            continue
        for dep in pkg["dependencies"]:
            if dep["name"] not in members:
                continue
            # Skip optional (feature-gated) deps
            if dep.get("optional", False):
                continue
            edge = (short(pkg["name"]), short(dep["name"]))
            if dep.get("kind") == "dev":
                dev_edges.append(edge)
            elif dep.get("kind") in (None, "normal"):
                normal_edges.append(edge)

    return all_members, sorted(set(normal_edges)), sorted(set(dev_edges))


def transitive_reduction(
    edges: list[tuple[str, str]],
) -> list[tuple[str, str]]:
    """Compute the transitive reduction (Hasse diagram) of a DAG."""
    # Build adjacency: src -> set of direct successors (dependencies).
    adj: dict[str, set[str]] = {}
    for src, dst in edges:
        adj.setdefault(src, set()).add(dst)
        adj.setdefault(dst, set())

    # For each node, compute the full set of reachable nodes.
    reachable: dict[str, set[str]] = {}

    def reach(n: str) -> set[str]:
        if n in reachable:
            return reachable[n]
        r: set[str] = set()
        for child in adj[n]:
            r.add(child)
            r |= reach(child)
        reachable[n] = r
        return r

    for n in adj:
        reach(n)

    # An edge src→dst is redundant if dst is reachable from src
    # through some other direct successor.
    reduced: list[tuple[str, str]] = []
    for src, dst in edges:
        others = adj[src] - {dst}
        reachable_without = set()
        for o in others:
            reachable_without.add(o)
            reachable_without |= reachable[o]
        if dst not in reachable_without:
            reduced.append((src, dst))

    return sorted(reduced)


def topo_order(edges: list[tuple[str, str]]) -> dict[str, int]:
    """Return a topological rank for each node (0 = leaf dependency)."""
    nodes: set[str] = set()
    for src, dst in edges:
        nodes.add(src)
        nodes.add(dst)

    children: dict[str, set[str]] = {n: set() for n in nodes}
    in_degree: dict[str, int] = {n: 0 for n in nodes}
    for src, dst in edges:
        children[dst].add(src)
        in_degree[src] += 1

    order: dict[str, int] = {}
    queue = sorted(n for n in nodes if in_degree[n] == 0)
    rank = 0
    while queue:
        next_queue: list[str] = []
        for n in queue:
            order[n] = rank
        for n in queue:
            for child in children[n]:
                in_degree[child] -= 1
                if in_degree[child] == 0:
                    next_queue.append(child)
        queue = sorted(next_queue)
        rank += 1

    return order


def generate_mermaid(
    all_members: list[str],
    edges: list[tuple[str, str]],
    dev_edges: list[tuple[str, str]] | None = None,
    title: str | None = None,
) -> str:
    all_edges = edges + (dev_edges or [])
    nodes: set[str] = set(all_members)
    for src, dst in all_edges:
        nodes.add(src)
        nodes.add(dst)

    order = topo_order(all_edges)

    # Group crates by prefix so Mermaid clusters them.
    groups: dict[str, list[str]] = {}
    grouped = {n for members in groups.values() for n in members}

    lines = ["```mermaid"]
    if title:
        lines.append("---")
        lines.append(f"title: {title}")
        lines.append("---")
    lines.append("graph BT")
    for label, members in groups.items():
        if members:
            lines.append(f"    subgraph {label}")
            for n in members:
                lines.append(f"        {n}")
            lines.append("    end")

    # Emit isolated nodes (no edges) that aren't in a subgraph.
    connected = set()
    for src, dst in all_edges:
        connected.add(src)
        connected.add(dst)
    for n in sorted(nodes - connected - grouped):
        lines.append(f"    {n}")

    sorted_edges = sorted(edges, key=lambda e: (order.get(e[0], 0), e[0], e[1]))
    for src, dst in sorted_edges:
        lines.append(f"    {src} --> {dst}")

    if dev_edges:
        sorted_dev = sorted(dev_edges, key=lambda e: (order.get(e[0], 0), e[0], e[1]))
        for src, dst in sorted_dev:
            lines.append(f"    {src} -.-> {dst}")

    lines.append("```")
    return "\n".join(lines)


def main() -> None:
    manifest_path = None
    if "--manifest-path" in sys.argv:
        idx = sys.argv.index("--manifest-path")
        manifest_path = sys.argv[idx + 1]

    all_members, edges, dev_edges = get_workspace_info(manifest_path)
    reduced = transitive_reduction(edges)
    # For dev edges, reduce considering normal edges too (a dev edge is
    # redundant if the target is already reachable via normal deps).
    reduced_dev = transitive_reduction(edges + dev_edges)
    reduced_dev = [e for e in reduced_dev if e not in set(reduced)]
    mermaid = generate_mermaid(all_members, reduced, dev_edges=reduced_dev)

    # --doc PATH: specify the doc file (default: auto-detected from script location).
    if "--doc" in sys.argv:
        idx = sys.argv.index("--doc")
        doc_file = Path(sys.argv[idx + 1])
    else:
        doc_file = DEFAULT_DOC_FILE

    if doc_file.exists():
        text = doc_file.read_text()
        blocks = list(re.finditer(r"```mermaid\n.*?```", text, flags=re.DOTALL))
        if blocks:
            text = text[: blocks[0].start()] + mermaid + text[blocks[0].end() :]
        else:
            print("No mermaid block found in doc file", file=sys.stderr)
            sys.exit(1)

        if "--update" in sys.argv:
            doc_file.write_text(text)
            print(f"Updated {doc_file}", file=sys.stderr)
        else:
            print(text, end="")
    else:
        print(mermaid)


if __name__ == "__main__":
    main()
