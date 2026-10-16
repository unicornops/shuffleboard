#!/usr/bin/env bash
# Runs the end-to-end tests against the server from start-server.sh (macOS, Xcode).
#
#   scripts/e2e/test.sh api          DeckAPI and AppState against the server (ShuffleboardTests/Server*)
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

case "$KIND" in
    api) scheme=Shuffleboard filters=(-only-testing:ShuffleboardTests/ServerDeckAPITests -only-testing:ShuffleboardTests/ServerAppStateTests) ;;
    ui) scheme=ShuffleboardUITests filters=(-skip-testing:ShuffleboardUITests/ScreenshotTests) ;;
    screenshots)
        scheme=ShuffleboardUITests filters=(-only-testing:ShuffleboardUITests/ScreenshotTests)
        export TEST_RUNNER_E2E_SCREENSHOTS=1
        ;;
    *)
        echo "Unknown test kind: $KIND" >&2
        exit 1
        ;;
esac

result="build/$KIND.xcresult"
rm -rf "$result"
# Ad-hoc signed, as in PR validation: the tests run the app, and UI tests a runner app too. A test that hangs fails
# after five minutes (the longest take under a minute), with a report, rather than using up the job's time.
xcodebuild \
    -project Shuffleboard.xcodeproj \
    -scheme "$scheme" \
    -destination 'platform=macOS' \
    -derivedDataPath build/E2EDerivedData \
    -resultBundlePath "$result" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 300 \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    "${filters[@]}" \
    "$@" \
    test

if [ "$KIND" = screenshots ]; then
    "$(dirname "$0")/export-screenshots.sh" "$result" docs/screenshots
fi
