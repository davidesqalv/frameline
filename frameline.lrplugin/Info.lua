return {
    LrSdkVersion = 6.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = 'com.frameline.plugin',
    LrPluginName = 'Frameline',
    LrInitPlugin = 'Init.lua',
    LrMetadataProvider = 'MetadataDefinition.lua',

    LrLibraryMenuItems = {
        { title = 'Frameline', file = 'CropMenuItem.lua' },
        { title = 'Frameline Settings…', file = 'Settings.lua' },
    },
    LrExportMenuItems = {
        { title = 'Frameline', file = 'CropMenuItem.lua' },
        { title = 'Frameline Settings…', file = 'Settings.lua' },
    },

    VERSION = { major = 0, minor = 3, revision = 22 },
}
