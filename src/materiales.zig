// materiales.zig
// Cada material tiene su propia textura y sus propios parámetros de
// albedo, especular, transparencia y reflectividad (lo que pide la rúbrica),
// más algunos extra: índice de refracción, emisión y translucidez.

const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const Textura = @import("texturas.zig").Textura;

pub const Material = struct {
    nombre: []const u8,
    /// Textura de los lados del cubo.
    textura: [:0]const u8,
    /// Textura de la cara de arriba (si es distinta, como el pasto).
    textura_arriba: ?[:0]const u8 = null,

    /// Qué fracción de la luz difusa devuelve la superficie (0..1).
    albedo: f32 = 0.9,
    /// Intensidad del brillo especular (Blinn-Phong).
    especular: f32 = 0.0,
    /// Exponente especular: más alto = brillo más pequeño y concentrado.
    brillo: f32 = 16.0,
    /// Qué fracción de la luz atraviesa el material (refracción).
    transparencia: f32 = 0.0,
    /// Qué fracción de la luz se refleja como espejo.
    reflectividad: f32 = 0.0,
    /// Índice de refracción (agua 1.33, vidrio 1.5, esmeralda 1.57).
    ior: f32 = 1.0,
    /// Materiales que brillan: emiten luz propia.
    emision: f32 = 0.0,
    /// Translucidez (dispersión subsuperficial tipo alabastro).
    translucidez: f32 = 0.0,
    /// Si es true, el material tiñe con su color lo que refleja/refracta.
    color_en_reflejo: bool = false,
    /// Absorción por unidad de distancia dentro del material (R, G, B).
    absorcion: Vec3 = Vec3.cero,
};

/// Identificadores de material usados en la grilla de voxeles.
pub const aire: u8 = 0;
pub const arena: u8 = 1;
pub const roca: u8 = 2;
pub const pasto: u8 = 3;
pub const tierra: u8 = 4;
pub const madera: u8 = 5;
pub const ladrillo_blanco: u8 = 6;
pub const ladrillo_rojo: u8 = 7;
pub const agua: u8 = 8;
pub const vidrio: u8 = 9;
pub const esmeralda: u8 = 10;
pub const alabastro: u8 = 11;
pub const cobre: u8 = 12;
pub const hierro: u8 = 13;
pub const bote_rojo: u8 = 14;
pub const pared: u8 = 15;
pub const ventana: u8 = 16;
pub const lampara: u8 = 17;

