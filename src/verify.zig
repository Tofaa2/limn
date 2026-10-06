const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const canvas_scene = @import("canvas_scene");

/// Reads the flags, builds the scene they ask for, renders it and reports.
pub fn main(init: std.process.Init) !void {
    var output: []const u8 = "world.png";
    var width: u32 = 1920;
    var height: u32 = 1080;
    var frame_argument: ?u32 = null;
    var validation = false;
    var camera_position: math.Vec3 = .{ 8.5, 2.1, -0.6 };
    var camera_target: math.Vec3 = .{ 0.0, 2.4, -0.2 };
    var settings: gfx.Settings = .{};
    var sun_direction: math.Vec3 = .{ -0.42, -1.0, 0.18 };
    var sun_intensity: f32 = 28;
    var environment_intensity: f32 = 1.0;
    // Stress modes: move the camera and character every frame, and churn
    // through load/spawn/despawn/destroy cycles while rendering.
    var motion = false;
    var soak_cycles: u32 = 0;
    var compact_test = false;
    var coarse_test = false;
    var coarse_near = false;
    var helmet = false;
    var lights = false;
    var glass = false;
    // Optional sub-rectangle {x, y, width, height} of the frame to write.
    var crop: ?[4]u32 = null;
    // Draw-list coverage: a HUD and world-space labels over the scene, or
    // the 2D demo with no scene at all.
    var overlay = false;
    var canvas = false;
    var multi_view = false;
    var custom_pass = false;
    var sky = false;
    var sky_sweep = false;
    var sky_spread: u32 = 1;
    var sky_turbidity: f32 = 2.5;
    var instance_count: usize = 0;
    var instances_as_entities = false;
    var wave = false;
    var coat = false;
    var decals = false;
    var decal_count: usize = 0;
    var decal_ktx2: ?[]const u8 = null;
    var decal_bc1: ?[]const u8 = null;
    var streaming: ?gfx.TextureStreaming = null;
    var shift_frame: ?usize = null;
    var clouds = false;
    var bumps = false;
    var compress_images = false;
    var fluid_frame: ?[]const u8 = null;
    var fluid_flipbook: ?[]const u8 = null;
    var fluid_sharp = false;
    var fluid_lamp = false;
    var tube_shadows = false;
    var fire_size: f32 = 0;
    var light_size: f32 = 0;
    var text_fallback = false;
    var shape_font: ?[]const u8 = null;
    var geometry_distance: ?f32 = null;
    var geometry_coarse: f32 = 0;
    var teleport_frame: ?u32 = null;
    var teleport_to: [6]f32 = @splat(0);
    var shape_text: []const u8 = "";
    var coat_maps = false;
    var flat_panes = false;
    var transform_panel = false;
    var panel_model: []const u8 = "examples/assets/panel/panel.gltf";
    var bc7_test = false;
    var many_lights: usize = 0;
    var terrain = false;
    var mirror_panel = false;
    var mirror_far = false;
    var reflection_probe = false;
    var probe_settle: u32 = 40;
    var lens_pane = false;
    var cloud_coverage: f32 = 0.6;
    var cloud_lighting = true;
    var morph_row: ?[]const u8 = null;
    var pane_row: enum { none, group, entities } = .none;
    var cube_env: ?[]const u8 = null;
    var ktx2_model: ?[]const u8 = null;
    var crowd: usize = 0;
    var crowd_sync = false;
    var crowd_group = false;
    var gi_dynamic_refits: u32 = 0;
    var instance_params = false;
    var shader_variants = true;
    var meshlet_bounds = false;
    var cluster_lods = false;
    var lod_normal_weight: ?f32 = null;
    var lod_uv_weight: ?f32 = null;
    var sort_test = false;
    var wax = false;
    var no_player = false;
    var static_gi = false;
    var morph = false;
    var bc7_normals = false;
    var aniso = false;
    var cache_limit: u64 = 0;
    var tube = false;
    var panel = false;
    var sheen = false;
    var tints = false;
    var lut: ?[]const u8 = null;
    var stars = false;
    var fluid = false;
    var particles = false;
    var custom_material = false;
    var fail_frame: ?usize = null;
    var oom_rounds: usize = 0;
    var gpu_oom_rounds: usize = 0;
    var flicker_frames: usize = 0;
    var reload_frame: ?usize = null;
    var debug_names = @import("builtin").mode == .Debug;
    var profile = false;
    var zone_log = ZoneLog{ .io = init.io };
    var reference: ?[]const u8 = null;
    var update_reference = false;
    var tolerance: f32 = 2.0;
    var compression: gfx.TextureCompression = .bc7;
    var cache_dir: ?[]const u8 = null;
    var pick_pixel: ?[2]u32 = null;
    var picked: ?gfx.PickResult = null;
    // Worker tasks hammering the renderer API while frames are rendered.
    var thread_count: u32 = 0;
    // Fixed workload for measuring: a camera orbit, a warm-up, then per-pass
    // medians over `frames` frames.
    var bench = false;
    var max_quality = false;

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--output")) {
            output = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--width")) {
            width = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--height")) {
            height = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--frames")) {
            frame_argument = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--validation")) {
            validation = true;
        } else if (std.mem.eql(u8, arg, "--camera")) {
            for (&camera_position) |*value| value.* = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
            for (&camera_target) |*value| value.* = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--sun")) {
            for (&sun_direction) |*value| value.* = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--env")) {
            environment_intensity = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--sun-intensity")) {
            sun_intensity = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--crop")) {
            var rect: [4]u32 = undefined;
            for (&rect) |*value| value.* = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
            crop = rect;
        } else if (std.mem.eql(u8, arg, "--overlay")) {
            overlay = true;
        } else if (std.mem.eql(u8, arg, "--bench")) {
            bench = true;
        } else if (std.mem.eql(u8, arg, "--threads")) {
            thread_count = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--canvas")) {
            canvas = true;
        } else if (std.mem.eql(u8, arg, "--pick")) {
            var pixel: [2]u32 = undefined;
            for (&pixel) |*value| value.* = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
            pick_pixel = pixel;
        } else if (std.mem.eql(u8, arg, "--fail-frame")) {
            fail_frame = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--gpu-oom")) {
            gpu_oom_rounds = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--oom")) {
            oom_rounds = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--no-compress")) {
            compression = .none;
        } else if (std.mem.eql(u8, arg, "--stream")) {
            // Texture streaming with a budget in MiB; 0 means no limit.
            const megabytes = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
            streaming = .{ .budget_bytes = megabytes * 1024 * 1024, .evict_delay_frames = 8 };
        } else if (std.mem.eql(u8, arg, "--stream-visible")) {
            // After --stream: only what the camera can see asks for detail.
            if (streaming) |*value| value.visible_only = true;
        } else if (std.mem.eql(u8, arg, "--stream-skip-occluded")) {
            // After --stream: only what the camera drew asks for detail.
            if (streaming) |*value| value.skip_occluded = true;
        } else if (std.mem.eql(u8, arg, "--stream-from-cache")) {
            // After --stream: large levels are read from the asset cache.
            if (streaming) |*value| value.from_cache = true;
        } else if (std.mem.eql(u8, arg, "--shift-frame")) {
            // Shifts the whole scene far away on this frame; nothing should show.
            shift_frame = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--cloud-coverage")) {
            cloud_coverage = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--no-cloud-lighting")) {
            // The clouds are drawn but left out of the sky's lighting.
            cloud_lighting = false;
        } else if (std.mem.eql(u8, arg, "--clouds")) {
            clouds = true;
        } else if (std.mem.eql(u8, arg, "--fluid")) {
            fluid = true;
        } else if (std.mem.eql(u8, arg, "--cache-limit")) {
            // Megabytes the asset cache is trimmed to at startup.
            cache_limit = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10) * 1024 * 1024;
        } else if (std.mem.eql(u8, arg, "--cache")) {
            cache_dir = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--flicker")) {
            flicker_frames = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--mip-bias")) {
            settings.texture_mip_bias = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--no-specular-aa")) {
            settings.specular_antialiasing = false;
        } else if (std.mem.eql(u8, arg, "--sharpen")) {
            settings.sharpen = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--reference")) {
            reference = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--update-reference")) {
            update_reference = true;
        } else if (std.mem.eql(u8, arg, "--tolerance")) {
            tolerance = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--names")) {
            debug_names = true;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            profile = true;
        } else if (std.mem.eql(u8, arg, "--reload-frame")) {
            reload_frame = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--material")) {
            custom_material = true;
        } else if (std.mem.eql(u8, arg, "--particles")) {
            particles = true;
        } else if (std.mem.eql(u8, arg, "--ktx2")) {
            // Stores the decal picture as a KTX2 file at this path and loads it back.
            decal_ktx2 = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--ktx2-model")) {
            // Writes a panel model whose texture is a BC1 KTX2 file into
            // this directory, loads it and stands it in the scene.
            ktx2_model = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--cube-env")) {
            // Writes a half-float cube map to this KTX2 file and uses it
            // as the environment.
            cube_env = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--morph-row")) {
            // Writes a model of twelve tiles with a morph target each into
            // this directory and raises four of them by their weights.
            morph_row = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--ktx2-bc1")) {
            // With --decals: the decal picture is a BC1 checkerboard written to
            // this KTX2 file and loaded back.
            decal_bc1 = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--decal-count")) {
            // Scatters this many small marks over the floor (with --decals).
            decal_count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--decals")) {
            decals = true;
        } else if (std.mem.eql(u8, arg, "--coat")) {
            coat = true;
        } else if (std.mem.eql(u8, arg, "--wave")) {
            wave = true;
        } else if (std.mem.eql(u8, arg, "--instances")) {
            instance_count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--entities")) {
            instance_count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
            instances_as_entities = true;
        } else if (std.mem.eql(u8, arg, "--sky")) {
            sky = true;
        } else if (std.mem.eql(u8, arg, "--sky-sweep")) {
            sky = true;
            sky_sweep = true;
        } else if (std.mem.eql(u8, arg, "--turbidity")) {
            sky_turbidity = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--custom-pass")) {
            custom_pass = true;
        } else if (std.mem.eql(u8, arg, "--views")) {
            multi_view = true;
        } else if (std.mem.eql(u8, arg, "--pane-row")) {
            // With --glass: a row of tinted panes, as one instance group
            // ("group") or as separate entities ("entities").
            const how = args.next() orelse return error.MissingValue;
            pane_row = if (std.mem.eql(u8, how, "group")) .group else if (std.mem.eql(u8, how, "entities")) .entities else return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--lens-pane")) {
            // With --glass: a tinted pane behind the lens.
            lens_pane = true;
        } else if (std.mem.eql(u8, arg, "--layered-refraction")) {
            settings.layered_refraction = true;
        } else if (std.mem.eql(u8, arg, "--glass")) {
            glass = true;
        } else if (std.mem.eql(u8, arg, "--many-lights")) {
            // This many small colored lights in rows along the hall.
            many_lights = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--bounce-lights")) {
            settings.gi_bounce_lights = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--lights")) {
            lights = true;
        } else if (std.mem.eql(u8, arg, "--helmet")) {
            helmet = true;
        } else if (std.mem.eql(u8, arg, "--motion")) {
            motion = true;
        } else if (std.mem.eql(u8, arg, "--coarse-test")) {
            // A detailed ball far down the hall: with
            // `--geometry-coarse` it keeps only its coarser levels.
            coarse_test = true;
        } else if (std.mem.eql(u8, arg, "--coarse-near")) {
            // Then brought up close, where it must be whole again.
            coarse_near = true;
        } else if (std.mem.eql(u8, arg, "--compact-test")) {
            // A large model made and dropped again while a later one
            // stays: the gap it leaves in the geometry pools must be
            // closed.
            compact_test = true;
        } else if (std.mem.eql(u8, arg, "--soak")) {
            soak_cycles = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--no-taa")) {
            settings.temporal_antialiasing = false;
        } else if (std.mem.eql(u8, arg, "--no-shadows")) {
            settings.shadows = false;
        } else if (std.mem.eql(u8, arg, "--ao-res")) {
            settings.ao_resolution = std.meta.stringToEnum(gfx.EffectResolution, args.next() orelse return error.MissingArgument) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--fog-res")) {
            settings.fog_resolution = std.meta.stringToEnum(gfx.EffectResolution, args.next() orelse return error.MissingArgument) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--gi-res")) {
            settings.gi_resolution = std.meta.stringToEnum(gfx.EffectResolution, args.next() orelse return error.MissingArgument) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--gi-interval")) {
            settings.gi_update_interval = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--max-quality")) {
            // Everything at its most expensive setting.
            settings.ao_resolution = .full;
            settings.fog_resolution = .full;
            settings.gi_resolution = .full;
            settings.gi_update_interval = 1;
            settings.gi_rays = 256;
            settings.fog_steps = 48;
            settings.ao_slices = 4;
            settings.ao_steps = 12;
            settings.shadow_cascade_stagger = false;
            max_quality = true;
        } else if (std.mem.eql(u8, arg, "--no-gi")) {
            settings.global_illumination = false;
        } else if (std.mem.eql(u8, arg, "--no-occlusion")) {
            settings.occlusion_culling = false;
        } else if (std.mem.eql(u8, arg, "--no-ao-temporal")) {
            settings.ao_temporal_filter = false;
        } else if (std.mem.eql(u8, arg, "--gi-hysteresis")) {
            settings.gi_hysteresis = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--gi-rays")) {
            settings.gi_rays = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--gi-tolerance")) {
            settings.gi_change_tolerance = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--lod")) {
            settings.lod_error_pixels = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--gi-spacing")) {
            settings.gi_probe_spacing = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--no-gi-follow")) {
            settings.gi_follow_camera = false;
        } else if (std.mem.eql(u8, arg, "--grade")) {
            // A stylized look, to exercise every grading control.
            settings.vignette = 0.45;
            settings.film_grain = 0.5;
            settings.saturation = 1.2;
            settings.contrast = 1.15;
            settings.temperature = 0.35;
            settings.chromatic_aberration = 0.4;
        } else if (std.mem.eql(u8, arg, "--flare")) {
            settings.lens_flare = 1;
        } else if (std.mem.eql(u8, arg, "--quality")) {
            settings = gfx.Settings.preset(std.meta.stringToEnum(gfx.Quality, args.next() orelse return error.MissingArgument) orelse return error.InvalidArgument);
        } else if (std.mem.eql(u8, arg, "--lut")) {
            // "identity" must change nothing; "warm" is a visible grade.
            lut = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--autofocus")) {
            settings.dof_aperture = 1;
            settings.dof_autofocus = true;
        } else if (std.mem.eql(u8, arg, "--stars")) {
            stars = true;
        } else if (std.mem.eql(u8, arg, "--gi-middle-ratio")) {
            settings.gi_middle_ratio = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--gi-coarse-interval")) {
            settings.gi_coarse_interval = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--sheen")) {
            // With --coat: the three spheres are velvet instead of lacquer.
            sheen = true;
        } else if (std.mem.eql(u8, arg, "--contact-shadows")) {
            settings.contact_shadows = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--panel")) {
            // A glowing panel on the arcade wall, facing across the corridor.
            panel = true;
        } else if (std.mem.eql(u8, arg, "--tube")) {
            // A strip light lying just above the floor of the arcade.
            tube = true;
        } else if (std.mem.eql(u8, arg, "--aniso")) {
            // With --coat: the three spheres are brushed metal.
            aniso = true;
        } else if (std.mem.eql(u8, arg, "--bc7-normals")) {
            bc7_normals = true;
        } else if (std.mem.eql(u8, arg, "--morph")) {
            // The character pulls a face: its morph targets set by hand.
            morph = true;
        } else if (std.mem.eql(u8, arg, "--static-gi")) {
            // Leave skinned and morphed meshes out of the ray-tracing structure.
            static_gi = true;
        } else if (std.mem.eql(u8, arg, "--no-player")) {
            // Hides the animated character: nothing in the scene moves.
            no_player = true;
        } else if (std.mem.eql(u8, arg, "--shadow-lod-light")) {
            settings.shadow_lod = .light;
        } else if (std.mem.eql(u8, arg, "--no-reflect-transparent")) {
            settings.reflect_transparent = false;
        } else if (std.mem.eql(u8, arg, "--soft-text")) {
            // Text from the plain distance field: rounded corners when large.
            settings.sharp_text = false;
        } else if (std.mem.eql(u8, arg, "--terrain")) {
            terrain = true;
        } else if (std.mem.eql(u8, arg, "--lod-normal-weight")) {
            lod_normal_weight = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--lod-uv-weight")) {
            lod_uv_weight = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--panel-basis")) {
            // The tiled panel with its texture in one of Basis Universal's
            // formats: etc1s or uastc.
            transform_panel = true;
            const kind = args.next() orelse return error.MissingArgument;
            panel_model = if (std.mem.eql(u8, kind, "etc1s")) "examples/assets/panel/panel_etc1s.gltf" else "examples/assets/panel/panel_uastc.gltf";
        } else if (std.mem.eql(u8, arg, "--cluster-lods")) {
            // Levels of detail chosen cluster by cluster.
            cluster_lods = true;
        } else if (std.mem.eql(u8, arg, "--lod-fade")) {
            settings.lod_cross_fade = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--no-receiver-culling")) {
            settings.shadow_receiver_culling = false;
        } else if (std.mem.eql(u8, arg, "--no-cascade-stagger")) {
            settings.shadow_cascade_stagger = false;
        } else if (std.mem.eql(u8, arg, "--shadow-small")) {
            settings.shadow_small_feature_texels = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--aerial-sky")) {
            // The simple haze: one grey, fading to the sky behind.
            settings.aerial_model = .sky;
        } else if (std.mem.eql(u8, arg, "--aerial")) {
            settings.aerial_perspective = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--wax")) {
            // With --coat: the three spheres are wax.
            wax = true;
        } else if (std.mem.eql(u8, arg, "--sort-test")) {
            // A sorted emitter, whose drawing order is read back and checked.
            sort_test = true;
        } else if (std.mem.eql(u8, arg, "--meshlet-bounds")) {
            // Animated meshes are culled meshlet by meshlet.
            meshlet_bounds = true;
        } else if (std.mem.eql(u8, arg, "--no-shader-variants")) {
            // Always shade with the full pass, whatever the view uses.
            shader_variants = false;
        } else if (std.mem.eql(u8, arg, "--instance-params")) {
            // With --material: a second lava block, cooled through its own
            // entity parameters.
            instance_params = true;
        } else if (std.mem.eql(u8, arg, "--refits")) {
            // Ray-tracing structures of animated meshes brought up to date per frame.
            gi_dynamic_refits = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--crowd-sync")) {
            // The crowd walks in step with the player.
            crowd_sync = true;
        } else if (std.mem.eql(u8, arg, "--crowd-group")) {
            // The crowd is one instance group that takes the player's pose,
            // instead of an entity per character.
            crowd_group = true;
        } else if (std.mem.eql(u8, arg, "--crowd")) {
            // This many more walking characters, each at its own point of the walk.
            crowd = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--transform-panel")) {
            // A panel whose glow texture is tiled four times while its base
            // color is not (examples/assets/panel/panel.gltf).
            transform_panel = true;
        } else if (std.mem.eql(u8, arg, "--coat-maps")) {
            // With --coat: a checker on the first sphere, a rippled coat on
            // the second, a coat in stripes on the third.
            coat_maps = true;
        } else if (std.mem.eql(u8, arg, "--geometry-distance")) {
            // Geometry streaming: models farther than this leave GPU memory.
            geometry_distance = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--geometry-coarse")) {
            // Beyond this, models keep only their coarser levels in GPU memory.
            geometry_coarse = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--teleport")) {
            // At this frame the camera jumps to a position and target.
            teleport_frame = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
            for (&teleport_to) |*value| value.* = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--shape-font")) {
            // A font file and a line of text to set large with it, for
            // looking at how a script is shaped.
            shape_font = args.next() orelse return error.MissingArgument;
            shape_text = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--text-fallback")) {
            text_fallback = true;
        } else if (std.mem.eql(u8, arg, "--light-size")) {
            // With --lights: the radius of the two shadow-casting lamps.
            light_size = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--fire-size")) {
            // Width of the fire's light as a share of its box: soft shadows.
            fire_size = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--tube-shadows")) {
            // With --tube: the tube casts shadows.
            tube_shadows = true;
        } else if (std.mem.eql(u8, arg, "--fluid-lamp")) {
            // A spot light shining through the fluid onto the floor beyond.
            fluid_lamp = true;
        } else if (std.mem.eql(u8, arg, "--relocate")) {
            settings.gi_probe_relocation = true;
        } else if (std.mem.eql(u8, arg, "--skip-buried")) {
            settings.gi_skip_buried_probes = true;
        } else if (std.mem.eql(u8, arg, "--no-fluid-rays")) {
            settings.fluid_rays = false;
        } else if (std.mem.eql(u8, arg, "--no-fluid-motion")) {
            settings.fluid_motion_vectors = false;
        } else if (std.mem.eql(u8, arg, "--no-fluid-shadows")) {
            settings.fluid_shadows = false;
        } else if (std.mem.eql(u8, arg, "--fluid-sharp")) {
            // Error-corrected advection of the flow itself, in both fluids.
            fluid_sharp = true;
        } else if (std.mem.eql(u8, arg, "--fluid-flipbook")) {
            // With --fluid: records the flat fluid as a 4x4 sheet and saves it here.
            fluid_flipbook = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--fluid-frame")) {
            // With --fluid: saves the 2D fluid's picture as a PNG at the end.
            fluid_frame = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--compress-images")) {
            // With --decals: the decal picture is stored block-compressed.
            compress_images = true;
        } else if (std.mem.eql(u8, arg, "--bumps")) {
            // With --decals: the stain carries a ripple normal map.
            bumps = true;
        } else if (std.mem.eql(u8, arg, "--tints")) {
            // Colors per instance (with --instances) and on the character.
            tints = true;
        } else if (std.mem.eql(u8, arg, "--sharp-reflections")) {
            settings.reflection_blur_samples = 0;
        } else if (std.mem.eql(u8, arg, "--no-traced-shadows")) {
            settings.ray_traced_light_shadows = false;
        } else if (std.mem.eql(u8, arg, "--no-light-bounce")) {
            settings.gi_local_lights = false;
        } else if (std.mem.eql(u8, arg, "--no-shadow-filter")) {
            settings.light_shadow_filter = false;
        } else if (std.mem.eql(u8, arg, "--dof-blades")) {
            settings.dof_blades = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--spatial-upscaling")) {
            settings.upscaling = .spatial;
        } else if (std.mem.eql(u8, arg, "--sky-spread")) {
            // With --sky-sweep: frames each sky rebuild is spread over.
            sky_spread = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--flat-panes")) {
            flat_panes = true;
        } else if (std.mem.eql(u8, arg, "--colored-shadows")) {
            settings.colored_shadows = true;
        } else if (std.mem.eql(u8, arg, "--half-dof")) {
            settings.dof_resolution = .half;
        } else if (std.mem.eql(u8, arg, "--no-blur-spread")) {
            settings.motion_blur_spread = false;
        } else if (std.mem.eql(u8, arg, "--half-reflections")) {
            settings.reflection_resolution = .half;
        } else if (std.mem.eql(u8, arg, "--mirror-far")) {
            mirror_panel = true;
            mirror_far = true;
        } else if (std.mem.eql(u8, arg, "--bc7-test")) {
            // Draws a picture of all 64 two-group block shapes, compressed
            // (with --compress-images) or not, large on the screen.
            bc7_test = true;
        } else if (std.mem.eql(u8, arg, "--mirror-panel")) {
            mirror_panel = true;
        } else if (std.mem.eql(u8, arg, "--probe-settle")) {
            // Frames the probe waits before its pictures are taken.
            probe_settle = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--probe")) {
            // A local reflection probe in the middle of the hall.
            reflection_probe = true;
        } else if (std.mem.eql(u8, arg, "--no-traced-reflections")) {
            settings.reflection_ray_tracing = false;
        } else if (std.mem.eql(u8, arg, "--no-reflections")) {
            settings.screen_space_reflections = false;
        } else if (std.mem.eql(u8, arg, "--dof")) {
            settings.dof_aperture = 1;
            settings.dof_focus_distance = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--motion-blur")) {
            settings.motion_blur = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--peel")) {
            settings.transparency = .peeled;
        } else if (std.mem.eql(u8, arg, "--oit")) {
            settings.transparency = .weighted;
        } else if (std.mem.eql(u8, arg, "--render-scale")) {
            settings.render_scale = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--hdr10")) {
            // Encode as for an HDR10 display; in an 8-bit file this looks
            // flat, it only checks that the path runs.
            settings.output_encoding = .hdr10;
        } else if (std.mem.eql(u8, arg, "--low-quality")) {
            // Every quality knob at its cheapest.
            settings.shadow_cascades = 2;
            settings.shadow_samples = 4;
            settings.bloom_levels = 3;
            settings.ao_resolution = .quarter;
            settings.fog_resolution = .quarter;
            settings.gi_resolution = .quarter;
            settings.render_scale = 0.67;
        } else if (std.mem.eql(u8, arg, "--no-ao-bounce")) {
            settings.ao_bounce = 0;
        } else if (std.mem.eql(u8, arg, "--no-ao")) {
            settings.ambient_occlusion = false;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            settings.debug_view = std.meta.stringToEnum(gfx.DebugView, args.next() orelse return error.MissingArgument) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--exposure")) {
            settings.automatic_exposure = false;
            settings.exposure_compensation = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--fog")) {
            settings.fog_density = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--no-bloom")) {
            settings.bloom = 0;
        } else return error.InvalidArgument;
    }
    // A benchmark needs enough frames for stable percentiles.
    const frames: u32 = frame_argument orelse if (bench) 900 else 64;
    if (width == 0 or height == 0 or frames == 0) return error.InvalidArgument;

    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
    // With --oom the renderer allocates through a wrapper that can be told
    // to fail a chosen allocation.
    var failing = FailingAllocator{ .backing = init.gpa };
    const renderer_start = std.Io.Clock.Timestamp.now(init.io, .awake);
    const renderer = try gfx.Renderer.init(if (oom_rounds != 0) failing.allocator() else init.gpa, init.io, .{
        .shader_variants = shader_variants,
        .skinned_meshlet_bounds = meshlet_bounds,
        .cluster_lods = cluster_lods,
        .geometry_streaming = if (geometry_distance) |distance| .{ .distance = distance, .coarse_distance = geometry_coarse } else null,
        .lod_normal_weight = lod_normal_weight orelse std.meta.fieldInfo(gfx.Options, .lod_normal_weight).defaultValue().?,
        .lod_uv_weight = lod_uv_weight orelse std.meta.fieldInfo(gfx.Options, .lod_uv_weight).defaultValue().?,
        .gi_dynamic_refits = gi_dynamic_refits,
        .job_allocator = if (oom_rounds != 0) failing.allocator() else null,
        .application_name = "limn verify",
        .validation = validation,
        .debug_names = debug_names,
        .profiler = if (profile) .{ .context = &zone_log, .begin = ZoneLog.begin, .end = ZoneLog.end } else null,
        .shadow_resolution = if (max_quality) 4096 else 2048,
        .local_shadow_resolution = if (max_quality) 4096 else 2048,
        .texture_anisotropy = if (max_quality) 16 else 8,
        .data_texture_anisotropy = if (max_quality) 16 else 1,
        .texture_compression = if (max_quality) .none else compression,
        .asset_cache_dir = cache_dir,
        .pipeline_cache_path = "zig-out/pipeline.cache",
        .asset_cache_max_bytes = cache_limit,
        .gi_dynamic_geometry = !static_gi,
        .normal_maps_bc5 = !bc7_normals,
        .texture_streaming = streaming,
    });
    std.log.info("renderer started in {d} ms", .{elapsedMs(init.io, renderer_start)});
    defer renderer.deinit();
    const device = renderer.device;
    std.log.info("device: {s}, recommended quality {s}", .{ device.name(), @tagName(renderer.recommendedQuality()) });

    const target = try device.createTexture(.{
        .name = "output",
        .width = width,
        .height = height,
        .format = .rgba8_unorm,
        .usage = .{ .color_attachment = true, .sampled = true, .copy_src = true },
    });
    defer device.destroyTexture(target);

    const scene = try renderer.createScene();
    const environment = try renderer.loadEnvironment("examples/assets/world/venice_sunset_2k.hdr", 24);
    const sponza = try renderer.loadModel("examples/assets/world/Sponza.glb");
    const robot = try renderer.loadModel("examples/assets/world/RobotExpressive.glb");
    try renderer.waitUntilLoaded();
    if (renderer.modelState(sponza) != .ready) return renderer.modelError(sponza) orelse error.ModelLoadFailed;
    if (renderer.modelState(robot) != .ready) return renderer.modelError(robot) orelse error.ModelLoadFailed;
    std.log.info("assets loaded in {d} ms", .{elapsedMs(init.io, start)});

    const sponza_info = renderer.modelInfo(sponza).?;
    std.log.info("sponza: {d} meshes, {d} triangles, {d} meshlets, {d} textures", .{
        sponza_info.mesh_count, sponza_info.triangle_count, sponza_info.meshlet_count, sponza_info.texture_count,
    });

    renderer.setEnvironment(scene, environment, environment_intensity);
    renderer.setSun(scene, .{ .direction = sun_direction, .color = .{ 1.0, 0.93, 0.82 }, .intensity = sun_intensity });
    var sky_environment: ?gfx.Environment = null;
    defer if (sky_environment) |handle| renderer.destroyEnvironment(handle);
    if (sky) {
        // A computed clear sky and the sun that belongs to it, in place of
        // the photographed environment.
        const sky_desc = gfx.SkyDesc{ .sun_direction = if (stars) .{ -0.4, 0.25, -0.3 } else sun_direction, .turbidity = sky_turbidity, .stars = if (stars) 1 else 0, .moon = if (stars) 1 else 0, .moon_direction = .{ -0.3, -0.9, 0.05 } };
        sky_environment = try renderer.createSky(sky_desc);
        renderer.setEnvironment(scene, sky_environment, 1);
        renderer.setSun(scene, gfx.skySun(sky_desc));
    }
    var cube_environment: ?gfx.Environment = null;
    defer if (cube_environment) |handle| renderer.destroyEnvironment(handle);
    if (cube_env) |path| {
        // Each face its own color, two levels, and one very bright texel
        // on the +X face that the loader has to find.
        const size = 32;
        const face_colors = [6][3]f32{ .{ 1.6, 0.5, 0.4 }, .{ 0.4, 1.4, 0.5 }, .{ 0.9, 1.3, 2.4 }, .{ 0.25, 0.2, 0.15 }, .{ 1.5, 1.4, 0.4 }, .{ 1.2, 0.4, 1.5 } };
        const texels = try init.gpa.alloc(u8, 6 * (size * size + (size / 2) * (size / 2)) * 8);
        defer init.gpa.free(texels);
        var cursor: usize = 0;
        for ([_]usize{ size, size / 2 }) |level_size| for (face_colors, 0..) |color, face| for (0..level_size * level_size) |index| {
            const bright = level_size == size and face == 0 and index == 8 * size + 20;
            for (0..4) |channel| {
                const value: f16 = if (channel == 3) 1 else if (bright) 60 else @floatCast(color[channel]);
                std.mem.writeInt(u16, texels[cursor..][0..2], @bitCast(value), .little);
                cursor += 2;
            }
        };
        const file = try gfx.ktx2.write(init.gpa, .{ .width = size, .height = size, .format = .rgba16f, .srgb = false, .levels = 2, .faces = 6, .data = texels });
        defer init.gpa.free(file);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = file });
        cube_environment = try renderer.loadEnvironment(path, 24);
        try renderer.waitUntilLoaded();
        const info = renderer.environmentInfo(cube_environment.?) orelse return error.CubeEnvironmentNotLoaded;
        // Texel (20, 8) of +X: (1, -py, -px) with px, py from its center.
        const expected = math.normalize(.{ 1, -((8.5 / 32.0) * 2 - 1), -((20.5 / 32.0) * 2 - 1) });
        if (math.dot(info.brightest_direction, expected) < 0.9999) return error.CubeEnvironmentBrightestWrong;
        renderer.setEnvironment(scene, cube_environment, environment_intensity);
    }
    _ = try renderer.spawn(scene, .{ .model = sponza });
    const player = try renderer.spawn(scene, .{
        .model = robot,
        .transform = math.mul(math.translation(.{ 2.0, 0, -0.4 }), math.mul(math.rotationY(1.9), math.uniformScaling(0.42))),
    });
    if (tints) renderer.setTint(player, .{ 1.0, 0.45, 0.4 });
    if (morph) renderer.setMorphWeights(player, &.{ 1, 1, 1 });
    if (no_player) renderer.setVisible(player, false);
    if (ktx2_model) |directory| {
        const path = try writeKtx2Panel(init.gpa, init.io, directory);
        defer init.gpa.free(path);
        const checkered = try renderer.loadModel(path);
        _ = try renderer.spawn(scene, .{ .model = checkered, .transform = math.mul(math.translation(.{ 3.0, 0.3, 1.2 }), math.rotationY(std.math.pi * 0.5)) });
        try renderer.waitUntilLoaded();
        if (renderer.modelState(checkered) != .ready) return error.Ktx2ModelNotLoaded;
    }
    if (morph_row) |directory| {
        const path = try writeMorphRow(init.gpa, init.io, directory);
        defer init.gpa.free(path);
        const tiles = try renderer.loadModel(path);
        try renderer.waitUntilLoaded();
        if (renderer.modelState(tiles) != .ready) return renderer.modelError(tiles) orelse error.MorphRowNotLoaded;
        const info = renderer.modelInfo(tiles).?;
        if (info.morph_targets != morph_row_tiles) return error.MorphRowTargetsMissing;
        const row = try renderer.spawn(scene, .{ .model = tiles, .transform = math.mul(math.translation(.{ 3.0, 0.2, -0.4 }), math.rotationY(std.math.pi * 0.5)) });
        // Tiles 1, 9, 10 and 11 rise; the last three are past the eight
        // targets a mesh used to be limited to.
        var weights: [morph_row_tiles]f32 = @splat(0);
        for ([_]usize{ 1, 9, 10, 11 }) |tile| weights[tile] = 1;
        renderer.setMorphWeights(row, &weights);
    }
    if (terrain) {
        // One large, finely tessellated landscape beside the building:
        // near and far at once, which is what choosing levels of detail
        // cluster by cluster is for.
        const cells = 512;
        const size: f32 = 200;
        const positions = try init.gpa.alloc([3]f32, (cells + 1) * (cells + 1));
        defer init.gpa.free(positions);
        const indices = try init.gpa.alloc(u32, cells * cells * 6);
        defer init.gpa.free(indices);
        for (0..cells + 1) |row| for (0..cells + 1) |column| {
            const x = (@as(f32, @floatFromInt(column)) / cells - 0.5) * size;
            const z = (@as(f32, @floatFromInt(row)) / cells - 0.5) * size;
            const ground = 6.0 * @sin(x * 0.045) * @cos(z * 0.037) + 1.5 * @sin(x * 0.21 + 1.3) * @sin(z * 0.17) + 0.25 * @sin(x * 1.1) * @cos(z * 0.9 + 0.4);
            positions[row * (cells + 1) + column] = .{ x, ground, z };
        };
        for (0..cells) |row| for (0..cells) |column| {
            const corner: u32 = @intCast(row * (cells + 1) + column);
            indices[(row * cells + column) * 6 ..][0..6].* = .{ corner, corner + cells + 1, corner + 1, corner + 1, corner + cells + 1, corner + cells + 2 };
        };
        const land = try renderer.createModel(&.{.{ .positions = positions, .indices = indices, .material = .{ .base_color = .{ 0.36, 0.42, 0.27, 1 }, .metallic = 0, .roughness = 0.9 } }});
        _ = try renderer.spawn(scene, .{ .model = land, .transform = math.translation(.{ 160, -8, 0 }) });
        try renderer.waitUntilLoaded();
        const land_info = renderer.modelInfo(land).?;
        std.log.info("terrain: {d} triangles, {d} meshlets", .{ land_info.triangle_count, land_info.meshlet_count });
    }
    if (mirror_panel) {
        // A polished metal panel facing the camera: it shows whatever
        // answers for reflections of what is behind the camera.
        const corners = [_][3]f32{ .{ -0.9, 0, 0 }, .{ 0.9, 0, 0 }, .{ 0.9, 1.9, 0 }, .{ -0.9, 1.9, 0 } };
        const two_triangles = [_]u32{ 0, 1, 2, 0, 2, 3 };
        const mirror = try renderer.createModel(&.{.{ .positions = &corners, .indices = &two_triangles, .material = .{
            .base_color = .{ 0.95, 0.95, 0.95, 1 },
            .metallic = 1,
            .roughness = 0.03,
            .double_sided = true,
        } }});
        // Near the camera, or (--mirror-far) at the far side of the fire.
        _ = try renderer.spawn(scene, .{ .model = mirror, .transform = math.mul(math.translation(.{ if (mirror_far) -4.5 else 4.2, 0.1, 0.9 }), math.rotationY(std.math.pi * 0.5)) });
    }
    if (reflection_probe) _ = try renderer.createReflectionProbe(scene, .{ .position = .{ 1.0, 1.6, -0.2 }, .extent = .{ 14, 6, 3 }, .settle_frames = probe_settle });
    if (transform_panel) {
        const tiled = try renderer.loadModel(panel_model);
        _ = try renderer.spawn(scene, .{ .model = tiled, .transform = math.mul(math.translation(.{ 3.0, 0.3, -0.4 }), math.rotationY(std.math.pi * 0.5)) });
        try renderer.waitUntilLoaded();
        if (renderer.modelState(tiled) != .ready) return error.PanelNotLoaded;
    }
    const crowd_entities = try init.gpa.alloc(gfx.Entity, if (crowd_group) 0 else crowd);
    defer init.gpa.free(crowd_entities);
    for (crowd_entities, 0..) |*member, index| {
        const column: f32 = @floatFromInt(index % 20);
        const row: f32 = @floatFromInt(index / 20);
        member.* = try renderer.spawn(scene, .{
            .model = robot,
            .transform = math.mul(math.translation(.{ -7 + column * 0.75, 0, -1.6 + row * 0.6 }), math.mul(math.rotationY(1.9), math.uniformScaling(0.2))),
        });
    }
    if (crowd_group and crowd != 0) {
        const placements = try init.gpa.alloc(math.Mat4, crowd);
        defer init.gpa.free(placements);
        for (placements, 0..) |*placement, index| {
            const column: f32 = @floatFromInt(index % 20);
            const row: f32 = @floatFromInt(index / 20);
            placement.* = math.mul(math.translation(.{ -7 + column * 0.75, 0, -1.6 + row * 0.6 }), math.mul(math.rotationY(1.9), math.uniformScaling(0.2)));
        }
        const followers = try renderer.createInstances(scene, robot, placements);
        renderer.setInstancesPose(followers, player);
    }
    if (morph) if (renderer.modelInfo(robot)) |info| std.log.info("morph: {d} meshes with targets, up to {d} each", .{ info.morph_meshes, info.morph_targets });
    const walk = renderer.findAnimation(robot, "Walking") orelse 0;
    if (panel) try renderer.setLights(scene, &.{
        .{ .kind = .rectangle, .position = .{ 3.0, 1.2, -4.6 }, .direction = .{ 0, -0.25, 1 }, .color = .{ 1.0, 0.6, 0.9 }, .intensity = 14, .range = 8, .source_length = 2.4, .source_height = 0.8, .cast_shadows = true },
    });
    if (tube) try renderer.setLights(scene, &.{
        .{ .position = .{ 3.0, 0.5, -3.6 }, .direction = .{ 1, 0, 0 }, .color = .{ 0.5, 0.8, 1.0 }, .intensity = 18, .range = 8, .source_length = 4, .source_radius = 0.04, .cast_shadows = tube_shadows },
    });
    if (fluid_lamp) try renderer.setLights(scene, &.{
        .{ .kind = .spot, .position = .{ -4.6, 3.4, 0.9 }, .direction = .{ 1.0, -0.55, 0 }, .color = .{ 0.7, 0.85, 1.0 }, .intensity = 260, .range = 14, .inner_angle = 0.3, .outer_angle = 0.5, .cast_shadows = true },
    });
    if (many_lights != 0) {
        const row = try init.gpa.alloc(gfx.Light, many_lights);
        defer init.gpa.free(row);
        for (row, 0..) |*light, index| {
            const along: f32 = @floatFromInt(index / 2);
            const side: f32 = if (index % 2 == 0) -1 else 1;
            const hue: f32 = @floatFromInt(index % 3);
            light.* = .{
                .position = .{ 9.0 - along * 18.0 / @as(f32, @floatFromInt(@max(many_lights / 2, 1))), 0.6, side * 0.9 },
                .color = .{ if (hue == 0) 1.0 else 0.2, if (hue == 1) 1.0 else 0.2, if (hue == 2) 1.0 else 0.2 },
                .intensity = 4,
                .range = 2.5,
            };
        }
        try renderer.setLights(scene, row);
    }
    if (lights) try renderer.setLights(scene, &.{
        // Unshadowed fill lights under the arcades.
        .{ .position = .{ 4.0, 1.2, -3.6 }, .color = .{ 1.0, 0.45, 0.15 }, .intensity = 12, .range = 6 },
        .{ .position = .{ -4.0, 1.2, 3.4 }, .color = .{ 0.3, 1.0, 0.4 }, .intensity = 12, .range = 6 },
        // A shadow-casting point light near the character...
        .{ .position = .{ 3.2, 1.0, -1.5 }, .color = .{ 0.4, 0.6, 1.0 }, .intensity = 25, .range = 9, .cast_shadows = true, .source_radius = light_size },
        // ...and a shadow-casting spot light aimed down the nave.
        .{
            .kind = .spot,
            .position = .{ 7.0, 3.5, 0.6 },
            .direction = .{ -1.0, -0.55, -0.15 },
            .color = .{ 1.0, 0.85, 0.6 },
            .intensity = 90,
            .range = 16,
            .inner_angle = 0.25,
            .outer_angle = 0.42,
            .source_radius = light_size,
            .cast_shadows = true,
        },
    });
    if (glass) {
        // Blended materials built from in-memory geometry: two tinted
        // panes and a frosted block.
        const pane = [_][3]f32{ .{ -0.9, 0, 0 }, .{ 0.9, 0, 0 }, .{ 0.9, 1.9, 0 }, .{ -0.9, 1.9, 0 } };
        const quad = [_]u32{ 0, 1, 2, 0, 2, 3 };
        const panes = try renderer.createModel(&.{
            .{ .positions = &pane, .indices = &quad, .material = .{
                .base_color = .{ 0.25, 0.75, 0.95, 0.35 },
                .metallic = 0,
                .roughness = 0.05,
                .alpha_mode = .blend,
                .double_sided = true,
            } },
        });
        const amber = try renderer.createModel(&.{
            .{ .positions = &pane, .indices = &quad, .material = .{
                .base_color = .{ 1.0, 0.55, 0.15, 0.55 },
                .metallic = 0,
                .roughness = 0.35,
                .alpha_mode = .blend,
                .double_sided = true,
            } },
        });
        _ = try renderer.spawn(scene, .{ .model = panes, .transform = math.mul(math.translation(.{ 3.6, 0, 0.5 }), math.rotationY(1.25)) });
        _ = try renderer.spawn(scene, .{ .model = amber, .transform = math.mul(math.translation(.{ 4.6, 0, -1.3 }), math.rotationY(1.75)) });
        if (pane_row != .none) {
            // The same five panes either way; the pictures must match.
            var row: [5]math.Mat4 = undefined;
            for (&row, 0..) |*transform, index| {
                const step: f32 = @floatFromInt(index);
                transform.* = math.mul(math.translation(.{ 1.0 + step * 0.7, 0, 0.9 - step * 0.45 }), math.rotationY(1.1 + step * 0.2));
            }
            if (pane_row == .group) {
                _ = try renderer.createInstances(scene, amber, &row);
            } else for (row) |transform| {
                _ = try renderer.spawn(scene, .{ .model = amber, .transform = transform });
            }
        }
        // Two more panes held flat above the sunlit floor, for their shadows.
        if (flat_panes) {
            _ = try renderer.spawn(scene, .{ .model = amber, .transform = math.mul(math.translation(.{ 2.4, 1.2, 0.2 }), math.rotationX(-std.math.pi * 0.5)) });
            _ = try renderer.spawn(scene, .{ .model = panes, .transform = math.mul(math.translation(.{ 0.2, 1.2, 0.2 }), math.rotationX(-std.math.pi * 0.5)) });
        }
        // A thick pane that bends what is seen through it.
        const lens = try renderer.createModel(&.{
            .{ .positions = &pane, .indices = &quad, .material = .{
                .base_color = .{ 0.85, 1.0, 0.9, 1 },
                .metallic = 0,
                .roughness = 0.04,
                .transmission = 0.95,
                .ior = 1.45,
                .thickness = 0.5,
                .double_sided = true,
            } },
        });
        _ = try renderer.spawn(scene, .{ .model = lens, .transform = math.mul(math.translation(.{ 2.6, 0, -1.9 }), math.rotationY(1.45)) });
        if (lens_pane) _ = try renderer.spawn(scene, .{ .model = amber, .transform = math.mul(math.translation(.{ 3.8, 0, -2.0 }), math.rotationY(1.45)) });
        // With the mirror panel: a pane behind the camera, seen only in the mirror.
        if (mirror_panel) _ = try renderer.spawn(scene, .{ .model = amber, .transform = math.mul(math.translation(.{ 9.8, 0.2, 1.2 }), math.rotationY(std.math.pi * 0.5)) });
        try renderer.waitUntilLoaded();
    }
    var lava_shader: ?gfx.MaterialShader = null;
    defer if (lava_shader) |shader| renderer.destroyMaterialShader(shader);
    if (custom_material) {
        // A block shaded by application code (examples/shaders/lava.frag).
        lava_shader = try renderer.createMaterialShader(@embedFile("lava.frag.spv"));
        var positions: [24][3]f32 = undefined;
        var indices: [36]u32 = undefined;
        const half = [3]f32{ 0.45, 0.45, 0.45 };
        for (0..6) |face| {
            const axis = face / 2;
            const sign: f32 = if (face % 2 == 0) 1 else -1;
            const u = (axis + 1) % 3;
            const v = (axis + 2) % 3;
            for (0..4) |corner| {
                var p: [3]f32 = undefined;
                p[axis] = sign * half[axis];
                p[u] = (if (corner == 1 or corner == 2) half[u] else -half[u]) * sign;
                p[v] = if (corner >= 2) half[v] else -half[v];
                positions[face * 4 + corner] = p;
            }
            const base: u32 = @intCast(face * 4);
            indices[face * 6 ..][0..6].* = .{ base, base + 1, base + 2, base, base + 2, base + 3 };
        }
        const block = try renderer.createModel(&.{.{
            .positions = &positions,
            .indices = &indices,
            .material = .{ .metallic = 0, .roughness = 0.8, .shader = lava_shader.?.slot, .params = .{ 3.5, 3, 0, 0 } },
        }});
        _ = try renderer.spawn(scene, .{ .model = block, .transform = math.translation(.{ 3.3, 0.45, -1.4 }) });
        if (instance_params) _ = try renderer.spawn(scene, .{ .model = block, .transform = math.translation(.{ 3.3, 0.45, -0.2 }), .params = .{ 0.85, 0, 0, 0 } });
        try renderer.waitUntilLoaded();
    }
    if (particles) {
        // A fire with sparks and a column of smoke lit by the scene.
        const base = math.Vec3{ 3.4, 0.1, -1.5 };
        _ = try renderer.createEmitter(scene, .{
            .position = base,
            .radius = 0.18,
            .capacity = 512,
            .rate = 220,
            .lifetime = .{ 0.5, 1.0 },
            .spread = 0.25,
            .speed = .{ 0.6, 1.4 },
            .gravity = .{ 0, 1.2, 0 },
            .size = .{ 0.35, 0.08 },
            .color_start = .{ 6.0, 2.2, 0.5, 0.8 },
            .color_end = .{ 2.0, 0.2, 0.02, 0 },
            .blend = .additive,
            .lit = false,
        });
        _ = try renderer.createEmitter(scene, .{
            .position = base,
            .radius = 0.1,
            .capacity = 256,
            .rate = 40,
            .lifetime = .{ 0.8, 1.6 },
            .spread = 0.9,
            .speed = .{ 1.5, 3.5 },
            .gravity = .{ 0, -4, 0 },
            .drag = 0.2,
            .size = .{ 0.03, 0.01 },
            .color_start = .{ 12, 6, 1.5, 1 },
            .color_end = .{ 6, 1, 0.1, 0 },
            .blend = .additive,
            .lit = false,
            .softness = 0,
        });
        _ = try renderer.createEmitter(scene, .{
            .position = math.add(base, .{ 0, 0.7, 0 }),
            .radius = 0.15,
            .capacity = 512,
            .rate = 45,
            .lifetime = .{ 3, 5 },
            .spread = 0.3,
            .speed = .{ 0.4, 0.9 },
            .gravity = .{ 0, 0.25, 0 },
            .drag = 0.3,
            .size = .{ 0.3, 1.6 },
            .color_start = .{ 0.55, 0.55, 0.6, 0.35 },
            .color_end = .{ 0.7, 0.7, 0.75, 0 },
        });
    }
    if (clouds) try renderer.setClouds(scene, .{ .coverage = cloud_coverage, .environment_interval = if (cloud_lighting) 4 else 0 });
    // A fire in the middle of the courtyard, and a 2D one as a picture.
    var fluid_picture: ?gfx.Image = null;
    var flat_fluid: ?gfx.Fluid = null;
    if (fluid) {
        _ = try renderer.createFluid(scene, .{
            .resolution = .{ 48, 72, 48 },
            .sharp_velocity = fluid_sharp,
            .vorticity = if (fluid_sharp) 4 else 12,
            .light_size = fire_size,
            .transform = math.mul(math.translation(.{ -1.5, 1.8, 0.9 }), math.scaling(.{ 2.4, 3.6, 2.4 })),
            // With the lamp: plain smoke, so the lamp is what lights it.
            .sources = if (fluid_lamp) &.{.{ .smoke = 6, .temperature = 3 }} else &.{.{ .fuel = 7, .temperature = 7 }},
            .obstacles = &.{.{ .sphere = .{ .center = .{ 0.5, 0.45, 0.5 }, .radius = 0.08 } }},
        });
        const flat = try renderer.createFluid(scene, .{
            .resolution = .{ 64, 64, 1 },
            .sharp_velocity = fluid_sharp,
            .transform = math.translation(.{ 0, -40, 0 }),
            .sources = &.{.{ .smoke = 5, .temperature = 2 }},
            .walls = .closed,
        });
        fluid_picture = try renderer.fluidImage(flat);
        flat_fluid = flat;
        if (fluid_flipbook != null) _ = try renderer.recordFluidFlipbook(flat, .{ .columns = 4, .rows = 4, .interval = 2 });
    }
    var lut_image: ?gfx.Image = null;
    defer if (lut_image) |image| renderer.destroyImage(image);
    if (lut) |kind| {
        const n = 16;
        var pixels: [n * n * n * 4]u8 = undefined;
        const warm = std.mem.eql(u8, kind, "warm");
        for (0..n) |b| for (0..n) |g| for (0..n) |r| {
            const red: f32 = @as(f32, @floatFromInt(r)) / (n - 1);
            const green: f32 = @as(f32, @floatFromInt(g)) / (n - 1);
            const blue: f32 = @as(f32, @floatFromInt(b)) / (n - 1);
            const out: [3]f32 = if (warm) .{ @min(red * 1.1 + 0.03, 1), green, blue * 0.75 } else .{ red, green, blue };
            pixels[(g * n * n + b * n + r) * 4 ..][0..4].* = .{ @intFromFloat(out[0] * 255 + 0.5), @intFromFloat(out[1] * 255 + 0.5), @intFromFloat(out[2] * 255 + 0.5), 255 };
        };
        lut_image = try renderer.createImage(n * n, n, &pixels, false);
        settings.color_lut = lut_image;
    }
    const sorted_emitter: ?gfx.Emitter = if (sort_test) try renderer.createEmitter(scene, .{
        .position = .{ 2.5, 1.0, 0.5 },
        .radius = 0.6,
        // Not a power of two, to exercise the padding.
        .capacity = 300,
        .rate = 240,
        .lifetime = .{ 0.6, 1.0 },
        .spread = std.math.pi,
        .speed = .{ 0.5, 2.0 },
        .sorted = true,
    }) else null;
    var decal_image: ?gfx.Image = null;
    var bump_image: ?gfx.Image = null;
    defer if (bump_image) |image| renderer.destroyImage(image);
    defer if (decal_image) |image| renderer.destroyImage(image);
    if (decals) {
        // A painted ring with an arrow, generated here, and a plain stain.
        const size = 128;
        const pixels = try init.gpa.alloc(u8, size * size * 4);
        defer init.gpa.free(pixels);
        for (0..size) |y| for (0..size) |x| {
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / size * 2 - 1;
            const v = (@as(f32, @floatFromInt(y)) + 0.5) / size * 2 - 1;
            const radius = @sqrt(u * u + v * v);
            const ring = radius > 0.72 and radius < 0.92;
            const arrow = @abs(u) < 0.5 * (v + 0.55) and v > -0.55 and v < 0.1 or (@abs(u) < 0.14 and v >= 0.1 and v < 0.55);
            const alpha: u8 = if (ring or arrow) 235 else 0;
            pixels[(y * size + x) * 4 ..][0..4].* = .{ 250, 200, 40, alpha };
        };
        if (decal_bc1) |path| {
            // 64x64 in 4x4 blocks: yellow and dark blue squares of 8 pixels,
            // each block one flat color (both end points the same).
            var blocks: [16 * 16 * 8]u8 = undefined;
            for (0..16) |by| for (0..16) |bx| {
                const yellow = (bx / 2 + by / 2) % 2 == 0;
                // RGB565, little-endian.
                const color: u16 = if (yellow) 0xfe60 else 0x18ca;
                const block = blocks[(by * 16 + bx) * 8 ..][0..8];
                std.mem.writeInt(u16, block[0..2], color, .little);
                std.mem.writeInt(u16, block[2..4], color, .little);
                @memset(block[4..8], 0);
            };
            const file = try gfx.ktx2.write(init.gpa, .{ .width = 64, .height = 64, .format = .bc1, .srgb = true, .levels = 1, .data = &blocks });
            defer init.gpa.free(file);
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = file });
            decal_image = try renderer.loadImage(path);
        } else if (decal_ktx2) |path| {
            try renderer.writeKtx2(path, size, size, pixels, true);
            decal_image = try renderer.loadImage(path);
        } else decal_image = if (compress_images) try renderer.createImageCompressed(size, size, pixels, true) else try renderer.createImage(size, size, pixels, true);
        if (bumps) {
            // Concentric ripples, as a tangent-space normal map.
            const bump_size = 64;
            var bump_pixels: [bump_size * bump_size * 4]u8 = undefined;
            for (0..bump_size) |y| for (0..bump_size) |x| {
                const u = (@as(f32, @floatFromInt(x)) + 0.5) / bump_size * 2 - 1;
                const v = (@as(f32, @floatFromInt(y)) + 0.5) / bump_size * 2 - 1;
                const radius = @max(@sqrt(u * u + v * v), 1e-3);
                const slope = @cos(radius * 18) * 0.6;
                const nx = -slope * u / radius;
                const ny = slope * v / radius;
                const length = @sqrt(nx * nx + ny * ny + 1);
                bump_pixels[(y * bump_size + x) * 4 ..][0..4].* = .{ @intFromFloat((nx / length * 0.5 + 0.5) * 255), @intFromFloat((ny / length * 0.5 + 0.5) * 255), @intFromFloat((1 / length * 0.5 + 0.5) * 255), 255 };
            };
            bump_image = try renderer.createImage(bump_size, bump_size, &bump_pixels, false);
        }
        var list: std.ArrayList(gfx.DecalDesc) = .empty;
        defer list.deinit(init.gpa);
        try list.appendSlice(init.gpa, &.{
            // On the floor: the box looks straight down.
            .{
                .transform = math.mul(math.translation(.{ 1.0, 0, -0.4 }), math.mul(math.rotationX(-std.math.pi * 0.5), math.scaling(.{ 1.6, 1.6, 0.6 }))),
                .image = decal_image,
                .roughness = 0.35,
            },
            // A dark wet stain further along.
            .{
                .transform = math.mul(math.translation(.{ 4.6, 0, 0.3 }), math.mul(math.rotationX(-std.math.pi * 0.5), math.scaling(.{ 2.2, 1.4, 0.6 }))),
                .color = .{ 0.12, 0.02, 0.02, 0.8 },
                .normal_image = bump_image,
                .normal_strength = 1.5,
                .roughness = 0.1,
            },
        });
        // Extra small marks in a grid, to measure cost against count.
        for (0..decal_count) |index| {
            const column: f32 = @floatFromInt(index % 16);
            const row: f32 = @floatFromInt(index / 16);
            try list.append(init.gpa, .{
                .transform = math.mul(math.translation(.{ -6 + column * 0.8, 0, -3 + row * 0.5 }), math.mul(math.rotationX(-std.math.pi * 0.5), math.scaling(.{ 0.3, 0.3, 0.4 }))),
                .color = .{ 0.1 + 0.05 * column, 0.6, 0.9 - 0.05 * column, 0.9 },
            });
        }
        try renderer.setDecals(scene, list.items);
    }
    // Images for --coat-maps: a checker, stripes (coat strength in red,
    // coat roughness in green) and ripples as a normal map.
    var coat_images: [3]?gfx.Image = .{ null, null, null };
    defer for (coat_images) |maybe| if (maybe) |image| renderer.destroyImage(image);
    if (coat and coat_maps) {
        const n = 64;
        var pixels: [n * n * 4]u8 = undefined;
        for (0..n) |y| for (0..n) |x| {
            const light = (x / 8 + y / 8) % 2 == 0;
            pixels[(y * n + x) * 4 ..][0..4].* = if (light) .{ 235, 235, 235, 255 } else .{ 60, 60, 60, 255 };
        };
        coat_images[0] = try renderer.createImage(n, n, &pixels, true);
        for (0..n) |y| for (0..n) |x| {
            const on = (y / 6) % 2 == 0;
            pixels[(y * n + x) * 4 ..][0..4].* = .{ if (on) 255 else 0, 255, 0, 255 };
        };
        coat_images[1] = try renderer.createImage(n, n, &pixels, false);
        for (0..n) |y| for (0..n) |x| {
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / n * 2 - 1;
            const v = (@as(f32, @floatFromInt(y)) + 0.5) / n * 2 - 1;
            const radius = @max(@sqrt(u * u + v * v), 1e-3);
            const slope = @cos(radius * 14) * 0.7;
            const nx = -slope * u / radius;
            const ny = slope * v / radius;
            const length = @sqrt(nx * nx + ny * ny + 1);
            pixels[(y * n + x) * 4 ..][0..4].* = .{ @intFromFloat((nx / length * 0.5 + 0.5) * 255), @intFromFloat((ny / length * 0.5 + 0.5) * 255), @intFromFloat((1 / length * 0.5 + 0.5) * 255), 255 };
        };
        coat_images[2] = try renderer.createImage(n, n, &pixels, false);
    }
    if (coat) {
        // The same red paint three times: bare, half coated, fully coated.
        const rings = 24;
        const segments = 48;
        var positions: [(rings + 1) * (segments + 1)][3]f32 = undefined;
        var normals: [(rings + 1) * (segments + 1)][3]f32 = undefined;
        var uvs: [(rings + 1) * (segments + 1)][2]f32 = undefined;
        var colors: [(rings + 1) * (segments + 1)][4]f32 = undefined;
        var sphere_indices: [rings * segments * 6]u32 = undefined;
        for (0..rings + 1) |ring| {
            const theta = std.math.pi * @as(f32, @floatFromInt(ring)) / rings;
            for (0..segments + 1) |segment| {
                const phi = std.math.tau * @as(f32, @floatFromInt(segment)) / segments;
                const n = [3]f32{ @sin(theta) * @cos(phi), @cos(theta), @sin(theta) * @sin(phi) };
                normals[ring * (segments + 1) + segment] = n;
                // With --tints: bands of color painted on the vertices.
                colors[ring * (segments + 1) + segment] = if (tints and ring % 6 < 3) .{ 0.15, 0.15, 0.15, 1 } else .{ 1, 1, 1, 1 };
                uvs[ring * (segments + 1) + segment] = .{ @as(f32, @floatFromInt(segment)) / segments, @as(f32, @floatFromInt(ring)) / rings };
                positions[ring * (segments + 1) + segment] = .{ n[0] * 0.4, n[1] * 0.4, n[2] * 0.4 };
            }
        }
        for (0..rings) |ring| for (0..segments) |segment| {
            const a: u32 = @intCast(ring * (segments + 1) + segment);
            const b: u32 = a + segments + 1;
            sphere_indices[(ring * segments + segment) * 6 ..][0..6].* = .{ a, a + 1, b, a + 1, b + 1, b };
        };
        for ([3]f32{ 0, 0.5, 1 }, 0..) |amount, index| {
            const sphere = try renderer.createModel(&.{.{
                .positions = &positions,
                .normals = &normals,
                .uvs = &uvs,
                .colors = &colors,
                .indices = &sphere_indices,
                .material = if (wax)
                    // Candle wax: no light under the surface, some, a lot.
                    .{ .base_color = .{ 0.9, 0.82, 0.6, 1 }, .metallic = 0, .roughness = 0.6, .subsurface = amount }
                else if (aniso)
                    // Brushed steel: round highlight, half stretched, fully stretched.
                    .{ .base_color = .{ 0.8, 0.8, 0.82, 1 }, .metallic = 1, .roughness = 0.35, .anisotropy = amount }
                else if (sheen)
                    // Dark velvet: no sheen, half, full.
                    .{ .base_color = .{ 0.08, 0.02, 0.12, 1 }, .metallic = 0, .roughness = 0.9, .sheen_color = .{ amount, amount * 0.85, amount }, .sheen_roughness = 0.35 }
                else
                    .{ .base_color = .{ 0.55, 0.03, 0.03, 1 }, .metallic = 0, .roughness = 0.65, .clearcoat = amount, .clearcoat_roughness = 0.04 },
            }});
            if (coat_maps) try renderer.setMaterialTextures(sphere, null, switch (index) {
                0 => .{ .base_color = coat_images[0] },
                1 => .{ .clearcoat_normal = coat_images[2] },
                else => .{ .clearcoat = coat_images[1], .clearcoat_roughness = coat_images[1] },
            });
            // The wax spheres stand in the sun, where the effect shows.
            const place: math.Vec3 = if (wax) .{ 4.2 + 0.95 * @as(f32, @floatFromInt(index)), 0.45, 1.3 } else .{ 3.0, 0.45, -1.3 + 1.0 * @as(f32, @floatFromInt(index)) };
            _ = try renderer.spawn(scene, .{ .model = sphere, .transform = math.translation(place) });
        }
        try renderer.waitUntilLoaded();
    }
    if (instance_count != 0) {
        // A cloud of small blocks above the courtyard, either as one
        // instance group or (for comparison) as that many entities.
        var positions: [24][3]f32 = undefined;
        var indices: [36]u32 = undefined;
        const half = [3]f32{ 0.06, 0.06, 0.06 };
        for (0..6) |face| {
            const axis = face / 2;
            const sign: f32 = if (face % 2 == 0) 1 else -1;
            const u = (axis + 1) % 3;
            const v = (axis + 2) % 3;
            for (0..4) |corner| {
                var p: [3]f32 = undefined;
                p[axis] = sign * half[axis];
                p[u] = (if (corner == 1 or corner == 2) half[u] else -half[u]) * sign;
                p[v] = if (corner >= 2) half[v] else -half[v];
                positions[face * 4 + corner] = p;
            }
            const base: u32 = @intCast(face * 4);
            indices[face * 6 ..][0..6].* = .{ base, base + 1, base + 2, base, base + 2, base + 3 };
        }
        const block = try renderer.createModel(&.{.{
            .positions = &positions,
            .indices = &indices,
            .material = .{ .base_color = .{ 0.2, 0.75, 0.9, 1 }, .metallic = 0, .roughness = 0.4 },
        }});
        try renderer.waitUntilLoaded();
        const transforms = try init.gpa.alloc(math.Mat4, instance_count);
        defer init.gpa.free(transforms);
        var random = std.Random.DefaultPrng.init(7);
        const rng = random.random();
        for (transforms) |*transform| {
            const position = math.Vec3{ -8 + 16 * rng.float(f32), 0.3 + 5 * rng.float(f32), -2.5 + 5 * rng.float(f32) };
            transform.* = math.mul(math.translation(position), math.mul(math.rotationY(rng.float(f32) * 6.28), math.uniformScaling(0.5 + rng.float(f32))));
        }
        if (instances_as_entities) {
            for (transforms) |transform| _ = try renderer.spawn(scene, .{ .model = block, .transform = transform });
        } else {
            const group = try renderer.createInstances(scene, block, transforms);
            if (tints) {
                const colors = try init.gpa.alloc([3]f32, transforms.len);
                defer init.gpa.free(colors);
                for (colors, 0..) |*color, index| {
                    const hue = @as(f32, @floatFromInt(index % 7)) / 7.0;
                    color.* = .{ 0.35 + 0.65 * hue, 1.0 - 0.6 * hue, 0.4 + 0.6 * @abs(hue - 0.5) };
                }
                try renderer.setInstanceColors(group, colors);
            }
        }
    }
    if (helmet) {
        // A metal/emissive material reference next to the character.
        const model = try renderer.loadModel("examples/assets/DamagedHelmet.glb");
        try renderer.waitUntilLoaded();
        _ = try renderer.spawn(scene, .{
            .model = model,
            .transform = math.mul(math.translation(.{ 0, 1.2, 0 }), math.mul(math.rotationY(1.2), math.uniformScaling(0.6))),
        });
    }

    if (soak_cycles != 0) try soak(renderer, scene, target, settings, soak_cycles);
    if (compact_test) try compaction(init.gpa, renderer, scene, target, settings);
    if (coarse_test) try coarseLevels(init.gpa, renderer, scene, target, settings, geometry_coarse > 0, coarse_near);
    if (oom_rounds != 0) try outOfMemory(renderer, &failing, scene, target, settings, oom_rounds);
    if (gpu_oom_rounds != 0) try outOfGpuMemory(renderer, scene, target, settings, gpu_oom_rounds);

    if (bench) {
        try benchmark(init, renderer, scene, target, settings, player, walk, frames);
        return;
    }
    var camera = gfx.Camera.lookAt(camera_position, camera_target);

    var workers: std.Io.Group = .init;
    var worker_state = WorkerState{ .renderer = renderer, .scene = scene, .model = robot, .io = init.io };
    for (0..thread_count) |index| try workers.concurrent(init.io, worker, .{ &worker_state, @as(u32, @intCast(index)) });
    var cpu_ns: u64 = 0;
    // Every way BC7 can split a block in two, one per block, in two
    // colors: if the encoder's table of splits matches the hardware's, the
    // compressed picture decodes to the same thing as the plain one.
    var bc7_picture: ?gfx.Image = null;
    if (bc7_test) {
        var shapes: [32 * 32 * 4]u8 = undefined;
        for (0..64) |shape| for (0..16) |texel| {
            const x = shape % 8 * 4 + texel % 4;
            const y = shape / 8 * 4 + texel / 4;
            const second = (gfx.bc7_partitions[shape] >> @intCast(texel)) & 1 != 0;
            // Each group shades along a line of its own, so that no one
            // line through color space fits the block.
            const step: u8 = @intCast(texel);
            shapes[(y * 32 + x) * 4 ..][0..4].* = if (second) .{ 240, 230 - step * 10, 40, 255 } else .{ 20, 40 + step * 8, 170, 255 };
        };
        bc7_picture = if (compress_images) try renderer.createImageCompressed(32, 32, &shapes, true) else try renderer.createImage(32, 32, &shapes, true);
    }
    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    // A font holding capitals only, to show world-space text falling back
    // to another font for the rest (`--text-fallback`).
    const capitals: ?*const gfx.Font = if (text_fallback) try renderer.loadFont("src/render/fonts/DejaVuSans.ttf", &.{.{ 'A', 'Z' }}) else null;
    defer if (capitals) |loaded| renderer.destroyFont(loaded);
    const shaped_font: ?*const gfx.Font = if (shape_font) |path| try renderer.loadFont(path, &.{.{ 32, 126 }}) else null;
    defer if (shaped_font) |loaded| renderer.destroyFont(loaded);
    if (shaped_font) |loaded| try renderer.prepareText(loaded, shape_text);
    // And the forms the font keeps for text set downward.
    if (shaped_font) |loaded| try renderer.prepareTextWith(loaded, shape_text, null, &.{"vert".*});
    var inset = gfx.DrawList.init(init.gpa);
    defer inset.deinit();
    var banner = gfx.DrawList.init(init.gpa);
    defer banner.deinit();
    const views = [2]gfx.View{ try renderer.createView(), try renderer.createView() };
    defer for (views) |view| renderer.destroyView(view);
    var outline = Outline{};
    defer if (outline.pipeline) |pipeline| renderer.device.destroyPipeline(pipeline);
    const passes: []const gfx.Pass = if (custom_pass) &.{.{ .stage = .after_tonemap, .context = &outline, .run = Outline.run }} else &.{};
    const monitor = try renderer.createTarget(320, 180);
    defer renderer.destroyTarget(monitor);
    const canvas_assets = try canvas_scene.Assets.init(renderer);
    defer canvas_assets.deinit(renderer);
    var world_shift = math.Vec3{ 0, 0, 0 };
    for (0..frames) |index| {
        const frame_start = std.Io.Clock.Timestamp.now(init.io, .awake);
        const t = @as(f32, @floatFromInt(index)) / 60.0;
        if (sky_sweep) {
            // The sun sinks toward the horizon; the sky is rebuilt as it moves.
            const elevation = 1.0 - t * 0.5;
            const desc = gfx.SkyDesc{ .sun_direction = .{ -@cos(elevation) * 0.6, -@sin(elevation), -@cos(elevation) * 0.8 }, .turbidity = sky_turbidity, .rebuild_frames = sky_spread };
            renderer.setSky(sky_environment.?, desc);
            renderer.setSun(scene, gfx.skySun(desc));
        }
        var player_pose = gfx.Pose{ .animation = walk, .time = t };
        // Upper body waves while the legs keep walking.
        if (wave) player_pose.layers[0] = .{
            .animation = renderer.findAnimation(robot, "Wave") orelse walk,
            .time = t,
            .weight = 1,
            .root = renderer.findNode(robot, "Abdomen"),
        };
        renderer.setPose(player, player_pose);
        for (crowd_entities, 0..) |member, place| renderer.setPose(member, .{ .animation = walk, .time = if (crowd_sync) t else t + @as(f32, @floatFromInt(place)) * 0.137 });
        if (teleport_frame != null and teleport_frame.? == index) {
            camera_position = teleport_to[0..3].*;
            camera_target = teleport_to[3..6].*;
            camera = gfx.Camera.lookAt(camera_position, camera_target);
        }
        if (shift_frame == index) {
            world_shift = .{ 512.25, 0, -1024.5 };
            try renderer.shiftScene(scene, world_shift);
            camera_position = math.add(camera_position, world_shift);
            camera_target = math.add(camera_target, world_shift);
            camera = gfx.Camera.lookAt(camera_position, camera_target);
        }
        var player_position = math.add(.{ 2.0, 0, -0.4 }, world_shift);
        if (motion) {
            // Strafe the camera and walk the character across the view.
            const offset = math.Vec3{ 0, 0, 1.5 * t };
            camera = gfx.Camera.lookAt(math.add(camera_position, offset), math.add(camera_target, offset));
            player_position = math.add(.{ 2.0, 0, -1.4 + 1.2 * t }, world_shift);
            renderer.setTransform(player, math.mul(math.translation(player_position), math.uniformScaling(0.42)));
        }

        list.clear();
        const size = [2]f32{ @floatFromInt(width), @floatFromInt(height) };
        if (canvas) try canvas_scene.draw(&list, font, canvas_assets, size, t + 1.5);
        if (fluid_picture) |picture| try list.image(picture, .{ .x = size[0] - 140, .y = 12, .width = 128, .height = 128 }, .{});
        if (bc7_picture) |picture| try list.image(picture, .{ .x = 40, .y = 40, .width = 448, .height = 448 }, .{});
        if (shaped_font) |loaded| {
            try list.rect(.{ .x = 20, .y = 20, .width = size[0] - 40, .height = 230 }, gfx.Color.rgba(10, 12, 20, 255));
            try list.text(loaded, shape_text, .{ 40, 70 }, .{ .size = 72 });
            // The same in a column, at the right.
            try list.textVertical(loaded, shape_text, .{ @as(f32, @floatFromInt(width)) - 60, 20 }, .{ .size = 40 });
        }
        if (capitals) |narrow| {
            // Capitals from the narrow font, everything else from the fallback.
            try list.text3d(narrow, "Fallback OK: lower case, 123", .{ 3.0, 2.6, -0.6 }, .{ .size = 0.3, .fallback = &.{font} });
        }
        if (overlay) {
            // World-space: a name tag, a wireframe box and text on the floor.
            try list.text3d(font, "RobotExpressive\nwalking", math.add(player_position, .{ 0, 2.25, 0 }), .{ .size = 0.2 });
            try list.box3d(math.add(player_position, .{ -0.55, 0, -0.55 }), math.add(player_position, .{ 0.55, 1.95, 0.55 }), 2, gfx.Color.hex(0x3ddc97));
            try list.text3d(font, "SPONZA", .{ 0, 0, 0 }, .{
                .size = 0.9,
                .color = gfx.Color.rgba(255, 255, 255, 200),
                .billboard = false,
                // Lying flat on the floor, readable from +X.
                .transform = math.mul(math.translation(.{ 4.5, 0.02, -0.2 }), math.mul(math.rotationY(std.math.pi * 0.5), math.rotationX(-std.math.pi * 0.5))),
            });
            // Screen-space HUD.
            var buffer: [96]u8 = undefined;
            try list.rect(.{ .x = 12, .y = 12, .width = 300, .height = 64 }, gfx.Color.rgba(10, 12, 20, 190));
            try list.text(font, "verify scene", .{ 24, 18 }, .{ .size = 22 });
            try list.text(font, try std.fmt.bufPrint(&buffer, "frame {d} · {d}x{d}", .{ index, width, height }), .{ 24, 46 }, .{
                .size = 15,
                .color = gfx.Color.hex(0x9aa7d0),
            });
        }
        if (reload_frame != null and reload_frame.? == index) {
            // Recompile every shader from source and rebuild the pipelines
            // in the middle of the run; the picture must not change.
            const count = try renderer.reloadShaders();
            std.log.info("frame {d}: reloaded {d} shaders", .{ index, count });
        }
        if (pick_pixel) |pixel| renderer.requestPick(null, pixel);
        if (renderer.takePick()) |result| picked = result;
        if (fail_frame != null and fail_frame.? == index) {
            // A pass that fails after the scene is half recorded; the
            // renderer must report it and carry on with the next frame.
            const broken: []const gfx.Pass = &.{.{ .stage = .after_opaque, .run = failingPass }};
            const outcome = renderer.render(.{ .views = &.{.{ .scene = scene, .camera = camera, .target = .{ .texture = target }, .settings = settings, .passes = broken }} });
            if (outcome != error.InjectedFailure) return error.FailureNotReported;
            std.log.info("frame {d}: injected failure reported, continuing", .{index});
        } else if (multi_view) {
            // A camera drawn into a texture, two cameras side by side, and
            // a 2D layer across both.
            const half = width / 2;
            const monitor_camera = gfx.Camera.lookAt(math.add(player_position, .{ -2.5, 2.2, 2.0 }), math.add(player_position, .{ 0, 1, 0 }));
            const reverse = gfx.Camera.lookAt(math.add(camera_target, .{ 3, 0.5, 0 }), camera.position);
            inset.clear();
            const monitor_image = renderer.targetImage(monitor);
            try inset.rect(.{ .x = 14, .y = @floatFromInt(height - 196), .width = 324, .height = 184 }, gfx.Color.rgba(255, 255, 255, 220));
            try inset.image(monitor_image, .{ .x = 16, .y = @floatFromInt(height - 194), .width = 320, .height = 180 }, .{});
            banner.clear();
            try banner.rect(.{ .x = @as(f32, @floatFromInt(half)) - 1, .y = 0, .width = 2, .height = @floatFromInt(height) }, gfx.Color.rgba(255, 255, 255, 255));
            try banner.text(font, "three views, one frame", .{ @as(f32, @floatFromInt(half)) - 110, @floatFromInt(height - 36) }, .{ .size = 20 });
            _ = try renderer.render(.{
                .views = &.{
                    .{ .view = views[0], .scene = scene, .camera = monitor_camera, .target = .{ .texture = monitor }, .settings = settings },
                    .{
                        .scene = scene,
                        .draw_lists = &.{ &list, &inset },
                        .camera = camera,
                        .target = .{ .texture = target },
                        .region = .{ .x = 0, .y = 0, .width = half, .height = height },
                        .settings = settings,
                    },
                    .{
                        .view = views[1],
                        .scene = scene,
                        .draw_lists = &.{&list},
                        .camera = reverse,
                        .target = .{ .texture = target },
                        .region = .{ .x = half, .y = 0, .width = width - half, .height = height },
                        .passes = passes,
                        .settings = settings,
                    },
                    .{ .draw_lists = &.{&banner}, .target = .{ .texture = target } },
                },
                .delta_time = 1.0 / 60.0,
            });
        } else _ = try renderer.render(.{
            .views = &.{.{
                .scene = if (canvas) null else scene,
                .draw_lists = &.{&list},
                .clear_color = .{ 0.02, 0.025, 0.045, 1 },
                .camera = camera,
                .target = .{ .texture = target },
                .settings = settings,
                .passes = passes,
            }},
            .delta_time = 1.0 / 60.0,
        });
        // Shading variants compile in the background; wait for them so that
        // what is measured and photographed does not depend on timing. The
        // first frame of each new feature set still uses the stand-in.
        try renderer.waitForShaderVariants();
        // Skip warm-up frames (pipeline first use, allocations).
        if (index >= frames / 2) cpu_ns += @intCast(frame_start.untilNow(init.io).raw.nanoseconds);
    }
    worker_state.stop.store(true, .release);
    try workers.await(init.io);
    if (thread_count != 0) {
        std.log.info("threads: {d} workers made {d} renderer calls during {d} frames", .{ thread_count, worker_state.calls.load(.acquire), frames });
        if (worker_state.failed.load(.acquire)) return error.WorkerFailed;
    }
    try device.waitIdle();

    const measured = frames - frames / 2;
    std.log.info("cpu: {d:.3} ms/frame over {d} frames", .{ @as(f64, @floatFromInt(cpu_ns)) / 1e6 / @as(f64, @floatFromInt(measured)), measured });
    var gpu_total: f32 = 0;
    for (device.passTimings()) |timing| {
        std.log.info("gpu: {s:<24} {d:.3} ms", .{ timing.name, timing.milliseconds });
        if (timing.depth == 0) gpu_total += timing.milliseconds;
    }
    std.log.info("gpu: {s:<24} {d:.3} ms", .{ "total", gpu_total });
    if (picked) |result| {
        if (result.hit) |hit| {
            std.log.info("pick at {d},{d}: {s} (mesh {d}), {d:.2} m away at {d:.2} {d:.2} {d:.2}", .{
                result.pixel[0],                                                  result.pixel[1],
                if (std.meta.eql(hit.entity, player)) "the robot" else "scenery", hit.mesh_instance,
                hit.distance,                                                     hit.position[0],
                hit.position[1],                                                  hit.position[2],
            });
        } else std.log.info("pick at {d},{d}: nothing", .{ result.pixel[0], result.pixel[1] });
    } else if (pick_pixel != null) return error.PickNeverAnswered;
    if (profile) zone_log.report();
    const stats = renderer.getStats();
    std.log.info("culling: {d} of {d} meshlets drawn in the main view, {d} across shadow cascades", .{
        stats.meshlets_drawn, stats.meshlets, stats.shadow_meshlets_drawn,
    });
    if (fluid_flipbook) |path| if (flat_fluid) |flat| {
        std.log.info("fluid flipbook: {d} frames recorded", .{renderer.fluidFlipbookFrames(flat)});
        try renderer.saveFluidFlipbook(flat, path);
    };
    if (fluid_frame) |path| if (flat_fluid) |flat| {
        try renderer.saveFluidImage(flat, path);
        std.log.info("wrote fluid frame {s}", .{path});
    };
    if (sorted_emitter) |emitter| {
        const keys = try renderer.emitterSortKeys(init.gpa, emitter);
        defer init.gpa.free(keys);
        var alive: usize = 0;
        for (keys, 0..) |key, index| {
            if (key < 1e29) alive += 1;
            if (index != 0 and key < keys[index - 1]) {
                std.log.err("sort test: key {d} at {d} is below the one before it ({d})", .{ key, index, keys[index - 1] });
                return error.ParticlesNotSorted;
            }
        }
        if (alive == 0) return error.NoParticlesAlive;
        std.log.info("sort test: {d} entries in order, {d} alive, farthest {d:.2} m, nearest {d:.2} m", .{ keys.len, alive, @sqrt(-keys[0]), @sqrt(-keys[alive - 1]) });
    }
    std.log.info("scene: {d} instances, {d} meshlets, {d} triangles; gpu memory {d} MiB", .{
        stats.instances, stats.meshlets, stats.triangles, stats.gpu_memory_bytes / (1024 * 1024),
    });
    if (geometry_distance != null) std.log.info("geometry streaming: {d} models with only their coarse levels in memory", .{renderer.getStats().geometry_models_coarse});
    if (geometry_distance != null) std.log.info("geometry streaming: {d} models released, {d} KiB of vertices and indices", .{
        stats.geometry_models_released, stats.geometry_bytes_released / 1024,
    });
    if (streaming != null) std.log.info("streaming: {d} textures, {d} MiB loaded, {d} waiting", .{
        stats.streamed_textures, stats.streamed_texture_bytes / (1024 * 1024), stats.streamed_textures_pending,
    });

    const pixels = if (flicker_frames != 0)
        try measureFlicker(init, renderer, scene, target, settings, camera, flicker_frames)
    else
        try device.readTexture(init.gpa, target);
    defer init.gpa.free(pixels);
    if (crop) |rect| {
        if (rect[0] + rect[2] > width or rect[1] + rect[3] > height or rect[2] == 0 or rect[3] == 0) return error.InvalidArgument;
        const cropped = try init.gpa.alloc(u8, @as(usize, rect[2]) * rect[3] * 4);
        defer init.gpa.free(cropped);
        for (0..rect[3]) |row| {
            const source = ((rect[1] + row) * width + rect[0]) * 4;
            @memcpy(cropped[row * rect[2] * 4 ..][0 .. rect[2] * 4], pixels[source..][0 .. rect[2] * 4]);
        }
        try gfx.png.write(init.gpa, init.io, output, .{ .width = rect[2], .height = rect[3], .pixels = cropped });
    } else {
        try gfx.png.write(init.gpa, init.io, output, .{ .width = width, .height = height, .pixels = pixels });
        if (reference) |path| try compareReference(init, renderer, path, pixels, width, height, tolerance, update_reference);
    }
    std.log.info("wrote {s}", .{output});

    if (device.validationErrorCount() != 0) return error.ValidationFailed;
}

