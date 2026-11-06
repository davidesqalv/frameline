-- Shared helpers: crop arithmetic, per-photo Frameline data, plain-language
-- descriptions, and the macOS keyboard shortcut.

local LrTasks = import 'LrTasks'
local Prefs = require 'FLPrefs'

local M = {}

M.LR_DOMAIN = 'com.adobe.LightroomClassicCC7'
M.MENU_TITLE = '   Frameline'     -- Lightroom indents plug-in menu items by three spaces

-- The detector reports the frame tilt with clockwise-on-screen positive;
-- Lightroom's CropAngle takes it with the same sign (verified on real scans).
M.ANGLE_SIGN = 1

-- Crop edge: when the clean border on an axis is less than this (percent of
-- the image), the short side may take up to HOLDER_TOLERANCE beyond it.
M.MIN_VISIBLE_BORDER = 0.4
M.HOLDER_TOLERANCE = 0.4
-- Sprockets: when the 9:8 rectangle does not fit centred, it may slide this
-- much (fraction of the axis) toward the side that has film to spare.
M.SPROCKET_SHIFT = 0.015

-- True when the photo already has a crop (or straighten angle) applied.
function M.hasCrop(photo)
    local s = photo:getDevelopSettings()
    if not s then return false end
    local l = s.CropLeft or 0
    local t = s.CropTop or 0
    local r = s.CropRight or 1
    local b = s.CropBottom or 1
    local a = s.CropAngle or 0
    return l > 0 or t > 0 or r < 1 or b < 1 or a ~= 0
end

function M.currentCrop(photo)
    local s = photo:getDevelopSettings() or {}
    return {
        CropLeft = s.CropLeft or 0, CropTop = s.CropTop or 0,
        CropRight = s.CropRight or 1, CropBottom = s.CropBottom or 1,
        CropAngle = s.CropAngle or 0,
    }
end

M.noCrop = { CropLeft = 0, CropTop = 0, CropRight = 1, CropBottom = 1, CropAngle = 0 }

-- Lightroom keeps the crop in the photo file's own coordinates, while the
-- preview Frameline analyses is the photo as displayed. For a photo shown
-- rotated, each displayed side is a different side of the file:
--   BC (shown 90° clockwise): file left = display top, file top = display right ...
-- Verified against the catalog on a rotated scan. The tilt angle is the same
-- either way: a clockwise tilt is clockwise whichever way the frame is turned.
local ORIENT = {
    AB = { l = 'l', t = 't', r = 'r', b = 'b' },
    BC = { l = 't', t = 'r', r = 'b', b = 'l' },
    CD = { l = 'r', t = 'b', r = 'l', b = 't' },
    DA = { l = 'b', t = 'l', r = 't', b = 'r' },
}
function M.toFileSpace(edges, orientation)
    local m = ORIENT[orientation or 'AB'] or ORIENT.AB
    local a = edges.avail or {}
    local f = edges.film or {}
    return { l = edges[m.l], t = edges[m.t], r = edges[m.r], b = edges[m.b],
             angle = edges.angle, aspect = edges.aspect, borders = edges.borders,
             avail = { l = a[m.l] or 0, t = a[m.t] or 0, r = a[m.r] or 0, b = a[m.b] or 0 },
             film = { l = f[m.l] or 0, t = f[m.t] or 0, r = f[m.r] or 0, b = f[m.b] or 0 } }
end

function M.orientation(photo)
    local o = photo:getRawMetadata('orientation')
    if type(o) == 'string' and ORIENT[o] then return o end
    return 'AB'
end

-- Lightroom's reference size for crop fractions under a straighten angle
-- (radians). Measured, not documented: the long side shrinks by the short
-- side's sine, the short side grows by the long side's sine.
function M.rotatedReference(W, H, a)
    local ca, sa = math.cos(a), math.abs(math.sin(a))
    if W >= H then
        return W * ca - H * sa, H * ca + W * sa
    end
    return W * ca + H * sa, H * ca - W * sa
end