pub const lista = [_]Material{
    .{ .nombre = "aire", .textura = "" },
    .{
        .nombre = "arena",
        .textura = "assets/texturas/arena.png",
        .albedo = 0.85,
        .especular = 0.05,
        .brillo = 8,
    },
    .{
        .nombre = "roca",
        .textura = "assets/texturas/roca.png",
        .albedo = 0.8,
        .especular = 0.15,
        .brillo = 12,
    },
    .{
        .nombre = "pasto",
        .textura = "assets/texturas/pasto_lado.png",
        .textura_arriba = "assets/texturas/pasto.png",
        .albedo = 0.85,
        .especular = 0.02,
        .brillo = 4,
    },
    .{
        .nombre = "tierra",
        .textura = "assets/texturas/tierra.png",
        .albedo = 0.8,
    },
    .{
        .nombre = "madera",
        .textura = "assets/texturas/madera.png",
        .albedo = 0.85,
        .especular = 0.1,
        .brillo = 10,
    },
    .{
        .nombre = "ladrillo blanco",
        .textura = "assets/texturas/ladrillo_blanco.png",
        .albedo = 0.9,
        .especular = 0.1,
        .brillo = 16,
    },
    .{
        .nombre = "ladrillo rojo",
        .textura = "assets/texturas/ladrillo_rojo.png",
        .albedo = 0.9,
        .especular = 0.1,
        .brillo = 16,
    },
    .{
        // Agua: refracción + reflexión, absorbe un poco de rojo.
        .nombre = "agua",
        .textura = "assets/texturas/agua.png",
        .albedo = 0.6,
        .especular = 0.8,
        .brillo = 120,
        .transparencia = 0.75,
        .reflectividad = 0.12,
        .ior = 1.33,
        .absorcion = Vec3.new(0.35, 0.12, 0.06),
    },
    .{
        // Vidrio de la linterna del faro (cilindro).
        .nombre = "vidrio",
        .textura = "assets/texturas/vidrio.png",
        .albedo = 0.3,
        .especular = 1.0,
        .brillo = 200,
        .transparencia = 0.88,
        .reflectividad = 0.06,
        .ior = 1.5,
    },
    .{
        // Esmeralda: translúcida con color, tiñe de verde lo que refleja y refracta.
        .nombre = "esmeralda",
        .textura = "assets/texturas/esmeralda.png",
        .albedo = 0.4,
        .especular = 1.0,
        .brillo = 150,
        .transparencia = 0.7,
        .reflectividad = 0.2,
        .ior = 1.57,
        .color_en_reflejo = true,
        .absorcion = Vec3.new(0.9, 0.05, 0.6),
    },
    .{
        // Alabastro: material translúcido, deja pasar la luz difusa.
        .nombre = "alabastro",
        .textura = "assets/texturas/alabastro.png",
        .albedo = 0.9,
        .especular = 0.25,
        .brillo = 30,
        .translucidez = 0.85,
    },
    .{
        // Cobre del techo del faro: metal reflectivo con color.
        .nombre = "cobre",
        .textura = "assets/texturas/cobre.png",
        .albedo = 0.5,
        .especular = 0.9,
        .brillo = 60,
        .reflectividad = 0.5,
        .color_en_reflejo = true,
    },
    .{
        .nombre = "hierro",
        .textura = "assets/texturas/hierro.png",
        .albedo = 0.6,
        .especular = 0.6,
        .brillo = 40,
        .reflectividad = 0.2,
    },
    .{
        // Bote rojo: su luz rebotada tiñe la pared blanca (color bleeding).
        .nombre = "bote rojo",
        .textura = "assets/texturas/bote_rojo.png",
        .albedo = 0.95,
        .especular = 0.2,
        .brillo = 20,
    },
    .{
        .nombre = "pared",
        .textura = "assets/texturas/pared.png",
        .albedo = 0.95,
        .especular = 0.05,
        .brillo = 8,
    },
    .{
        // Ventanas iluminadas de la casa del farero.
        .nombre = "ventana",
        .textura = "assets/texturas/ventana.png",
        .emision = 2.2,
    },
    .{
        // Bombilla del faro.
        .nombre = "lampara",
        .textura = "assets/texturas/lampara.png",
        .emision = 8.0,
    },
};

pub const num_materiales = lista.len;

/// Texturas cargadas en memoria, una por material (lados y cara de arriba),
/// más el color con el que cada material tiñe las sombras que lo atraviesan.
pub const Biblioteca = struct {
    lados: [num_materiales]Textura,
    arriba: [num_materiales]Textura,
    tinte_sombra: [num_materiales]Vec3,

    pub fn cargar(alloc: std.mem.Allocator) !Biblioteca {
        var b: Biblioteca = undefined;
        for (lista, 0..) |m, i| {
            if (i == aire) {
                b.lados[i] = undefined;
                b.arriba[i] = undefined;
                b.tinte_sombra[i] = Vec3.uno;
                continue;
            }
            b.lados[i] = try Textura.cargar(alloc, m.textura);
            b.arriba[i] = if (m.textura_arriba) |t| try Textura.cargar(alloc, t) else b.lados[i];

            // Cuánta luz deja pasar hacia las sombras (y de qué color).
            if (m.transparencia > 0) {
                var tinte = Vec3.uno;
                if (m.color_en_reflejo) {
                    const p = b.lados[i].promedio;
                    tinte = p.scale(1.0 / @max(0.001, p.maxComp()));
                }
                b.tinte_sombra[i] = tinte.scale(m.transparencia);
            } else if (m.translucidez > 0) {
                const p = b.lados[i].promedio;
                b.tinte_sombra[i] = p.scale(m.translucidez / @max(0.001, p.maxComp()));
            } else {
                b.tinte_sombra[i] = Vec3.cero;
            }
        }
        return b;
    }
};