fn elapsedMs(io: std.Io, start: std.Io.Clock.Timestamp) i64 {
    return @intCast(@divTrunc(start.untilNow(io).raw.nanoseconds, std.time.ns_per_ms));
}

/// A finely made ball placed far away, for `GeometryStreaming.coarse_distance`:
/// with it set, the ball must be down to its coarse levels after a few
/// frames and still be drawn; brought near, it must be whole again.
fn coarseLevels(gpa: std.mem.Allocator, renderer: *gfx.Renderer, scene: gfx.Scene, target: gfx.rhi.Texture, settings: gfx.Settings, expect_coarse: bool, near: bool) !void {
    const rings = 220;
    const positions = try gpa.alloc([3]f32, (rings + 1) * (rings + 1));
    defer gpa.free(positions);
    const indices = try gpa.alloc(u32, rings * rings * 6);
    defer gpa.free(indices);
    for (0..rings + 1) |ring| for (0..rings + 1) |segment| {
        const v = @as(f32, @floatFromInt(ring)) / rings * std.math.pi;
        const u = @as(f32, @floatFromInt(segment)) / rings * std.math.tau;
        // Dimpled, so that its levels of detail differ.
        const radius = 1.2 + 0.05 * @sin(u * 9) * @sin(v * 7);
        positions[ring * (rings + 1) + segment] = .{ radius * @sin(v) * @cos(u), radius * @cos(v), radius * @sin(v) * @sin(u) };
    };
    var at: usize = 0;
    for (0..rings) |ring| for (0..rings) |segment| {
        const corner: u32 = @intCast(ring * (rings + 1) + segment);
        indices[at..][0..6].* = .{ corner, corner + 1, corner + rings + 1, corner + 1, corner + rings + 2, corner + rings + 1 };
        at += 6;
    };
    const camera = gfx.Camera.lookAt(.{ 8.5, 2.1, -0.6 }, .{ 0.0, 2.4, -0.2 });
    const ball = try renderer.createModel(&.{.{ .positions = positions, .indices = indices, .material = .{ .base_color = .{ 0.85, 0.25, 0.1, 1 }, .metallic = 0, .roughness = 0.5, .double_sided = true } }});
    const entity = try renderer.spawn(scene, .{ .model = ball, .transform = math.translation(.{ -8, 3.2, -0.2 }) });
    try renderer.waitUntilLoaded();
    for (0..30) |_| _ = try renderer.render(.{ .views = &.{.{ .scene = scene, .camera = camera, .target = .{ .texture = target }, .settings = settings }} });
    const far = renderer.getStats();
    std.log.info("coarse levels: {d} models coarse with the ball far, gpu memory {d} KiB", .{ far.geometry_models_coarse, far.gpu_memory_bytes / 1024 });
    if (expect_coarse and far.geometry_models_coarse == 0) return error.CoarseLevelsNotKept;
    if (!expect_coarse and far.geometry_models_coarse != 0) return error.CoarseLevelsKeptUnasked;
    if (near) {
        renderer.setTransform(entity, math.translation(.{ 5.2, 2.2, -0.5 }));
        for (0..12) |_| _ = try renderer.render(.{ .views = &.{.{ .scene = scene, .camera = camera, .target = .{ .texture = target }, .settings = settings }} });
        const close = renderer.getStats();
        std.log.info("coarse levels: {d} models coarse with the ball near", .{close.geometry_models_coarse});
        if (close.geometry_models_coarse != 0) return error.CoarseLevelsNotRestored;
    }
}

