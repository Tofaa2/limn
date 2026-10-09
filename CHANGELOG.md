# Changelog

## Unreleased

### Added
- Validation of glTF files and font glyph sizes (`-Dvalidate_input=false` leaves it out).
- `entities.setTransforms`, and entity setters that do not wait for a frame being recorded.

### Changed
- Breaking: handles are 64 bits, so a reused slot no longer revives a stale handle.
- Breaking: `views.targetImage` fails with `error.InvalidTarget` for a destroyed target.
- Breaking: `shaders.reload` needs `-Dshader_reload` outside Debug builds.
- Breaking: `materials.createShader` takes a second shader, compiled with `PLAIN`, or null.
- Breaking: setters and `destroy` ignore a destroyed handle instead of failing.
- Breaking: `Options.pose_threads` is `worker_threads`, and instance records are written across threads too.
- Breaking: `Options.mesh_shaders` is off by default; indirect draws are faster.
- Only the FidelityFX shader permutations in use are compiled.
- Only entities that changed are prepared each frame, and their moves are applied on the GPU.
- Animation poses skip the nodes no clip moves.
- Global illumination probes and texture streaming cost less.

### Removed
- The verification scene and `zig build scene`.

### Fixed
- Tint, params, `receive_decals` and `rays_only` on skinned entities.
- Global illumination restarting when a scene has a reflection probe or several views.
- Shadows of local lights and virtual shadow maps with several views or skipped frames.
- Swapchain rebuilds that fail, and minimised windows.
- Particle collision without temporal antialiasing.
- Trails behind moving objects with temporal antialiasing.
- Traced soft shadows lagging on surfaces the camera uncovers.
- Texture streaming with an empty or unbounded view.
- Malformed font, KTX2 and DDS files, and glTF image names with percent escapes.
- The model cache missing a changed `.bin` file or `normal_maps_bc5`.
- A leak when a streamed model runs out of memory while loading.
- Example flags that take no value, such as `--vrs`.

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
