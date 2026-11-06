#!/bin/sh
# Renders the pipeline pictures in the README (docs/pipeline-1.jpg and
# docs/pipeline-2.jpg) from one scan, using the detector's own code:
# detect/main.swift without its command-line part, compiled together with
# tools/stages.swift.
#
#   tools/stages.sh <scan.jpg> [outdir]     (outdir defaults to docs)
#
# The README's pictures come from the tulip scan DSC09488 (the author's own,
# not in the repository).
set -e
cd "$(dirname "$0")/.."
scan="$1"
out="${2:-docs}"
if [ ! -f "$scan" ]; then
    echo "usage: tools/stages.sh <scan.jpg> [outdir]" >&2
    exit 1
fi
build=$(mktemp -d "${TMPDIR:-/tmp}/frameline-stages.XXXXXX")
# everything above the detector's command-line part
sed '/^var argv = Array(CommandLine.arguments.dropFirst())/,$d' detect/main.swift > "$build/detector.swift"
cp tools/stages.swift "$build/main.swift"
swiftc -O "$build/detector.swift" "$build/main.swift" -o "$build/stages"
"$build/stages" "$scan" "$build"
mkdir -p "$out"
for n in pipeline-1 pipeline-2; do
    sips -s format jpeg -s formatOptions 86 "$build/$n.png" --out "$out/$n.jpg" >/dev/null
done
rm -r "$build"
echo "wrote $out/pipeline-1.jpg and $out/pipeline-2.jpg"