/// Makes a gap in the geometry pools and checks that it is closed: a
/// large mesh, then a small one after it, then the large one dropped.
/// The small one has to be moved down for the pools to draw back.
fn compaction(gpa: std.mem.Allocator, renderer: *gfx.Renderer, scene: gfx.Scene, target: gfx.rhi.Texture, settings: gfx.Settings) !void {
    const side = 500;
    const positions = try gpa.alloc([3]f32, side * side);
    defer gpa.free(positions);
    const indices = try gpa.alloc(u32, (side - 1) * (side - 1) * 6);
    defer gpa.free(indices);
    for (0..side) |z| for (0..side) |x| {
        positions[z * side + x] = .{ @as(f32, @floatFromInt(x)) * 0.01, -3, @as(f32, @floatFromInt(z)) * 0.01 };
    };
    var at: usize = 0;
    for (0..side - 1) |z| for (0..side - 1) |x| {
        const corner: u32 = @intCast(z * side + x);
        indices[at..][0..6].* = .{ corner, corner + side, corner + 1, corner + 1, corner + side, corner + side + 1 };
        at += 6;
    };
    const camera = gfx.Camera.lookAt(.{ 8.5, 2.1, -0.6 }, .{ 0.0, 2.4, -0.2 });
    const large = try renderer.createModel(&.{.{ .positions = positions, .indices = indices, .material = .{ .metallic = 0, .roughness = 0.8 } }});
    const small = try renderer.createModel(&.{.{ .positions = positions[0 .. side * 60], .indices = indices[0 .. (side - 1) * 6 * 59], .material = .{ .base_color = .{ 0.9, 0.2, 0.1, 1 }, .metallic = 0, .roughness = 0.8, .double_sided = true } }});
    const entity = try renderer.spawn(scene, .{ .model = small, .transform = math.translation(.{ 1.5, 4.4, -0.9 }) });
    const group = try renderer.createInstances(scene, small, &.{ math.translation(.{ 1.5, 4.0, -0.2 }), math.translation(.{ 1.5, 3.6, 0.5 }) });
    try renderer.waitUntilLoaded();
    for (0..40) |_| _ = try renderer.render(.{ .views = &.{.{ .scene = scene, .camera = camera, .target = .{ .texture = target }, .settings = settings }} });
    // The picture with everything where it was put.
    const pixels_before = try renderer.device.readTexture(gpa, target);
    defer gpa.free(pixels_before);
    const before = renderer.getStats();
    try renderer.destroyModel(large);
    for (0..12) |_| _ = try renderer.render(.{ .views = &.{.{ .scene = scene, .camera = camera, .target = .{ .texture = target }, .settings = settings }} });
    const after = renderer.getStats();
    std.log.info("compaction: {d} KiB moved, gpu memory {d} -> {d} KiB", .{ (after.geometry_bytes_compacted - before.geometry_bytes_compacted) / 1024, before.gpu_memory_bytes / 1024, after.gpu_memory_bytes / 1024 });
    if (after.geometry_bytes_compacted == before.geometry_bytes_compacted) return error.GeometryNotCompacted;
    // And with the small model moved: it must look the same (the large
    // one lay under the floor, unseen).
    const pixels_after = try renderer.device.readTexture(gpa, target);
    defer gpa.free(pixels_after);
    var difference: u64 = 0;
    for (pixels_before, pixels_after) |a, b| difference += @abs(@as(i32, a) - @as(i32, b));
    const mean = @as(f32, @floatFromInt(difference)) / @as(f32, @floatFromInt(pixels_before.len));
    std.log.info("compaction: picture differs by {d:.2} levels", .{mean});
    if (mean > 3) return error.CompactedGeometryDrawnWrong;
    // Both stay, so the picture shows them drawn from where they now lie.
    _ = entity;
    _ = group;
}

