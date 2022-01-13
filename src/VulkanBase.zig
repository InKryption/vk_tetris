const std = @import("std");
const log = std.log;
const mem = std.mem;
const heap = std.heap;
const debug = std.debug;

const assert = debug.assert;

const vk = @import("vulkan");
const glfw = @import("mach-glfw");

const VulkanBase = @This();
instance: Instance,
physical_device: vk.PhysicalDevice,
surface: vk.SurfaceKHR,
qfi: QueueFamilyIndices,
device: Device,

pub fn init(
    child_allocator: mem.Allocator,
    vk_allocator: ?*const vk.AllocationCallbacks,
    window: glfw.Window,
) !VulkanBase {
    var arena_state = heap.ArenaAllocator.init(child_allocator);
    defer arena_state.deinit();

    const allocator = arena_state.allocator();

    const instance: Instance = try createInstance(allocator, struct {
        fn loader(instance: vk.Instance, proc_name: [*:0]const u8) ?glfw.VKProc {
            return glfw.getInstanceProcAddress(@intToPtr(?*anyopaque, @enumToInt(instance)), proc_name);
        }
    }.loader, vk_allocator);
    errdefer instance.d.destroyInstance(instance.h, vk_allocator);

    const physical_device: vk.PhysicalDevice = try selectPhysicalDevice(allocator, instance);

    const surface: vk.SurfaceKHR = surface: {
        var surface: vk.SurfaceKHR = undefined;
        assert(@intToEnum(vk.Result, try glfw.createWindowSurface(instance.h, window, vk_allocator, &surface)) == .success);
        break :surface surface;
    };
    errdefer instance.d.destroySurfaceKHR(instance.h, surface, vk_allocator);

    const qfi: QueueFamilyIndices = try selectQueueFamilies(allocator, instance.d, physical_device, surface);

    const device: Device = try createDevice(
        allocator,
        instance.d,
        physical_device,
        instance.d.dispatch.vkGetDeviceProcAddr,
        qfi,
        vk_allocator,
    );
    errdefer device.d.destroyDevice(device.h, vk_allocator);

    return VulkanBase{
        .instance = instance,
        .physical_device = physical_device,
        .surface = surface,
        .qfi = qfi,
        .device = device,
    };
}

pub fn deinit(
    self: VulkanBase,
    vk_allocator: ?*const vk.AllocationCallbacks,
) void {
    defer self.instance.d.destroyInstance(self.instance.h, vk_allocator);
    defer self.instance.d.destroySurfaceKHR(self.instance.h, self.surface, vk_allocator);
    defer self.device.d.destroyDevice(self.device.h, vk_allocator);
}

pub const QueueFamilyIndices = std.enums.EnumArray(QueueFamilyIndexName, u32);
pub const QueueFamilyIndexName = enum {
    graphics,
    present,
};

pub const Instance = struct {
    h: vk.Instance,
    d: VTable,

    pub const VTable = vk.InstanceWrapper(vk.InstanceCommandFlags{
        .destroyInstance = true,
        .getDeviceProcAddr = true,

        .enumeratePhysicalDevices = true,
        .getPhysicalDeviceQueueFamilyProperties = true,
        .getPhysicalDeviceSurfaceSupportKHR = true,

        .createDevice = true,
        .destroySurfaceKHR = true,
    });
};

pub const Device = struct {
    h: vk.Device,
    d: VTable,

    pub const VTable = vk.DeviceWrapper(.{
        .destroyDevice = true,
    });
};

