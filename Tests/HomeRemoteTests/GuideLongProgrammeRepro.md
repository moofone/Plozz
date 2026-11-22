# tvOS guide: oversized programme repro

This extends the existing `PlozzFocusHost` guide fixture, without changing app code.
`--guide-navigation-fixture --guide-long-programme` enables the new data; the
original fixture and its vertical, Now, and extended-timeline tests are unchanged.
Channel 2 has a 4½-hour listing (`Future 2.1`, 2¼ timeline viewports) followed by
`Future 2.2` (30 minutes). Channels 1 and 3 have ordinary listings throughout.
The fixture uses a fixed clock and no provider or playback.

## Rerun (from the worktree root)

Use an owned 1080p Apple TV simulator, not `booted` or a physical device. The
`sim-id` file is created only once per worktree; do not reuse it concurrently.
This runs all four guide remote tests; to run only the oversized scenario,
append `/testLongProgrammeScrollsOneViewportAtATime` to the `-only-testing` value.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
mkdir -p .build/guide-long-scroll
tools/with-apple-build-lease.sh plozz/guide-long-scroll -- bash <<'LANE'
set -euo pipefail
root="$PWD/.build/guide-long-scroll"
run=$(mktemp -d "$root/Run-XXXXXXXX")
echo "Evidence: $run"
source tools/lib/swift-package-storage.sh
configure_plozz_package_resolution "$root/packages"
if [[ ! -s "$root/sim-id" ]]; then
  python3 tools/run-bounded.py 30 'create guide simulator' -- xcrun simctl create \
    Plozz-Guide-Long-Scroll com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-4th-generation-1080p \
    com.apple.CoreSimulator.SimRuntime.tvOS-27-2 > "$root/sim-id"
fi
sim=$(< "$root/sim-id")
args=(-project Plozz.xcodeproj -scheme PlozzHomeFixtureTests
      -destination "platform=tvOS Simulator,id=$sim" -derivedDataPath "$root/derived"
      "${PACKAGE_RESOLUTION_ARGS[@]}" -parallel-testing-enabled NO
      SWIFT_OPTIMIZATION_LEVEL=-O CODE_SIGNING_ALLOWED=NO)
python3 tools/run-bounded.py 60 'guide project generation' -- tools/generate-project.sh \
  > "$run/generate.log" 2>&1
python3 tools/run-bounded.py 900 'guide fixture build' -- xcodebuild build-for-testing "${args[@]}" \
  -resultBundlePath "$run/Build.xcresult" > "$run/build.log" 2>&1
recorder=
cleanup() {
  if [[ -n "$recorder" ]]; then
    kill -INT "$recorder" 2>/dev/null || true
    for _ in {1..20}; do kill -0 "$recorder" 2>/dev/null || break; sleep 0.25; done
    kill -TERM "$recorder" 2>/dev/null || true
    for _ in {1..8}; do kill -0 "$recorder" 2>/dev/null || break; sleep 0.25; done
    kill -KILL "$recorder" 2>/dev/null || true
    wait "$recorder" || true
  fi
  python3 tools/run-bounded.py 30 'guide simulator shutdown' -- xcrun simctl shutdown "$sim"
}
trap cleanup EXIT
python3 tools/run-bounded.py 180 'guide simulator startup' -- xcrun simctl bootstatus "$sim" -b \
  > "$run/boot.log" 2>&1
xcrun simctl io "$sim" recordVideo --codec=h264 "$run/guide.mp4" > "$run/video.log" 2>&1 &
recorder=$!
status=0
python3 tools/run-bounded.py 240 'guide remote tests' -- xcodebuild test-without-building "${args[@]}" \
  -only-testing:PlozzHomeRemoteTests/GuideVerticalNavigationRemoteTests \
  -collect-test-diagnostics never -resultBundlePath "$run/Test.xcresult" \
  > "$run/test.log" 2>&1 || status=$?
python3 tools/run-bounded.py 30 'guide test summary' -- xcrun xcresulttool get test-results summary \
  --path "$run/Test.xcresult" > "$run/summary.json"
exit "$status"
LANE
```

## Read the replay

From `Current 0`, press Down twice, Right once onto the oversized programme,
then Right once from inside it. Continue Right one press at a time until the
next programme is focused (bounded in the test), then reverse with Left twice.
Keep the guide in its normal left-to-right, default-motion configuration.
Look at the ruler and adjacent rows as well as the wide card: the guide should
advance through the listing without abandoning it early, and should not jump
more than a viewport per press in either direction.

`GUIDE_LONG` in `test.log` and the `guide-long-programme-trace` attachment show
selection (the browser's confirmed-focus binding), settled timeline offset and
viewport width in points. These are not per-frame position samples. The test
reads them after an explicit settle delay and records the replay before checking
the desired behavior. The XCTest presses are taps with automation and snapshot
overhead, not a held Siri Remote button, and the timestamps are caller-side.

## Baseline evidence

`669783d95`, optimized Debug (`-O`), Xcode 27.2 (27B52), tvOS 27.2
(24K150), Apple TV 4K (4th generation) 1080p simulator. Build succeeded.
The fixture viewport was 1,508 points. This was one recorded run:

| Input | Confirmed-focus title after the tap | Settled offset | Delta |
| --- | --- | ---: | ---: |
| Down, Down | `Current 1`, then `Current 2` | 0 pt | 0 pt |
| Right onto long listing | `Future 2.1` | 124 pt | +124 pt |
| Right again | `Future 2.2` | 124 pt | 0 pt |
| Left (reverse) | `Future 2.1` | 124 pt | 0 pt |
| Left again | `Current 2` | 2,015 pt | **+1,891 pt** |

The second Right already selected the successor, so the bounded forward loop
needed no additional taps. It skipped the interior **according to the settled
samples**. The second Left advanced the reported offset by 1.25 viewports in
the wrong direction. The new test is red on both behaviors. Of the existing
checks, the extended-timeline test passed; the native/Now test and vertical
browsing test both failed at their first Down (`Expected Current 1`). Those two
tests ran on the original fixture configuration; there was no separate clean
checkout run or retry to attribute their failures.

Artifacts are local to `.build/guide-long-scroll/Run-hDxIknt7/`: `test.log`,
`summary.json`, `Test.xcresult` (including the step trace and existing focus
failure hierarchies), `Build.xcresult`, and `guide.mp4`. Extract recorder frame
intervals (PTS, milliseconds) without resampling:

```bash
run=.build/guide-long-scroll/Run-hDxIknt7
python3 tools/run-bounded.py 45 'guide video timestamps' -- ffprobe -v error \
  -select_streams v:0 -show_frames -show_entries frame=best_effort_timestamp_time \
  -of csv=p=0 "$run/guide.mp4" \
  | awk -F, '$1 ~ /^[0-9]+[.][0-9]+$/ {if (n++) printf "%.6f,%.3f\n", $1, 1000*($1-p); p=$1}' \
  > "$run/frame-intervals.csv"
```

Use the ruler and top focus/offset probes in the capture to identify the
motion windows; do not aggregate startup/idle with motion. The recorder finished,
but frame intervals were not extracted in this run (the command runner stopped
accepting commands after the replay). Settled samples establish focus/offset
mismatch, not the intermediate motion curve or the rate of compositor hitches.
Video timestamps reflect recorder output and may include capture artifacts;
no presented-frame metric, physical remote, real IPTV, or hardware validation
was collected.
