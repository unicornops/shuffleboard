#!/usr/bin/env bash
# Runs the end-to-end tests against the server from start-server.sh (macOS, Xcode).
#
#   scripts/e2e/test.sh api          DeckAPI, AppState and the Shortcuts actions against the server (ShuffleboardTests/Server*)
#   scripts/e2e/test.sh ui           the UI tests (ShuffleboardUITests), needs seed.sh's demo data
#   scripts/e2e/test.sh screenshots  only the README screenshots, then saves them to docs/screenshots
#
# Results go to build/<kind>.xcresult. Extra arguments are passed on to xcodebuild.
set -euo pipefail

KIND="${1:?usage: $0 api|ui|screenshots [xcodebuild arguments]}"
shift
E2E_DIR="${E2E_DIR:-build/e2e}"
[ -f "$E2E_DIR/env" ] || {
    echo "No $E2E_DIR/env: run scripts/e2e/start-server.sh first" >&2
    exit 1
}

# xcodebuild passes TEST_RUNNER_<NAME> on to the tests as <NAME>.
while IFS='=' read -r name value; do
    [ -n "$name" ] && export "TEST_RUNNER_$name=$value"
done <"$E2E_DIR/env"

# UI tests that fail are run again, up to three times in all (#197): now and then, on GitHub's macOS runners, a
# card's sheet starts opening and never shows. A test that only passed on another try is reported as a warning.
retries=()
case "$KIND" in
    api) scheme=Shuffleboard filters=(-only-testing:ShuffleboardTests/ServerDeckAPITests -only-testing:ShuffleboardTests/ServerAppStateTests -only-testing:ShuffleboardTests/ServerShortcutTests) ;;
    ui)
        scheme=ShuffleboardUITests filters=(-skip-testing:ShuffleboardUITests/ScreenshotTests)
        retries=(-retry-tests-on-failure -test-iterations 3)
        ;;
    screenshots)
        scheme=ShuffleboardUITests filters=(-only-testing:ShuffleboardUITests/ScreenshotTests)
        retries=(-retry-tests-on-failure -test-iterations 3)
        export TEST_RUNNER_E2E_SCREENSHOTS=1
        ;;
    *)
        echo "Unknown test kind: $KIND" >&2
        exit 1
        ;;
esac

project=(-project Shuffleboard.xcodeproj -scheme "$scheme" -derivedDataPath build/E2EDerivedData)

# Fetch the Swift packages first, trying again if GitHub times out (Sparkle's binary comes from its releases), so a
# download error isn't mistaken for a failing test (#197).
for attempt in 1 2 3; do
    xcodebuild "${project[@]}" -resolvePackageDependencies && break
    [ "$attempt" = 3 ] && exit 1
    echo "warning: couldn't fetch the Swift packages (try $attempt of 3)" >&2
    sleep $((attempt * 15))
done

result="build/$KIND.xcresult"
log="build/$KIND.log"
retried="build/$KIND-retried.txt"
rm -rf "$result" "$retried"
mkdir -p build
# Ad-hoc signed, as in PR validation: the tests run the app, and UI tests a runner app too. A test that hangs fails
# after five minutes (the longest take under a minute), with a report, rather than using up the job's time.
xcodebuild \
    "${project[@]}" \
    -destination 'platform=macOS' \
    -resultBundlePath "$result" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 300 \
    ${retries[@]+"${retries[@]}"} \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    "${filters[@]}" \
    "$@" \
    test 2>&1 | tee "$log"

# Everything passed in the end; name the tests that needed another try, so a test that starts failing for real
# doesn't go unnoticed. build/<kind>-retried.txt lists them, and tells the workflow to keep the test results.
# A test that hung is reported as having "exceeded execution time allowance" rather than "failed".
{ grep -oE "Test Case '-\[[^]]+\]' (failed|exceeded execution time allowance)" "$log" || true; } |
    sed -E "s/Test Case '-\[([^]]+)\]' .*/\1/" | sort -u >"$retried"
if [ -s "$retried" ]; then
    while read -r test; do
        echo "warning: $test failed, then passed when run again" >&2
        if [ -n "${GITHUB_ACTIONS:-}" ]; then
            echo "::warning::$test failed, then passed when run again; see $result in the job's artifacts"
        fi
    done <"$retried"
else
    rm "$retried"
fi

if [ "$KIND" = screenshots ]; then
    "$(dirname "$0")/export-screenshots.sh" "$result" docs/screenshots
fi
