## Manage floating-window zones, focus cycling, and numbered workspaces.
## Build: nim c -d:release zone_helper.nim

import std/[algorithm, json, math, options, os, osproc, re, streams, strutils, tables]
from std/unicode import runes

const ZONES = {
  "tl": (50, 50, 0, 0),
  "tr": (50, 50, 50, 0),
  "bl": (50, 50, 0, 50),
  "br": (50, 50, 50, 50),
  "left": (50, 100, 0, 0),
  "right": (50, 100, 50, 0),
  "top": (100, 50, 0, 0),
  "bottom": (100, 50, 0, 50),
  "center": (70, 70, 15, 15),
}.toTable

const ALIGNMENTS = {
  "tl": ("left", "top"),
  "tr": ("right", "top"),
  "bl": ("left", "bottom"),
  "br": ("right", "bottom"),
  "left": ("left", "center"),
  "right": ("right", "center"),
  "top": ("center", "top"),
  "bottom": ("center", "bottom"),
  "center": ("center", "center"),
}.toTable

const CYCLE_ZONES = {
  "tl": @["tl"],
  "tr": @["tr"],
  "bl": @["bl"],
  "br": @["br"],
  "left": @["left", "tl", "bl"],
  "right": @["right", "tr", "br"],
  "top": @["top", "tl", "tr"],
  "bottom": @["bottom", "bl", "br"],
  "center": @["center"],
}.toTable

type Entry = tuple[node: JsonNode, workspace_id: Option[int]]


proc json_dumps(value: string): string =
  ## Match Python's json.dumps(str), including ensure_ascii=True.
  for rune in ($(%value)).runes:
    let code = int(rune)
    if code < 128:
      result.add(char(code))
    elif code <= 0xffff:
      result.add("\\u" & toHex(code, 4).toLowerAscii())
    else:
      let pair = code - 0x10000
      result.add("\\u" & toHex(0xd800 + (pair shr 10), 4).toLowerAscii())
      result.add("\\u" & toHex(0xdc00 + (pair and 0x3ff), 4).toLowerAscii())


proc swaymsg(command: string) =
  let process = startProcess("swaymsg", args = ["-q", command],
                             options = {poUsePath, poParentStreams})
  defer: process.close()
  let exit_code = process.waitForExit()
  if exit_code != 0:
    raise newException(IOError, "swaymsg command failed with exit status " & $exit_code)


proc get_tree(): JsonNode =
  let process = startProcess("swaymsg", args = ["-r", "-t", "get_tree"],
                             options = {poUsePath})
  defer: process.close()
  let output = process.outputStream.readAll()
  discard process.errorStream.readAll()
  let exit_code = process.waitForExit()
  if exit_code != 0:
    raise newException(IOError, "swaymsg get_tree failed with exit status " & $exit_code)
  return parseJson(output)


proc walk(node: JsonNode, workspace_id = none(int)): seq[Entry] =
  # Materialize the same preorder as Python's recursive generator.
  var workspace_id = workspace_id
  if node{"type"}.getStr() == "workspace":
    let id = node{"id"}
    workspace_id = if id.isNil or id.kind == JNull: none(int) else: some(id.getInt())
  result.add((node, workspace_id))
  for child in node{"nodes"}.getElems() & node{"floating_nodes"}.getElems():
    result.add(walk(child, workspace_id))


proc focused_context(entries: seq[Entry]): tuple[focused, workspace: JsonNode] =
  ## Return the focused node and its workspace, including focused groups.
  var workspace_id = none(int)
  for entry in entries:
    if entry.node{"focused"}.getBool() and entry.workspace_id.isSome:
      result.focused = entry.node
      workspace_id = entry.workspace_id
      break
  if result.focused.isNil:
    return
  for entry in entries:
    if entry.node{"type"}.getStr() == "workspace" and
        entry.node{"id"}.getInt() == workspace_id.get():
      result.workspace = entry.node
      break


proc is_view(node: JsonNode): bool =
  return node{"type"}.getStr() in ["con", "floating_con"] and
    node{"nodes"}.getElems().len == 0 and
    node{"floating_nodes"}.getElems().len == 0


proc active_view(node: JsonNode): JsonNode =
  ## Resolve a focused group to its most recently focused leaf window.
  if is_view(node):
    return node
  let children = node{"nodes"}.getElems() & node{"floating_nodes"}.getElems()
  var by_id = initTable[int, JsonNode]()
  for child in children:
    by_id[child{"id"}.getInt()] = child
  var ordered: seq[JsonNode] = @[]
  for con_id in node{"focus"}.getElems():
    if con_id.getInt() in by_id:
      ordered.add(by_id[con_id.getInt()])
  for child in children:
    if child notin ordered:
      ordered.add(child)
  for child in ordered:
    let view = active_view(child)
    if not view.isNil:
      return view
  return nil


