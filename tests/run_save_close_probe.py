"""Run real separate Godot processes; never touch the player's save directory."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
GODOT = Path("F:/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe")
LOGS = ROOT / "docs" / "combat"


def main() -> int:
    checks = 0
    failures: list[str] = []
    summary: list[str] = []

    def verify(ok: bool, label: str) -> None:
        nonlocal checks
        checks += 1
        summary.append(("PASS " if ok else "FAIL ") + label)
        if not ok:
            failures.append(label)

    with tempfile.TemporaryDirectory(prefix="mosslight-close-") as temporary:
        base = Path(temporary)
        for mode in ("close", "freed"):
            directory = base / mode
            directory.mkdir()
            command = [
                str(GODOT), "--headless", "--path", str(ROOT), "--fixed-fps", "60",
                "--script", "res://tests/save_close_probe.gd", "--",
                "--mode", mode, "--directory", str(directory),
            ]
            try:
                result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=45)
            except subprocess.TimeoutExpired as error:
                verify(False, f"{mode}: child process terminates within 45 seconds")
                (LOGS / f"save_close_{mode}_stdout.log").write_bytes(error.stdout or b"")
                (LOGS / f"save_close_{mode}_stderr.log").write_bytes(error.stderr or b"")
                continue
            stdout = result.stdout.decode("utf-8", errors="replace")
            stderr = result.stderr.decode("utf-8", errors="replace")
            (LOGS / f"save_close_{mode}_stdout.log").write_text(stdout, encoding="utf-8")
            (LOGS / f"save_close_{mode}_stderr.log").write_text(stderr, encoding="utf-8")
            verify(result.returncode == 0, f"{mode}: actual Godot child exits with code 0 (got {result.returncode})")
            verify("FAIL " not in stdout + stderr and "SCRIPT ERROR" not in stdout + stderr and "ERROR:" not in stdout + stderr,
                   f"{mode}: probe has no failed assertions, script or engine errors")
            if mode == "close":
                verify("SAVE_CLOSE_DISPATCH mode=close" in stdout, "close: real PLAYING handler received the root Window close request")
                file = directory / "slot_05.json"
                verify(file.is_file(), "close: save exists after the child process has exited")
                if file.is_file():
                    envelope = json.loads(file.read_text(encoding="utf-8"))
                    payload = envelope["payload_json"]
                    verify(hashlib.sha256(payload.encode("utf-8")).hexdigest() == envelope["sha256"], "close: persisted file passes integrity checksum")
                    snapshot = json.loads(payload)
                    expected = json.loads((directory / "close_expected.json").read_text(encoding="utf-8"))
                    verify(snapshot["loadout"]["level"] == expected["level"] and snapshot["progression"]["experience"] == expected["experience"],
                           "close: latest level three and 42 XP survive full process termination")
                    verify(snapshot["inventory"]["stacks"].get("magic_candy") == expected["magic_candy"] and snapshot["inventory"]["stacks"].get("healing_potion") == expected["healing_potion"],
                           "close: latest 10 candies and 22 potions survive full process termination")
            elif mode == "freed":
                verify("SAVE_CLOSE_PROBE mode=freed" in stdout, "freed: completed auto_accept restoration assertions")
            warnings = sum(line.startswith("WARNING:") for line in stderr.splitlines())
            summary.append(f"INFO {mode}: teardown warnings={warnings}; full stderr preserved")
    summary.append(f"SAVE_CLOSE_DRIVER_RESULT checks={checks} failures={len(failures)}")
    output = "\n".join(summary) + "\n"
    print(output, end="")
    (LOGS / "save_close_probe_test.log").write_text(output, encoding="utf-8")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