fn createInstance(
    allocator: mem.Allocator,
    loader: anytype,
    vk_allocator: ?*const vk.AllocationCallbacks,
) !Instance {
    var arena_state = heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const arena_allocator = arena_state.allocator();

    const BaseDispatch = vk.BaseWrapper(vk.BaseCommandFlags{
        .createInstance = true,
        .enumerateInstanceLayerProperties = true,
        .enumerateInstanceExtensionProperties = true,
    });
    const base_dispatch = try BaseDispatch.load(loader);

    const enabled_extensions: []const [*:0]const u8 = enabled_extensions: {
        var enabled_extensions = std.ArrayList([*:0]const u8).init(arena_allocator);
        errdefer enabled_extensions.deinit();

        const desired_extensions: []const [*:0]const u8 = desired_extensions: {
            var desired_extensions = std.ArrayList([*:0]const u8).init(arena_allocator);
            errdefer desired_extensions.deinit();

            try desired_extensions.appendSlice(try glfw.getRequiredInstanceExtensions());

            break :desired_extensions desired_extensions.toOwnedSlice();
        };
        defer arena_allocator.free(desired_extensions);

        const available_extensions: []const vk.ExtensionProperties = available_extensions: {
            var count: u32 = undefined;
            assert(base_dispatch.enumerateInstanceExtensionProperties(null, &count, null) catch unreachable == .success);

            const slice = try arena_allocator.alloc(vk.ExtensionProperties, count);
            errdefer arena_allocator.free(slice);

            assert(base_dispatch.enumerateInstanceExtensionProperties(null, &count, slice.ptr) catch unreachable == .success);
            assert(count == slice.len);

            break :available_extensions slice;
        };
        defer arena_allocator.free(available_extensions);

        try enabled_extensions.ensureTotalCapacityPrecise(available_extensions.len);
        outer: for (desired_extensions) |desired_ptr| {
            const desired = mem.span(desired_ptr);
            for (available_extensions) |available| {
                if (desired.len > available.extension_name.len) {
                    const err_msg = "Desired Instance Extension name '{s}' is longer than the maximum layer name length '{}'";
                    log.err(err_msg, .{ desired, available.extension_name.len });
                    return error.NameOverlong;
                }
                if (mem.eql(u8, desired, available.extension_name[0..desired.len])) {
                    enabled_extensions.appendAssumeCapacity(desired);
                    continue :outer;
                }
            } else {
                log.err("Instance Extension with name '{s}' could not be found.", .{desired});
                return error.LayerUnavailable;
            }
        }

        break :enabled_extensions enabled_extensions.toOwnedSlice();
    };
    defer arena_allocator.free(enabled_extensions);

    const enabled_layers: []const [*:0]const u8 = enabled_layers: {
        // If not in debug, return no layers
        if (@import("builtin").mode != .Debug) break :enabled_layers &.{};

        var enabled_layers = std.ArrayList([*:0]const u8).init(arena_allocator);
        errdefer enabled_layers.deinit();

        const desired_layers: []const [*:0]const u8 = desired_layers: {
            var desired_layers = std.ArrayList([*:0]const u8).init(arena_allocator);
            errdefer desired_layers.deinit();

            try desired_layers.append("VK_LAYER_KHRONOS_validation");

            break :desired_layers desired_layers.toOwnedSlice();
        };
        defer arena_allocator.free(desired_layers);

        const available_layers: []const vk.LayerProperties = available_layers: {
            var count: u32 = undefined;
            assert(base_dispatch.enumerateInstanceLayerProperties(&count, null) catch unreachable == .success);

            const slice = try arena_allocator.alloc(vk.LayerProperties, count);
            errdefer arena_allocator.free(slice);

            assert(base_dispatch.enumerateInstanceLayerProperties(&count, slice.ptr) catch unreachable == .success);
            assert(count == slice.len);

            break :available_layers slice;
        };
        defer arena_allocator.free(available_layers);

        try enabled_layers.ensureTotalCapacityPrecise(available_layers.len);
        outer: for (desired_layers) |desired_ptr| {
            const desired = mem.span(desired_ptr);
            for (available_layers) |available| {
                if (desired.len > available.layer_name.len) {
                    const err_msg = "Desired Instance Layer name '{s}' is longer than the maximum layer name length '{}'";
                    log.err(err_msg, .{ desired, available.layer_name.len });
                    return error.NameOverlong;
                }
                if (mem.eql(u8, desired, available.layer_name[0..desired.len])) {
                    enabled_layers.appendAssumeCapacity(desired);
                    continue :outer;
                }
            } else {
                log.err("Instance Layer with name '{s}' could not be found.", .{desired});
                return error.LayerUnavailable;
            }
        }

        // for (available_layers) |al| {
        //     debug.print("{s}\n", .{al.layer_name[0..]});
        // }

        break :enabled_layers enabled_layers.toOwnedSlice();
    };
    defer arena_allocator.free(enabled_layers);

    const handle: vk.Instance = try base_dispatch.createInstance(&vk.InstanceCreateInfo{
        .flags = vk.InstanceCreateFlags{},
        .p_application_info = &vk.ApplicationInfo{
            .p_application_name = "vk_tetris",
            .application_version = vk.makeApiVersion(0, 0, 0, 0),
            .p_engine_name = null,
            .engine_version = vk.makeApiVersion(0, 0, 0, 0),
            .api_version = vk.API_VERSION_1_2,
        },

        .enabled_layer_count = @intCast(u32, enabled_layers.len),
        .pp_enabled_layer_names = enabled_layers.ptr,

        .enabled_extension_count = @intCast(u32, enabled_extensions.len),
        .pp_enabled_extension_names = enabled_extensions.ptr,
    }, vk_allocator);

    const vtable: Instance.VTable = Instance.VTable.load(handle, loader) catch |err| {
        const MinVTable = vk.InstanceWrapper(.{ .destroyInstance = true });
        if (MinVTable.load(handle, loader)) |min| {
            min.destroyInstance(handle, vk_allocator);
        } else |_| {
            log.err("Failed to load function to destroy instance before encountering error '{s}'.", .{@errorName(err)});
        }
        return err;
    };

    return Instance{
        .h = handle,
        .d = vtable,
    };
}

