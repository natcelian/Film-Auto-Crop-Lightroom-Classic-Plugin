-- Fields Film Auto-Crop writes on each photo (Metadata panel > Film Auto-Crop)
return {
	metadataFieldsForPhotos = {
		{ id = "nlpBorderBuffer", title = "NLP Border Buffer", dataType = "string",
			readOnly = true, searchable = true, browsable = true },
		{ id = "autoCropStatus", title = "Auto-Crop", dataType = "string",
			readOnly = true, searchable = true, browsable = true },
	},
	schemaVersion = 1,
}
