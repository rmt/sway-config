#!/usr/bin/env python3
"""Manage floating-window zones, focus cycling, and numbered workspaces."""

import json
import re
import subprocess
import sys

ZONES = {
    "tl": (50, 50, 0, 0),
    "tr": (50, 50, 50, 0),
    "bl": (50, 50, 0, 50),
    "br": (50, 50, 50, 50),
    "left": (50, 100, 0, 0),
    "right": (50, 100, 50, 0),
    "top": (100, 50, 0, 0),
    "bottom": (100, 50, 0, 50),
    "center": (70, 70, 15, 15),
}

ALIGNMENTS = {
    "tl": ("left", "top"),
    "tr": ("right", "top"),
    "bl": ("left", "bottom"),
    "br": ("right", "bottom"),
    "left": ("left", "center"),
    "right": ("right", "center"),
    "top": ("center", "top"),
    "bottom": ("center", "bottom"),
    "center": ("center", "center"),
}

CYCLE_ZONES = {
    "tl": {"tl"},
    "tr": {"tr"},
    "bl": {"bl"},
    "br": {"br"},
    "left": {"left", "tl", "bl"},
    "right": {"right", "tr", "br"},
    "top": {"top", "tl", "tr"},
    "bottom": {"bottom", "bl", "br"},
    "center": {"center"},
}


def swaymsg(command):
    subprocess.run(["swaymsg", "-q", command], check=True)