/// Exercises asset and entity lifetimes: every cycle streams a model in,
/// spawns animated entities, renders, then tears it all down again. Run
/// with `--validation` to catch use-after-free and synchronization errors.
fn soak(renderer: *gfx.Renderer, scene: gfx.Scene, target: gfx.rhi.Texture, settings: gfx.Settings, cycles: u32) !void {
    const camera = gfx.Camera.lookAt(.{ 6, 2, 3 }, .{ 0, 1, 0 });
    // Measured after the first cycle, once render targets and pools exist.
    var before: u64 = 0;
    for (0..cycles) |cycle| {
        const fox = try renderer.loadModel("examples/assets/world/Fox.glb");
        var entities: [4]gfx.Entity = undefined;
        // Spawned while still loading; they appear once the model is ready.
        for (&entities, 0..) |*entity, index| {
            entity.* = try renderer.spawn(scene, .{
                .model = fox,
                .transform = math.mul(math.translation(.{ @floatFromInt(index), 0, 1.5 }), math.uniformScaling(0.012)),
            });
        }
        for (0..6) |frame| {
            // Half the cycles render while the model is still streaming.
            if (frame == 1 and cycle % 2 == 0) try renderer.waitUntilLoaded();
            for (entities, 0..) |entity, index|
                renderer.setPose(entity, .{ .animation = @intCast(index % 3), .time = @as(f32, @floatFromInt(frame)) * 0.1 });
            if (frame == 3) renderer.setVisible(entities[0], false);
            _ = try renderer.render(.{ .views = &.{.{ .scene = scene, .camera = camera, .target = .{ .texture = target }, .settings = settings }} });
        }
        if (renderer.destroyModel(fox) != error.ModelInUse) return error.ExpectedModelInUse;
        for (entities) |entity| renderer.despawn(entity);
        try renderer.destroyModel(fox);
        if (cycle == 0) {
            try renderer.device.waitIdle();
            before = renderer.getStats().gpu_memory_bytes;
        }
    }
    try renderer.device.waitIdle();
    const after = renderer.getStats().gpu_memory_bytes;
    std.log.info("soak: {d} cycles, gpu memory {d} -> {d} KiB", .{ cycles, before / 1024, after / 1024 });
    if (after > before + 1024 * 1024) return error.GpuMemoryLeak;
}

