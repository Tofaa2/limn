//! Sun and light shadow constants, `FrameConstants.shadows`. The shader struct is generated
//! from it by the build, so it imports nothing but the frame constants.
const frame_constants = @import("../../core/frame_constants.zig");
const invalid_id = frame_constants.invalid_id;

pub const ShadowConstants = extern struct {
    /// A `VsmParams` when `virtual_maps` is set.
    vsm: u64 = 0,
    cascade_view_proj: [frame_constants.cascade_count][16]f32 = @splat(@splat(0)),
    /// View depth at which each cascade ends.
    cascade_splits: [4]f32 = @splat(0),
    /// World size of one shadow map texel in each cascade.
    cascade_texel_size: [4]f32 = @splat(0),
    /// Width of the sun shadow's penumbra, in world units.
    shadow_softness: f32 = 0,
    /// The sun's cascades (a 2D array texture) and its comparison sampler.
    shadow_map: u32 = invalid_id,
    shadow_sampler: u32 = 0,
    /// The local lights' shadow atlas and its comparison sampler.
    local_shadow_map: u32 = invalid_id,
    local_shadow_sampler: u32 = 0,
    /// Sun shadow filter samples: 4, 8 or 16.
    shadow_taps: u32 = 16,
    /// Contact shadow depth buffer, or `invalid_id`, and reach in world units.
    contact_depth: u32 = invalid_id,
    contact_length: f32 = 0,
    /// Address of the scene's TLAS for traced light shadows, in two halves;
    /// 0 for none.
    tlas_low: u32 = 0,
    tlas_high: u32 = 0,
    /// Tint of sunlight passed by see-through casters, per cascade (rgb) with
    /// the nearest such caster's depth (a); or `invalid_id`.
    shadow_color: u32 = invalid_id,
    /// 1 when the sun's cascades are valid.
    enabled: u32 = 0,
    /// 1 when see-through casters tint sunlight.
    colored: u32 = 0,
    /// 1 when the sun's shadows are read from `vsm` where it has them.
    virtual_maps: u32 = 0,
    /// Rays per traced light shadow, 1 to 15.
    light_rays: u32 = 1,
    pad: u32 = 0,

    pub const references = .{ .vsm = "Vsm" };
};

comptime {
    @import("std").debug.assert(@sizeOf(ShadowConstants) % 8 == 0);
}
