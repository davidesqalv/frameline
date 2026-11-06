-- Frameline: auto-crop camera-scanned film frames in Lightroom Classic.
--
-- Photos Frameline already cropped are left alone: a selection of only
-- those opens the review window (FLReview.lua); a mixed selection crops just
-- the rest. Otherwise: save a ~2048px preview of each photo to a temp
-- folder as 0001.jpg, 0002.jpg, ... -> run the bundled frameline-detect
-- helper once on the whole folder -> read results.csv -> apply the crops
-- with the crop edge and straighten choices from the settings.
--
-- Previews come from requestJpegThumbnail (fast, uses Lightroom's preview
-- cache); any photo that does not deliver one is exported for real through
-- LrExportSession instead (slower, always works). A frameline.log in the
-- temp folder records what happened to every photo.

local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrProgressScope = import 'LrProgressScope'
local Prefs = require 'FLPrefs'
local Frame = require 'FLFrame'
local Review = require 'FLReview'

-- Thumbnails come from Lightroom's preview cache in well under a second. When
-- a photo has no preview yet, the request can stall for a long time, so the
-- wait is generous for the first photo and short once a stall has been seen;
-- after two stalls in a row the rest of the batch goes straight to export.
local THUMB_TIMEOUT_FIRST = 10
local THUMB_TIMEOUT_AFTER_STALL = 2
local STALLS_BEFORE_EXPORT = 2
-- Photos that need a look are collected, not listed: Collections > Frameline.
local COLLECTION_SET = 'Frameline'
local COLLECTION_LOOK = 'Worth a look'
local COLLECTION_SKIPPED = 'Skipped'
local COLLECTION_NOROOM = 'No room for sprockets'

math.randomseed(os.time())