const WorkerState = struct {
    renderer: *gfx.Renderer,
    scene: gfx.Scene,
    model: gfx.Model,
    io: std.Io,
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(u64) = .init(0),
};

/// Uses the renderer from a second thread the way game code would: spawn
/// and move entities, change poses, create and destroy images and fonts,
/// and record a private draw list, all while the main thread renders.
fn worker(state: *WorkerState, index: u32) std.Io.Cancelable!void {
    workerLoop(state, index) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        std.log.err("worker {d} failed: {}", .{ index, err });
        state.failed.store(true, .release);
    };
}

fn workerLoop(state: *WorkerState, index: u32) !void {
    const renderer = state.renderer;
    var list = gfx.DrawList.init(std.heap.smp_allocator);
    defer list.deinit();
    const pixels = [_]u8{ 255, 0, 255, 255 } ** 4;
    var iteration: u32 = 0;
    while (!state.stop.load(.acquire)) : (iteration += 1) {
        const x = @as(f32, @floatFromInt(index)) * 0.8 - 2.0;
        const entity = try renderer.spawn(state.scene, .{
            .model = state.model,
            .transform = math.mul(math.translation(.{ x, 0, 1.2 }), math.uniformScaling(0.2)),
        });
        for (0..16) |step| {
            const t = @as(f32, @floatFromInt(iteration * 16 + @as(u32, @intCast(step)))) * 0.02;
            renderer.setTransform(entity, math.mul(math.translation(.{ x, 0.1 * @sin(t), 1.2 }), math.uniformScaling(0.2)));
            renderer.setPose(entity, .{ .animation = (index + iteration) % 8, .time = t });
            if (step == 8) renderer.setVisible(entity, iteration % 2 == 0);
            _ = renderer.modelInfo(state.model);
            _ = renderer.getStats();
            // Recording is lock-free and private to this thread.
            list.clear();
            try list.text(renderer.defaultFont(), "worker", .{ 0, 0 }, .{});
            try list.text3d(renderer.defaultFont(), "worker", .{ x, 1, 1.2 }, .{});
        }
        const image = try renderer.createImage(2, 2, &pixels, true);
        renderer.destroyImage(image);
        if (iteration % 8 == 0) {
            const font = try renderer.loadFont("src/render/fonts/DejaVuSans.ttf", &.{.{ 'A', 'Z' }});
            renderer.destroyFont(font);
        }
        renderer.despawn(entity);
        _ = state.calls.fetchAdd(16 * 5 + 4, .monotonic);
        try state.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
    }
}

