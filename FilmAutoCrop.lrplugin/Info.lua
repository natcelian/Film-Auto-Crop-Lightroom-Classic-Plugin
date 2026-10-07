-- Film Auto-Crop for Lightroom Classic (Silver Nodes): finds the picture of
-- scanned film frames, straightens and crops it.

return {
	LrSdkVersion = 10.0,
	LrSdkMinimumVersion = 6.0,
	LrToolkitIdentifier = "com.silvernodes.filmautocrop",
	LrPluginName = "Film Auto-Crop",

	LrLibraryMenuItems = {
		{ title = "Film Auto-Crop...", file = "MenuAutoCrop.lua", enabledWhen = "photosSelected" },
		{ title = "Film Auto-Crop (last settings)", file = "MenuAutoCropQuick.lua", enabledWhen = "photosSelected" },
	},
	LrExportMenuItems = {
		{ title = "Film Auto-Crop...", file = "MenuAutoCrop.lua", enabledWhen = "photosSelected" },
		{ title = "Film Auto-Crop (last settings)", file = "MenuAutoCropQuick.lua", enabledWhen = "photosSelected" },
	},

	LrMetadataProvider = "MetadataDefinition.lua",
	LrMetadataTagsetFactory = "Tagset.lua",

	VERSION = { major = 1, minor = 1, revision = 0, build = 1 },
}
