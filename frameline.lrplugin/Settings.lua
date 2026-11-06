-- Frameline Settings: the defaults every run uses.

local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'
local Prefs = require 'FLPrefs'
local Frame = require 'FLFrame'

LrFunctionContext.callWithContext('frameline settings', function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local share = LrView.share
    local prefs = Prefs.load()
    local props = LrBinding.makePropertyTable(context)
    for k, v in pairs(prefs) do props[k] = v end

    local contents = f:column {
        bind_to_object = props,
        spacing = f:dialog_spacing(),
        fill_horizontal = 1,

        f:group_box {
            title = 'Crop',
            fill_horizontal = 1,
            spacing = f:control_spacing(),
            f:row {
                f:static_text { title = 'Crop edge', width = share 'lbl' },
                f:popup_menu { value = bind 'border', items = Prefs.items(Prefs.borderSteps), width_in_chars = 28 },
            },
            f:static_text {
                title = 'Sprockets keeps the sprocket holes in: the crop becomes 9:8, not 3:2. It needs a scan that shows the whole strip; '
                    .. 'a photo without that much film gets a thin border instead and goes to Collections › Frameline › No room for sprockets.',
                font = '<system/small>',
                width = 420,
                height_in_lines = 4,
            },
            f:row {
                f:static_text { title = '', width = share 'lbl' },
                f:checkbox { title = 'Straighten tilted frames', value = bind 'straighten' },
            },
        },

        f:group_box {
            title = 'Film',
            fill_horizontal = 1,
            spacing = f:control_spacing(),
            f:row {
                f:static_text { title = 'Format', width = share 'lbl' },
                f:popup_menu { value = bind 'format', items = Prefs.items(Prefs.formats), width_in_chars = 28 },
            },
            f:static_text {
                title = 'Used to place a frame edge that cannot be seen, such as a night sky against a black border.',
                font = '<system/small>',
                width = 420,
                height_in_lines = 2,
            },
        },

        f:group_box {
            title = 'Photos worth a look',
            fill_horizontal = 1,
            spacing = f:control_spacing(),
            f:static_text {
                title = 'Photos where one frame edge had weak evidence are still cropped, and gathered in Collections › Frameline › Worth a look. Skipped photos go to Frameline › Skipped.',
                font = '<system/small>',
                width = 420,
                height_in_lines = 3,
            },
            f:row {
                f:static_text { title = 'Also mark them with', width = share 'lbl' },
                f:popup_menu { value = bind 'label', items = Prefs.items(Prefs.labels), width_in_chars = 28 },
            },
        },

        f:group_box {
            title = 'Keyboard shortcut',
            fill_horizontal = 1,
            spacing = f:control_spacing(),
            f:row {
                f:static_text { title = 'Run Frameline with', width = share 'lbl' },
                f:popup_menu { value = bind 'shortcut', items = Prefs.items(Prefs.shortcuts), width_in_chars = 28 },
            },
            f:static_text {
                title = 'A new key works after Lightroom restarts. On cropped photos the key opens the review window instead.',
                font = '<system/small>',
                width = 420,
                height_in_lines = 2,
            },
        },
    }

    local result = LrDialogs.presentModalDialog {
        title = 'Frameline Settings ' .. Prefs.version,
        contents = contents,
        actionVerb = 'Save',
        cancelVerb = 'Cancel',
        otherVerb = 'Restore defaults',
    }

    if result == 'other' then
        Prefs.save(Prefs.defaults)
        LrDialogs.showBezel('Frameline: defaults restored', 1.5)
    elseif result == 'ok' then
        local new = {}
        for k in pairs(Prefs.defaults) do new[k] = props[k] end
        Prefs.save(new)
        if new.shortcut ~= prefs.shortcut then
            LrTasks.startAsyncTask(function()
                Frame.registerShortcut(new.shortcut)
                LrDialogs.showBezel('Frameline: shortcut changes after Lightroom restarts', 2.5)
            end)
        else
            LrDialogs.showBezel('Frameline ' .. Prefs.version .. ': settings saved', 1.5)
        end
    end
end)
