//! Render pipeline abstraction, mirroring `opengl/Pipeline.zig`.
//!
//! Consumes precompiled SPIR-V (shaders/vulkan/compiled/*.spv, built
//! with glslc targeting vulkan1.2). The actual VkPipeline objects are
//! created lazily per attachment format (the offscreen target is BGRA,
//! custom-shader intermediate textures are RGBA, both with sRGB
//! variants depending on the blending mode) and cached on the shared
//! Device keyed by SPIR-V pointer identity + format. This sidesteps
//! the fact that generic.zig copies Pipeline structs by value.
const Self = @This();

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;

const log = std.log.scoped(.vulkan);

/// Options for initializing a render pipeline.
pub const Options = struct {
    /// SPIR-V binary of the vertex stage.
    vertex_spv: []const u8,
    /// SPIR-V binary of the fragment stage.
    fragment_spv: []const u8,

    /// Vertex step function
    step_fn: StepFunction = .per_vertex,

    /// Whether to enable blending.
    blending_enabled: bool = true,

    pub const StepFunction = enum {
        constant,
        per_vertex,
        per_instance,
    };
};

pub const Error = error{
    InvalidSpirv,
} || vk.Error;

/// SPIR-V modules (comptime-embedded; pointer identity keys the
/// device pipeline cache).
vertex_spv: []const u8,
fragment_spv: []const u8,

/// Vertex input layout derived from the vertex attributes struct.
vertex_attrs: []const vk.VertexAttr,
stride: usize,
step_fn: Options.StepFunction,
blending_enabled: bool,

pub fn init(comptime VertexAttributes: ?type, opts: Options) Error!Self {
    try validateSpirv(opts.vertex_spv);
    try validateSpirv(opts.fragment_spv);

    return .{
        .vertex_spv = opts.vertex_spv,
        .fragment_spv = opts.fragment_spv,
        .vertex_attrs = if (VertexAttributes) |VA|
            vk.vertexAttrs(VA)
        else
            &.{},
        .stride = if (VertexAttributes) |VA| @sizeOf(VA) else 0,
        .step_fn = opts.step_fn,
        .blending_enabled = opts.blending_enabled,
    };
}

pub fn deinit(self: *const Self) void {
    // VkPipelines live in the device cache and are destroyed with it.
    // Shader reinitialization reuses the same embedded SPIR-V blobs,
    // so cached pipelines remain valid across reinits.
    _ = self;
}

/// Get (or create) the VkPipeline for this pipeline rendering into an
/// attachment of the given format.
pub fn vkPipeline(self: *const Self, format: vk.AttachmentFormat) vk.Error!c.VkPipeline {
    const d = vk.dev();
    const key: vk.Device.PipelineKey = .{
        .vert = @intFromPtr(self.vertex_spv.ptr),
        .frag = @intFromPtr(self.fragment_spv.ptr),
        .format = format,
    };

    d.mutex.lock();
    defer d.mutex.unlock();
    if (d.pipelines.get(key)) |p| return p;

    const pipeline = try self.createVkPipeline(format);
    d.pipelines.put(d.alloc, key, pipeline) catch return error.OutOfMemory;
    return pipeline;
}

fn createShaderModule(spv: []const u8) vk.Error!c.VkShaderModule {
    const d = vk.dev();
    const smci = std.mem.zeroInit(c.VkShaderModuleCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = spv.len,
        .pCode = @as([*]const u32, @ptrCast(@alignCast(spv.ptr))),
    });
    var module: c.VkShaderModule = null;
    try vk.check(d.vk.vkCreateShaderModule(d.device, &smci, null, &module));
    return module;
}