const BenchPass = struct {
    name: []const u8,
    depth: u8,
    samples: std.ArrayList(f32) = .empty,
};

fn percentile(samples: []f32, fraction: f32) f32 {
    if (samples.len == 0) return 0;
    std.mem.sort(f32, samples, {}, std.sort.asc(f32));
    const index: usize = @intFromFloat(@as(f32, @floatFromInt(samples.len - 1)) * fraction);
    return samples[index];
}

/// A repeatable workload: the camera orbits the courtyard while the
/// character walks, so shadows, culling and temporal passes all do real
/// work. Reports median and 95th-percentile GPU time per pass and the CPU
/// time spent recording frames.
fn benchmark(
    init: std.process.Init,
    renderer: *gfx.Renderer,
    scene: gfx.Scene,
    target: gfx.rhi.Texture,
    settings: gfx.Settings,
    player: gfx.Entity,
    walk: u32,
    frames: u32,
) !void {
    const gpa = init.gpa;
    const warmup = 240;
    var passes: std.ArrayList(BenchPass) = .empty;
    defer {
        for (passes.items) |*pass| pass.samples.deinit(gpa);
        passes.deinit(gpa);
    }
    var totals: std.ArrayList(f32) = .empty;
    defer totals.deinit(gpa);
    var cpu: std.ArrayList(f32) = .empty;
    defer cpu.deinit(gpa);

    for (0..warmup + frames) |index| {
        const t = @as(f32, @floatFromInt(index)) / 60.0;
        const angle = t * 0.35;
        const position = math.Vec3{ 6.5 * @cos(angle), 2.2 + 0.8 * @sin(angle * 2), 1.6 * @sin(angle) };
        const camera = gfx.Camera.lookAt(position, .{ -2.0 * @cos(angle), 1.8, -0.5 * @sin(angle) });
        renderer.setPose(player, .{ .animation = walk, .time = t });
        renderer.setTransform(player, math.mul(math.translation(.{ 2.0 + @sin(t * 0.5), 0, -0.4 }), math.uniformScaling(0.42)));
        _ = try renderer.render(.{ .views = &.{.{ .scene = scene, .camera = camera, .target = .{ .texture = target }, .settings = settings }}, .delta_time = 1.0 / 60.0 });
        try renderer.waitForShaderVariants();
        if (index < warmup) continue;
        var total: f32 = 0;
        for (renderer.device.passTimings()) |timing| {
            if (timing.depth == 0) total += timing.milliseconds;
            const pass = for (passes.items) |*candidate| {
                if (candidate.name.ptr == timing.name.ptr) break candidate;
            } else blk: {
                try passes.append(gpa, .{ .name = timing.name, .depth = timing.depth });
                break :blk &passes.items[passes.items.len - 1];
            };
            try pass.samples.append(gpa, timing.milliseconds);
        }
        try totals.append(gpa, total);
        try cpu.append(gpa, renderer.getStats().cpu_ms);
    }
    try renderer.device.waitIdle();

    const info = renderer.device.textureInfo(target);
    std.log.info("benchmark: {d}x{d}, {d} frames after {d} warm-up", .{ info.width, info.height, frames, warmup });
    // Other programs sharing the GPU can only add time, so the low
    // percentile is the best estimate of a pass's own cost.
    std.log.info("{s:<26} {s:>9} {s:>9} {s:>9}", .{ "pass (ms)", "p5", "median", "p95" });
    var floor_total: f32 = 0;
    for (passes.items) |*pass| {
        if (pass.depth == 0) floor_total += percentile(pass.samples.items, 0.05);
        std.log.info("{s}{s:<24} {d:>9.3} {d:>9.3} {d:>9.3}", .{
            if (pass.depth == 0) "  " else "    ",
            pass.name,
            percentile(pass.samples.items, 0.05),
            percentile(pass.samples.items, 0.5),
            percentile(pass.samples.items, 0.95),
        });
    }
    std.log.info("{s:<26} {d:>9.3} {d:>9.3} {d:>9.3}", .{ "gpu total", percentile(totals.items, 0.05), percentile(totals.items, 0.5), percentile(totals.items, 0.95) });
    std.log.info("{s:<26} {d:>9.3}", .{ "sum of pass p5", floor_total });
    std.log.info("{s:<26} {d:>9.3} {d:>9.3} {d:>9.3}", .{ "cpu record+submit", percentile(cpu.items, 0.05), percentile(cpu.items, 0.5), percentile(cpu.items, 0.95) });
    const stats = renderer.getStats();
    std.log.info("meshlets drawn {d}/{d} main, {d} shadow; gi probes {d}", .{ stats.meshlets_drawn, stats.meshlets, stats.shadow_meshlets_drawn, stats.gi_probes });
    if (renderer.device.validationErrorCount() != 0) return error.ValidationFailed;
}

