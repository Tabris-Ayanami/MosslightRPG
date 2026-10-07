"""Encode the real GPU frames recorded by combat_charge_visual.gd using Pillow."""
from pathlib import Path
import argparse
from PIL import Image


project = Path(__file__).resolve().parents[1]
evidence = project / "docs" / "combat"
arguments = argparse.ArgumentParser()
arguments.add_argument("--defense", action="store_true", help="Encode the real grab / defense test sequence")
arguments.add_argument("--parry", action="store_true", help="Encode paired sword/shield and precise window input")
arguments.add_argument("--greatsword", action="store_true", help="Encode greatsword charging into its precision release")
arguments.add_argument("--dual", action="store_true", help="Encode real dual-sword two-strike input")
arguments.add_argument("--kirito-world", action="store_true", help="Encode real shared Kirito combat in main world and arena")
arguments.add_argument("--stamina", action="store_true", help="Encode the real 1080p foot-ring dodge and recovery")
options = arguments.parse_args()
kind = "stamina" if options.stamina else ("kirito_world" if options.kirito_world else ("dual" if options.dual else ("parry" if options.parry or options.greatsword else ("defense" if options.defense else "charge"))))
report = (evidence / f"{kind}_visual_test.log").read_text(encoding="utf-8")
prefix = "GreatswordVideoFrames: " if options.greatsword else "VideoFrames: "
directory = next(line.removeprefix(prefix) for line in report.splitlines() if line.startswith(prefix))
sources = sorted(Path(directory).glob("frame_*.png"))
if not sources:
    raise SystemExit("Run the GPU charge test first; its frame directory is unavailable.")
frames = []
for source in sources:
    with Image.open(source) as image:
        frames.append(image.convert("RGB"))
output_kind = "greatsword" if options.greatsword else kind
destination = evidence / f"feel_{output_kind}_preview.gif"
durations = [30 if index % 3 != 2 else 40 for index in range(len(frames))]
frames[0].save(destination, save_all=True, append_images=frames[1:],
               duration=durations, loop=0, disposal=2, optimize=True)
with Image.open(destination) as result:
    total_ms = 0
    for index in range(result.n_frames):
        result.seek(index)
        total_ms += result.info["duration"]
    sequence = "shield precision glow -> ordinary guard -> Shift changes QER -> sword and shield still work" if options.parry else ("held shield -> red grab warning -> startup -> grapple -> recovery" if options.defense else "idle -> hold -> precision window -> full without glow -> release -> recovery")
    if options.greatsword:
        sequence = "greatsword idle -> charge before window -> precision glow -> in-window release -> guarded slash -> recovery"
    if options.dual:
        sequence = "left B -> right A weapon attacks -> charge -> spin twice -> one dash and two thrusts -> mirrored skill slashes"
    if options.kirito_world:
        sequence = "main world left/right sword attack and two spins -> arena shield precision and held guard -> fujian stance and actual counter -> held dual charge and mirrored release"
    if options.stamina:
        sequence = "real combat dodge spends stamina -> empty foot point follows real recovery outline -> actual resource gain fills point -> quiet full ring"
    metadata = (f"Source: tests/combat_{kind}_visual.gd real InputEvent capture\n"
                f"Frames: {result.n_frames}\nSize: {result.width}x{result.height}\n"
                f"Duration: {total_ms} ms\nRenderer: NVIDIA GeForce RTX 4060 Laptop GPU\n"
                f"Sequence: {sequence}\n"
                f"SourceFrames: {directory}\nOutput: {destination.name}\n")
    (evidence / f"feel_{output_kind}_preview.log").write_text(metadata, encoding="utf-8")
    print(metadata)
if options.stamina:
    # Inspection crop of the same recorded pixels, with nearest-neighbour scaling.
    # Full 1080p source frames and the full-frame GIF are retained above.
    detail = [frame.crop((640, 480, 1120, 760)).resize((960, 560), Image.Resampling.NEAREST)
              for frame in frames]
    detail[0].save(evidence / "feel_stamina_detail.gif", save_all=True,
                   append_images=detail[1:], duration=durations,
                   loop=0, disposal=2, optimize=True)
    (evidence / "feel_stamina_detail.log").write_text(
        metadata.replace(f"Output: {destination.name}", "Output: feel_stamina_detail.gif")
        + "Crop: x=640,y=480,width=480,height=280; 2x nearest-neighbour inspection preview\n",
        encoding="utf-8")
