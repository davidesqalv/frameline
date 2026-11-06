# How Frameline finds the frame

The detector (`detect/main.swift`) and the crop arithmetic (`frameline.lrplugin/FLFrame.lua`), case by case. Most sections exist because a real scan broke the previous rule. The scans named here (`test-scans/...`) are the author's own test set, which isn't published; to check a change, run `./test.sh` on your own (see [developing.md](developing.md)).

## How detection works

Scans always show, from the outside in: the holder (if visible), the film
border, then the picture. The border is unexposed film, so it is uniform and
its tone is the same on all four sides; the holder is the opposite extreme
and shows on fewer sides.

1. Grayscale at 900px long side. Gradient magnitude; the top 5% of pixels
   are "edge" pixels; per column and row, the fraction of edge pixels.
2. Per side, walk inward line by line (columns for left/right, rows for
   top/bottom) and split the lines into *uniform runs*: most pixels within
   14 levels of the line median, median drifting by at most 10. A line with
   a strong edge fraction ends a run even if the tone continues (border
   meeting same-toned picture); tiny gaps (the ragged film edge) are bridged.
3. The border tone is the run tone seen near the rim on the most sides,
   ties going to the tone that lies inside another (the holder is never
   inside the border).
4. Per side, the border is the outermost near-rim run of that tone. The edge
   is where it ends, snapped to the strongest nearby edge line (the innermost
   strong one, so a glow strip between border and picture is left out).
5. Geometry: the film frame is 3:2, so the least trusted side (a run with no
   real edge line, or one wider than any plausible border) is placed from the
   other three. Photos where evidence was weak get status `check`; the plugin
   still crops them but lists them for a look. Margins are offset by `--inset`
   (default 0.5 % outside the frame edge, so a thin line of border shows).

## Rotated photos

Lightroom keeps the crop in the photo file's own coordinates, while the
preview Frameline analyses is the photo as displayed. For a photo shown
rotated (orientation BC, CD or DA) each displayed side is a different side of
the file, so the margins are permuted before the crop is written
(`FLFrame.toFileSpace`, verified against the catalog on a rotated scan). The
tilt angle is unchanged: a clockwise tilt is clockwise either way. Note that
Lightroom reports a photo's `dimensions` as displayed (rotated for BC/DA),
while the crop lives in file coordinates; the plug-in swaps them back.

## The frame ratio is a hard rule

The crop always has the chosen format's shape. The helper enforces it on the
detected edges (the axis that is too long gives up the difference, mostly on
its less trusted side, always inward), and the plug-in enforces it again on
the final rectangle after border offsets, so what lands in Lightroom is
exactly 3:2 (or the format picked in Settings, or per photo in the review
window; "Free" keeps the edges as detected).

## A frame the film cut short

When one side has no border because the strip was cut at the frame, the
frame measures too narrow for its shape. Geometry may nudge a measured side
outward by at most 1.2% of the image (the slop of a faint edge); beyond that
the side stays put and the shape rule trims the other axis instead, so the
crop gets a little tighter rather than growing into border or holder.

## When it gives up

With fewer than two sides actually seen (a frame that runs off the scan on
two sides, or clear film against clear film almost all round) there is no
frame to reconstruct; the photo is skipped and listed as "no frame found"
rather than cropped to the whole scan. DSC01550 in test-scans/lightroom is
the reference case: right border 3 lines, no top border, water at the
border tone below, and a 1-level ramp on the left.

## Faint edges (adaptive step)

Film border is extremely flat line to line: its medians move by a fraction
of a level. So on a side that has no proper edge line, the detector measures
the border's own noise from its first lines and calls an edge wherever the
line median shifts by at least 2 levels and several times that noise, and
stays shifted. That catches a night sky on a negative (clear film at 197
against border at 200) or deep shadow on a positive (tone 8 against 2).
It runs only on sides without a strong edge, so ordinary photos are
untouched; on the test scans it agreed with the 3:2 inference to the line.

The step search runs a few lines past the border run's end as well as
inside it. A run that stopped because the picture next to it is textured
(dark foliage against a black rebate, a negative's grain against its clear
border) rather than because its tone changed has its step exactly at the
end, one line outside the old search window; those sides used to come out
"soft" and be placed by geometry. The edge lands on the line where the tone
has changed, so crops on such sides are a line or two tighter than before
and the crop edge setting supplies the border.

## Ramps next to the holder

Some scans show a soft shadow from the film gate between the holder and the
border: a band close to the border tone that ramps slowly (202 to 208 over
thirty lines on one scan). It is uniform enough to be a run, so "outermost run
of the border tone" would take it. A border run must be flat over its first
25 lines (3 levels at most); a ramping run is passed over for the next flat
one. Only the head is judged, because a border run can go on to merge with
pale picture that the faint-edge step separates later.

## Which side moves

