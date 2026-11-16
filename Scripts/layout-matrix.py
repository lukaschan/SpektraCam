#!/usr/bin/env python3
"""Run the adaptive layout tests on every display class the app supports.

Layout follows the size of the space, never the device, so a change is only verified once it
has run on a phone, a tablet and iPhone Duo. Boot the simulators first; unfold the Duo in
Xcode's Device Hub to cover its inner display. Screenshots go to --shots/<device>/.
"""
import argparse, json, os, pathlib, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENV = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
CLASSES = {"phone": "iPhone 1", "duo": "iPhone Duo", "tablet": "iPad"}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--photo", help="A non-square host image the tests import.")
parser.add_argument("--shots", default="/tmp/spektracam-layout", help="Host directory for screenshots.")
parser.add_argument("--camera-only", action="store_true", help="Run the self-contained camera/rendering round trips.")
args = parser.parse_args()
if not args.camera_only and not args.photo:
    parser.error("--photo is required unless --camera-only is selected")

listing = subprocess.run([ENV["DEVELOPER_DIR"] + "/usr/bin/simctl", "list", "devices", "booted", "--json"],
                         env=ENV, text=True, capture_output=True, check=True)
booted = [d for group in json.loads(listing.stdout)["devices"].values() for d in group if d["state"] == "Booted"]
failed = False
for label, prefix in CLASSES.items():
    device = next((d for d in booted if d["name"].startswith(prefix) or (label == "phone" and "iPhone" in d["name"] and "Duo" not in d["name"]) or (label == "phone" and "UI Checks" in d["name"])), None)
    if device is None:
        print(f"SKIPPED {label}: boot a matching Simulator")
        failed = True
        continue
    shots = pathlib.Path(args.shots) / label
    shots.mkdir(parents=True, exist_ok=True)
    env = dict(ENV, TEST_RUNNER_SPEKTRACAM_LAYOUT_SHOTS=str(shots))
    if args.photo: env["TEST_RUNNER_SPEKTRACAM_LAYOUT_PHOTO"] = args.photo
    suites = ["-only-testing:SpektraCamUITests/CameraLifecycleTests"]
    if not args.camera_only: suites.append("-only-testing:SpektraCamUITests/AdaptiveLayoutTests")
    result = subprocess.run(
        [ENV["DEVELOPER_DIR"] + "/usr/bin/xcodebuild", "-project", str(ROOT / "SpektraCam.xcodeproj"), "-scheme", "SpektraCam",
         "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "id=" + device["udid"],
         "-derivedDataPath", "/private/tmp/spektrafilm-build", "CODE_SIGNING_ALLOWED=NO", "-parallel-testing-enabled", "NO",
         "-resultBundlePath", str(shots / (str(time.time_ns()) + ".xcresult")),
         *suites, "test"],
        env=env, text=True, capture_output=True)
    (shots / "build-and-test.log").write_text(result.stdout + result.stderr)
    lines = [l.split("AdaptiveLayoutTests ")[-1] for l in result.stdout.splitlines() if "Test Case" in l and ("passed" in l or "failed" in l or "skipped" in l)]
    print(f"{label} ({device['name']}):", *lines, sep="\n  ")
    if result.returncode:
        print("\n".join((result.stdout + result.stderr).splitlines()[-25:]))
    failed = failed or result.returncode != 0
sys.exit(1 if failed else 0)
