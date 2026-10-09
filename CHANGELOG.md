# Changelog

## 0.1.4 

### Added
- glTF and font validation (`-Dvalidate_input=false`).
- NVIDIA DLSS: `Upscaling.dlss`, `Renderer.dlssSupport`.
- DLSS Ray Reconstruction for path tracing.
- `zig build dlss-sdk`.
- Path tracing: normal maps.
- Path tracing: resampled lamp and glow light.
- `Settings.path_tracing_probes`.
- `entities.setTransforms`.
- Entity setters work mid-frame.

### Changed
- Breaking: handles are 64 bits.
- Breaking: `views.targetImage` can fail with `error.InvalidTarget`.
- Breaking: `shaders.reload` needs `-Dshader_reload` outside Debug.
- Breaking: `materials.createShader` takes a `PLAIN` shader or null.
- Breaking: setters and `destroy` ignore destroyed handles.
- Breaking: `Options.pose_threads` is `worker_threads`.
- Breaking: `Options.mesh_shaders` is off by default.
- Fewer FidelityFX shader permutations compiled.
- Only changed entities are prepared each frame.
- Animation poses skip unmoved nodes.
- Cheaper GI probes and texture streaming.
- Path tracing keeps its picture while the scene changes.
- Path traced lamp light is no longer blurred.



### Fixed
- Tint, params and flags on skinned entities.
- GI restarting with reflection probes or several views.
- Local light and virtual shadows with several views.
- Failed swapchain rebuilds and minimised windows.
- Particle collision without TAA.
- TAA trails behind moving objects.
- Traced soft shadows lagging on uncovered surfaces.
- Texture streaming with an empty or unbounded view.
- Malformed font, KTX2, DDS and glTF files.
- Stale model cache entries.
- A leak when a streamed model runs out of memory.
- Example flags that take no value.

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
