Frameline - crops camera-scanned film to the frame in Lightroom Classic
=======================================================================

Finds the film frame in each selected scan, crops to it, and straightens
it if the frame sat a little crooked. Works on negatives and positives.
The crops are ordinary Lightroom crops: press R to adjust one, or undo it.

The version you have shows in Plug-in Manager and in the title of the
Settings window. More, with pictures: https://github.com/davidesqalv/frameline

Install
-------
  1. Keep this folder (frameline.lrplugin) somewhere permanent.
     Lightroom runs the plug-in from where it is.
  2. Lightroom Classic > File > Plug-in Manager > Add > choose this folder.
  3. Restart Lightroom once so the control-F shortcut works.

  Needs a Mac with Apple Silicon. If macOS blocks frameline-detect the
  first time, run this once in Terminal (with your path):
      xattr -dr com.apple.quarantine ~/path/to/frameline.lrplugin

Use
---
  Select scans and press control-F (or File > Plug-in Extras > Frameline).
  A short message says how many were cropped.

  Unsure about one edge: the photo is cropped anyway and added to
  Collections > Frameline > Worth a look. No frame found: the photo is left
  alone and added to Frameline > Skipped.

  Select photos Frameline has cropped and press control-F again to open the
  review window. Change the crop edge or the film format and the crop moves
  while you watch. "Make this my default" keeps the choice for future runs;
  "Remove crop" takes the crop off. A mixed selection crops only the photos
  not done yet.

Crop edge
---------
  Tighter        0.6% into the picture
  Tight          0.3% into the picture
  Edge to edge   exactly on the frame edge
  Thin border    0.5% of film border (the default)
  Wide border    1.2%
  Chonk border   2.5%
  Sprockets      the frame plus the sprocket holes, cropped 9:8; needs a
                 scan that shows the whole strip

  Opposite sides get the same border, and a side never shows more border
  than the scan has there.

Settings
--------
  File > Plug-in Extras > Frameline Settings...: crop edge, straighten
  tilted frames, film format (35mm, half frame, 6x4.5, 6x6, 6x7, 6x9, or
  free), a colour label for photos worth a look, and the shortcut key.

Limits
------
  - Tested on 35mm only; the other formats haven't been tried on real scans.
  - One frame per scan.
  - A frame that runs off the edge of the scan on two sides is skipped.
    Rescan it with some film border showing all round.
  - If the four edges disagree about the tilt, the photo is cropped but not
    straightened.

Files
-----
  Info.lua                plug-in details and menu items
  MetadataDefinition.lua  what Frameline stores on each photo
  Init.lua                registers the keyboard shortcut (macOS)
  CropMenuItem.lua        a run: previews -> detector -> crops, or the review
  FLReview.lua            the review window
  Settings.lua            the settings window
  FLPrefs.lua             settings and their defaults
  FLFrame.lua             crop arithmetic, per-photo data, the shortcut
  frameline-detect        the frame detector (built from detect/main.swift)

License: GNU GPL v3. Copyright (c) 2026 David Esquivel.
