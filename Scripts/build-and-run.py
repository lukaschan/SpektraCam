#!/usr/bin/env python3
"""Build/run the one app; --ui-tests runs native editor checks on the booted Simulator."""
import json, os, subprocess, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
OUTPUT = Path("/private/tmp/spektrafilm-build")
OUTPUT.mkdir(exist_ok=True)
ENV = os.environ.copy()
ENV["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
SIM = ENV["DEVELOPER_DIR"] + "/usr/bin/simctl"
result = subprocess.run([SIM, "list", "devices", "available", "--json"], env=ENV, text=True, capture_output=True, check=True)
devices = [device for group in json.loads(result.stdout)["devices"].values() for device in group if device["state"] == "Booted"]
requested_simulator = os.environ.get("SPEKTRACAM_SIMULATOR_ID")
if requested_simulator:
    devices = [device for device in devices if device["udid"] == requested_simulator]
    if not devices: raise SystemExit("The selected Simulator is not booted.")
ui_tests = "--ui-tests" in sys.argv
if ui_tests and not devices:
    raise SystemExit("Boot a Simulator before running UI checks.")
scheme = "SpektraCam"
destination = "id=" + devices[0]["udid"] if devices else "generic/platform=iOS Simulator"
args = [ENV["DEVELOPER_DIR"] + "/usr/bin/xcodebuild", "-project", str(ROOT / "SpektraCam.xcodeproj"), "-scheme", scheme, "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", destination, "-derivedDataPath", str(OUTPUT), "CODE_SIGNING_ALLOWED=NO"]
if ui_tests:
    args += ["-parallel-testing-enabled", "NO", "-resultBundlePath", str(OUTPUT / ("editor-checks-" + str(time.time_ns()) + ".xcresult")), "test"]
else:
    args += ["build"]
log_path = OUTPUT / ("ui-checks.log" if ui_tests else "build.log")
with log_path.open("w") as log:
    result = subprocess.run(args, env=ENV, stdout=log, stderr=subprocess.STDOUT)
lines = log_path.read_text().splitlines()
print("\n".join(line for line in lines if ": error:" in line or ": warning:" in line or "** BUILD" in line or "** TEST" in line or line.startswith("Test Case ")), flush=True)
if result.returncode:
    print("\n".join(lines[-25:]))
    sys.exit(result.returncode)
if "--run" in sys.argv and not ui_tests:
    if not devices:
        raise SystemExit("No simulator is booted; build succeeded.")
    device = devices[0]["udid"]
    app = OUTPUT / "Build/Products/Debug-iphonesimulator/SpektraCam.app"
    subprocess.run([SIM, "install", device, str(app)], env=ENV, check=True)
    subprocess.run([SIM, "launch", "--terminate-running-process", device, "io.github.runzeni.spektracam"], env=ENV, check=True)