When the frame measures too wide or too tall for its shape, the whole
correction goes to the less trusted side of that axis (seen edge over faint
edge over placed edge; among seen edges, one whose edge line is strong, at
least 0.4 of its length in edge pixels, over one whose edge line is weak);
only sides of equal trust split it. A side with real contrast is an anchor.
A small residual (up to 0.5% of the axis, or 4 lines) is measurement slop
and is shared equally instead, so the crop stays centred. A side the rule
moves by more than 1% of the axis (or 8 lines) was not really seen: it is
relabelled as placed from the frame's shape (worth a look only when another
side is weak too; placed from three firm sides it is as good as seen).

## Sides with no border tone

Inside Lightroom the preview is always the whole scan, so a side where no
border tone was found is almost always a detection miss (a border under 1%
wide, an unusual tone), not a pre-cropped scan. When such a side breaks the
frame's shape, geometry places it like any other unseen side. When both
sides of one axis are weak and the frame comes out too wide or tall for its
shape, the pair is pulled in equally (weak edges err outward).

## Partial edges

When a side's border runs on into same-toned picture (a black dashboard
against a black border), the side is cut into twelve segments and each is
walked inward on its own. Wherever the picture is not border-toned, even a
shoulder or a patch of sky, the border stops at the true edge; the edge is
the outermost position at least two segments agree on. A partial edge is
kept only if it fits the frame's shape given the other three sides;
otherwise geometry places the side.

## Tilt

