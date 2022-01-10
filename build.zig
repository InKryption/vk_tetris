const std = @import("std");
const mach_glfw = @import("dep/mach/glfw/build.zig");
const vulkan_zig = @import("dep/vulkan-zig/generator/index.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("vk_tetris", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    mach_glfw.link(b, exe, .{});
    exe.addPackagePath("mach-glfw", "dep/mach/glfw/src/main.zig");

    const vulkan_sdk_path = b.env_map.get("VULKAN_SDK").?;
    const glslc_cmd_path = b.pathJoin(&[_][]const u8{ vulkan_sdk_path, "bin", "glslc" });
    _ = glslc_cmd_path;

    const generate_vk = vulkan_zig.VkGenerateStep.initFromSdk(b, vulkan_sdk_path, "vk.zig");
    exe.step.dependOn(&generate_vk.step);
    exe.addPackagePath(generate_vk.package.name, "zig-cache/vk.zig");

    // const shader_bytecode_paths = b.addOptions();
    // const compile_shaders = vulkan_zig.ShaderCompileStep.init(b, &.{ glslc_cmd_path }, "shaders");
    // shader_bytecode_paths.step.dependOn(&compile_shaders.step);

    // shader_bytecode_paths.addOption([]const u8, "triangle_frag", compile_shaders.add("src/shaders/triangle.frag"));
    // shader_bytecode_paths.addOption([]const u8, "triangle_vert", compile_shaders.add("src/shaders/triangle.vert"));

    // exe.addOptions("shader_bytecode_paths", shader_bytecode_paths);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