/// A pass written against the renderer's public interface: it owns its
/// pipeline and draws depth-edge outlines over the tone-mapped picture.
const Outline = struct {
    pipeline: ?gfx.rhi.Pipeline = null,
    format: gfx.rhi.Format = undefined,

    fn run(context: ?*anyopaque, pass: gfx.PassContext) anyerror!void {
        const self: *Outline = @ptrCast(@alignCast(context.?));
        if (self.pipeline == null or self.format != pass.color_format) {
            if (self.pipeline) |old| pass.device.destroyPipeline(old);
            self.pipeline = try pass.device.createGraphicsPipeline(.{
                .name = "outline",
                .vertex = @embedFile("example_fullscreen.vert.spv"),
                .fragment = @embedFile("outline.frag.spv"),
                .color_targets = &.{.{ .format = pass.color_format, .blend = .alpha }},
                .cull = .none,
            });
            self.format = pass.color_format;
        }
        try pass.cmd.beginRendering(.{ .color = &.{.{ .texture = pass.color, .load = .load }} });
        pass.cmd.bindPipeline(self.pipeline.?);
        pass.cmd.pushConstants(extern struct { frame: u64, depth: u32, strength: f32, pad: [2]f32 = .{ 0, 0 }, color: [4]f32 }{
            .frame = pass.frame,
            .depth = pass.device.textureIndex(pass.depth),
            .strength = 1,
            .color = .{ 0.02, 0.02, 0.03, 0.9 },
        });
        pass.cmd.drawFullscreen();
        pass.cmd.endRendering();
    }
};

fn failingPass(_: ?*anyopaque, pass: gfx.PassContext) anyerror!void {
    // Fail in the worst place: inside an open render pass.
    try pass.cmd.beginRendering(.{ .color = &.{.{ .texture = pass.color, .load = .load }} });
    return error.InjectedFailure;
}

/// An allocator that can be told to fail one chosen allocation, counted
/// from the start. Safe to use from several threads at once, which the
/// standard library's testing one is not: asset loading allocates on
/// worker threads.
const FailingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_index: std.atomic.Value(usize) = .init(0),
    fail_index: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),

    fn allocator(self: *FailingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(context));
        if (self.alloc_index.fetchAdd(1, .monotonic) == self.fail_index.load(.monotonic)) return null;
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *FailingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *FailingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

/// Fails one allocation at a time, further into the same sequence of
/// operations each round. Every operation must either succeed or return
/// `error.OutOfMemory`, and the renderer must draw a normal frame afterwards.
fn outOfMemory(
    renderer: *gfx.Renderer,
    failing: *FailingAllocator,
    scene: gfx.Scene,
    target: gfx.rhi.Texture,
    settings: gfx.Settings,
    rounds: usize,
) !void {
    const camera = gfx.Camera.lookAt(.{ -6, 2, 0 }, .{ 4, 1.5, 0 });
    const triangle = [_][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    const indices = [_]u32{ 0, 1, 2 };
    var list = gfx.DrawList.init(failing.allocator());
    defer list.deinit();
    var failures: usize = 0;
    for (0..rounds) |round| {
        failing.fail_index.store(failing.alloc_index.load(.monotonic) + round, .monotonic);
        const outcome: anyerror!void = blk: {
            const model = renderer.createModel(&.{.{ .positions = &triangle, .indices = &indices }}) catch |err| break :blk err;
            defer renderer.destroyModel(model) catch {};
            const entity = renderer.spawn(scene, .{ .model = model, .transform = math.translation(.{ 2, 1, 0 }) }) catch |err| break :blk err;
            defer renderer.despawn(entity);
            list.clear();
            list.text(renderer.defaultFont(), "out of memory test", .{ 20, 20 }, .{ .size = 18 }) catch |err| break :blk err;
            const lights = [_]gfx.Light{.{ .position = .{ 2, 2, 0 }, .color = .{ 1, 1, 1 }, .intensity = 5, .range = 6 }};
            renderer.setLights(scene, &lights) catch |err| break :blk err;
            _ = renderer.render(.{ .views = &.{.{ .scene = scene, .camera = camera, .draw_lists = &.{&list}, .target = .{ .texture = target }, .settings = settings }} }) catch |err| break :blk err;
        };
        failing.fail_index.store(std.math.maxInt(usize), .monotonic);
        if (outcome) |_| {} else |err| {
            if (err != error.OutOfMemory) return err;
            failures += 1;
        }
        // Whatever happened, the next frame must work.
        _ = try renderer.render(.{ .views = &.{.{ .scene = scene, .camera = camera, .target = .{ .texture = target }, .settings = settings }} });
    }
    try renderer.setLights(scene, &.{});
    std.log.info("out of memory: {d} of {d} rounds hit an injected failure, all recovered", .{ failures, rounds });

    // The same for a model loaded from a file, whose decoding runs on
    // worker threads: one clean load counts its allocations, then each
    // round fails one of them, spread evenly over the whole load.
    const path = "examples/assets/world/Fox.glb";
    const before = failing.alloc_index.load(.monotonic);
    {
        const clean = try renderer.loadModel(path);
        try renderer.waitUntilLoaded();
        if (renderer.modelState(clean) != .ready) return error.ModelNotLoaded;
        try renderer.destroyModel(clean);
    }
    const allocations = failing.alloc_index.load(.monotonic) - before;
    var load_failures: usize = 0;
    for (0..rounds) |round| {
        failing.fail_index.store(failing.alloc_index.load(.monotonic) + round * allocations / rounds, .monotonic);
        const loaded: ?gfx.Model = renderer.loadModel(path) catch |err| blk: {
            if (err != error.OutOfMemory) return err;
            break :blk null;
        };
        if (loaded) |model| {
            renderer.waitUntilLoaded() catch |err| if (err != error.OutOfMemory) return err;
            failing.fail_index.store(std.math.maxInt(usize), .monotonic);
            // A wait cut short leaves the load unfinished; let it finish.
            try renderer.waitUntilLoaded();
            switch (renderer.modelState(model)) {
                .ready => {},
                .failed => {
                    const cause = renderer.modelError(model) orelse return error.UnexpectedLoadFailure;
                    if (cause != error.OutOfMemory) return cause;
                    load_failures += 1;
                },
                else => return error.ModelStillLoading,
            }
            try renderer.destroyModel(model);
        } else load_failures += 1;
        failing.fail_index.store(std.math.maxInt(usize), .monotonic);
        _ = try renderer.render(.{ .views = &.{.{ .scene = scene, .camera = camera, .target = .{ .texture = target }, .settings = settings }} });
    }
    std.log.info("out of memory while loading: {d} allocations per load, {d} of {d} rounds failed the load, all recovered", .{ allocations, load_failures, rounds });
}

/// Fails one GPU memory allocation at a time while a view with render
/// targets of its own, an image, a model and an entity are created and a
/// frame is drawn with them. Whatever fails, the next frame must work, and
/// validation must find nothing left behind.
fn outOfGpuMemory(
    renderer: *gfx.Renderer,
    scene: gfx.Scene,
    target: gfx.rhi.Texture,
    settings: gfx.Settings,
    rounds: usize,
) !void {
    const device = renderer.device;
    const camera = gfx.Camera.lookAt(.{ -6, 2, 0 }, .{ 4, 1.5, 0 });
    const triangle = [_][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    const indices = [_]u32{ 0, 1, 2 };
    const pixels = [_]u8{200} ** (16 * 16 * 4);
    var failures: usize = 0;
    for (0..rounds) |round| {
        device.failGpuAllocation(@intCast(round));
        const outcome: anyerror!void = blk: {
            const view = renderer.createView() catch |err| break :blk err;
            defer renderer.destroyView(view);
            // A size of its own each round, so the view's targets are new.
            const small = device.createTexture(.{
                .name = "small output",
                .width = @intCast(192 + round * 2),
                .height = 108,
                .format = .rgba8_unorm,
                .usage = .{ .color_attachment = true, .sampled = true, .copy_src = true },
            }) catch |err| break :blk err;
            defer device.destroyTexture(small);
            const image = renderer.createImage(16, 16, &pixels, true) catch |err| break :blk err;
            defer renderer.destroyImage(image);
            const model = renderer.createModel(&.{.{ .positions = &triangle, .indices = &indices }}) catch |err| break :blk err;
            defer renderer.destroyModel(model) catch {};
            const entity = renderer.spawn(scene, .{ .model = model, .transform = math.translation(.{ 2, 1, 0 }) }) catch |err| break :blk err;
            defer renderer.despawn(entity);
            _ = renderer.render(.{ .views = &.{.{ .view = view, .scene = scene, .camera = camera, .target = .{ .texture = small }, .settings = settings }} }) catch |err| break :blk err;
        };
        // Some failures are absorbed (a model that fails to upload is
        // reported and skipped), so count the ones that were injected.
        if (!device.gpuAllocationFailurePending()) failures += 1;
        device.failGpuAllocation(null);
        if (outcome) |_| {} else |err| {
            if (err != error.OutOfDeviceMemory) return err;
        }
        _ = try renderer.render(.{ .views = &.{.{ .scene = scene, .camera = camera, .target = .{ .texture = target }, .settings = settings }} });
    }
    std.log.info("out of GPU memory: {d} of {d} rounds hit an injected failure, all recovered", .{ failures, rounds });
}

/// Renders a scene in which nothing moves and measures how much the
/// picture still changes from frame to frame. Returns a heat map: black is
/// stable, white changes by 8 or more 8-bit levels per frame on average.
fn measureFlicker(
    init: std.process.Init,
    renderer: *gfx.Renderer,
    scene: gfx.Scene,
    target: gfx.rhi.Texture,
    settings: gfx.Settings,
    camera: gfx.Camera,
    frames: usize,
) ![]u8 {
    const device = renderer.device;
    const view = gfx.ViewDesc{ .scene = scene, .camera = camera, .target = .{ .texture = target }, .settings = settings };
    // Let temporal effects settle on the now static scene first.
    for (0..48) |_| _ = try renderer.render(.{ .views = &.{view} });
    var previous = try device.readTexture(init.gpa, target);
    defer init.gpa.free(previous);
    const sums = try init.gpa.alloc(f32, previous.len / 4);
    defer init.gpa.free(sums);
    @memset(sums, 0);
    for (0..frames) |_| {
        _ = try renderer.render(.{ .views = &.{view} });
        const current = try device.readTexture(init.gpa, target);
        for (sums, 0..) |*sum, pixel| {
            var difference: u32 = 0;
            inline for (0..3) |channel| {
                const a: i32 = current[pixel * 4 + channel];
                const b: i32 = previous[pixel * 4 + channel];
                difference = @max(difference, @abs(a - b));
            }
            // A change of one level is the output dither, not flicker.
            if (difference >= 2) sum.* += @floatFromInt(difference);
        }
        init.gpa.free(previous);
        previous = current;
    }
    const heat = try init.gpa.alloc(u8, previous.len);
    var total: f64 = 0;
    var above_one: usize = 0;
    var above_three: usize = 0;
    var worst: f32 = 0;
    for (sums, 0..) |sum, pixel| {
        const mean = sum / @as(f32, @floatFromInt(frames));
        total += mean;
        worst = @max(worst, mean);
        if (mean > 0.25) above_one += 1;
        if (mean > 1) above_three += 1;
        const shade: u8 = @intFromFloat(@min(mean / 8.0, 1.0) * 255.0);
        heat[pixel * 4 ..][0..4].* = .{ shade, shade, shade, 255 };
    }
    const count: f64 = @floatFromInt(sums.len);
    std.log.info("flicker over {d} static frames: mean {d:.3} levels/frame, {d:.2}% of pixels above 0.25, {d:.2}% above 1, worst {d:.1}", .{
        frames,                                             total / count,
        @as(f64, @floatFromInt(above_one)) * 100.0 / count, @as(f64, @floatFromInt(above_three)) * 100.0 / count,
        worst,
    });
    return heat;
}

/// Compares the frame with a stored picture of what it should look like.
/// Small differences (other GPUs round and filter slightly differently) are
/// allowed; the test fails when the average difference per channel exceeds
/// `tolerance` 8-bit levels or more than 2% of the pixels are clearly off.
fn compareReference(
    init: std.process.Init,
    renderer: *gfx.Renderer,
    path: []const u8,
    pixels: []const u8,
    width: u32,
    height: u32,
    tolerance: f32,
    update: bool,
) !void {
    // The stored pictures were made on one particular GPU. Another one
    // filters textures and rounds a little differently, so the comparison
    // is strict on the same device and loose on any other: there it only
    // catches a picture that is plainly wrong.
    const device_name = renderer.device.name();
    var device_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const device_path = try std.fmt.bufPrint(&device_path_buffer, "{s}/device.txt", .{std.fs.path.dirname(path) orelse "."});
    var same_device = true;
    if (!update) {
        var name_buffer: [256]u8 = undefined;
        if (std.Io.Dir.cwd().readFile(init.io, device_path, &name_buffer)) |recorded| {
            same_device = std.mem.eql(u8, std.mem.trim(u8, recorded, " \n"), device_name);
        } else |_| {}
    }
    // Ray-traced global illumination is in the pictures; without it the
    // lit views are legitimately different.
    if (!renderer.device.ray_tracing and !update) {
        std.log.info("reference {s}: skipped, this device has no ray tracing", .{path});
        return;
    }
    const stored = renderer.readImageFile(init.gpa, path) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        break :blk null;
    };
    if (update or stored == null) {
        if (stored) |image| init.gpa.free(image.pixels);
        try gfx.png.write(init.gpa, init.io, path, .{ .width = width, .height = height, .pixels = pixels });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = device_path, .data = device_name });
        std.log.info("reference {s}: written", .{path});
        return;
    }
    const expected = stored.?;
    defer init.gpa.free(expected.pixels);
    if (expected.width != width or expected.height != height) {
        std.log.err("reference {s}: is {d}x{d}, frame is {d}x{d}", .{ path, expected.width, expected.height, width, height });
        return error.ReferenceMismatch;
    }
    var total: u64 = 0;
    var off: usize = 0;
    for (0..pixels.len / 4) |pixel| {
        var worst: u32 = 0;
        inline for (0..3) |channel| {
            const difference = @abs(@as(i32, pixels[pixel * 4 + channel]) - @as(i32, expected.pixels[pixel * 4 + channel]));
            total += difference;
            worst = @max(worst, difference);
        }
        if (worst > 24) off += 1;
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(pixels.len / 4 * 3));
    const off_percent = @as(f64, @floatFromInt(off)) * 100.0 / @as(f64, @floatFromInt(pixels.len / 4));
    std.log.info("reference {s}: mean difference {d:.3} levels, {d:.2}% of pixels clearly off", .{ path, mean, off_percent });
    const allowed_mean: f64 = if (same_device) tolerance else @max(tolerance, 8);
    const allowed_off: f64 = if (same_device) 2.0 else 20.0;
    if (!same_device) std.log.info("reference {s}: made on another device, compared loosely", .{path});
    if (mean > allowed_mean or off_percent > allowed_off) return error.ReferenceMismatch;
}

