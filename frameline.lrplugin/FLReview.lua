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

        -- the crop each photo gets for a choice, and the film borders note if any
        local function cropOf(it, val, fmt)
            it.data.edges.aspect = Prefs.aspectFor(fmt)
            return Frame.cropFor(it.data.edges, val, prefs.straighten, it.dims, nil, it.orientation)
        end
        -- the line under the crop edge
        local function noteFor(val, noRoom, lastNote)
            if Prefs.bordersFor(val) == 0 then return '' end
            if noRoom == 0 then
                return 'Sprockets: the crop is 9:8 with the sprocket holes in, not 3:2.'
            elseif #items == 1 then
                return lastNote
            end
            return string.format('%d of %d have no room for sprockets and keep a thin border.', noRoom, #items)
        end
        do
            local noRoom, lastNote = 0, nil
            for _, it in ipairs(items) do
                local _, note = cropOf(it, startBorder, startFormat)
                if note then noRoom = noRoom + 1; lastNote = note end
            end
            props.note = noteFor(startBorder, noRoom, lastNote)
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
                    local noRoom, lastNote = 0, nil
                    catalog:withWriteAccessDo('Frameline edge', function()
                        for _, it in ipairs(items) do
                            local crop, note = cropOf(it, val, fmt)
                            it.photo:applyDevelopSettings(crop, 'Frameline edge')
                            it.photo:setPropertyForPlugin(_PLUGIN, 'frameline_edges', Frame.edgesToString(it.data.edges))
                            Frame.setBorder(it.photo, it.data, val, prefs.straighten, note)
                            if note then noRoom = noRoom + 1; lastNote = note end
                        end
                    end, { timeout = 3 })
                    props.note = noteFor(val, noRoom, lastNote)
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
            f:static_text { title = bind 'note', font = '<system/small>', width = 440, height_in_lines = 2 },

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
                    local _, note = cropOf(it, startBorder, startFormat)
                    Frame.setBorder(it.photo, it.data, startBorder, prefs.straighten, note)
                end
            end, { timeout = 3 })
        end
    end)
    return verdict
end

return M