local logLines = {}
local function log(fmt, ...)
    logLines[#logLines + 1] = string.format(fmt, ...)
end
local function writeLog(tmp)
    local f = io.open(LrPathUtils.child(tmp, 'frameline.log'), 'w')
    if f then
        f:write(table.concat(logLines, '\n') .. '\n')
        f:close()
    end
end

local function shellQuote(s)
    return '"' .. s .. '"'
end

-- An existing collection in the set, or nil (never creates one).
local function findCollection(set, name)
    for _, c in ipairs(set:getChildCollections()) do
        if c:getName() == name then return c end
    end
    return nil
end

-- Runs the compiled helper on the folder. Success means results.csv exists.
-- The helper's --debug output lands in Lightroom's lrc_console.log. The
-- helper reports the raw frame edges (--inset 0); the crop edge from the
-- settings is applied here, so the review window can move it later.
local function runDetector(folder, aspect)
    local exe = LrPathUtils.child(_PLUGIN.path, 'frameline-detect')
    local csv = LrPathUtils.child(folder, 'results.csv')
    if LrFileUtils.exists(csv) then
        LrFileUtils.delete(csv)
    end
    local cmd = shellQuote(exe) .. ' ' .. shellQuote(folder)
        .. string.format(' --inset 0 --aspect %.4f --debug', aspect)
    local rc = LrTasks.execute(cmd)
    log('helper exit code %s: %s', tostring(rc), cmd)
    return LrFileUtils.exists(csv), rc, exe
end

local function previewPath(tmp, i)
    return LrPathUtils.child(tmp, string.format('%04d.jpg', i))
end

-- Ask Lightroom for a rendered thumbnail; returns the JPEG bytes or nil, err.
local function fetchThumbnail(photo, timeout)
    local received, errMsg = nil, nil
    -- keep the request object alive until the callback has fired
    local request = photo:requestJpegThumbnail(2048, 2048, function(jpegData, err)
        if jpegData and #jpegData > 0 then
            received = jpegData
        else
            errMsg = tostring(err or 'empty')
        end
    end)
    local waited = 0
    while received == nil and waited < timeout do
        LrTasks.sleep(0.05)
        waited = waited + 0.05
    end
    local _ = request
    if received then
        return received, nil
    end
    return nil, string.format('no thumbnail after %.0fs (%s)', waited, errMsg or 'callback never fired')
end

-- Export the given photos as 2048px JPEGs into tmp, named by their index.
local function exportPreviews(photos, indexOf, tmp, progress)
    local session = LrExportSession {
        photosToExport = photos,
        exportSettings = {
            LR_exportServiceProvider = 'com.adobe.ag.export.file',
            LR_export_destinationType = 'specificFolder',
            LR_export_destinationPathPrefix = tmp,
            LR_export_useSubfolder = false,
            LR_collisionHandling = 'overwrite',
            LR_renamingTokensOn = false,
            LR_format = 'JPEG',
            LR_jpeg_quality = 0.85,
            LR_export_colorSpace = 'sRGB',
            LR_export_bitDepth = 8,
            LR_size_doConstrain = true,
            LR_size_resizeType = 'longEdge',
            LR_size_maxWidth = 2048,
            LR_size_maxHeight = 2048,
            LR_size_units = 'pixels',
            LR_size_doNotEnlarge = true,
            LR_outputSharpeningOn = false,
            LR_useWatermark = false,
            LR_minimizeEmbeddedMetadata = true,
            LR_removeLocationMetadata = true,
            LR_reimportExportedPhoto = false,
        },
    }
    local done = 0
    for _, rendition in session:renditions() do
        if progress:isCanceled() then return done end
        local ok, pathOrMsg = rendition:waitForRender()
        local i = indexOf[rendition.photo.localIdentifier]
        if ok and i then
            local dest = previewPath(tmp, i)
            if LrFileUtils.exists(dest) then LrFileUtils.delete(dest) end
            local moved = LrFileUtils.move(pathOrMsg, dest)
            log('%d: exported %s -> %s (%s)', i, tostring(pathOrMsg), dest, tostring(moved))
            done = done + 1
        else
            log('%s: export failed: %s', tostring(i), tostring(pathOrMsg))
        end
    end
    return done
end

LrTasks.startAsyncTask(function()

    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()
    if #photos == 0 then
        LrDialogs.message('Frameline', 'Select at least one photo first.')
        return
    end
    local prefs = Prefs.load()

    -- Photos Frameline already cropped are left alone: a selection of only
    -- those opens the review window; a mixed selection crops just the rest.
    -- Detect again in the review window is the way to redo on purpose.
    local todo, done = {}, {}
    for _, photo in ipairs(photos) do
        if Frame.dataFor(photo) and Frame.hasCrop(photo) then
            done[#done + 1] = photo
        else
            todo[#todo + 1] = photo
        end
    end
    if #todo == 0 then
        local verdict = Review.show(catalog, photos, prefs)
        if verdict ~= 'redetect' then return end
        todo, done = photos, {}
    end
    photos = todo
    local alreadyDone = #done

    -- Every run gets its own working folder, so runs started while another
    -- is still going cannot trample each other. Folders older than a day
    -- are tidied away; the recent ones stay for diagnosis (frameline.log).
    local base = LrPathUtils.getStandardFilePath('temp')
    local stamp = string.format('%s-%04d', os.date('%Y%m%d-%H%M%S'), math.random(0, 9999))
    local tmp = LrPathUtils.child(base, 'frameline_run_' .. stamp)
    for entry in LrFileUtils.directoryEntries(base) do
        local leaf = LrPathUtils.leafName(entry)
        if leaf:match('^frameline_run') and entry ~= tmp then
            local attrs = LrFileUtils.fileAttributes(entry)
            local modified = attrs and attrs.fileModificationDate
            if not modified or (LrDate.currentTime() - modified) > 86400 then
                LrFileUtils.delete(entry)
            end
        end
    end
    LrFileUtils.createAllDirectories(tmp)
    log('frameline %s run: %d photo(s) (%d already done), folder %s, border %.2f%%, format %s, straighten %s',
        Prefs.version, #photos, alreadyDone, tmp, prefs.border, prefs.format, tostring(prefs.straighten))

    local progress = LrProgressScope { title = 'Frameline' }
    progress:setCancelable(true)

    -- Phase 0: reset any existing crop. The preview Lightroom renders for us
    -- reflects the current crop, so without this a second run on an
    -- already-cropped photo would crop it again.
    local needReset = {}
    for _, photo in ipairs(photos) do
        if Frame.hasCrop(photo) then
            needReset[#needReset + 1] = photo
        end
    end
    if #needReset > 0 then
        progress:setCaption(string.format('Resetting %d existing crop(s)', #needReset))
        catalog:withWriteAccessDo('Frameline: reset crop', function()
            for _, photo in ipairs(needReset) do
                photo:applyDevelopSettings(Frame.noCrop, 'Frameline: reset crop')
            end
        end, { timeout = 60 })
        log('reset %d existing crop(s)', #needReset)
    end

    -- Phase 1: a preview of each photo into the temp folder.
    local missing, indexOf = {}, {}
    local stalls = 0
    for i, photo in ipairs(photos) do
        if progress:isCanceled() then writeLog(tmp); return end
        progress:setPortionComplete(i - 1, #photos * 2)
        progress:setCaption(string.format('Reading previews %d of %d', i, #photos))
        local name = photo:getFormattedMetadata('fileName')
        indexOf[photo.localIdentifier] = i

        local data, err = nil, 'skipped after repeated stalls, exporting instead'
        if stalls < STALLS_BEFORE_EXPORT then
            data, err = fetchThumbnail(photo, stalls == 0 and THUMB_TIMEOUT_FIRST or THUMB_TIMEOUT_AFTER_STALL)
            if data then stalls = 0 else stalls = stalls + 1 end
        end
        if data then
            local path = previewPath(tmp, i)
            local f, ferr = io.open(path, 'wb')
            if f then
                f:write(data)
                f:close()
                log('%d %s: thumbnail %d bytes -> %s', i, name, #data, path)
            else
                log('%d %s: cannot write %s: %s', i, name, path, tostring(ferr))
                missing[#missing + 1] = photo
            end
        else
            log('%d %s: %s', i, name, err)
            missing[#missing + 1] = photo
        end
    end

    -- Phase 1b: whatever did not come as a thumbnail is exported for real.
    if #missing > 0 then
        progress:setCaption(string.format('Exporting %d preview(s)', #missing))
        log('exporting %d photo(s) via LrExportSession', #missing)
        local okCount = exportPreviews(missing, indexOf, tmp, progress)
        log('export delivered %d of %d', okCount, #missing)
    end

    local previewCount = 0
    for i = 1, #photos do
        if LrFileUtils.exists(previewPath(tmp, i)) then previewCount = previewCount + 1 end
    end
    log('%d of %d previews in place', previewCount, #photos)
    if previewCount == 0 then
        writeLog(tmp)
        progress:done()
        LrDialogs.message('Frameline', 'Lightroom rendered no previews, so nothing was analysed.\n\n'
            .. table.concat(logLines, '\n'))
        return
    end

    -- Phase 2: run the detector on the whole folder at once.
    progress:setCaption('Detecting frames...')
    local ok, rc, exe = runDetector(tmp, Prefs.aspectFor(prefs.format))
    if not ok then
        writeLog(tmp)
        progress:done()
        LrDialogs.message('Frameline', string.format(
            'Frame detection failed to run (exit code %s).\nHelper: %s\nFolder: %s',
            tostring(rc), exe, tmp))
        return
    end

    -- Phase 3: read results and apply crops.
    -- index,l,t,r,b,status,sides,angle,avail,film
    -- status: ok = confident; check = cropped, but one side had weak
    -- evidence, worth a glance; skip = no usable frame found.
    -- sides: how each edge was found, e.g. run/run/inferred/run.
    -- angle: frame tilt in degrees, clockwise on screen positive.
    -- avail: clean border available outside each edge, L/T/R/B, fraction of the image.
    -- film: how far the film itself goes on outside each edge (sprocket
    -- holes and all), L/T/R/B, fraction of the image.
    local function fourOf(field)
        local v = {}
        for x in (field or ''):gmatch('[^/]+') do v[#v + 1] = math.max(0, tonumber(x) or 0) end
        return { l = v[1] or 0, t = v[2] or 0, r = v[3] or 0, b = v[4] or 0 }
    end
    local crops = {}
    local csv = LrPathUtils.child(tmp, 'results.csv')
    for line in io.lines(csv) do
        local i, l, t, r, b, status, sides, angle, avail, film =
            line:match('^(%d+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),(%a+),?([%a%-/]*),?([%d%.%-]*),?([%d%./%-]*),?([%d%./%-]*)')
        if i then
            crops[tonumber(i)] = { l = tonumber(l), t = tonumber(t),
                                   r = tonumber(r), b = tonumber(b),
                                   ok = (status == 'ok' or status == 'check'),
                                   check = (status == 'check'),
                                   sides = sides or '',
                                   angle = tonumber(angle) or 0,
                                   avail = fourOf(avail),
                                   film = fourOf(film) }
            log('result %s: %s', i, line)
        end
    end

    local cropped, flagged, skipped, clean, noRoom, fitted = 0, {}, {}, {}, {}, {}
    catalog:withWriteAccessDo('Frameline', function()
        local set = catalog:createCollectionSet(COLLECTION_SET, nil, true)
        local lookColl = catalog:createCollection(COLLECTION_LOOK, set, true)
        local skipColl = catalog:createCollection(COLLECTION_SKIPPED, set, true)
        for i, photo in ipairs(photos) do
            progress:setPortionComplete(#photos + i - 1, #photos * 2)
            progress:setCaption(string.format('Applying crops %d of %d', i, #photos))
            local c = crops[i]
            if c and c.ok then
                c.aspect = Prefs.aspectFor(prefs.format)
                local crop, note = Frame.cropFor(c, prefs.border, prefs.straighten, Frame.dimensions(photo), c.aspect, Frame.orientation(photo))
                photo:applyDevelopSettings(crop, 'Frameline')
                Frame.store(photo, c, c.sides, c.check and 'check' or 'ok', prefs.border, prefs.straighten, note)
                cropped = cropped + 1
                if note then
                    noRoom[#noRoom + 1] = photo
                    log('photo %d: %s', i, note)
                else
                    fitted[#fitted + 1] = photo
                end
                if c.check then
                    flagged[#flagged + 1] = photo
                    if prefs.label ~= 'none' then
                        photo:setRawMetadata('colorNameForLabel', prefs.label)
                    end
                else
                    clean[#clean + 1] = photo
                end
            else
                skipped[#skipped + 1] = photo
            end
        end
        -- the collections always reflect each photo's latest run
        if #flagged > 0 then lookColl:addPhotos(flagged) end
        if #skipped > 0 then skipColl:addPhotos(skipped) end
        local settled = {}
        for _, p in ipairs(clean) do settled[#settled + 1] = p end
        for _, p in ipairs(flagged) do settled[#settled + 1] = p end
        if #settled > 0 then skipColl:removePhotos(settled) end
        local notFlagged = {}
        for _, p in ipairs(clean) do notFlagged[#notFlagged + 1] = p end
        for _, p in ipairs(skipped) do notFlagged[#notFlagged + 1] = p end
        if #notFlagged > 0 then lookColl:removePhotos(notFlagged) end
        -- photos asked to show sprockets that have no film to show;
        -- the collection only exists once that has happened
        local roomColl = #noRoom > 0 and catalog:createCollection(COLLECTION_NOROOM, set, true)
            or findCollection(set, COLLECTION_NOROOM)
        if roomColl then
            if #noRoom > 0 then roomColl:addPhotos(noRoom) end
            if #fitted > 0 then roomColl:removePhotos(fitted) end
        end
    end, { timeout = 60 })

    progress:done()
    writeLog(tmp)

    -- One passing line. Anything that needs the user is in the collections.
    local summary = string.format('Cropped %d of %d', cropped, #photos)
    if alreadyDone > 0 then
        summary = summary .. string.format(' · %d already done', alreadyDone)
    end
    if #flagged > 0 then
        summary = summary .. string.format(' · %d worth a look', #flagged)
    end
    if #skipped > 0 then
        summary = summary .. string.format(' · %d skipped', #skipped)
    end
    if #noRoom > 0 then
        summary = summary .. string.format(' · %d without room for sprockets', #noRoom)
    end
    local needsYou = #flagged > 0 or #skipped > 0 or #noRoom > 0
    if needsYou then
        summary = summary .. '  →  Collections › Frameline'
    end
    LrDialogs.showBezel('Frameline ' .. Prefs.version .. ': ' .. summary, needsYou and 4 or 2.5)
end)