proc zone_for_mark(mark: string): Option[string] =
  var matches: array[1, string]
  if mark.match(re"(*UTF8)(*UCP)_zone_([a-z]+)(?:_\d+)?\z", matches) and
      matches[0] in ZONES:
    return some(matches[0])
  return none(string)


proc preserve_window_size(node: JsonNode): bool =
  let title = node{"name"}.getStr()
  let properties = node{"window_properties"}
  let identities = [
    title,
    node{"app_id"}.getStr(),
    node{"class"}.getStr(),
    properties{"class"}.getStr(),
    properties{"instance"}.getStr(),
  ]
  var pianoteq = false
  for value in identities:
    # Include dotted/dotless I to match Python's Unicode IGNORECASE.
    if value.match(re"(*UTF8)(*UCP)(?i)^P[i\x{0130}\x{0131}]anoteq"):
      pianoteq = true
      break
  let plugin_title = title.find(re"(*UTF8)(*UCP)(?i)VST|CLAP") >= 0
  return pianoteq or plugin_title


proc aligned_position(zone: string, window_width, window_height: int,
                      workspace_rect: JsonNode): tuple[x, y: int] =
  let (horizontal, vertical) = ALIGNMENTS[zone]
  let left = workspace_rect{"x"}.getInt()
  let top = workspace_rect{"y"}.getInt()
  let right = left + workspace_rect{"width"}.getInt()
  let bottom = top + workspace_rect{"height"}.getInt()
  let x = case horizontal
    of "left": left
    of "right": right - window_width
    else: left + floorDiv(right - left - window_width, 2)
  let y = case vertical
    of "top": top
    of "bottom": bottom - window_height
    else: top + floorDiv(bottom - top - window_height, 2)
  return (x, y)


proc place(zone: string, size_override = none(int)) =
  var entries = walk(get_tree())
  var (focused, _) = focused_context(entries)
  if focused.isNil:
    return
  focused = active_view(focused)
  if focused.isNil:
    return

  let con_id = focused{"id"}.getInt()
  let mark = "_zone_" & zone & "_" & $con_id
  var command = "[con_id=" & $con_id & "] floating enable"

  if not preserve_window_size(focused):
    var width, height: int
    if size_override.isNone:
      width = ZONES[zone][0]
      height = ZONES[zone][1]
    elif zone in ["left", "right"]:
      width = size_override.get()
      height = 100
    elif zone in ["top", "bottom"]:
      width = 100
      height = size_override.get()
    else:
      width = size_override.get()
      height = size_override.get()
    command.add(", resize set width " & $width & " ppt height " & $height & " ppt")

  # Read back Sway's resolved geometry after resize, then align the actual
  # container against the usable workspace (excluding panels on any edge).
  swaymsg(command)
  let tree = get_tree()
  entries = walk(tree)
  var window_entry = none(Entry)
  for entry in entries:
    if entry.node{"id"}.getInt() == con_id and is_view(entry.node):
      window_entry = some(entry)
      break
  if window_entry.isNone:
    return
  let (window, workspace_id) = window_entry.get()
  var workspace: JsonNode = nil
  for entry in entries:
    if entry.node{"type"}.getStr() == "workspace" and
        workspace_id == some(entry.node{"id"}.getInt()):
      workspace = entry.node
      break
  if workspace.isNil:
    return
  let window_rect = window{"rect"}
  let deco_rect = window{"deco_rect"}
  let workspace_rect = workspace{"rect"}
  let window_width = window_rect{"width"}.getInt()
  # The IPC rect excludes Sway's titlebar; move position anchors its outer edge.
  let window_height = window_rect{"height"}.getInt() + deco_rect{"height"}.getInt()
  if window_width == 0 or window_height == 0 or
      workspace_rect{"width"}.getInt() == 0 or workspace_rect{"height"}.getInt() == 0:
    return
  let (x, y) = aligned_position(zone, window_width, window_height, workspace_rect)
  var commands = @["move absolute position " & $x & " px " & $y & " px"]
  for old_mark in window{"marks"}.getElems():
    if zone_for_mark(old_mark.getStr()).isSome:
      commands.add("unmark " & json_dumps(old_mark.getStr()))
  commands.add("mark --add " & mark)
  swaymsg("[con_id=" & $con_id & "] " & commands.join(", "))


proc adjacent_workspace_number(current: JsonNode, direction: string): Option[int] =
  if current.isNil or current.kind != JInt or current.getInt() notin 1..10:
    return none(int)
  let step = if direction == "previous": -1 else: 1
  return some(floorMod(current.getInt() - 1 + step, 10) + 1)


