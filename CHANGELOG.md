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
- `rhi.Device.caps` and `rhi.native`.
- `Stats.pipelines`.
- The `canvas` example takes `--screenshot` and `--timings`.
- `DrawStage.scene`: draw lists under bloom, exposure and tone mapping, with or without a scene.
- `Stats.downgraded`.
- `DrawList.setBlend`, `setLayer` and `setShader`; `Renderer.canvas.createShader`.
- The `canvas` example takes `--lit` and `--effects`.
- `Camera.orthographic`, for scenes and draw lists.
- `Settings.global_illumination.probes.cascades`: up to four probe grids.
- `Settings.path_tracing.direct`.
- `Settings.resolution.edge_antialiasing`: antialiasing from the finished picture alone, for views without TAA.
- `--timings` prints the slowest frame; the `bistro` example takes `--walk`.
- NVIDIA NRD (ReLAX) as a path tracing denoiser: `Denoiser.nrd`, `zig build nrd-sdk`; the `pathtrace` and `rtx` examples take `--nrd`.
- `Settings.path_tracing.nrd`: history length and pre-blur radius for NRD.
- `Settings.global_illumination.probes.idle_interval`: probes are re-traced less often while the scene and its lights are still.
- `Pass` runs on views without a scene; `PassContext` has the camera, its matrices and the resolved settings.
- The `isometric` example.
- `rhi.TextureKind.@"3d"`; storage images can be read, used in any shader stage and bound per layer.

### Changed
- Breaking: handles are 64 bits.
- Breaking: `views.targetImage` can fail with `error.InvalidTarget`.
- Breaking: `shaders.reload` needs `-Dshader_reload` outside Debug.
- Breaking: `materials.createShader` takes a `PLAIN` shader or null.
- Breaking: setters and `destroy` ignore destroyed handles.
- Breaking: `Options.pose_threads` is `worker_threads`.
- Breaking: `Options.mesh_shaders` is off by default.
- Breaking: `Device.ray_tracing`, `mesh_shaders` and the like are in `Device.caps`.
- Breaking: `rhi.instanceProcAddr` and `deviceProcAddr` are in `rhi.native.device`.
- Breaking: traced reflections, traced light shadows and path tracing work without `global_illumination`.
- Ray traced reflections, probes, lightmaps and path tracing share one trace and surface shader library.
- Breaking: `ViewDesc.draw_lists` holds `DrawLayer`s.
- Breaking: `Settings` is nested by feature (`shadows`, `reflections`, `global_illumination`, `post`, `resolution`, ...); a feature that can be off is an optional, null for off.
- Breaking: fog, depth of field, motion blur and path tracing are off as null, not as a zero strength.
- Breaking: `shadows = null` also turns off ray traced light shadows.
- Breaking: `Settings.resolution.upscaling` is `upscaler`, of type `Upscaler`; `frame_generation` is null or `.fsr3`.
- Breaking: `Settings.path_tracing.denoise` is `denoiser`; DLSS Ray Reconstruction is asked for with `.ray_reconstruction`.
- Breaking: `Settings.global_illumination` names its technique: `.{ .probes = .{} }`. `middle_ratio` is `cascade_ratio`.
- An upscaler, frame generator or denoiser that cannot run is listed in `Stats.downgraded`.
- Breaking: `Options` is nested: `ray_tracing`, `shadows`, `textures`, `geometry`, `cache`. `ray_tracing` is `ray_tracing.hardware`, `path_tracing_fallback` is `ray_tracing.software_path_tracing`.
- Breaking: `Renderer.capabilities` replaces `pathTracing`, `dlssSupport` and `hdrActive`.
- Breaking: `images.create`, `environments.load`, `materials.setShader` and `scenes.setEnvironment` take a struct.
- Breaking: `PassContext.depth` and `motion` are optional.
- Breaking: `rhi.Device.storageIndex` takes a layer; `CommandEncoder.copyDepthToColor` is gone.
- Path tracing runs in a compute shader where storage images are available.
- Acceleration structures of static meshes are compacted after they are built.
- The high preset traces 64 rays per probe and 2 shadow rays per lamp.
- Temporal antialiasing keeps less history of what moves, so motion blurs and trails less.
- A probe grid that follows the camera to a new cell seeds the probes it moves onto from the coarser grid; it no longer re-traces every probe that frame.
- The `pathtrace` example's walls no longer overlap, which showed as speckles in motion.
- Path tracing: the tracer writes what one frame's paths found, and gathering it over frames is a step of the denoiser.
- The Vulkan code of the RHI is in `src/rhi/vulkan/`.
- Breaking: the `PathTracing` enum is `PathTracingSupport`.
- Switching an effect on or off keeps the view's other targets and history.
- Draw lists send rectangles, sprites and glyphs to the GPU as one record each, and keep the GPU copy of a list drawn again unchanged.
- Building needs `slangc`: shaders are moving from GLSL to Slang.
- Pipelines are built on first use.
- A renderer that draws no scene makes no scene buffers.
- The frame constants in shaders are generated from `frame_constants.zig`.
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