-- The file's own width and height. Lightroom reports 'dimensions' as displayed,
-- i.e. already rotated for BC and DA photos, while the crop lives in file
-- coordinates (verified from the catalog: file 6192x4128 reported as
-- 4128x6192), so those two orientations are swapped back.
function M.dimensions(photo)
    local d = photo:getRawMetadata('dimensions')
    if not (d and d.width and d.height and d.width > 0 and d.height > 0) then return nil end
    local o = M.orientation(photo)
    if o == 'BC' or o == 'DA' then
        return { width = d.height, height = d.width }
    end
    return { width = d.width, height = d.height }
end

-- edges: the detected frame edges as margins (0-1) measured inward from
-- each side of the image, before any border offset, plus .angle (degrees),
-- .avail = { l, t, r, b } (clean border available outside each edge,
-- fraction) and .film = { l, t, r, b } (how far the film itself goes on
-- outside each edge, sprocket holes and all, fraction).
-- border: percent of the image to show around the picture (negative cuts
-- in), or the film borders marker (see FLPrefs.borderSteps).
-- straighten: apply the tilt; needs dims = { width, height } of the photo.
-- aspect: the frame's long/short ratio, a hard rule on the final rectangle
-- (0 = free, as detected); edges.aspect overrides it when set.
-- orientation: how the photo is displayed ('AB', 'BC', 'CD', 'DA'); the
-- edges are as detected on the displayed preview and are mapped to the file.
-- Returns the develop settings and, second, nil or a sentence saying why
-- film borders were asked for but could not be shown.
function M.cropFor(edges, border, straighten, dims, aspect, orientation)
    edges = M.toFileSpace(edges, orientation)
    local avail, film = edges.avail or {}, edges.film or {}
    local known = {}
    for _, v in pairs(avail) do
        if v and v > 0 then known[#known + 1] = v end
    end
    table.sort(known)
    local fallback = known[1]
    -- A side shows at most the clean border it has, minus a hair for the
    -- ragged film edge; a side whose border could not be measured gets the
    -- narrowest measured one. Both sides of an axis show the same border,
    -- so the picture stays centred: when one side runs short the other
    -- gives up the same amount. When that leaves essentially no border at
    -- all, the short side may take a little of what lies beyond its clean
    -- border (the holder, a sprocket row) so that some border shows; the
    -- scan's own edge is never crossed.
    local function most(sideAvail)
        local a = (sideAvail and sideAvail > 0) and sideAvail or fallback
        if a then return math.max(0, a * 100 - 0.3) end
        return nil
    end
    local function stretch(sideAvail, inset)
        local a = (sideAvail and sideAvail > 0) and sideAvail or fallback
        if not a then return nil end
        local reach = math.min(a * 100 + M.HOLDER_TOLERANCE, (inset or 0) * 100)
        return math.max(0, reach - 0.3)
    end
    local function axisBorder(a1, a2, i1, i2, want)
        local bpct = want
        if bpct > 0 then
            local allowed = bpct
            local m1, m2 = most(a1), most(a2)
            if m1 then allowed = math.min(allowed, m1) end
            if m2 then allowed = math.min(allowed, m2) end
            if allowed < M.MIN_VISIBLE_BORDER then
                local s1, s2 = stretch(a1, i1), stretch(a2, i2)
                local more = bpct
                if s1 then more = math.min(more, s1) end
                if s2 then more = math.min(more, s2) end
                allowed = math.max(allowed, more)
            end
            bpct = math.min(bpct, allowed)
        end
        return bpct
    end
    local function m(v, bpct)
        return math.max(0, math.min(0.45, v - bpct / 100))
    end
    -- the crop rectangle's margins for a border of `want` percent
    local function rectFor(want)
        local bx = axisBorder(avail.l, avail.r, edges.l, edges.r, want)
        local by = axisBorder(avail.t, avail.b, edges.t, edges.b, want)
        return m(edges.l, bx), m(edges.t, by), m(edges.r, bx), m(edges.b, by)
    end
    local A = edges.aspect
    if A == nil or A == 0 then A = aspect or 0 end
    local W, H = 3, 2
    if dims then W, H = dims.width, dims.height end
    if A > 0 and W < H then A = 1 / A end
    -- hard rule: the rectangle keeps the frame's shape; the axis that is too
    -- long gives up the difference, half on each side
    local function keepShape(wpx, hpx)
        if A <= 0 then return wpx, hpx end
        if wpx > hpx * A then return hpx * A, hpx end
        if hpx > wpx / A then return wpx, wpx / A end
        return wpx, hpx
    end
    local angle = (straighten and edges.angle) or 0
    if math.abs(angle) < 0.05 or not dims then angle = 0 end

    -- sprockets: a hairline on the long sides, the short sides grow below
    local B = Prefs.bordersFor(border)
    local l, t, r, b = rectFor(B > 0 and Prefs.filmMargin or (border or 0))
    local cx, cy = (l + 1 - r) / 2, (t + 1 - b) / 2
    -- The detected edges sit near the middle of a tilted edge's spread, so
    -- the measured size is already the frame's size to within half a
    -- percent. Keep it, and let Lightroom rotate that rectangle in place.
    local wf, hf = keepShape((1 - l - r) * W, (1 - t - b) * H)

    -- Sprockets: keep the frame's long side (with its hairline), grow the
    -- short one until the whole rectangle has the ratio, the picture staying
    -- centred. Only when the film really goes that far on both growing
    -- sides: the scan's edge, the holder or the light table must stay out.
    -- Where the film runs to the scan's edge there is no ragged film edge to
    -- keep clear of. When it does not fit centred, first the hairline goes
    -- (the short sides then grow a little less), then the rectangle may
    -- slide a little toward the side with room; only then is there no room,
    -- and the reason says, in millimetres of film, how far the crop would
    -- reach past the frame and how far the film goes.
    local note
    if B > 0 and wf > 0 and hf > 0 then
        local sa = math.abs(math.sin(math.rad(angle)))
        local frameLong = math.max((1 - edges.l - edges.r) * W, (1 - edges.t - edges.b) * H)
        local pxPerMm = frameLong / 36
        -- film left over on one side after the crop's reach past the frame edge (negative = short)
        local function room(edgeIn, filmOut, cropOut, slackPx, n)
            local reach = edgeIn - cropOut + slackPx / n
            local hair = (filmOut >= edgeIn - 0.0005) and 0 or 0.003
            return filmOut - (reach + hair), reach + hair
        end
        local fit, short
        for _, want in ipairs({ Prefs.filmMargin, 0 }) do
            local l2, t2, r2, b2 = rectFor(want)
            local cx2, cy2 = (l2 + 1 - r2) / 2, (t2 + 1 - b2) / 2
            local wf2, hf2 = keepShape((1 - l2 - r2) * W, (1 - t2 - b2) * H)
            local nw, nh = wf2, hf2
            if wf2 >= hf2 then nh = wf2 / B else nw = hf2 / B end
            local room1, room2, reach1, reach2, film1, film2, n1
            if nh > hf2 then
                local slack = nw * sa / 2
                room1, reach1 = room(edges.t, film.t or 0, cy2 - nh / 2 / H, slack, H)
                room2, reach2 = room(edges.b, film.b or 0, 1 - (cy2 + nh / 2 / H), slack, H)
                film1, film2, n1 = film.t or 0, film.b or 0, H
            elseif nw > wf2 then
                local slack = nh * sa / 2
                room1, reach1 = room(edges.l, film.l or 0, cx2 - nw / 2 / W, slack, W)
                room2, reach2 = room(edges.r, film.r or 0, 1 - (cx2 + nw / 2 / W), slack, W)
                film1, film2, n1 = film.l or 0, film.r or 0, W
            else
                room1, room2, reach1, reach2, film1, film2, n1 = 0, 0, 0, 0, 0, 0, 1
            end
            -- one side short: slide toward the other, when it has that much to spare
            local shift = 0
            if room1 < 0 and -room1 <= M.SPROCKET_SHIFT and room2 + room1 >= 0 then
                shift = -room1; room2 = room2 + room1; room1 = 0
            elseif room2 < 0 and -room2 <= M.SPROCKET_SHIFT and room1 + room2 >= 0 then
                shift = room2; room1 = room1 + room2; room2 = 0
            end
            if room1 >= 0 and room2 >= 0 then
                fit = { l2, t2, r2, b2, nw, nh, shift, nh > hf2 }
                break
            end
            if room1 < room2 then
                short = { reach1 * n1 / pxPerMm, film1 * n1 / pxPerMm }
            else
                short = { reach2 * n1 / pxPerMm, film2 * n1 / pxPerMm }
            end
        end
        if fit then
            l, t, r, b = fit[1], fit[2], fit[3], fit[4]
            wf, hf = fit[5], fit[6]
            cx, cy = (l + 1 - r) / 2, (t + 1 - b) / 2
            if fit[8] then cy = cy + fit[7] else cx = cx + fit[7] end
        else
            note = string.format(
                'No room for sprockets: the crop would reach %.1f mm past the frame, this scan shows %.1f mm of film there.',
                short[1], short[2])
        end
    end

    if angle == 0 then
        local hw, hh = wf / W / 2, hf / H / 2
        return { CropLeft = math.max(0, cx - hw), CropTop = math.max(0, cy - hh),
                 CropRight = math.min(1, cx + hw), CropBottom = math.min(1, cy + hh), CropAngle = 0 }, note
    end
    -- Under a straighten angle Lightroom reads the crop fractions against a
    -- reference that is narrower and taller than the image (measured from
    -- the catalog's own cropped sizes on real scans):
    --   long side  = W cos a - H |sin a|,  short side = H cos a + W |sin a|
    -- so a rectangle of wf x hf pixels is wf / refW by hf / refH.
    local a = math.rad(angle)
    local ca = math.cos(a)
    local refW, refH = M.rotatedReference(W, H, a)
    -- the frame centre, offset from the image centre, follows the rotation
    local dx, dy = (cx - 0.5) * W, (cy - 0.5) * H
    local sgn = math.sin(a)
    local rx = dx * ca + dy * sgn
    local ry = -dx * sgn + dy * ca
    local ucx, ucy = 0.5 + rx / refW, 0.5 + ry / refH
    local hw, hh = wf / refW / 2, hf / refH / 2
    return {
        CropLeft = math.max(0, ucx - hw), CropTop = math.max(0, ucy - hh),
        CropRight = math.min(1, ucx + hw), CropBottom = math.min(1, ucy + hh),
        CropAngle = M.ANGLE_SIGN * angle,
    }, note
end

-- l,t,r,b,angle,availL..B,aspect,filmL..B,borders (older photos stop early)
function M.edgesToString(e)
    local a = e.avail or {}
    local f = e.film or {}
    return string.format('%.5f,%.5f,%.5f,%.5f,%.2f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f',
        e.l, e.t, e.r, e.b, e.angle or 0, a.l or 0, a.t or 0, a.r or 0, a.b or 0, e.aspect or 0,
        f.l or 0, f.t or 0, f.r or 0, f.b or 0, e.borders or 0)
end

function M.edgesFromString(s)
    if not s then return nil end
    local parts = {}
    for v in s:gmatch('[^,]+') do parts[#parts + 1] = tonumber(v) end
    if #parts < 4 then return nil end
    return { l = parts[1], t = parts[2], r = parts[3], b = parts[4], angle = parts[5] or 0,
             avail = { l = parts[6] or 0, t = parts[7] or 0, r = parts[8] or 0, b = parts[9] or 0 },
             aspect = parts[10] or 0,
             film = { l = parts[11] or 0, t = parts[12] or 0, r = parts[13] or 0, b = parts[14] or 0 },
             borders = parts[15] or 0 }
end

-- What Frameline stored on a photo the last time it cropped it, or nil.
function M.dataFor(photo)
    local edges = M.edgesFromString(photo:getPropertyForPlugin(_PLUGIN, 'frameline_edges'))
    if not edges then return nil end
    return {
        edges = edges,
        sides = photo:getPropertyForPlugin(_PLUGIN, 'frameline_sides') or '',
        status = photo:getPropertyForPlugin(_PLUGIN, 'frameline_status') or 'ok',
        border = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'frameline_border')),
    }
end

-- "run/run/inferred/run" -> a sentence a person can act on.
local SIDE_NAMES = { 'left', 'top', 'right', 'bottom' }
function M.describeSides(sides)
    local methods = {}
    for m in (sides or ''):gmatch('[^/]+') do methods[#methods + 1] = m end
    if #methods ~= 4 then return 'Cropped by Frameline.' end
    local notes = {}
    local clean = 0
    for i, m in ipairs(methods) do
        local side = SIDE_NAMES[i]
        if m == 'run' then
            clean = clean + 1
        elseif m == 'squeezed' then
            notes[#notes + 1] = string.format('The %s edge could not be seen; the width was pulled in to the frame\'s shape.', side)
        elseif m == 'subtle' then
            notes[#notes + 1] = string.format('The %s edge was found from a faint change in tone.', side)
        elseif m == 'partial' then
            notes[#notes + 1] = string.format('The %s edge was found from the part of it that shows.', side)
        elseif m == 'inferred' then
            notes[#notes + 1] = string.format('The %s edge could not be seen and was placed from the frame\'s shape.', side)
        elseif m == 'batch' then
            notes[#notes + 1] = string.format('The %s edge could not be seen and was placed where it sits on the other photos.', side)
        elseif m == 'soft' then
            notes[#notes + 1] = string.format('The %s edge is faint; worth a glance.', side)
        elseif m == 'agreed' then
            notes[#notes + 1] = string.format('The %s edge is faint, and the frame\'s shape confirms it.', side)
        elseif m == 'too-wide' then
            notes[#notes + 1] = string.format('The %s edge could not be found, so that side is uncropped.', side)
        elseif m == 'no-border' then
            notes[#notes + 1] = string.format('No film border on the %s; that side was left as it is.', side)
        end
    end
    if clean == 4 then return 'Frame found cleanly on all four sides.' end
    return table.concat(notes, ' ')
end

function M.describeAngle(angle, straighten)
    if not angle or math.abs(angle) < 0.05 then return 'Not tilted.' end
    if straighten then
        return string.format('Straightened by %.1f°.', math.abs(angle))
    end
    return string.format('Tilted %.1f°, left as is.', math.abs(angle))
end

-- One readable line for the Metadata panel. note: why film borders could
-- not be shown, when they were asked for.
function M.summaryFor(sides, border, edges, straighten, note)
    local s = M.describeSides(sides) .. ' ' .. Prefs.describeBorder(border) .. '. '
        .. M.describeAngle(edges and edges.angle, straighten)
    if note then s = s .. ' ' .. note end
    return s
end

-- Must be called inside catalog:withWriteAccessDo.
function M.store(photo, edges, sides, status, border, straighten, note)
    photo:setPropertyForPlugin(_PLUGIN, 'frameline_edges', M.edgesToString(edges))
    photo:setPropertyForPlugin(_PLUGIN, 'frameline_sides', sides or '')
    photo:setPropertyForPlugin(_PLUGIN, 'frameline_status', status or 'ok')
    photo:setPropertyForPlugin(_PLUGIN, 'frameline_border', tostring(border or 0))
    photo:setPropertyForPlugin(_PLUGIN, 'frameline_summary', M.summaryFor(sides, border, edges, straighten, note))
end

-- Must be called inside catalog:withWriteAccessDo.
function M.setBorder(photo, data, border, straighten, note)
    photo:setPropertyForPlugin(_PLUGIN, 'frameline_border', tostring(border or 0))
    photo:setPropertyForPlugin(_PLUGIN, 'frameline_summary', M.summaryFor(data.sides, border, data.edges, straighten, note))
end

function M.forget(photo)
    photo:setPropertyForPlugin(_PLUGIN, 'frameline_edges', nil)
    photo:setPropertyForPlugin(_PLUGIN, 'frameline_sides', nil)
    photo:setPropertyForPlugin(_PLUGIN, 'frameline_status', nil)
    photo:setPropertyForPlugin(_PLUGIN, 'frameline_border', nil)
    photo:setPropertyForPlugin(_PLUGIN, 'frameline_summary', nil)
end

-- Register (or change) the menu shortcut through macOS's per-app menu keys.
-- Takes effect the next time Lightroom starts. Returns true when it wrote.
function M.registerShortcut(key)
    if not MAC_ENV then return false end
    local probe = string.format(
        '/usr/bin/defaults read %s NSUserKeyEquivalents 2>/dev/null | /usr/bin/grep -q \'"%s" = "%s"\'',
        M.LR_DOMAIN, M.MENU_TITLE, key)
    if LrTasks.execute(probe) == 0 then return false end
    LrTasks.execute(string.format(
        '/usr/bin/defaults write %s NSUserKeyEquivalents -dict-add "%s" "%s"',
        M.LR_DOMAIN, M.MENU_TITLE, key))
    return true
end

return M
