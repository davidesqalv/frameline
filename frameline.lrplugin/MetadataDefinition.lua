-- Fields Frameline stores on each photo it crops. Lightroom requires them
-- to be declared here before setPropertyForPlugin may write them. Fields
-- without a title are internal; "Frameline" shows in the Metadata panel
-- (choose the Frameline or "All Plug-in Metadata" view).

return {
    metadataFieldsForPhotos = {
        { id = 'frameline_edges',   dataType = 'string' },   -- raw frame edges l,t,r,b (0-1 margins)
        { id = 'frameline_sides',   dataType = 'string' },   -- how each edge was found, e.g. run/run/inferred/run
        { id = 'frameline_status',  dataType = 'string' },   -- ok | check
        { id = 'frameline_border',  dataType = 'string' },   -- border percent applied
        { id = 'frameline_summary', dataType = 'string', title = 'Frameline', readOnly = true, searchable = true, browsable = true },
    },
    schemaVersion = 1,
}
