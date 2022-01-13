const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const math = std.math;
const debug = std.debug;

const assert = debug.assert;

const vk = @import("vulkan");
const glfw = @import("mach-glfw");

const VulkanBase = @import("VulkanBase.zig");

const VulkanSwapchain = @This();
handle: vk.SwapchainKHR,
capabilities: vk.SurfaceCapabilitiesKHR,
surface_format: vk.SurfaceFormatKHR,
present_mode: vk.PresentModeKHR,
extent: vk.Extent2D,
images: ImageHandleAndView.MultiSlice,

pub fn init(
    child_allocator: mem.Allocator,
    vk_base: VulkanBase,
    window: glfw.Window,
    vk_allocator: ?*const vk.AllocationCallbacks,
) !VulkanSwapchain {
    var local_arena = heap.ArenaAllocator.init(child_allocator);
    defer local_arena.deinit();

    const allocator = local_arena.allocator();

    const capabilities = try vk_base.instance.d.getPhysicalDeviceSurfaceCapabilitiesKHR(
        vk_base.physical_device,
        vk_base.surface,
    );

    const surface_format: vk.SurfaceFormatKHR = surface_format: {
        const all_surface_formats: []const vk.SurfaceFormatKHR = all_surface_formats: {
            var count: u32 = undefined;

            const func = vk_base.instance.d.getPhysicalDeviceSurfaceFormatsKHR;
            const args0_2 = .{ vk_base.physical_device, vk_base.surface, &count };

            assert(@call(.{}, func, args0_2 ++ .{null}) catch unreachable == .success);

            const slice = try allocator.alloc(vk.SurfaceFormatKHR, count);
            errdefer allocator.free(slice);

            assert(@call(.{}, func, args0_2 ++ .{slice.ptr}) catch unreachable == .success);
            assert(count == slice.len);

            break :all_surface_formats slice;
        };
        defer allocator.free(all_surface_formats);

        break :surface_format selectSurfaceFormat(all_surface_formats);
    };

    const present_mode: vk.PresentModeKHR = present_mode: {
        const all_present_modes: []const vk.PresentModeKHR = all_present_modes: {
            var count: u32 = undefined;

            const func = vk_base.instance.d.getPhysicalDeviceSurfacePresentModesKHR;
            const args0_2 = .{ vk_base.physical_device, vk_base.surface, &count };

            assert(@call(.{}, func, args0_2 ++ .{null}) catch unreachable == .success);

            const slice = try allocator.alloc(vk.PresentModeKHR, count);
            errdefer allocator.free(slice);

            assert(@call(.{}, func, args0_2 ++ .{slice.ptr}) catch unreachable == .success);
            assert(count == slice.len);

            break :all_present_modes slice;
        };
        defer allocator.free(all_present_modes);

        break :present_mode selectPresentMode(all_present_modes);
    };

    const extent = try selectExtent(window, capabilities);

    const exclusive_queue_access = vk_base.qfi.get(.graphics) == vk_base.qfi.get(.present);

    const handle = try vk_base.device.d.createSwapchainKHR(vk_base.device.h, &vk.SwapchainCreateInfoKHR{
        .flags = vk.SwapchainCreateFlagsKHR{},
        .surface = vk_base.surface,
        .min_image_count = selectImageCount(capabilities),
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = vk.ImageUsageFlags{ .color_attachment_bit = true },

        .image_sharing_mode = if (exclusive_queue_access) .exclusive else .concurrent,
        .queue_family_index_count = if (exclusive_queue_access) 0 else 2,
        .p_queue_family_indices = if (exclusive_queue_access)
            undefined
        else
            &[_]u32{ vk_base.qfi.get(.graphics), vk_base.qfi.get(.present) },

        .pre_transform = capabilities.current_transform,
        .composite_alpha = vk.CompositeAlphaFlagsKHR{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = .null_handle,
    }, vk_allocator);
    errdefer vk_base.device.d.destroySwapchainKHR(vk_base.device.h, handle, vk_allocator);

    var images: ImageHandleAndView.MultiArrayList = try createImageAndHandleViewMultiArrayList(
        child_allocator,
        vk_base,
        handle,
        surface_format,
        vk_allocator,
    );
    errdefer {
        destroyImageViews(vk_base, images.items(.view), vk_allocator);
        images.deinit(child_allocator);
    }

    return VulkanSwapchain{
        .handle = handle,
        .capabilities = capabilities,
        .surface_format = surface_format,
        .present_mode = present_mode,
        .extent = extent,
        .images = images.toOwnedSlice(),
    };
}

pub fn deinit(
    self: *VulkanSwapchain,
    allocator: mem.Allocator,
    vk_base: VulkanBase,
    vk_allocator: ?*const vk.AllocationCallbacks,
) void {
    destroyImageViews(vk_base, self.images.items(.view), vk_allocator);
    self.images.deinit(allocator);
    vk_base.device.d.destroySwapchainKHR(vk_base.device.h, self.handle, vk_allocator);
}

pub const ImageHandleAndView = struct {
    handle: vk.Image,
    view: vk.ImageView,

    pub const MultiArrayList = std.MultiArrayList(ImageHandleAndView);
    pub const MultiSlice = MultiArrayList.Slice;
};

fn selectSurfaceFormat(surface_formats: []const vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    for (surface_formats) |surface_format| {
        if (surface_format.format == .b8g8r8a8_srgb and surface_format.color_space == .srgb_nonlinear_khr) {
            return surface_format;
        }
    } else return surface_formats[0];
}

fn selectPresentMode(present_modes: []const vk.PresentModeKHR) vk.PresentModeKHR {
    assert(present_modes.len >= 1);
    assert(mem.count(vk.PresentModeKHR, present_modes, &.{.fifo_khr}) == 1);
    for (present_modes) |present_mode| {
        if (present_mode == .mailbox_khr) {
            return present_mode;
        }
    } else return .fifo_khr;
}

fn selectExtent(window: glfw.Window, capabilities: vk.SurfaceCapabilitiesKHR) !vk.Extent2D {
    if (capabilities.current_extent.width != math.maxInt(u32)) {
        return capabilities.current_extent;
    }

    const fb_size: glfw.Window.Size = try window.getFramebufferSize();

    const min = capabilities.min_image_extent;
    const max = capabilities.max_image_extent;

    return vk.Extent2D{
        .width = math.clamp(fb_size.width, min.width, max.width),
        .height = math.clamp(fb_size.height, min.height, max.height),
    };
}

fn selectImageCount(capabilities: vk.SurfaceCapabilitiesKHR) u32 {
    const min = capabilities.min_image_count;
    const max = if (capabilities.max_image_count == 0) math.maxInt(u32) else capabilities.max_image_count;
    return math.clamp(min + 1, min, max);
}

fn createImageAndHandleViewMultiArrayList(
    allocator: mem.Allocator,
    vk_base: VulkanBase,
    swapchain_handle: vk.SwapchainKHR,
    surface_format: vk.SurfaceFormatKHR,
    vk_allocator: ?*const vk.AllocationCallbacks,
) !ImageHandleAndView.MultiArrayList {
    var result = ImageHandleAndView.MultiArrayList{};

    populate_handles: {
        var count: u32 = undefined;
        assert(vk_base.device.d.getSwapchainImagesKHR(
            vk_base.device.h,
            swapchain_handle,
            &count,
            null,
        ) catch unreachable == .success);

        try result.resize(allocator, count);
        assert(vk_base.device.d.getSwapchainImagesKHR(
            vk_base.device.h,
            swapchain_handle,
            &count,
            result.items(.handle).ptr,
        ) catch unreachable == .success);

        break :populate_handles;
    }

    const slice = result.slice();
    for (slice.items(.handle)) |handle, i| {
        const create_info = vk.ImageViewCreateInfo{
            .flags = vk.ImageViewCreateFlags{},
            .image = handle,
            .view_type = .@"2d",
            .format = surface_format.format,
            .components = vk.ComponentMapping{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = vk.ImageSubresourceRange{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        slice.items(.view)[i] = vk_base.device.d.createImageView(
            vk_base.device.h,
            &create_info,
            vk_allocator,
        ) catch |err| {
            for (slice.items(.view)[0..i]) |created_view| {
                vk_base.device.d.destroyImageView(vk_base.device.h, created_view, vk_allocator);
            }
            return err;
        };
    }

    return result;
}

fn destroyImageViews(
    vk_base: VulkanBase,
    views: []const vk.ImageView,
    vk_allocator: ?*const vk.AllocationCallbacks,
) void {
    for (views) |view| {
        vk_base.device.d.destroyImageView(
            vk_base.device.h,
            view,
            vk_allocator,
        );
    }
}
