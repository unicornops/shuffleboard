#!/usr/bin/env bash
# Runs the end-to-end tests against the server from start-server.sh (macOS, Xcode).
#
#   scripts/e2e/test.sh api          DeckAPI, AppState and the Shortcuts actions against the server (ShuffleboardTests/Server*)
#   scripts/e2e/test.sh ui           the UI tests (ShuffleboardUITests), needs seed.sh's demo data
#   scripts/e2e/test.sh screenshots  only the README screenshots, then saves them to docs/screenshots (or E2E_SCREENSHOTS_DIR)
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

# The Swift packages go to build/SourcePackages, which the workflows cache (#203). git does the fetching
# (-scmProvider system), not Xcode's own client, so it uses the credentials the workflow gives it in git's config.
project=(-project Shuffleboard.xcodeproj -scheme "$scheme" -derivedDataPath build/E2EDerivedData
    -clonedSourcePackagesDirPath build/SourcePackages -scmProvider system)

# A warning, which on GitHub Actions is also an annotation on the run, so a download that only worked on another try
# still shows up (#203).
warn() {
    echo "warning: $*" >&2
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning::$*"
    fi
}

# git traces its HTTP requests and responses (headers only) to $git_trace. After a failed try, this shows them, so a
# refusal (#203: a 403 on every try) tells whether GitHub was rate limiting. git leaves out the Authorization
# header's value; perl removes it too, in case.
git_trace="$PWD/build/git-trace.log"
show_git_trace() {
    if [ ! -s "$git_trace" ]; then
        echo "No git trace: git didn't make any HTTP requests"
        return
    fi
    echo "::group::git's HTTP requests and responses (headers)"
    grep -iE '(=> Send header: (GET|POST) |=> Send header: authorization:|<= Recv header: (HTTP/|x-ratelimit-|retry-after|x-github-request-id|www-authenticate))' \
        "$git_trace" | perl -pe 's/(authorization:\s*\S+\s+).*/$1<redacted>/i' || true
    echo "::endgroup::"
}

# Fetch the Swift packages first, trying again if GitHub refuses or times out (#197, #203: Sparkle's repository and
# its binary come from GitHub), waiting 30 s, 90 s and 3 minutes, so a download error isn't mistaken for a failing test.
mkdir -p build
waits=(30 90 180)
for attempt in 1 2 3 4; do
    rm -f "$git_trace"
    if GIT_TRACE_CURL="$git_trace" GIT_TRACE_CURL_NO_DATA=1 GIT_TRACE_REDACT=1 \
        xcodebuild "${project[@]}" -resolvePackageDependencies; then
        # Whether git sent the workflow's credentials, without showing them.
        requests=$(grep -cE '=> Send header: (GET|POST) ' "$git_trace" 2>/dev/null || true)
        with_credentials=$(grep -ciE '=> Send header: authorization:' "$git_trace" 2>/dev/null || true)
        echo "git made ${requests:-0} HTTP requests for the Swift packages, ${with_credentials:-0} with credentials"
        break
    fi
    show_git_trace
    [ "$attempt" = 4 ] && exit 1
    warn "couldn't fetch the Swift packages (try $attempt of 4), trying again in ${waits[attempt - 1]} s"
    sleep "${waits[attempt - 1]}"
done
rm -f "$git_trace"

result="build/$KIND.xcresult"
log="build/$KIND.log"
retried="build/$KIND-retried.txt"
rm -rf "$result" "$retried"
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
    "$(dirname "$0")/export-screenshots.sh" "$result" "${E2E_SCREENSHOTS_DIR:-docs/screenshots}"
fi
