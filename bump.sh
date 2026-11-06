#!/bin/sh
# Increments the plug-in revision (0.3.4 -> 0.3.5) in Info.lua and FLPrefs.lua
# so a reload in Lightroom is visible: the version shows in the passing
# message and in the Settings window title. Run after every change set.
set -e
cd "$(dirname "$0")/frameline.lrplugin"
cur=$(perl -ne 'print "$1.$2.$3" if /VERSION = \{ major = (\d+), minor = (\d+), revision = (\d+) \}/' Info.lua)
major=${cur%%.*}; rest=${cur#*.}; minor=${rest%%.*}; rev=${rest#*.}
rev=$((rev + 1))
new="$major.$minor.$rev"
perl -pi -e "s/VERSION = \{ major = \d+, minor = \d+, revision = \d+ \}/VERSION = { major = $major, minor = $minor, revision = $rev }/" Info.lua
perl -pi -e "s/^M\.version = '[^']*'/M.version = '$new'/" FLPrefs.lua
echo "Frameline $new"
