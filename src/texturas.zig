// texturas.zig
// Carga de texturas PNG (con Raylib) y el skybox de 6 caras.
// Los colores se pasan a espacio lineal para que la iluminación sea correcta.

const std = @import("std");
const rl = @import("raylib");
const Vec3 = @import("vec.zig").Vec3;

/// Tabla para convertir de sRGB (como vienen los PNG) a valores lineales.
var tabla_lineal: [256]f32 = undefined;
var tabla_lista = false;

fn prepararTabla() void {
    if (tabla_lista) return;
    for (0..256) |i| {
        const c: f32 = @as(f32, @floatFromInt(i)) / 255.0;
        tabla_lineal[i] = std.math.pow(f32, c, 2.2);
    }
    tabla_lista = true;
}

pub const Textura = struct {
    ancho: usize,
    alto: usize,
    pixeles: []Vec3,
    promedio: Vec3,

    pub fn cargar(alloc: std.mem.Allocator, ruta: [:0]const u8) !Textura {
        prepararTabla();
        var img = rl.LoadImage(ruta.ptr);
        if (img.data == null) {
            std.debug.print(
                "No se pudo cargar '{s}'. Corré el programa desde la carpeta del proyecto (zig build run).\n",
                .{ruta},
            );
            return error.TexturaNoEncontrada;
        }
        defer rl.UnloadImage(img);
        rl.ImageFormat(&img, rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);

        const w: usize = @intCast(img.width);
        const h: usize = @intCast(img.height);
        const datos: [*]const u8 = @ptrCast(img.data.?);
        const pix = try alloc.alloc(Vec3, w * h);

        var suma = Vec3.cero;
        for (0..w * h) |i| {
            const c = Vec3.new(
                tabla_lineal[datos[i * 4 + 0]],
                tabla_lineal[datos[i * 4 + 1]],
                tabla_lineal[datos[i * 4 + 2]],
            );
            pix[i] = c;
            suma = suma.add(c);
        }
        const n: f32 = @floatFromInt(w * h);
        return .{ .ancho = w, .alto = h, .pixeles = pix, .promedio = suma.scale(1.0 / n) };
    }

    /// Muestreo con repetición (la textura se repite en cada cara del cubo)
    /// y filtro "nearest" para mantener el estilo pixelado de los bloques.
    pub fn muestrear(self: *const Textura, u: f32, v: f32) Vec3 {
        const fu = u - @floor(u);
        const fv = v - @floor(v);
        var x: usize = @intFromFloat(fu * @as(f32, @floatFromInt(self.ancho)));
        var y: usize = @intFromFloat(fv * @as(f32, @floatFromInt(self.alto)));
        if (x >= self.ancho) x = self.ancho - 1;
        if (y >= self.alto) y = self.alto - 1;
        return self.pixeles[y * self.ancho + x];
    }

    /// Muestreo bilineal sin repetición (para el skybox, que es más grande).
    pub fn muestrearSuave(self: *const Textura, u: f32, v: f32) Vec3 {
        const wf: f32 = @floatFromInt(self.ancho);
        const hf: f32 = @floatFromInt(self.alto);
        const px = @max(0.0, @min(wf - 1.001, u * wf - 0.5));
        const py = @max(0.0, @min(hf - 1.001, v * hf - 0.5));
        const x0: usize = @intFromFloat(px);
        const y0: usize = @intFromFloat(py);
        const tx = px - @as(f32, @floatFromInt(x0));
        const ty = py - @as(f32, @floatFromInt(y0));
        const a = self.pixeles[y0 * self.ancho + x0];
        const b = self.pixeles[y0 * self.ancho + x0 + 1];
        const c = self.pixeles[(y0 + 1) * self.ancho + x0];
        const d = self.pixeles[(y0 + 1) * self.ancho + x0 + 1];
        return a.lerp(b, tx).lerp(c.lerp(d, tx), ty);
    }
};

/// Skybox de 6 caras (cubemap). El orden es +X, -X, +Y, -Y, +Z, -Z.
pub const Skybox = struct {
    caras: [6]Textura,
    intensidad: f32 = 1.0,

    pub fn cargar(alloc: std.mem.Allocator) !Skybox {
        const nombres = [6][:0]const u8{
            "assets/skybox/derecha.png",
            "assets/skybox/izquierda.png",
            "assets/skybox/arriba.png",
            "assets/skybox/abajo.png",
            "assets/skybox/frente.png",
            "assets/skybox/atras.png",
        };
        var sky: Skybox = .{ .caras = undefined };
        for (nombres, 0..) |nombre, i| {
            sky.caras[i] = try Textura.cargar(alloc, nombre);
        }
        return sky;
    }

    /// Devuelve el color del cielo en la dirección d (en coordenadas del mundo).
    pub fn muestrear(self: *const Skybox, d: Vec3) Vec3 {
        const ax = @abs(d.x);
        const ay = @abs(d.y);
        const az = @abs(d.z);
        var cara: usize = 0;
        var u: f32 = 0;
        var v: f32 = 0;
        if (ax >= ay and ax >= az) {
            if (d.x > 0) {
                cara = 0;
                u = -d.z / ax;
            } else {
                cara = 1;
                u = d.z / ax;
            }
            v = -d.y / ax;
        } else if (ay >= az) {
            if (d.y > 0) {
                cara = 2;
                u = d.x / ay;
                v = d.z / ay;
            } else {
                cara = 3;
                u = d.x / ay;
                v = -d.z / ay;
            }
        } else {
            if (d.z > 0) {
                cara = 4;
                u = d.x / az;
            } else {
                cara = 5;
                u = -d.x / az;
            }
            v = -d.y / az;
        }
        const c = self.caras[cara].muestrearSuave((u + 1.0) * 0.5, (v + 1.0) * 0.5);
        return c.scale(self.intensidad);
    }
};
