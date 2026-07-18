#!/bin/bash
# Launches the app through LaunchServices (`open`) instead of exec'ing the binary
# from a shell. photolibraryd vets connecting processes: shell-spawned ones — even
# from inside an .app bundle — can be refused with endless CoreData 4097 retries,
# while the same app launched by LaunchServices is a first-class app process.
# Terminal output is routed back here; state paths are made absolute because
# LaunchServices starts apps with cwd "/".
#
# Usage: ./Scripts/run.sh download --limit 20
set -uo pipefail
cd "$(dirname "$0")/.."

if [ ! -d SharedAlbumRescue.app ]; then
    ./Scripts/build-app.sh
fi

ARGS=("$@")
case " $* " in
    *" --state "*) ;;
    *) ARGS+=(--state "$PWD/state") ;;
esac

# `open -W` cannot reliably block on this bundle (no run loop to attach to), so we
# poll for process exit ourselves. Exit status is not propagated by `open` — treat
# a ❌ line in the output as failure, not the shell status.
wait_for_exit() {
    # First wait for the process to appear (LaunchServices spawns it asynchronously),
    # then for it to exit.
    for _ in $(seq 1 50); do
        pgrep -qf "SharedAlbumRescue.app/Contents/MacOS/shared-album-rescue" && break
        sleep 0.2
    done
    while pgrep -qf "SharedAlbumRescue.app/Contents/MacOS/shared-album-rescue"; do
        sleep 2
    done
}

# `tty` prints the literal string "not a tty" to STDOUT on failure, so test the
# file descriptor instead of trusting its output.
TTY_DEV=""
if [ -t 1 ]; then
    TTY_DEV="$(tty)"
fi
if [ -n "$TTY_DEV" ]; then
    open --stdout "$TTY_DEV" --stderr "$TTY_DEV" ./SharedAlbumRescue.app --args "${ARGS[@]}"
    wait_for_exit
else
    LOG="$(mktemp -t shared-album-rescue-out)"
    open --stdout "$LOG" --stderr "$LOG" ./SharedAlbumRescue.app --args "${ARGS[@]}"
    wait_for_exit
    cat "$LOG"
    rm -f "$LOG"
fi
