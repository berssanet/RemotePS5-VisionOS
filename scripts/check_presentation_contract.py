#!/usr/bin/env python3
"""Check the 02.01 design tables; does not simulate or validate app behavior."""

from pathlib import Path
import sys


def table(text, name, width):
    begin = f"<!-- presentation-{name}:start -->"
    end = f"<!-- presentation-{name}:end -->"
    if text.count(begin) != 1 or text.count(end) != 1:
        raise ValueError(f"{name}: expected one marked table")
    section = text.split(begin, 1)[1].split(end, 1)[0]
    lines = [line.strip() for line in section.splitlines() if line.strip()]
    rows = []
    for line in lines:
        if not line.startswith("|") or not line.endswith("|"):
            raise ValueError(f"{name}: unexpected non-table content")
        cells = [cell.strip() for cell in line[1:-1].split("|")]
        if len(cells) != width or not all(cells):
            raise ValueError(f"{name}: invalid row width or empty cell")
        rows.append(cells)
    if len(rows) < 3 or any(cell != "---" for cell in rows[1]):
        raise ValueError(f"{name}: missing table header/separator/data")
    return rows[2:]


def check(path):
    text = path.read_text(encoding="utf-8")
    states = {}
    for name, lease, _ in table(text, "states", 3):
        if name in states or lease not in {"none", "S"}:
            raise ValueError(f"invalid/duplicate state: {name}")
        states[name] = lease
    required = {"idle", "starting", "windowed", "opening", "immersive",
                "recoveringWindow", "closing", "error", "terminating", "terminated"}
    if states.keys() != required:
        raise ValueError("state inventory differs from the reviewed contract")

    transitions = table(text, "transitions", 6)
    identifiers = set()
    edges = {state: set() for state in states}
    expanded = 0
    for identifier, origin, _, target, owner, _ in transitions:
        if identifier in identifiers:
            raise ValueError(f"duplicate transition: {identifier}")
        identifiers.add(identifier)
        sources = list(states) if origin == "*" else origin.split(",")
        if len(sources) != len(set(sources)) or any(s not in states for s in sources):
            raise ValueError(f"{identifier}: invalid source state")
        if owner not in {"same", "none", "S", "new S"}:
            raise ValueError(f"{identifier}: unspecified ownership")
        for source in sources:
            destination = source if target == "same" else target
            if destination not in states:
                raise ValueError(f"{identifier}: unknown destination")
            lease = states[source] if owner == "same" else ("S" if owner == "new S" else owner)
            if states[destination] != lease:
                raise ValueError(f"{identifier}: destination has inconsistent ownership")
            if owner == "new S":
                if source not in {"idle", "terminated"} or destination != "starting":
                    raise ValueError(f"{identifier}: illegal lease replacement")
            elif states[source] == "none" and lease == "S":
                raise ValueError(f"{identifier}: lease introduced without reservation")
            if states[source] == "S" and lease == "none":
                if (source, destination) != ("terminating", "terminated"):
                    raise ValueError(f"{identifier}: lease released outside termination")
            edges[source].add(destination)
            expanded += 1

    if transitions[-1][1:5] != ["*", "Otherwise: unsupported request, unmet guard or unrecognized event", "same", "same"]:
        raise ValueError("missing final rejection rule with explicit destination/ownership")

    def reachable(start):
        seen = {start}
        pending = [start]
        while pending:
            for destination in edges[pending.pop()] - seen:
                seen.add(destination)
                pending.append(destination)
        return seen

    if reachable("idle") != set(states):
        raise ValueError("unreachable state in the specification graph")
    if any("terminated" not in reachable(state) for state in states):
        raise ValueError("state without a specified path to completed termination")
    print(f"PASS: {len(states)} states, {len(transitions)} rules, {expanded} expanded edges; "
          "references, lease ownership and structural reachability consistent.")
    print("Scope: specification only; guards, async behavior and device transitions are untested.")


if __name__ == "__main__":
    contract = Path(__file__).resolve().parents[1] / "docs/presentation_state_contract_2026_09.md"
    try:
        check(contract)
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
