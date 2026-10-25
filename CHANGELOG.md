# Changelog

## 0.1.4 

### Added
- glTF and font validation (`-Dvalidate_input=false`).
- NVIDIA DLSS: `Upscaler.dlss`.
- DLSS Ray Reconstruction for path tracing.
- `zig build dlss-sdk`.
- Path tracing: normal maps.
- Path tracing: resampled lamp and glow light.
- `Settings.path_tracing_probes`.
- `entities.setTransforms`.
- Entity setters work mid-frame.
- `rhi.Device.caps` and `rhi.native`.
- `rhi.Capabilities` limits and per-format support.
- Compute pipelines take specialization constants; `rhi.Device.compileComputePipeline`.
- `rhi.Device.storageArrayIndex`: storage views of every layer.
- `rhi.CommandEncoder.buildBlases` and `updateTlas`.
- `Stats.pipelines`.
- `--uneven-frames` for headless example runs.
- `Stats.commands`, `Stats.frame_data_bytes` and `PassTiming.work`.
- `zig build costs`.
- `Settings.lightweight` and the `lightweight` example.
- `PassStage.sun_shadow` and `.light_shadow`, `PassContext.layer` and `.origin`, `Pass.moving`.
- `Settings.post.tone_curve`.
- The `passes` example.
- `--memory N` for headless example runs.
- `GeometryStreaming` exported.
- `rhi.Capabilities.unified_memory`: integrated and software GPUs write GPU-only buffers without staging.
- `zig build costs -- --device NAME`.
- `Camera.valid`, `TextureInfo.usage`, `MaterialShader.generation`.
- A lost device logs where it faulted, where the driver reports it.
- The `canvas` example takes `--screenshot` and `--timings`.
- `DrawStage.scene`: draw lists under bloom, exposure and tone mapping, with or without a scene.
- `DrawStage.under`: draw lists behind the scene, where no surface is.
- `Renderer.lights` and `Renderer.decals`: single lights and decals by handle, beside `scenes.setLights` and `setDecals`.
- `Pass.reads`, `PassStage.after_resolve`, and `PassContext.visibility` and `ambient_occlusion`.
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
- `ViewDesc.cut`: temporal history starts over after a camera jump.
- `Options.deterministic`: runs of the same frames give the same picture; `--screenshot` turns it on.
- `rhi.TextureKind.@"3d"`; storage images can be read, used in any shader stage and bound per layer.
- `CloudDesc.weather`, `weather_size`, `kind` and `curl`.
- `HairDesc.variation`, `clump`, `curl`, `curl_turns` and `frizz`.
- `LiquidDesc.scatter` and `foam`: lit liquid body and whitewater.
- The `clouds` example takes `--kind`, `hair` takes `--orbit` and `--blonde`, `liquid` takes `--orbit`.
- `Camera.project`, `ray` and `viewProjection`.
- `entities.setParent` and `entities.info`.
- `Material.unlit`, also from `KHR_materials_unlit`.
- `primitives` and `models.createPrimitive`.
- `MeshDesc.textures`.
- `DrawList.measureText`.
- `views.saveTarget`.