For each seen side, the tilt is the straight line through the most edge
pixels in a narrow band around the detected edge (10 lines inward, and
outward only as far as the border goes, so the ragged holder edge, a long
straight line at the scan's own angle, never enters the fit). The frame edge
is the longest straight line there; picture that matches the border tone
contributes nothing, and a side with no visible edge gives no vote instead
of a wrong one. Sides that agree within 0.35 degrees form groups; the group
with the most edge support wins and its angle is the support-weighted mean.
The long sides count double: the film is held by its long edges, and a
slightly cupped strip skews the short edges. A very clean edge may set the
tilt alone; a weak lone side, or sides that all disagree, means no tilt.
Validated on the synthetic frames rotated by 0.8 degrees (measured 0.80 and
0.84). The plug-in applies it as Lightroom's CropAngle with the crop
rectangle kept at the measured size and rotated in place (the measured
edges sit mid-spread on a tilted edge, so they are already the frame's size
to within half a percent). The sign convention is verified on real scans.

One undocumented Lightroom fact, measured from the catalog's own cropped
sizes on three straightened scans: under a CropAngle, the crop fractions
are read against a reference of (W cos a − H |sin a|) by (H cos a + W |sin a|)
for a landscape image, not against W by H. `FLFrame.rotatedReference`
encodes it; without it an exact 3:2 rectangle comes out at 1.46.

## Crop edge

The crop edge (Tighter ... Chonk border) is a percentage of the image shown
around the frame, or cut into it. A side shows at most the clean border it
has, minus a 0.3% hair for the ragged film edge; a side whose border could
not be measured gets the narrowest measured one. Both sides of an axis
always show the same border, so the picture stays centred: when one side
runs short (the sprocket holes below the frame in an Easy35 scan, the
scan's own edge above it) the other side gives up the same amount. On the
Easy35 scans in the test set that leaves Chonk at about 1-2% top and
bottom; the film simply is not there. Top-and-bottom may differ from
left-and-right (each is a percentage of its own image dimension). When the
clean border on an axis comes to less than 0.4%, essentially none, the
short side may take up to 0.4% of what lies beyond it (holder, a sprocket
row) so that some border shows, still symmetric; the scan's own edge is
never crossed, and a side with a real border never takes anything beyond
it.

Equal borders also need the frame's shape residual shared. A measured
frame is rarely exactly 3:2 (a gate a hair off, an edge a line off), and
the hard shape rule used to push the whole residual onto the least trusted
side, which set the crop off-centre by that much. A residual up to 0.5% of
the axis (or 4 lines) is now shared equally by both sides; a larger one is
a missed edge and still goes to the less trusted side. Likewise a soft side
that agrees with the other three to within that slop stands as measured
(method `agreed`, no flag) instead of being overwritten by geometry. A
run's reference tone is the median of its second to fourth lines rather
than its first, which often sits on a transition and used to split one
rebate into two runs with the edge lost between them.

Equal borders also need equal edges. A sharp frame edge is one line; a soft
one (the gate's shadow, film not quite flat) ramps over ten, and the run
walk lands at the foot of the ramp on one side and mid-ramp on another,
which showed as a visibly thicker border on one side of a Chinatown scan
(`test-scans/lightroom/DSC00632.jpg`, left edge soft, right edge sharp).
Every measured edge is now moved to the same point of its transition: the
first line, walking in, whose median over the frame's own span has gone
40% of the way from the border's tone to the picture's. Sharp edges stay
put; on the test set edges moved by at most four lines.

## Full-border scans (two passes)

A scan that shows the whole strip (light table, copy stand) has two rings
around the frame: the surround, and inside it the film's rebate with its
sprocket holes and edge printing. The rim walk finds the surround first: on
the sprocket sides no line is uniform end to end, because the surround
shows past the strip's ends, so the rebate never forms a run there and the
first pass returns the film's outline. When a band just inside that outline
is one uniform tone on every measured side, unlike the outer tone, and the
whole picture lies on one side of that tone (unexposed film is the film's
extreme tone; a picture is never both lighter and darker than its rebate),
the detector runs again inside the outline. The inner frame is taken only
when it is seen firmly on at least three sides and has the format's shape;
otherwise the first pass stands. Sides where no surround was seen run to
the scan's edge. Verified on a Kodak Pro 800 frame shot on a light table
(converted, and the same scan inverted as a stand-in for a negative).

For negatives with bright sprocket holes the border run breaks at the
holes. A run of the border tone that faded out without an edge line, a gap
whose every line is still mostly border tone and nearly all far from
uniform (holes punched out of it; the rows through the holes' rounded ends
are allowed to be more uniform, a sixth of the gap at most), and a flat run
of the same tone ending at a strong edge line: that is the border resuming,
and the later run is taken. A bright sky next to a bright border fails this
on both counts (its gap is nearly uniform, and it ends in nothing), which
is what the night-sky scan checks. Verified on a Tri-X negative shot on a
light table (`test-scans/fullborders/DSC_bw_dog.jpg`).

That scan also settled what a soft side is worth. Its right edge borders
pale sand of exactly the rebate's tone, so the border run walked 117 lines
into the picture and faded out there: no edge line, no tone step. The
other three sides were firm. Geometry places such a side, and it used to
be held back by the cut-film rule (a measured side moves outward by at
most 1.2%); that rule now applies to measured sides only. A soft side is
not a measurement, only where a run of the border's tone stopped, and three
firm sides plus the frame's shape put it where they say, its border width
reduced by the move.

The ring is looked for where the rebate begins, not right at the outline:
a holder's out-of-focus edge ramps over a dozen lines and, under a round
vignette, is uneven along its length, so up to 25 lines are skipped until a
line is 60% uniform (the rebate carries edge printing and frame numbers, so
60% is enough). The second pass starts there too. Inside the outline a
soft edge is judged against a wider plausible border (20% of the sub-image,
from the outline) since the sprocket sides run to about 16% of the strip.
The inner frame is accepted when three sides were seen firmly (run, faint
step, or agreed) and the shape rule left them where they were measured; the
fourth may have been placed by it. When a rebate ring was seen, the inner
frame was not taken, and the first pass kept less than 65% of the scan (a
film outline, never the right crop), the photo is flagged "frame inside
the film outline not confirmed" and the debug line says why. The tulips
scan (`test-scans/fullborders/DSC09488.jpg`, whose top of picture is dark
foliage against the rebate) and the second Tri-X dog (`DSC_bw_dog2.jpg`,
in a round-vignetted holder, with sprocket holes so faint on the shaded
side that the run walk reads them as border) shaped these rules.

## Sprockets (9:8)

The last crop edge step, "Sprockets", keeps the frame's long sides with
a hairline of rebate (0.5%) and grows the short sides until the whole
rectangle is 9:8, centred on the frame: on 35mm that is 4 mm of film beyond
the frame on each side, which takes in the sprocket holes and stops about
1.5 mm inside the film's edge (the edge printing gets clipped; that is the
look). It sits in the crop edge list rather than the format list because
that is what it is, how much to show around the frame; the format still
says what shape the frame has. Nothing stacks on it: the percentage steps
are simply other choices. It is a hard rule with a hard precondition: the
film must really go that far on both growing sides. The detector reports,
per side, how far the film continues past the frame (`film` in the CSV: to
the outline found by the second pass, or on a scan without a surround as
far as the lines stay mostly border tone, so frame numbers and sprocket
rows at the rim count as film). The plug-in adds the tilt's reach (half the
rectangle's long side times the sine of the angle) and the usual hair, none
where the film runs off the scan. When the rectangle does not fit centred,
the hairline on the long sides goes first (the short sides then grow about
half a percent less), then the rectangle may slide up to 1.5% of the axis
toward the side that has film to spare (the second Tri-X dog sits low in
its scan and would otherwise have ended two pixels past the bottom edge and
been refused). Only then does the photo get a thin border instead, the
reason lands in its Frameline summary in millimetres of film ("the crop
would reach 4.3 mm past the frame, this scan shows 0.7 mm of film there"),
and the photo goes to Collections › Frameline › No room for sprockets, a
collection that only exists once that has happened. The review window switches it live and a line under the crop
edge says what happened. None of the Easy35 scans in the test set have the
room (0.7 mm above the frame, sprocket halves below); the Met light-table
scan does, with about 0.3 mm to spare: it shows 4.6 mm of rebate beside the
frame rather than the nominal 5.5, so a wider hairline on the long sides
(which grows the short sides in proportion) would already tip it over.

## Batch prior

The helper sees the whole selection at once. In one scanning session the film
sits in the same place frame after frame, so when a photo cannot show a side
at all (a bright region of a negative meeting the bright border, a night sky
meeting a black border) and geometry has already placed one unseen side, the
remaining one is filled from the median border width of that side across the
photos where it was seen firmly (needs at least 3). Such photos get status
`check`. A single photo has no batch, so it keeps the side uncropped instead.