fn createDevice(
    allocator: mem.Allocator,
    idispatch: Instance.VTable,
    physical_device: vk.PhysicalDevice,
    loader: anytype,
    qfi: QueueFamilyIndices,
    vk_allocator: ?*const vk.AllocationCallbacks,
) !Device {
    const enabled_extensions: []const [*:0]const u8 = enabled_extensions: {
        var enabled_extensions = std.ArrayList([*:0]const u8).init(allocator);

        try enabled_extensions.append(vk.extension_info.khr_swapchain.name.ptr);

        break :enabled_extensions enabled_extensions.toOwnedSlice();
    };
    defer allocator.free(enabled_extensions);

    const queue_create_infos: []const vk.DeviceQueueCreateInfo = queue_create_infos: {
        var queue_create_infos = std.ArrayList(vk.DeviceQueueCreateInfo).init(allocator);
        errdefer queue_create_infos.deinit();

        const queue_priorities_per_family: []const f32 = &.{1.0};

        try queue_create_infos.append(vk.DeviceQueueCreateInfo{
            .flags = vk.DeviceQueueCreateFlags{},
            .queue_family_index = qfi.get(.graphics),

            .queue_count = @intCast(u32, queue_priorities_per_family.len),
            .p_queue_priorities = queue_priorities_per_family.ptr,
        });
        if (qfi.get(.present) != qfi.get(.graphics)) {
            try queue_create_infos.append(vk.DeviceQueueCreateInfo{
                .flags = vk.DeviceQueueCreateFlags{},
                .queue_family_index = qfi.get(.present),

                .queue_count = @intCast(u32, queue_priorities_per_family.len),
                .p_queue_priorities = queue_priorities_per_family.ptr,
            });
        }

        break :queue_create_infos queue_create_infos.toOwnedSlice();
    };
    defer allocator.free(queue_create_infos);

    const handle = try idispatch.createDevice(physical_device, &vk.DeviceCreateInfo{
        .flags = vk.DeviceCreateFlags{},

        .queue_create_info_count = @intCast(u32, queue_create_infos.len),
        .p_queue_create_infos = queue_create_infos.ptr,

        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,

        .enabled_extension_count = @intCast(u32, enabled_extensions.len),
        .pp_enabled_extension_names = enabled_extensions.ptr,

        .p_enabled_features = @as(?*const vk.PhysicalDeviceFeatures, null),
    }, vk_allocator);

    const vtable: Device.VTable = Device.VTable.load(handle, loader) catch |err| {
        const MinVTable = vk.DeviceWrapper(.{ .destroyDevice = true });
        if (MinVTable.load(handle, loader)) |min| {
            min.destroyDevice(handle, vk_allocator);
        } else |_| {
            log.err("Failed to load function to destroy device before encountering error '{s}'.", .{@errorName(err)});
        }
        return err;
    };

    return Device{
        .h = handle,
        .d = vtable,
    };
}

