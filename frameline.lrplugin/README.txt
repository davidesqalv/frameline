Frameline 0.2 - auto-crop camera-scanned film frames in Lightroom Classic
=========================================================================

Finds the film frame inside each selected scan (the picture area inside the
border) and applies a Lightroom crop to it. Works on unconverted negatives
and converted positives. Crops are normal Lightroom crops: non-destructive,
adjustable with the R key, undoable.

Install
-------
  Lightroom Classic > File > Plug-in Manager > Add... > choose this folder
  (frameline.lrplugin). After editing the plugin, use Plug-in Manager >
  Reload Plug-in. The control-F shortcut is registered the first time the
  plug-in loads and works after the next Lightroom restart.

Use
---
  Select scans, press control-F (or File > Plug-in Extras > Frameline).
  A passing message says how many were cropped. Photos "worth a look" had
  one frame edge with weak evidence; the crop is still applied, and they
  can get a colour label (see Settings).

  A mixed selection crops only the photos not done yet and leaves the rest
  alone. Press control-F on photos Frameline has cropped to open the review
  window: the crop edge choice (Tighter, Tight, Edge to edge, Thin border,
  Wide border, Chonk border) moves the crop live, and the Frame choice
  (35mm, half frame, 6x6, ..., or free) re-shapes it. A side never shows
  more border than the scan has there, with a plain sentence on how the frame
  was found and whether it was straightened. Buttons: Detect again, Remove
  crop, Make this my default.

  Frameline Settings... (same menu): crop edge, straighten tilted frames,
  film format, colour label for photos worth a look, and the shortcut key.

Requirements
------------
  macOS on Apple Silicon. Nothing else: the detector (frameline-detect) is a
  native binary with no dependencies.

Known limitations (v0.2)
------------------------
  - Tilts the four sides disagree on are left alone (the photo is not
    straightened).
  - Film formats other than 35mm have not been tested yet.
  - One frame per scan file, and the frame must sit inside the scan: a
    frame pushed against the scan's edge on two or more sides, or one whose
    dark areas match the border on most sides, is skipped rather than
    guessed. Rescan it centred in the holder.

Files
-----
  Info.lua           plugin metadata + menu registration
  MetadataDefinition.lua  the per-photo fields Frameline stores
  Init.lua           registers the keyboard shortcut (macOS)
  CropMenuItem.lua   the run: previews -> helper -> apply crops, or review
  FLReview.lua       the review window
  Settings.lua       the settings window
  FLPrefs.lua        preferences and their defaults
  FLFrame.lua        crop arithmetic, per-photo data, shortcut registration
  frameline-detect   the frame detector (compiled from detect/main.swift)
