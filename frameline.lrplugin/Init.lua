-- Runs once when Lightroom loads the plug-in: makes sure the menu shortcut
-- from the preferences is registered with macOS (see Frame.registerShortcut).
-- What happened is written to frameline-init.log in Lightroom's temp folder.

local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local Prefs = require 'FLPrefs'
local Frame = require 'FLFrame'

local function note(fmt, ...)
    local f = io.open(LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'frameline-init.log'), 'a')
    if f then
        f:write(os.date('%Y-%m-%d %H:%M:%S ') .. string.format(fmt, ...) .. '\n')
        f:close()
    end
end

LrTasks.startAsyncTask(function()
    local key = Prefs.load().shortcut
    local wrote = Frame.registerShortcut(key)
    note('shortcut %s: %s', key, wrote and 'registered (active after Lightroom restarts)' or 'already registered or not macOS')
end)