proc navigate_workspace(direction: string, move_window = false) =
  let entries = walk(get_tree())
  let (focused, workspace) = focused_context(entries)
  if workspace.isNil:
    return

  let target_number = adjacent_workspace_number(workspace{"num"}, direction)
  let sway_direction = if direction == "previous": "prev" else: "next"
  let destination = if target_number.isNone: sway_direction else: "number " & $target_number.get()
  if move_window:
    if focused{"type"}.getStr() notin ["con", "floating_con"]:
      return
    # Move a focused group as a group, just like Sway's native move command.
    swaymsg("[con_id=" & $focused{"id"}.getInt() & "] move container to workspace " & destination)
    swaymsg("[con_id=" & $focused{"id"}.getInt() & "] focus")
  else:
    swaymsg("workspace " & destination)


proc cycle_target(candidates: seq[int], focused_id, direction: int): int =
  if focused_id in candidates:
    let index = candidates.find(focused_id)
    return candidates[floorMod(index + direction, candidates.len)]
  return if direction > 0: candidates[0] else: candidates[^1]


proc cycle(zone = none(string), direction = 1) =
  let entries = walk(get_tree())
  let (focused, workspace) = focused_context(entries)
  if workspace.isNil:
    return
  let current_workspace = workspace{"id"}.getInt()
  let focused_id = focused{"id"}.getInt()
  var candidates: seq[int] = @[]
  var target: int

  if zone.isNone:
    # Keep Tab cycling all windows in its existing forward/reverse order.
    for (node, workspace_id) in entries:
      if workspace_id == some(current_workspace) and is_view(node):
        let id = node{"id"}.getInt()
        if id notin candidates:
          candidates.add(id)
    candidates.sort()
    if candidates.len == 0:
      return
    target = cycle_target(candidates, focused_id, direction)
  else:
    # Preserve the existing zone stacking order and membership rules.
    var member_marks = initTable[string, tuple[legacy, prefix: string]]()
    for member in CYCLE_ZONES[zone.get()]:
      member_marks[member] = ("_zone_" & member, "_zone_" & member & "_")
    for (node, workspace_id) in entries:
      if workspace_id != some(current_workspace) or not is_view(node):
        continue
      var matches = false
      var has_zone = false
      for mark_node in node{"marks"}.getElems():
        let mark = mark_node.getStr()
        if zone_for_mark(mark).isSome:
          has_zone = true
        for (legacy, prefix) in member_marks.values:
          if mark == legacy or mark.startsWith(prefix):
            matches = true
            break
      if matches or (zone.get() == "center" and not has_zone):
        candidates.add(node{"id"}.getInt())
    if candidates.len == 0:
      return
    # Start at the zone's topmost member. Once one is focused, raise the
    # bottommost zone member; this also raises a lone member over outsiders.
    target = if focused_id in candidates: candidates[0] else: candidates[^1]
  swaymsg("[con_id=" & $target & "] focus")


proc main() =
  let args = commandLineParams()
  if args.len == 2 and args[0] in ["workspace-step", "move-step"]:
    if args[1] notin ["previous", "next"]:
      quit("workspace direction must be previous or next", 1)
    navigate_workspace(args[1], move_window = args[0] == "move-step")
    return

  if args.len == 2 and args[0] == "cycle-all":
    let directions = {"next": 1, "previous": -1}.toTable
    if args[1] notin directions:
      quit("cycle-all direction must be next or previous", 1)
    cycle(direction = directions[args[1]])
    return

  if args.len notin [2, 3] or args[0] notin ["place", "cycle"]:
    quit("usage: zone_helper.nim place ZONE [SIZE] | cycle ZONE | " &
         "cycle-all next|previous | workspace-step next|previous | " &
         "move-step next|previous", 1)
  let (action, zone) = (args[0], args[1])
  if zone notin ZONES:
    quit("unknown zone: " & zone, 1)
  if action == "place":
    let size_arg = if args.len == 3: some(args[2]) else: none(string)
    if size_arg.isSome and size_arg.get() notin ["70", "90"]:
      quit("placement SIZE must be 70 or 90", 1)
    let size_override = if size_arg.isSome: some(parseInt(size_arg.get())) else: none(int)
    place(zone, size_override)
  elif args.len == 2:
    cycle(some(zone))
  else:
    quit("cycle does not accept a SIZE", 1)


when isMainModule:
  try:
    main()
  except OSError, IOError, JsonParsingError:
    stderr.writeLine("zone_helper.nim: " & getCurrentExceptionMsg())
    quit(1)