def get_tree():
    result = subprocess.run(
        ["swaymsg", "-r", "-t", "get_tree"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def walk(node, workspace_id=None):
    if node.get("type") == "workspace":
        workspace_id = node.get("id")
    yield node, workspace_id
    for child in node.get("nodes", []) + node.get("floating_nodes", []):
        yield from walk(child, workspace_id)


def focused_context(entries):
    """Return the focused node and its workspace, including focused groups."""
    focused_entry = next(
        ((node, workspace_id) for node, workspace_id in entries
         if node.get("focused") and workspace_id is not None),
        None,
    )
    if focused_entry is None:
        return None, None
    focused, workspace_id = focused_entry
    workspace = next(
        (node for node, _ in entries
         if node.get("type") == "workspace" and node.get("id") == workspace_id),
        None,
    )
    return focused, workspace


def is_view(node):
    return (
        node.get("type") in {"con", "floating_con"}
        and not node.get("nodes")
        and not node.get("floating_nodes")
    )


def active_view(node):
    """Resolve a focused group to its most recently focused leaf window."""
    if is_view(node):
        return node
    children = node.get("nodes", []) + node.get("floating_nodes", [])
    by_id = {child["id"]: child for child in children}
    ordered = [by_id[con_id] for con_id in node.get("focus", []) if con_id in by_id]
    ordered.extend(child for child in children if child not in ordered)
    for child in ordered:
        view = active_view(child)
        if view is not None:
            return view
    return None


def zone_for_mark(mark):
    match = re.fullmatch(r"_zone_([a-z]+)(?:_\d+)?", mark)
    if match is not None and match.group(1) in ZONES:
        return match.group(1)
    return None


def preserve_window_size(node):
    title = str(node.get("name") or "")
    properties = node.get("window_properties") or {}
    identities = (
        title,
        str(node.get("app_id") or ""),
        str(node.get("class") or ""),
        str(properties.get("class") or ""),
        str(properties.get("instance") or ""),
    )
    pianoteq = any(re.match(r"^Pianoteq", value, re.IGNORECASE) for value in identities)
    plugin_title = re.search(r"VST|CLAP", title, re.IGNORECASE) is not None
    return pianoteq or plugin_title


def aligned_position(zone, window_width, window_height, workspace_rect):
    horizontal, vertical = ALIGNMENTS[zone]
    left = workspace_rect.get("x", 0)
    top = workspace_rect.get("y", 0)
    right = left + workspace_rect.get("width", 0)
    bottom = top + workspace_rect.get("height", 0)
    x = {
        "left": left,
        "right": right - window_width,
        "center": left + (right - left - window_width) // 2,
    }[horizontal]
    y = {
        "top": top,
        "bottom": bottom - window_height,
        "center": top + (bottom - top - window_height) // 2,
    }[vertical]
    return x, y


def place(zone, size_override=None):
    entries = list(walk(get_tree()))
    focused, _ = focused_context(entries)
    if focused is None:
        return
    focused = active_view(focused)
    if focused is None:
        return

    con_id = focused["id"]
    mark = f"_zone_{zone}_{con_id}"
    command = f"[con_id={con_id}] floating enable"

    if not preserve_window_size(focused):
        if size_override is None:
            width, height, _, _ = ZONES[zone]
        elif zone in {"left", "right"}:
            width, height = size_override, 100
        elif zone in {"top", "bottom"}:
            width, height = 100, size_override
        else:
            width = height = size_override
        command += f", resize set width {width} ppt height {height} ppt"

    # Read back Sway's resolved geometry after resize, then align the actual
    # container against the usable workspace (excluding panels on any edge).
    swaymsg(command)
    tree = get_tree()
    entries = list(walk(tree))
    window_entry = next(
        ((node, workspace_id) for node, workspace_id in entries
         if node.get("id") == con_id and is_view(node)),
        None,
    )
    if window_entry is None:
        return
    window, workspace_id = window_entry
    workspace = next(
        (node for node, _ in entries
         if node.get("type") == "workspace" and node.get("id") == workspace_id),
        None,
    )
    if workspace is None:
        return
    window_rect = window.get("rect") or {}
    deco_rect = window.get("deco_rect") or {}
    workspace_rect = workspace.get("rect") or {}
    window_width = window_rect.get("width", 0)
    # The IPC rect excludes Sway's titlebar; move position anchors its outer edge.
    window_height = window_rect.get("height", 0) + deco_rect.get("height", 0)
    if not all((window_width, window_height, workspace_rect.get("width"),
                workspace_rect.get("height"))):
        return
    x, y = aligned_position(zone, window_width, window_height, workspace_rect)
    commands = [f"move absolute position {x} px {y} px"]
    commands.extend(
        f"unmark {json.dumps(old_mark)}"
        for old_mark in window.get("marks", [])
        if zone_for_mark(old_mark) is not None
    )
    commands.append(f"mark --add {mark}")
    swaymsg(f"[con_id={con_id}] " + ", ".join(commands))


def adjacent_workspace_number(current, direction):
    if current not in range(1, 11):
        return None
    step = -1 if direction == "previous" else 1
    return (current - 1 + step) % 10 + 1


def navigate_workspace(direction, move_window=False):
    entries = list(walk(get_tree()))
    focused, workspace = focused_context(entries)
    if workspace is None:
        return

    target_number = adjacent_workspace_number(workspace.get("num"), direction)
    sway_direction = "prev" if direction == "previous" else "next"
    destination = sway_direction if target_number is None else f"number {target_number}"
    if move_window:
        if focused.get("type") not in {"con", "floating_con"}:
            return
        # Move a focused group as a group, just like Sway's native move command.
        swaymsg(f"[con_id={focused['id']}] move container to workspace {destination}")
        swaymsg(f"[con_id={focused['id']}] focus")
    else:
        swaymsg(f"workspace {destination}")


def cycle_target(candidates, focused_id, direction):
    if focused_id in candidates:
        index = candidates.index(focused_id)
        return candidates[(index + direction) % len(candidates)]
    return candidates[0] if direction > 0 else candidates[-1]


def cycle(zone=None, direction=1):
    entries = list(walk(get_tree()))
    focused, workspace = focused_context(entries)
    if workspace is None:
        return
    current_workspace = workspace["id"]
    focused_id = focused.get("id")

    if zone is None:
        # Keep Tab cycling all windows in its existing forward/reverse order.
        candidates = sorted(
            {
                node["id"]
                for node, workspace_id in entries
                if workspace_id == current_workspace and is_view(node)
            }
        )
        if not candidates:
            return
        target = cycle_target(candidates, focused_id, direction)
    else:
        # Preserve the existing zone stacking order and membership rules.
        member_marks = {
            member: (f"_zone_{member}", f"_zone_{member}_")
            for member in CYCLE_ZONES[zone]
        }
        candidates = []
        for node, workspace_id in entries:
            if workspace_id != current_workspace or not is_view(node):
                continue
            matches_zone = False
            has_zone = False
            for mark in node.get("marks", []):
                if zone_for_mark(mark) is not None:
                    has_zone = True
                if any(
                    mark == legacy or mark.startswith(prefix)
                    for legacy, prefix in member_marks.values()
                ):
                    matches_zone = True
            if matches_zone or (zone == "center" and not has_zone):
                candidates.append(node["id"])
        if not candidates:
            return
        # Start at the zone's topmost member. Once one is focused, raise the
        # bottommost zone member; this also raises a lone member over outsiders.
        target = candidates[0] if focused_id in candidates else candidates[-1]
    swaymsg(f"[con_id={target}] focus")


def main():
    if len(sys.argv) == 3 and sys.argv[1] in {"workspace-step", "move-step"}:
        if sys.argv[2] not in {"previous", "next"}:
            raise SystemExit("workspace direction must be previous or next")
        navigate_workspace(
            sys.argv[2], move_window=sys.argv[1] == "move-step"
        )
        return

    if len(sys.argv) == 3 and sys.argv[1] == "cycle-all":
        directions = {"next": 1, "previous": -1}
        if sys.argv[2] not in directions:
            raise SystemExit("cycle-all direction must be next or previous")
        cycle(direction=directions[sys.argv[2]])
        return

    if len(sys.argv) not in {3, 4} or sys.argv[1] not in {"place", "cycle"}:
        raise SystemExit(
            "usage: zone_helper.py place ZONE [SIZE] | cycle ZONE | "
            "cycle-all next|previous | workspace-step next|previous | "
            "move-step next|previous"
        )
    action, zone = sys.argv[1:3]
    if zone not in ZONES:
        raise SystemExit(f"unknown zone: {zone}")
    if action == "place":
        size_arg = sys.argv[3] if len(sys.argv) == 4 else None
        if size_arg not in {None, "70", "90"}:
            raise SystemExit("placement SIZE must be 70 or 90")
        size_override = int(size_arg) if size_arg is not None else None
        place(zone, size_override)
    elif len(sys.argv) == 3:
        cycle(zone)
    else:
        raise SystemExit("cycle does not accept a SIZE")


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"zone_helper.py: {error}", file=sys.stderr)
        raise SystemExit(1)
