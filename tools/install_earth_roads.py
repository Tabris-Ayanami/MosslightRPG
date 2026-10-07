"""Update only saved road references, without reserializing the terrain or foliage.

Run bake_earth_roads.gd first. Removes old road resources only when unreferenced.
"""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[1]
SCENE = ROOT / "scenes/reference_map.tscn"
WORK = ROOT / ".work/roads"

def blocks(text):
    starts = [m.start() for m in re.finditer(r"(?m)^\[(?:ext_resource|sub_resource|node|connection)\b", text)]
    starts.append(len(text))
    return text[:starts[0]], [text[a:b] for a, b in zip(starts, starts[1:])]

def node_path(block):
    line = block.splitlines()[0]
    if not line.startswith("[node "): return None
    name = re.search(r'name="([^"]+)"', line)[1]
    parent = re.search(r'parent="([^"]+)"', line)
    return (parent[1] + "/" if parent and parent[1] != "." else "") + name

def main():
    old = SCENE.read_text(encoding="utf-8")
    if "metadata/earth_roads_version = 1" in old:
        print("EARTH_ROADS_ALREADY_INSTALLED")
        return
    header, original = blocks(old)
    changed = []
    unused = set()
    layout = json.loads((ROOT / "assets/roads/layout.json").read_text(encoding="utf-8"))
    roads = {entry["node"]: (i, entry) for i, entry in enumerate(layout["roads"])}
    additions = [
        '[ext_resource type="Material" path="res://assets/roads/earth.tres" id="road_soil"]\n\n',
        '[ext_resource type="Material" path="res://assets/roads/plaza_earth.tres" id="road_plaza"]\n\n',
        '[ext_resource type="PackedScene" path="res://assets/roads/flagstones.tscn" id="road_flags"]\n\n',
    ]
    for i, entry in enumerate(layout["roads"]):
        additions.append(f'[ext_resource type="ArrayMesh" path="{entry["mesh"]}" id="road_mesh_{i}"]\n\n')
    output = []
    for block in original:
        path = node_path(block)
        next_block = block
        if path in roads:
            i, entry = roads[path]
            for property, resource in [("mesh", f"road_mesh_{i}"), ("material_override", "road_soil")]:
                pattern = rf'(?m)^{property} = SubResource\("([^"]+)"\)$'
                match = re.search(pattern, next_block)
                assert match, (path, property)
                unused.add(match[1])
                next_block = re.sub(pattern, f'{property} = ExtResource("{resource}")', next_block, count=1)
        elif path == layout["plaza"]:
            match = re.search(r'material_override = SubResource\("([^"]+)"\)', next_block)
            assert match
            unused.add(match[1])
            next_block = next_block.replace(match[0], 'material_override = ExtResource("road_plaza")')
            next_block = next_block.rstrip() + '\nmetadata/footstep_surface = &"dirt"\n\n'
        elif path and 'parent=' not in block.splitlines()[0]:
            next_block = next_block.rstrip() + '\nmetadata/earth_roads_version = 1\n\n'
        if next_block != block: changed.append(path)
        output.append(next_block)
    assert len(changed) == 11, changed
    assembled = "".join(output)
    # Remove only the now-unreferenced mesh/material blocks replaced above.
    output = [b for b in output if not any(
        re.match(rf'\[sub_resource [^\n]*id="{re.escape(key)}"\]', b)
        and f'SubResource("{key}")' not in assembled for key in unused)]
    root_flags = '[node name="RoadFlagstones" parent="." instance=ExtResource("road_flags")]\n'
    insert_at = next(i for i, b in enumerate(output) if not b.startswith('[ext_resource '))
    output[insert_at:insert_at] = additions
    result = header + "".join(output) + "\n" + root_flags
    # Every untouched resource/node block, including MultiMesh buffers, stays exact.
    for block in original:
        path = node_path(block)
        if path in changed: continue
        if block.startswith('[sub_resource ') and any(f'id="{key}"]' in block.splitlines()[0] for key in unused): continue
        assert block in result, block[:180]
    SCENE.write_text(result, encoding="utf-8", newline="\n")
    report = {"changed_nodes": changed, "flagstones": layout["flagstones"],
              "removed_unreferenced_resources": len(original) + len(additions) - len(output),
              "unrelated_blocks_identical": True, "scene_sha256": hashlib.sha256(SCENE.read_bytes()).hexdigest()}
    (WORK / "preservation.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))

if __name__ == "__main__": main()