fn selectPhysicalDevice(
    allocator: mem.Allocator,
    instance: Instance,
) !vk.PhysicalDevice {
    const all_physical_devices: []const vk.PhysicalDevice = all_physical_devices: {
        var count: u32 = undefined;
        assert(instance.d.enumeratePhysicalDevices(instance.h, &count, null) catch unreachable == .success);

        const slice = try allocator.alloc(vk.PhysicalDevice, count);
        errdefer allocator.free(allocator);

        assert(instance.d.enumeratePhysicalDevices(instance.h, &count, slice.ptr) catch unreachable == .success);
        assert(count == slice.len);

        break :all_physical_devices slice;
    };
    defer allocator.free(all_physical_devices);

    return switch (all_physical_devices.len) {
        0 => error.NoPhysicalDevices,
        1 => all_physical_devices[0],
        else => blk: {
            log.warn("No mechanism for selecting between physical devices, selecting first one available.", .{});
            break :blk all_physical_devices[0];
        },
    };
}

fn selectQueueFamilies(
    allocator: mem.Allocator,
    idispatch: Instance.VTable,
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !QueueFamilyIndices {
    const all_qfamily_properties: []const vk.QueueFamilyProperties = all_qfamily_properties: {
        var count: u32 = undefined;
        idispatch.getPhysicalDeviceQueueFamilyProperties(physical_device, &count, null);

        const slice = try allocator.alloc(vk.QueueFamilyProperties, count);
        errdefer allocator.free(slice);

        idispatch.getPhysicalDeviceQueueFamilyProperties(physical_device, &count, slice.ptr);
        assert(count == slice.len);

        break :all_qfamily_properties slice;
    };
    defer allocator.free(all_qfamily_properties);

    var selected_indices = std.enums.EnumArray(QueueFamilyIndexName, ?u32).initFill(null);
    for (all_qfamily_properties) |qfamily_properties, i| {
        const index = @intCast(u32, i);

        const present_support: bool = (try idispatch.getPhysicalDeviceSurfaceSupportKHR(physical_device, index, surface)) == vk.TRUE;
        const graphics_support: bool = qfamily_properties.queue_flags.graphics_bit;

        if (graphics_support and present_support) {
            selected_indices.set(.graphics, index);
            selected_indices.set(.present, index);
        }

        if (selected_indices.get(.graphics) == null and graphics_support) {
            selected_indices.set(.graphics, index);
        }

        if (selected_indices.get(.present) == null and present_support) {
            selected_indices.set(.present, index);
        }
    }

    var result = QueueFamilyIndices.initUndefined();
    inline for (comptime std.enums.values(QueueFamilyIndexName)) |queue_name| {
        const selected_index = selected_indices.get(queue_name) orelse {
            log.err("Failed to find queue family index matching requirements for '{s}'.", .{@tagName(queue_name)});
            return error.NoQualifiedQueueFamilies;
        };
        result.set(queue_name, selected_index);
    }

    return result;
}
