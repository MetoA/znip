const std = @import("std");
const c = @cImport({
    @cInclude("blend2d/blend2d.h");
});

pub fn generateImage() void {
    var img: c.BLImageCore = undefined;
    _ = c.bl_image_init_as(&img, 800, 400, c.BL_FORMAT_PRGB32);
    defer _ = c.bl_image_reset(&img);

    var ctx: c.BLContextCore = undefined;
    _ = c.bl_context_init_as(&ctx, &img, null);
    defer _ = c.bl_context_reset(&ctx);

    fillBackground(&ctx, 0xFF37A3FF);
    drawCodeWindow(&ctx, 0xFF44475A);

    var codec: c.BLImageCodecCore = undefined;
    _ = c.bl_image_codec_init(&codec);
    _ = c.bl_image_codec_find_by_name(&codec, "PNG", @intCast("PNG".len), null);
    _ = c.bl_image_write_to_file(&img, "output.png", &codec);
    defer _ = c.bl_image_codec_reset(&codec);

    std.log.debug("Image generated", .{});
}

fn fillBackground(ctx: *c.BLContextCore, color: u32) void {
    _ = c.bl_context_set_fill_style_rgba32(ctx, color);
    _ = c.bl_context_fill_all(ctx);
}

fn drawCodeWindow(ctx: *c.BLContextCore, color: u32) void {
    const rect = c.BLRoundRect{ .x = 50, .y = 50, .w = 700, .h = 300, .rx = 12, .ry = 12 };
    _ = c.bl_context_set_fill_style_rgba32(ctx, color);
    _ = c.bl_context_fill_geometry(ctx, c.BL_GEOMETRY_TYPE_ROUND_RECT, &rect);

    drawCodeWindowControls(ctx);
}

fn drawCodeWindowControls(ctx: *c.BLContextCore) void {
    const colors = [_]u32{ 0xFFFF5F56, 0xFFFFBD2E, 0xFF27C93F };
    for (colors, 0..) |color, index| {
        const circle = c.BLCircle{ .cx = @as(f64, @floatFromInt(75 + (index * 20))), .cy = @as(f64, @floatFromInt(75)), .r = @as(f64, @floatFromInt(6)) };
        _ = c.bl_context_set_fill_style_rgba32(ctx, color);
        _ = c.bl_context_fill_geometry(ctx, c.BL_GEOMETRY_TYPE_CIRCLE, &circle);
    }
}
