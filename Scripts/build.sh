#!/bin/bash
# Build the bridge and its dependencies with the toolchain's default engine.
# --all retains SwiftPM's full product build; explicit selections pass through.
set -euo pipefail
args=()
selected=false
configuration=debug
previous=""
custom_batch=false
informational=false
for argument in "$@"; do
    if [ "$previous" = -c ] || [ "$previous" = --configuration ]; then configuration="$argument"; fi
    case "$argument" in
        --configuration=*|-c=*) configuration="${argument#*=}" ;;
        -driver-batch-count*|-driver-batch-size-limit*|-disable-batch-mode|-enable-batch-mode|-whole-module-optimization|-wmo)
            custom_batch=true ;;
        --help|-h|--version) informational=true ;;
    esac
    previous="$argument"
    case "$argument" in
        --all) selected=true ;;
        --product|--product=*|--target|--target=*|--build-tests|--show-bin-path|--help|-h|--version)
            selected=true
            args+=("$argument") ;;
        *) args+=("$argument") ;;
    esac
done
if ! "$selected"; then args=(--product homeswift ${args[@]+"${args[@]}"}); fi
# Fewer batches reduce repeated frontend work in clean macOS debug builds.
# Keep release/Linux settings and explicit compiler batching choices untouched.
# Set HOMESWIFT_BUILD_BATCHES=0 to use the toolchain's automatic partitioning.
if [ "$(uname)" = Darwin ] && [ "$configuration" = debug ] && ! "$custom_batch" && ! "$informational"; then
    batches="${HOMESWIFT_BUILD_BATCHES:-2}"
    if ! [[ "$batches" =~ ^[0-9]+$ ]]; then
        echo "HOMESWIFT_BUILD_BATCHES must be a nonnegative integer (0 uses the toolchain default)" >&2
        exit 2
    fi
    if [ "$batches" != 0 ]; then args+=(-Xswiftc -driver-batch-count -Xswiftc "$batches"); fi
fi
exec swift build ${args[@]+"${args[@]}"}