/// A minimal profiler behind the renderer's hooks: total time and call
/// count per zone name. A real one (Tracy) plugs in the same way.
const ZoneLog = struct {
    io: std.Io,
    names: [16][:0]const u8 = undefined,
    totals: [16]u64 = @splat(0),
    calls: [16]u64 = @splat(0),
    count: usize = 0,
    starts: [64]std.Io.Clock.Timestamp = undefined,
    depth: usize = 0,

    fn begin(context: ?*anyopaque, name: [:0]const u8) u64 {
        const self: *ZoneLog = @ptrCast(@alignCast(context.?));
        const index = for (self.names[0..self.count], 0..) |known, index| {
            if (known.ptr == name.ptr) break index;
        } else blk: {
            self.names[self.count] = name;
            self.count += 1;
            break :blk self.count - 1;
        };
        self.starts[self.depth] = std.Io.Clock.Timestamp.now(self.io, .awake);
        self.depth += 1;
        return index;
    }

    fn end(context: ?*anyopaque, zone: u64) void {
        const self: *ZoneLog = @ptrCast(@alignCast(context.?));
        self.depth -= 1;
        self.totals[@intCast(zone)] += @intCast(self.starts[self.depth].untilNow(self.io).raw.nanoseconds);
        self.calls[@intCast(zone)] += 1;
    }

    fn report(self: *const ZoneLog) void {
        for (self.names[0..self.count], self.totals[0..self.count], self.calls[0..self.count]) |name, total, calls| {
            std.log.info("zone {s:<16} {d:>6} calls, {d:.3} ms each", .{ name, calls, @as(f64, @floatFromInt(total)) / 1e6 / @as(f64, @floatFromInt(@max(calls, 1))) });
        }
    }
};

/// Writes a two-triangle panel as a glTF model whose only texture is a
/// KTX2 file of BC1 blocks (a yellow and blue checkerboard), and returns
/// the model's path.
fn writeKtx2Panel(gpa: std.mem.Allocator, io: std.Io, directory: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, directory, .{});
    defer dir.close(io);

    var blocks: [16 * 16 * 8]u8 = undefined;
    for (0..16) |by| for (0..16) |bx| {
        const color: u16 = if ((bx / 2 + by / 2) % 2 == 0) 0xfe60 else 0x18ca;
        const block = blocks[(by * 16 + bx) * 8 ..][0..8];
        std.mem.writeInt(u16, block[0..2], color, .little);
        std.mem.writeInt(u16, block[2..4], color, .little);
        @memset(block[4..8], 0);
    };
    const texture = try gfx.ktx2.write(gpa, .{ .width = 64, .height = 64, .format = .bc1, .srgb = true, .levels = 1, .data = &blocks });
    defer gpa.free(texture);
    try dir.writeFile(io, .{ .sub_path = "checker.ktx2", .data = texture });

    const positions = [4][3]f32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 2, 0 }, .{ -1, 2, 0 } };
    const uvs = [4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
    const indices = [6]u16{ 0, 1, 2, 0, 2, 3 };
    var geometry: [92]u8 = undefined;
    @memcpy(geometry[0..48], std.mem.asBytes(&positions));
    @memcpy(geometry[48..80], std.mem.asBytes(&uvs));
    @memcpy(geometry[80..92], std.mem.asBytes(&indices));
    try dir.writeFile(io, .{ .sub_path = "checker.bin", .data = &geometry });

    try dir.writeFile(io, .{ .sub_path = "checker.gltf", .data =
        \\{
        \\  "asset": { "version": "2.0" },
        \\  "scene": 0,
        \\  "scenes": [{ "nodes": [0] }],
        \\  "nodes": [{ "mesh": 0 }],
        \\  "meshes": [{ "primitives": [{ "attributes": { "POSITION": 0, "TEXCOORD_0": 1 }, "indices": 2, "material": 0 }] }],
        \\  "materials": [{ "doubleSided": true, "pbrMetallicRoughness": { "baseColorTexture": { "index": 0 }, "metallicFactor": 0, "roughnessFactor": 0.8 } }],
        \\  "textures": [{ "source": 0, "sampler": 0 }],
        \\  "samplers": [{ "magFilter": 9728 }],
        \\  "images": [{ "uri": "checker.ktx2" }],
        \\  "buffers": [{ "uri": "checker.bin", "byteLength": 92 }],
        \\  "bufferViews": [
        \\    { "buffer": 0, "byteOffset": 0, "byteLength": 48 },
        \\    { "buffer": 0, "byteOffset": 48, "byteLength": 32 },
        \\    { "buffer": 0, "byteOffset": 80, "byteLength": 12 }
        \\  ],
        \\  "accessors": [
        \\    { "bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [-1, 0, 0], "max": [1, 2, 0] },
        \\    { "bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC2" },
        \\    { "bufferView": 2, "componentType": 5123, "count": 6, "type": "SCALAR" }
        \\  ]
        \\}
        \\
    });
    return std.fs.path.join(gpa, &.{ directory, "checker.gltf" });
}

const morph_row_tiles = 12;

/// Writes a glTF model of twelve square tiles in a row, each with a morph
/// target of its own that lifts it, and returns the model's path.
fn writeMorphRow(gpa: std.mem.Allocator, io: std.Io, directory: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, directory, .{});
    defer dir.close(io);
    const tiles = morph_row_tiles;
    const vertices = tiles * 4;
    var positions: [vertices][3]f32 = undefined;
    var indices: [tiles * 6]u16 = undefined;
    var deltas: [tiles][vertices][3]f32 = @splat(@splat(.{ 0, 0, 0 }));
    for (0..tiles) |tile| {
        const left = (@as(f32, @floatFromInt(tile)) - tiles * 0.5) * 0.22;
        positions[tile * 4 ..][0..4].* = .{ .{ left, 0, 0 }, .{ left + 0.2, 0, 0 }, .{ left + 0.2, 0.2, 0 }, .{ left, 0.2, 0 } };
        const base: u16 = @intCast(tile * 4);
        indices[tile * 6 ..][0..6].* = .{ base, base + 1, base + 2, base, base + 2, base + 3 };
        for (deltas[tile][tile * 4 ..][0..4]) |*delta| delta.* = .{ 0, 0.5, 0 };
    }
    const position_bytes = @sizeOf(@TypeOf(positions));
    const index_bytes = @sizeOf(@TypeOf(indices));
    const delta_bytes = @sizeOf(@TypeOf(deltas));
    const geometry = try gpa.alloc(u8, position_bytes + index_bytes + delta_bytes);
    defer gpa.free(geometry);
    @memcpy(geometry[0..position_bytes], std.mem.asBytes(&positions));
    @memcpy(geometry[position_bytes..][0..index_bytes], std.mem.asBytes(&indices));
    @memcpy(geometry[position_bytes + index_bytes ..], std.mem.asBytes(&deltas));
    try dir.writeFile(io, .{ .sub_path = "tiles.bin", .data = geometry });

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa,
        \\{ "asset": { "version": "2.0" }, "scene": 0, "scenes": [{ "nodes": [0] }], "nodes": [{ "mesh": 0 }],
        \\  "materials": [{ "doubleSided": true, "pbrMetallicRoughness": { "baseColorFactor": [0.9, 0.3, 0.2, 1], "metallicFactor": 0, "roughnessFactor": 0.7 } }],
        \\  "meshes": [{ "primitives": [{ "attributes": { "POSITION": 0 }, "indices": 1, "material": 0, "targets": [
    );
    for (0..tiles) |tile| {
        const entry = try std.fmt.allocPrint(gpa, "{s}{{ \"POSITION\": {d} }}", .{ if (tile == 0) "" else ", ", tile + 2 });
        defer gpa.free(entry);
        try json.appendSlice(gpa, entry);
    }
    const middle = try std.fmt.allocPrint(gpa,
        \\] }}] }}],
        \\  "buffers": [{{ "uri": "tiles.bin", "byteLength": {d} }}],
        \\  "bufferViews": [
        \\    {{ "buffer": 0, "byteOffset": 0, "byteLength": {d} }},
        \\    {{ "buffer": 0, "byteOffset": {d}, "byteLength": {d} }},
        \\    {{ "buffer": 0, "byteOffset": {d}, "byteLength": {d} }}
        \\  ],
        \\  "accessors": [
        \\    {{ "bufferView": 0, "componentType": 5126, "count": {d}, "type": "VEC3", "min": [-1.32, 0, 0], "max": [1.32, 0.2, 0] }},
        \\    {{ "bufferView": 1, "componentType": 5123, "count": {d}, "type": "SCALAR" }}
    , .{ geometry.len, position_bytes, position_bytes, index_bytes, position_bytes + index_bytes, delta_bytes, vertices, tiles * 6 });
    defer gpa.free(middle);
    try json.appendSlice(gpa, middle);
    for (0..tiles) |tile| {
        const entry = try std.fmt.allocPrint(gpa, ",\n    {{ \"bufferView\": 2, \"byteOffset\": {d}, \"componentType\": 5126, \"count\": {d}, \"type\": \"VEC3\" }}", .{ tile * vertices * 12, vertices });
        defer gpa.free(entry);
        try json.appendSlice(gpa, entry);
    }
    try json.appendSlice(gpa, "\n  ]\n}\n");
    try dir.writeFile(io, .{ .sub_path = "tiles.gltf", .data = json.items });
    return std.fs.path.join(gpa, &.{ directory, "tiles.gltf" });
}
