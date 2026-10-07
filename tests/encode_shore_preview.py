"""Encode actual fixed-60 Hz GPU frames sampled every two ticks. No game assets."""
from pathlib import Path
import json
from PIL import Image, ImageDraw

project = Path(__file__).resolve().parents[1]
output = project / "docs" / "traversal"
traces = json.loads((output / "continuous_render_trace.json").read_text(encoding="utf-8"))
metadata = []
for label, data in traces.items():
    if not data["frames_directory"]:
        continue
    sources = sorted(Path(data["frames_directory"]).glob("frame_*.png"))
    points = [row["foot_screen"] for row in data["rows"]]
    center_x = int(sum(point[0] for point in points) / len(points))
    bottom = min(1080, int(max(point[1] for point in points)) + 85)
    top = max(0, int(min(point[1] for point in points)) - 330)
    rect = (center_x - 340, top, center_x + 340, bottom)
    frames = []
    for source in sources:
        with Image.open(source) as image:
            frames.append(image.convert("RGB").crop(rect))
    duration = [30 if i % 3 != 2 else 40 for i in range(len(frames))]
    target = output / f"continuous_{label}_preview.gif"
    frames[0].save(target, save_all=True, append_images=frames[1:], duration=duration,
                   loop=0, optimize=False, disposal=2)
    # Six actual consecutive-time samples make pose/terrain contact inspectable.
    w, h = frames[0].size
    sheet = Image.new("RGB", (w * 3, (h + 24) * 2), "#122124")
    draw = ImageDraw.Draw(sheet)
    chosen = [round(i * (len(frames) - 1) / 5) for i in range(6)]
    for i, index in enumerate(chosen):
        x, y = (i % 3) * w, (i // 3) * (h + 24)
        sheet.paste(frames[index], (x, y + 24))
        draw.text((x + 10, y + 4), f"{label}  {index * 2 / 60:.2f}s", fill="white")
    sheet.save(output / f"continuous_{label}_sequence.png")
    result = {"file": target.name, "frames": len(frames), "duration_ms": sum(duration),
              "crop_from_1920x1080": rect, "bytes": target.stat().st_size}
    metadata.append(result)
    print(json.dumps(result))
(output / "continuous_preview_metadata.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
