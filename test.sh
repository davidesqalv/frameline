#!/bin/sh
# Build the detector, run it on a folder of your own scans, and open
# previews with the crop drawn on each one.
#
#   ./test.sh                     asks which folder to use
#   ./test.sh ~/Desktop/scans     uses that folder
#   ./test.sh ~/scans --inset 0.005   anything after the folder goes to the detector
#
# The folder holds JPEG exports of camera scans (any size), directly or in
# subfolders (e.g. converted/, unconverted/); each folder is run as its own
# batch. Your photos are not changed: the detector writes results.csv next
# to them and the previews go to <folder>/_frameline_previews/.
# A local test-scans/ folder, if there is one, is used without asking.
set -e
cd "$(dirname "$0")"

has_jpegs() {
    find "$1" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' \) | grep -q .
}

if [ $# -gt 0 ] && [ -d "$1" ]; then
    ROOT="$1"; shift
elif [ -d test-scans ]; then
    ROOT=test-scans
elif [ -t 0 ]; then
    echo "Frameline is tested on your own scans."
    echo "Export a few from Lightroom as JPEG (any size) into a folder, then type"
    echo "its path or drag the folder into this window, and press return."
    echo "(No scans handy? docs/developing.md has a synthetic test that needs none.)"
    printf "Folder: "
    read -r ROOT
    # a dragged folder arrives with escaped spaces and maybe quotes or a trailing space
    ROOT=$(printf '%s' "$ROOT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/' -e 's/\\\(.\)/\1/g')
    case "$ROOT" in "~"/*) ROOT="$HOME/${ROOT#"~"/}" ;; "~") ROOT="$HOME" ;; esac
else
    echo "usage: ./test.sh <folder of JPEG scans> [detector flags]" >&2
    exit 1
fi

if [ ! -d "$ROOT" ]; then
    echo "No folder at: $ROOT" >&2
    exit 1
fi
ROOT=$(cd "$ROOT" && pwd)

is_previews() {
    case "$(basename "$1")" in _previews|_frameline_previews) return 0 ;; esac
    return 1
}

found=0
for dir in "$ROOT" "$ROOT"/*/; do
    dir="${dir%/}"
    is_previews "$dir" && continue
    [ -d "$dir" ] && has_jpegs "$dir" && found=1
done
if [ "$found" = 0 ]; then
    echo "No JPEGs in $ROOT or the folders directly inside it." >&2
    echo "Export some scans from Lightroom as JPEG and try again." >&2
    exit 1
fi

./build.sh

# Previews from the last run are cleared, but only from a folder this script
# made: it marks the folders it creates, and never marks one it found.
PREV="$ROOT/_frameline_previews"
if [ -f "$PREV/.frameline-previews" ]; then
    rm -rf -- "$PREV"
fi
if [ ! -d "$PREV" ]; then
    mkdir -p "$PREV"
    touch "$PREV/.frameline-previews"
fi

for dir in "$ROOT" "$ROOT"/*/; do
    dir="${dir%/}"
    name="$(basename "$dir")"
    is_previews "$dir" && continue
    [ -d "$dir" ] && has_jpegs "$dir" || continue
    echo "== $dir"
    ./frameline.lrplugin/frameline-detect "$dir" --preview "$PREV/$name" --debug --corners --borders 1.125 "$@"
    echo
done
open "$PREV"