fn createVkPipeline(self: *const Self, format: vk.AttachmentFormat) vk.Error!c.VkPipeline {
    const d = vk.dev();

    const vert_module = try createShaderModule(self.vertex_spv);
    defer d.vk.vkDestroyShaderModule(d.device, vert_module, null);
    const frag_module = try createShaderModule(self.fragment_spv);
    defer d.vk.vkDestroyShaderModule(d.device, frag_module, null);

    const stages = [_]c.VkPipelineShaderStageCreateInfo{
        std.mem.zeroInit(c.VkPipelineShaderStageCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vert_module,
            .pName = "main",
        }),
        std.mem.zeroInit(c.VkPipelineShaderStageCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = frag_module,
            .pName = "main",
        }),
    };

    // Vertex input: one binding (index 0) with the derived attributes.
    var attr_descs: [16]c.VkVertexInputAttributeDescription = undefined;
    for (self.vertex_attrs, 0..) |attr, i| {
        attr_descs[i] = .{
            .location = attr.location,
            .binding = 0,
            .format = attr.format,
            .offset = attr.offset,
        };
    }
    const binding_desc = c.VkVertexInputBindingDescription{
        .binding = 0,
        .stride = @intCast(self.stride),
        .inputRate = switch (self.step_fn) {
            .per_vertex => c.VK_VERTEX_INPUT_RATE_VERTEX,
            .per_instance, .constant => c.VK_VERTEX_INPUT_RATE_INSTANCE,
        },
    };
    const has_vertex_input = self.vertex_attrs.len > 0;
    const vis = std.mem.zeroInit(c.VkPipelineVertexInputStateCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = @as(u32, if (has_vertex_input) 1 else 0),
        // Pointers are ignored by the spec when the counts are 0.
        .pVertexBindingDescriptions = @as(
            [*c]const c.VkVertexInputBindingDescription,
            @ptrCast(&binding_desc),
        ),
        .vertexAttributeDescriptionCount = @as(u32, @intCast(self.vertex_attrs.len)),
        .pVertexAttributeDescriptions = @as(
            [*c]const c.VkVertexInputAttributeDescription,
            @ptrCast(&attr_descs),
        ),
    });

    // Topology is dynamic-ish in the generic renderer (each step has a
    // primitive type), but in practice each pipeline is only ever used
    // with one topology: fullscreen passes draw triangles, instanced
    // pipelines draw triangle strips. We bake the topology by whether
    // the pipeline has vertex input, matching generic.zig's usage.
    const topology: c.VkPrimitiveTopology = if (has_vertex_input)
        c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
    else
        c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    const ias = std.mem.zeroInit(c.VkPipelineInputAssemblyStateCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = topology,
    });

    const vps = std.mem.zeroInit(c.VkPipelineViewportStateCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    });

    const rs = std.mem.zeroInit(c.VkPipelineRasterizationStateCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .cullMode = c.VK_CULL_MODE_NONE,
        .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1.0,
    });

    const ms = std.mem.zeroInit(c.VkPipelineMultisampleStateCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
    });

    // Premultiplied alpha: ONE, ONE_MINUS_SRC_ALPHA (both color+alpha).
    const blend_attachment = std.mem.zeroInit(c.VkPipelineColorBlendAttachmentState, .{
        .blendEnable = if (self.blending_enabled) c.VK_TRUE else c.VK_FALSE,
        .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = c.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .alphaBlendOp = c.VK_BLEND_OP_ADD,
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT |
            c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
    });
    const cbs = std.mem.zeroInit(c.VkPipelineColorBlendStateCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
    });

    const dynamic_states = [_]c.VkDynamicState{
        c.VK_DYNAMIC_STATE_VIEWPORT,
        c.VK_DYNAMIC_STATE_SCISSOR,
    };
    const dys = std.mem.zeroInit(c.VkPipelineDynamicStateCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = @as(u32, dynamic_states.len),
        .pDynamicStates = &dynamic_states,
    });

    // Note: caller holds the device mutex; renderPassFor would
    // deadlock, so build the render pass inline here via the cache
    // accessor that assumes the lock. We rely on renderPassFor being
    // called only from vkPipeline (locked) and RenderPass (locked
    // separately) — to keep it simple renderPassFor takes the lock, so
    // release it around this call is not possible here. Instead we
    // access the cache directly.
    const rp = try renderPassLocked(d, format);

    const gpci = std.mem.zeroInit(c.VkGraphicsPipelineCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = @as(u32, stages.len),
        .pStages = &stages,
        .pVertexInputState = &vis,
        .pInputAssemblyState = &ias,
        .pViewportState = &vps,
        .pRasterizationState = &rs,
        .pMultisampleState = &ms,
        .pColorBlendState = &cbs,
        .pDynamicState = &dys,
        .layout = d.pipeline_layout,
        .renderPass = rp,
        .subpass = 0,
    });
    var pipeline: c.VkPipeline = null;
    try vk.check(d.vk.vkCreateGraphicsPipelines(
        d.device,
        null,
        1,
        &gpci,
        null,
        &pipeline,
    ));
    return pipeline;
}

/// renderPassFor without taking the device mutex (caller holds it).
/// Duplicated from Device.renderPassFor to avoid recursive locking.
fn renderPassLocked(d: *vk.Device, format: vk.AttachmentFormat) vk.Error!c.VkRenderPass {
    const fi: usize = @intFromEnum(format);
    if (d.render_passes[fi][1]) |rp| return rp;

    const attachment = std.mem.zeroInit(c.VkAttachmentDescription, .{
        .format = format.toVk(),
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    });
    const color_ref = c.VkAttachmentReference{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    const subpass = std.mem.zeroInit(c.VkSubpassDescription, .{
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_ref,
    });
    const rpci = std.mem.zeroInit(c.VkRenderPassCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
    });
    var rp: c.VkRenderPass = null;
    try vk.check(d.vk.vkCreateRenderPass(d.device, &rpci, null, &rp));
    d.render_passes[fi][1] = rp;
    return rp;
}

/// Validate that the provided bytes look like a SPIR-V module:
/// 4-byte aligned length and the SPIR-V magic number 0x07230203.
fn validateSpirv(bytes: []const u8) Error!void {
    if (bytes.len < 20 or bytes.len % 4 != 0) return error.InvalidSpirv;
    const magic = std.mem.readInt(u32, bytes[0..4], .little);
    if (magic != 0x0723_0203) return error.InvalidSpirv;
}

test "spirv validation rejects garbage" {
    try std.testing.expectError(
        error.InvalidSpirv,
        validateSpirv("not spirv at all!"),
    );
}
