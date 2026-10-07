# Film Auto-Crop (Lightroom Classic plugin)

Auto-crops scanned film frames in Lightroom Classic: finds the picture edge,
straightens and crops it (or keeps the film rebate), and reports the Border
Buffer Negative Lab Pro needs for each frame.

Install: Lightroom Classic > File > Plug-in Manager > Add > this folder.
Use: select frames, then Library > Plug-in Extras > Film Auto-Crop...

Full documentation: the README at the root of the repository.

| File | Role |
|---|---|
| `Info.lua` | plugin manifest, menu entries, metadata |
| `MenuAutoCrop.lua`, `MenuAutoCropQuick.lua` | the two menu commands |
| `Settings.lua` | options dialog and saved preferences |
| `AutoCropLr.lua` | Lightroom side: export for analysis, apply crops, check, report |
| `AutoCropCore.lua` | batch logic: roll frame size, crop modes, grading |
| `FrameDetect.lua` | frame and film-edge detection (no Lightroom dependency) |
| `CropMath.lua` | crop geometry, Lightroom crop coordinates, Border Buffer |
| `TiffReader.lua` | reads the uncompressed TIFF exported for analysis |
| `MetadataDefinition.lua`, `Tagset.lua` | the Film Auto-Crop metadata fields and panel preset |