### Changed
- `render` fails with `error.InvalidDeltaTime`, `error.InvalidCamera` or `error.InvalidTarget` for a bad frame, `Renderer.init` with `error.InvalidOptions`.
- `entities.setTransforms` pairs the slices up to the shorter one.
- Liquids with more than four sources fail with `error.TooManyLiquidSources`.
- `decals.create` past the limit fails with `error.TooManyDecals`, as `setDecals` does.
- `bc7_partitions` is no longer public.
- `entities.spawn`/`despawn` are `entities.create`/`destroy`.
- `Light` is `LightDesc`, `LightHandle` is `Light`, `DecalHandle` is `Decal`, `Sun` is `SunDesc`.
- `instances.set` is `setTransforms`, `instances.setPose` is `followPose`, `probes.update` is `recapture`, `getStats` is `stats`, `liquids.particles` is `particleCount`, `fluids.flipbookFrames` is `flipbookFrameCount`.
- `Renderer.probes` is `Renderer.reflection_probes`.
- `models.destroy` cannot fail: a model in use is freed when its last entity or group goes.
- `materials.setShader` takes the material index as an argument; `ShaderAssignment.material` is gone.
- `images.createCompressed` is `ImageDesc.compressed`; `writeKtx2` takes an `ImageDesc`; `images.update` takes a `Region`.
- `max_blur_pixels`, `blur_radius_pixels`, `paper_white_nits`, `peak_nits`, `ImpostorDesc.max_pixels`, `ambient_occlusion.power`.
- `loadSceneLights` and `SceneLight` are `models.loadLights`, which returns `LightDesc`s.
- `SunDesc.intensity` and `FrameDesc.delta_time` have no default.
- Renderer internals (`ensureSceneResources`, `tryLock`, `queueEdit`, `markOf`, `moveEntity` and the like) are no longer methods.
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
- Every shader is Slang; `glslc` is only needed to build the FidelityFX SDK.
- Breaking: custom material shaders are Slang, include "shade.slang" and are compiled with entry `fragmentMain`; see `examples/shaders/lava.slang`.
- Slang shaders mark the buffers they only read as read-only, as GLSL did; probe GI and culling run faster.
- `rhi.CommandEncoder` returns drawn and copied textures to `shader_read` itself, before the next work that could sample them.
- Breaking: `rhi.Device.endImmediate` takes the encoder.
- Breaking: shaders read a feature's frame constants from its block (`frame.shadows`, `frame.lights`, `frame.gi`, `frame.shading` and so on), and the `FRAME_*` flags are fields of those blocks.
- Breaking: `Renderer` fields other than the namespaces, `options` and `device` are in `Renderer.internal`.
- Breaking: `environments.load` takes an `EnvironmentDesc`.
- Breaking: `rhi.BlasDesc` holds a list of `rhi.BlasGeometry`; `createTlas` takes a `rhi.TlasDesc`.
- Pipelines are built on first use, kept by their description; any can compile on a worker thread.
- A renderer that draws no scene makes no scene buffers.
- The frame constants in shaders are generated from `frame_constants.zig`.
- The shaders' push constants are generated from `src/render/shaders/push`.
- Fewer FidelityFX shader permutations compiled.
- Only changed entities are prepared each frame.
- Animation poses skip unmoved nodes.
- Cheaper GI probes and texture streaming.
- Path tracing keeps its picture while the scene changes.
- Path traced lamp light is no longer blurred.
- Clouds fade into the air between them and the eye, take the sun's full colour, and are lit by sky through the cloud around them.
- The sky reaches below level when seen from high up.
- Hair is shaded as fibres (Marschner lobes), shadows itself through its density, and lets light through in shadow maps.
- Liquid particles are drawn as ellipsoids along their neighbours; the liquid reflects the scene.
- Breaking: `LiquidDesc.murk` defaults to 1.5.
- Breaking: destroyed images, fonts and canvas shaders are refused (`error.InvalidImage`, `InvalidFont`, `InvalidShader`) or sample nothing; `Image.id` is required, `CanvasShader` has a `generation`.
- `fonts.destroy` keeps the font readable until the renderer is destroyed.
- Breaking: namespace state, `DrawList` state and `rhi.Device`'s split frame loop are behind `internal` fields (`device.internal.startFrame`, ...).
- Breaking: `Material` defaults to metallic 0 and roughness 0.6 for `MeshDesc` too; glTF files still start from 1 and 1.



### Fixed
- Two uploads to the same buffer range or texture level in one frame raced each other.
- Features switched off on a view give their memory back.
- Path tracing restarts its history after frames it did not trace.
- Impostor textures and reflection probes are freed with the renderer.
- Particle trails are freed with the renderer.
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
- Water and liquid gaining energy at uneven frame rates.
- Bloom drawn with bloom, automatic exposure and lens flare off.
- 128 KiB of per-frame data reserved for threads that were not used.
- Heap allocations every frame while preparing lights.
- GPU memory held for features and geometry a scene does not use.
- Decal texture derivatives in divergent shader code.
- Attachments left in the wrong state after a failed `beginRendering`.
- A data race on the swapchain's out-of-date flag with paced presentation.
- Shader reloading half applied when it ran out of memory.
- Unbounded work shaping text with a malicious font.
- Application task and mesh shaders sampling textures without a barrier.
- GPU faults drawing custom materials.
- Mirrored instances drawn inside out.
- Crashes from bad mesh attribute lengths, collision meshes, sprite sheets, rounded rects, liquid and fluid sizes, IES files and oversized textures.
- Stale material shader handles selecting another shader.
- Custom material use counts underflowing with specular-glossiness materials.
- Fluid and water textures lost when a resize failed.

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
