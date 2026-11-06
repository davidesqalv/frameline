-- Frameline preferences: the few choices a photographer makes, persisted
-- through Lightroom's plug-in preferences.

local LrPrefs = import 'LrPrefs'

local M = {}

M.version = '0.3.22'   -- kept in step with Info.lua by bump.sh

-- border: percent of the image around the picture; positive shows film
-- border, negative cuts into the picture. Chosen by name (borderSteps),
-- stored as the number so old values and fine-tuning still work. The last
-- step, sprockets, is not a percentage: the frame's long sides get a
-- thin margin (filmMargin) and the short sides grow until the whole
-- rectangle is 9:8, sprocket holes in. Its stored number is a marker.
M.defaults = {
    border = 0.5,
    format = '35mm',
    label = 'none',
    shortcut = '^f',
    straighten = true,
}

M.borderSteps = {
    { title = 'Tighter',      value = -0.6 },
    { title = 'Tight',        value = -0.3 },
    { title = 'Edge to edge', value = 0 },
    { title = 'Thin border',  value = 0.5 },
    { title = 'Wide border',  value = 1.2 },
    { title = 'Chonk border', value = 2.5 },
    { title = 'Sprockets',    value = 10, borders = 9 / 8 },
}
M.filmMargin = 0.5     -- border on the frame's long sides with sprockets (percent), a hairline of rebate

M.formats = {
    { title = '35mm (3:2)',                      value = '35mm', aspect = 1.5 },
    { title = 'Half frame (4:3)',                value = 'half', aspect = 4 / 3 },
    { title = '6×4.5',                           value = '645',  aspect = 1.35 },
    { title = '6×6',                             value = '66',   aspect = 1.0 },
    { title = '6×7',                             value = '67',   aspect = 1.25 },
    { title = '6×9',                             value = '69',   aspect = 1.5 },
    { title = 'Free (as detected)',              value = 'none', aspect = 0 },
}

M.labels = {
    { title = 'Nothing else', value = 'none' },
    { title = 'Red label',    value = 'red' },
    { title = 'Yellow label', value = 'yellow' },
    { title = 'Green label',  value = 'green' },
    { title = 'Blue label',   value = 'blue' },
    { title = 'Purple label', value = 'purple' },
}

M.shortcuts = {
    { title = 'control-F', value = '^f' },
    { title = 'control-G', value = '^g' },
    { title = 'control-J', value = '^j' },
    { title = 'control-K', value = '^k' },
    { title = 'control-L', value = '^l' },
}

-- popup_menu wants plain title/value pairs
function M.items(list)
    local out = {}
    for _, it in ipairs(list) do
        out[#out + 1] = { title = it.title, value = it.value }
    end
    return out
end

function M.load()
    local p = LrPrefs.prefsForPlugin()
    local out = {}
    for k, v in pairs(M.defaults) do
        if p[k] == nil then out[k] = v else out[k] = p[k] end
    end
    out.border = M.nearestStep(out.border)
    return out
end

function M.save(t)
    local p = LrPrefs.prefsForPlugin()
    for k, v in pairs(t) do
        p[k] = v
    end
end

-- the format whose ratio matches, for a photo that stores its own aspect
function M.formatFor(aspect)
    for _, f in ipairs(M.formats) do
        if math.abs(f.aspect - (aspect or 0)) < 0.01 then return f.value end
    end
    return M.defaults.format
end

function M.aspectFor(format)
    for _, f in ipairs(M.formats) do
        if f.value == format then return f.aspect end
    end
    return 1.5
end

-- the film borders ratio (long/short of the whole rectangle) a crop edge
-- value asks for; 0 for the ordinary percentage steps
function M.bordersFor(border)
    for _, s in ipairs(M.borderSteps) do
        if s.borders and math.abs(s.value - (border or 0)) < 0.01 then return s.borders end
    end
    return 0
end

local function nearest(v)
    local best = M.borderSteps[1]
    for _, s in ipairs(M.borderSteps) do
        if math.abs(s.value - (v or 0)) < math.abs(best.value - (v or 0)) then best = s end
    end
    return best
end

function M.nearestStep(v)
    return nearest(v).value
end

function M.describeBorder(v)
    return nearest(v).title
end

return M
