const shader_bytecode_paths = @import("shader_bytecode_paths");

pub const triangle_frag = @embedFile(shader_bytecode_paths.triangle_frag);
pub const triangle_vert = @embedFile(shader_bytecode_paths.triangle_vert);
