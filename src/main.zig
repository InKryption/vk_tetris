const std = @import("std");
const log = std.log;
const mem = std.mem;
const heap = std.heap;
const meta = std.meta;
const debug = std.debug;

const assert = debug.assert;

const vk = @import("vulkan");
const glfw = @import("mach-glfw");

const VulkanBase = @import("VulkanBase.zig");

pub fn main() !void {
    var gpa_state = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();

    const allocator: mem.Allocator = gpa_state.allocator();
    _ = allocator;

    try glfw.init(.{});
    defer glfw.terminate();

    const window = try glfw.Window.create(600, 600, "TETRIS", null, null, glfw.Window.Hints{
        .client_api = .no_api,
    });
    defer window.destroy();

    const vk_allocator: ?*const vk.AllocationCallbacks = null;

    const vk_base = try VulkanBase.init(allocator, vk_allocator, window);
    defer vk_base.deinit(vk_allocator);

    while (!window.shouldClose()) {
        glfw.pollEvents() catch unreachable;
    }
}
