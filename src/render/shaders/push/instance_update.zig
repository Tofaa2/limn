//! Push constants of the passes in instance_update.slang. The build writes each
//! struct as `instance_update.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    records: u64,
    previous: u64,
    tlas: u64,
    updates: u64,
    count: u32,

    pub const references = .{ .records = "Instance*", .previous = "float3x4*", .tlas = "TlasInstance*", .updates = "Updates" };
};
