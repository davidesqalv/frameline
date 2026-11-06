# Developing Frameline

## Build

Needs only Xcode Command Line Tools (`swiftc`).

```sh
./build.sh
```

## Test the detector on your own scans

The repository doesn't ship any scans, so the test runs on yours. Export a
few from Lightroom as JPEG (any size) into a folder, then:

```sh
./test.sh
```

It asks for the folder; type its path or drag it into the Terminal window.
To skip the question, give the folder as an argument
(`./test.sh ~/Desktop/scans`), or keep your scans in a `test-scans/`
folder in the repository, which is used without asking and which git
ignores. Scans can sit directly in the folder or in subfolders
(`converted/`, `unconverted/`, ...); each folder is run as its own batch,
since the detector uses the other photos in a batch to fill in edges it
can't see. Your photos are not changed.

Why bother: the detector is a pile of rules, and most of them exist because
one real scan broke the rule before it (see
[how-it-works.md](how-it-works.md)). A change that fixes one scan can
quietly move the crop on another, so run it on a varied set (negatives,
positives, dark and bright frames, a tilted one) before and after a change
and compare.

For each folder it prints one line per image
(`name,left,top,right,bottom,status,sides,angle,avail,film`; margins are 0-1
fractions measured inward from each edge; status is `ok`, `check` or `skip`;
sides says how each edge was found, e.g. `run/run/inferred/run`; angle is
the frame tilt in degrees, clockwise on screen positive (0 when the four
sides disagree); avail is the clean border available outside each edge,
L/T/R/B; film is how far the film itself goes on outside each edge, sprocket
holes and all), writes `results.csv` next to the images, and opens
`_frameline_previews/` inside your folder, which holds, per folder:

- `NAME.jpg`: the scan with the crop drawn on it (green box, border dimmed;
  a red frame means skipped; a blue box is the film-borders rectangle,
  drawn when `--borders 1.125` is given and the film goes that far)
- `NAME_corners.jpg`: the four crop corners at 100% with the crop lines
  through them, to judge placement to the pixel

The `--debug` lines list, per side, the uniform runs found walking in from
the rim (`level[start..end]`, `+` = still running at the limit, `|` = ended
by a strong edge line), which run was taken, and how the edge was placed.
Arguments after the folder go to the helper:
`./test.sh ~/Desktop/scans --inset 0.005`.

## Tuning

All tunables are helper flags, so you can iterate without rebuilding:

| flag | default | meaning |
|---|---|---|
| `--inset` | -0.005 | crop offset from the detected frame edge, as a fraction of the image: negative shows that much border, positive cuts inside (the future tighter/looser slider) |
| `--aspect` | 1.5 | frame aspect used for geometry; 0 disables inference |
| `--tol` | 14 | luminance tolerance for a line to count as uniform |
| `--level-tol` | 15 | how close a run's tone must be to the border tone |
| `--max-border` | 0.18 | give up on a side whose border run is wider than this |
| `--border-start` | 0.10 | the border run must begin within this outer fraction |
| `--percentile` | 95 | gradient percentile that defines edge pixels |
| `--min-area` | 0.30 | reject crops keeping less than this fraction of the image |
| `--corners` | | also write the corner sheets |
| `--dump` | | print per-line median / uniformity / edge fraction for every side |

Once a setting works, make it the default in `detect/main.swift` (`Params`)
and run `./build.sh`; the plugin calls the helper with defaults.

## Synthetic test

`tools/synth.swift` renders seven scans with known margins:

```sh
swiftc -O tools/synth.swift -o /tmp/synth && /tmp/synth /tmp/synthetic
./frameline.lrplugin/frameline-detect /tmp/synthetic --preview --debug
cat /tmp/synthetic/expected.csv
```

## How the plug-in calls the helper

The plug-in asks the helper for raw edges (`--inset 0`) and applies the crop edge itself (`FLFrame.cropFor`), storing the edges on each photo so the review window can move the crop without detecting again. After editing the plug-in, run `./bump.sh` so the new version number shows in Lightroom, and reload it from Plug-in Manager (new files need a full Lightroom restart).

## Diagnosing a run inside Lightroom

Every run leaves its working folder behind: `frameline_run_<stamp>/` inside
Lightroom's temp folder (your user's `$TMPDIR`, somewhere under
`/var/folders/`; folders older than a day are removed at the next run),
holding the previews it analysed (`0001.jpg`, ...), `results.csv`, and
`frameline.log`, which records what happened to each photo (thumbnail
received, exported instead, or why neither worked). The helper's `--debug`
output goes to `~/Library/Application Support/Adobe/Lightroom/lrc_console.log`.
Running the helper by hand on that folder reproduces exactly what the plugin
saw:

```sh
./frameline.lrplugin/frameline-detect "$(ls -td "$TMPDIR"frameline_run_* | head -1)" --preview --corners --debug
```

## README images

`tools/hero.swift` renders `docs/hero.jpg` and `docs/budapest.jpg` from a scan and its detected edges, with the crop the plug-in would apply by default. Usage is in the file header.

`tools/stages.sh <scan.jpg>` renders the two pipeline strips in the README's "How it works" (`docs/pipeline-1.jpg`, `docs/pipeline-2.jpg`). It compiles `tools/stages.swift` together with the detector's own code (`detect/main.swift` without its command-line part), so the pictures always show what the detector really does. Re-run it after changing the detector if the README's numbers might have moved.
