const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Por defecto compilamos en ReleaseFast: un raytracer en modo Debug es
    // muchísimo más lento (se puede cambiar con -Doptimize=Debug).
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Modo de optimización") orelse .ReleaseFast;

    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "diorama_faro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "raylib", .module = raylib_dep.module("raylib") },
            },
        }),
    });
    exe.root_module.linkLibrary(raylib_dep.artifact("raylib"));
    // Usamos el enlazador propio de Zig: en modo Release, LLD da un error falso
    // con las librerías del sistema (GL, X11) que Raylib incluye en Linux/WSL.
    exe.use_lld = false;

    b.installArtifact(exe);

    const run_step = b.step("run", "Ejecutar el diorama");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
