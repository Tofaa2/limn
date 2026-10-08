# Changelog

## 0.1.3

### Changed
- Breaking: `Renderer` methods are grouped by what they act on, as `renderer.models`, `materials`, `environments`, `scenes`, `entities`, `instances`, `emitters`, `probes`, `fluids`, `waters`, `liquids`, `hairs`, `views`, `fonts`, `images` and `shaders`. `renderer.loadModel(path)` is `renderer.models.load(path)`, `renderer.spawn` is `renderer.entities.spawn`, `renderer.createWater` is `renderer.waters.create`, and so on.

### Fixed
- The FidelityFX SDK builds on Windows.

## 0.1.2

### Added
- Upscaling with FSR 1, FSR 2 and FSR 3, and FSR 3 frame generation (`-Dfidelityfx=false` leaves the SDK out).
- Hair: strands with simulation, colliders and collision fields.
- Virtual shadow maps and staggered cascade updates.
- Mesh shader path, occlusion culling and variable rate shading.
- Impostors for instance groups.
- Lightmap baking.
- Stereo cameras (`Camera.stereo`) and lens shift.
- DDS textures.
- Examples: `asteroids`, `bistro`, `hair`, `lightmap`, `shadows`, `stereo`, `upscaling`, `voxels`.
- API docs published to GitHub Pages.

### Changed
- Reflections are denoised with the FidelityFX reflection denoiser.
- `renderer.zig` and `rhi/device.zig` are split into topic files
