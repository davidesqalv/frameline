-- The review window: opened when Frameline runs on photos it has already
-- cropped. The frame and crop edge choices move the crop live on the
-- selected photos; a line under the crop edge says what sprockets did.

local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'
local Prefs = require 'FLPrefs'
local Frame = require 'FLFrame'

local M = {}

-- Returns 'done', 'cancel', 'redetect' or 'removed'.
function M.show(catalog, photos, prefs)
    local verdict = 'cancel'
    LrFunctionContext.callWithContext('frameline review', function(context)
        local f = LrView.osFactory()
        local bind = LrView.bind

        -- what each photo looks like now, so Cancel can put it back
        local items = {}
        for _, photo in ipairs(photos) do
            items[#items + 1] = {
                photo = photo,
                data = Frame.dataFor(photo),
                dims = Frame.dimensions(photo),
                orientation = Frame.orientation(photo),
                original = Frame.currentCrop(photo),
            }
        end
        local first = items[1]
        local startBorder = Prefs.nearestStep(first.data.border or prefs.border)
        local startFormat = Prefs.formatFor(
            first.data.edges.aspect ~= 0 and first.data.edges.aspect or Prefs.aspectFor(prefs.format))

        local props = LrBinding.makePropertyTable(context)
        props.border = startBorder
        props.format = startFormat
        props.note = ''

        -- the crop each photo gets for a choice, and the sprocket sentences if any
        local function cropOf(it, val, fmt)
            it.data.edges.aspect = Prefs.aspectFor(fmt)
            return Frame.cropFor(it.data.edges, val, prefs.straighten, it.dims, nil, it.orientation)
        end
        -- the line under the crop edge
        -- counts over the photos: noRoom (older photos only), cut, plain;
        -- last: the sentence of the last photo that had one
        local SPROCKETS = 'Sprockets: the crop takes in the sprocket holes.'
        local function noteFor(val, k)
            if Prefs.bordersFor(val) == 0 then return '' end
            if #items == 1 then return k.last or SPROCKETS end
            local parts = {}
            if k.cut > 0 then
                parts[#parts + 1] = string.format('%d of %d have one row of holes cut by the scan.', k.cut, #items)
            end
            if k.plain > 0 then
                parts[#parts + 1] = string.format('%d of %d show no sprocket holes and keep a thin border.', k.plain, #items)
            end
            if k.noRoom > 0 then
                parts[#parts + 1] = string.format('%d of %d have no room for sprockets and keep a thin border.', k.noRoom, #items)
            end
            if #parts == 0 then return SPROCKETS end
            return table.concat(parts, ' ')
        end
        local function tally(k, note, info, kind)
            if note then k.noRoom = k.noRoom + 1 end
            if kind == 'cut' then k.cut = k.cut + 1 end
            if kind == 'plain' then k.plain = k.plain + 1 end
            k.last = note or info or k.last
        end
        local function counts() return { noRoom = 0, cut = 0, plain = 0 } end
        do
            local k = counts()
            for _, it in ipairs(items) do
                local _, note, info, kind = cropOf(it, startBorder, startFormat)
                tally(k, note, info, kind)
            end
            props.note = noteFor(startBorder, k)
        end

        -- live update, one write at a time, always ending on the latest value
        local applying, pending = false, nil
        local function applyNow()
            pending = true
            if applying then return end
            applying = true
            LrTasks.startAsyncTask(function()
                while pending do
                    pending = false
                    local val, fmt = props.border, props.format
                    local k = counts()
                    catalog:withWriteAccessDo('Frameline edge', function()
                        for _, it in ipairs(items) do
                            local crop, note, info, kind = cropOf(it, val, fmt)
                            it.photo:applyDevelopSettings(crop, 'Frameline edge')
                            it.photo:setPropertyForPlugin(_PLUGIN, 'frameline_edges', Frame.edgesToString(it.data.edges))
                            Frame.setBorder(it.photo, it.data, val, prefs.straighten, note or info)
                            tally(k, note, info, kind)
                        end
                    end, { timeout = 3 })
                    props.note = noteFor(val, k)
                end
                applying = false
            end)
        end
        props:addObserver('border', function() applyNow() end)
        props:addObserver('format', function() applyNow() end)

        local heading, detail
        if #items == 1 then
            heading = first.photo:getFormattedMetadata('fileName')
            detail = Frame.describeSides(first.data.sides) .. ' '
                .. Frame.describeAngle(first.data.edges.angle, prefs.straighten)
        else
            heading = string.format('%d photos', #items)
            local look = 0
            for _, it in ipairs(items) do
                if it.data.status == 'check' then look = look + 1 end
            end
            detail = look == 0 and 'All frames found cleanly.'
                or string.format('%d of them worth a look. The crop edge below moves all %d together.', look, #items)
        end

        local contents = f:column {
            bind_to_object = props,
            spacing = f:dialog_spacing(),
            fill_horizontal = 1,

            f:static_text { title = heading, font = '<system/bold>' },
            f:static_text { title = detail, width = 440, height_in_lines = 2 },

            f:row {
                f:static_text { title = 'Frame' },
                f:popup_menu { value = bind 'format', items = Prefs.items(Prefs.formats), width_in_chars = 18 },
            },
            f:row {
                f:static_text { title = 'Crop edge' },
                f:popup_menu { value = bind 'border', items = Prefs.items(Prefs.borderSteps), width_in_chars = 18 },
                f:push_button {
                    title = 'Make this my default',
                    action = function()
                        local p = Prefs.load()
                        p.border = props.border
                        Prefs.save(p)
                        LrDialogs.showBezel('Frameline: default crop edge saved', 1.5)
                    end,
                },
            },
            f:static_text { title = bind 'note', font = '<system/small>', width = 440, height_in_lines = 3 },

            f:row {
                f:push_button {
                    title = 'Remove crop',
                    action = function(button)
                        LrDialogs.stopModalWithResult(button, 'removed')
                    end,
                },
                f:static_text {
                    title = 'The next run detects the frame again.',
                    font = '<system/small>',
                },
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = 'Frameline ' .. Prefs.version,
            contents = contents,
            actionVerb = 'Done',
            cancelVerb = 'Cancel',
            otherVerb = 'Detect again',
        }

        if result == 'ok' then
            verdict = 'done'
        elseif result == 'other' then
            verdict = 'redetect'
        elseif result == 'removed' then
            verdict = 'removed'
            catalog:withWriteAccessDo('Frameline: remove crop', function()
                for _, it in ipairs(items) do
                    it.photo:applyDevelopSettings(Frame.noCrop, 'Frameline: remove crop')
                    Frame.forget(it.photo)
                end
            end, { timeout = 3 })
            LrDialogs.showBezel('Frameline: crop removed', 1.5)
        elseif result == 'cancel' then
            verdict = 'cancel'
            catalog:withWriteAccessDo('Frameline: cancel', function()
                for _, it in ipairs(items) do
                    it.photo:applyDevelopSettings(it.original, 'Frameline: cancel')
                    it.data.edges.aspect = Prefs.aspectFor(startFormat)
                    it.photo:setPropertyForPlugin(_PLUGIN, 'frameline_edges', Frame.edgesToString(it.data.edges))
                    local _, note, info = cropOf(it, startBorder, startFormat)
                    Frame.setBorder(it.photo, it.data, startBorder, prefs.straighten, note or info)
                end
            end, { timeout = 3 })
        end
    end)
    return verdict
end

return M
