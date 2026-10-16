// escena.zig
// El diorama: una grilla de cubos (voxeles) con material, más algunas formas
// analíticas (cilindro, cono, esfera) y las luces.
// Los rayos recorren la grilla con el algoritmo DDA (Amanatides & Woo),
// que salta de cubo en cubo sin revisar los cubos vacíos uno por uno.

const std = @import("std");
const vec = @import("vec.zig");
const Vec3 = vec.Vec3;
const mat = @import("materiales.zig");
const formas = @import("formas.zig");
const Objeto = formas.Objeto;

pub const ANCHO: i32 = 32; // X
pub const ALTO: i32 = 24; // Y
pub const PROF: i32 = 32; // Z
/// Posición de la esquina (0,0,0) de la grilla en el espacio local del diorama.
pub const ORIGEN = Vec3.new(-16, 0, -16);

pub const EPS: f32 = 0.002;

pub const TipoLuz = enum { direccional, puntual, reflector };

pub const Luz = struct {
    tipo: TipoLuz,
    /// Color e intensidad de la luz.
    color: Vec3,
    /// Para la puntual y el reflector.
    posicion: Vec3 = Vec3.cero,
    /// Direccional: hacia dónde está la luz. Reflector: hacia dónde apunta.
    direccion: Vec3 = Vec3.new(0, 1, 0),
    /// Reflector: ángulos del cono (cosenos).
    cos_interno: f32 = 0.98,
    cos_externo: f32 = 0.96,
    /// Qué tan rápido se apaga con la distancia.
    atenuacion: f32 = 0.0,
};

pub const Golpe = struct {
    t: f32,
    punto: Vec3,
    /// Normal siempre apuntando hacia el lado de donde viene el rayo.
    normal: Vec3,
    material: u8,
    u: f32,
    v: f32,
    cara_arriba: bool,
    /// true si el rayo está saliendo del material (de agua a aire, etc.).
    saliendo: bool,
    es_objeto: bool,
};

pub const MAX_OBJETOS = 8;

pub const Escena = struct {
    voxeles: [@as(usize, @intCast(ANCHO * ALTO * PROF))]u8,
    objetos: [MAX_OBJETOS]Objeto,
    num_objetos: usize,

    // Puntos importantes del diorama (en espacio local)
    pos_lampara: Vec3,
    pos_farol: Vec3,

    pub fn voxel(self: *const Escena, x: i32, y: i32, z: i32) u8 {
        if (x < 0 or y < 0 or z < 0 or x >= ANCHO or y >= ALTO or z >= PROF) return mat.aire;
        return self.voxeles[@intCast((y * PROF + z) * ANCHO + x)];
    }

    fn poner(self: *Escena, x: i32, y: i32, z: i32, m: u8) void {
        if (x < 0 or y < 0 or z < 0 or x >= ANCHO or y >= ALTO or z >= PROF) return;
        self.voxeles[@intCast((y * PROF + z) * ANCHO + x)] = m;
    }

    fn agregarObjeto(self: *Escena, o: Objeto) void {
        self.objetos[self.num_objetos] = o;
        self.num_objetos += 1;
    }

    // ------------------------------------------------------------------
    // Construcción del diorama: isla con faro, casa del farero, muelle
    // ------------------------------------------------------------------
    pub fn construir(self: *Escena) void {
        @memset(&self.voxeles, mat.aire);
        self.num_objetos = 0;

        const NIVEL_AGUA: i32 = 4; // el agua llena y < 4
        const cx: f32 = 16.0;
        const cz: f32 = 17.0;

        var x: i32 = 0;
        while (x < ANCHO) : (x += 1) {
            var z: i32 = 0;
            while (z < PROF) : (z += 1) {
                const fx: f32 = @floatFromInt(x);
                const fz: f32 = @floatFromInt(z);
                // distancia al centro de la isla, con ondulaciones para que no sea un círculo perfecto
                const d = @sqrt((fx - cx) * (fx - cx) + (fz - cz) * (fz - cz)) +
                    1.1 * @sin(fx * 0.7) + 0.9 * @cos(fz * 0.9);

                var h: i32 = 2; // fondo del mar
                if (d < 8.5) h = 7 else if (d < 10.0) h = 6 else if (d < 11.5) h = 5 else if (d < 13.0) h = 4;

                // terreno plano donde va la casa y el bote
                if (x >= 7 and x <= 15 and z >= 11 and z <= 23) h = 7;

                // base de roca y fondo de arena
                self.poner(x, 0, z, mat.roca);
                var y: i32 = 1;
                while (y < h) : (y += 1) {
                    var m: u8 = mat.roca;
                    const arriba = (y == h - 1);
                    if (h >= 6) {
                        if (arriba) m = mat.pasto else if (y >= h - 3) m = mat.tierra;
                    } else {
                        if (y >= h - 2) m = mat.arena;
                    }
                    // acantilado de roca en el lado norte de la isla
                    if (z < 10 and h >= 5) m = mat.roca;
                    self.poner(x, y, z, m);
                }
                // agua
                while (y < NIVEL_AGUA) : (y += 1) self.poner(x, y, z, mat.agua);
            }
        }

        // Rocas sueltas en el mar
        self.columna(3, 6, 2, 6, mat.roca);
        self.columna(4, 6, 2, 4, mat.roca);
        self.columna(3, 7, 2, 4, mat.roca);
        self.columna(28, 5, 2, 7, mat.roca);
        self.columna(27, 5, 2, 5, mat.roca);
        self.columna(28, 26, 2, 5, mat.roca);

        // ---------------- Faro ----------------
        const fx: f32 = 21.5;
        const fz: f32 = 13.5;
        const base_faro: i32 = 7;
        const tope_faro: i32 = 18;
        {
            // torre con franjas blancas y rojas cada 2 bloques
            var y: i32 = base_faro;
            while (y < tope_faro) : (y += 1) {
                const banda: u8 = if (@mod(@divFloor(y - base_faro, 2), 2) == 0) mat.ladrillo_blanco else mat.ladrillo_rojo;
                self.disco(fx, fz, 2.6, y, banda);
            }
        }
        // puerta de madera y ventanitas iluminadas
        self.poner(21, 7, 15, mat.madera);
        self.poner(21, 8, 15, mat.madera);
        self.poner(23, 12, 13, mat.ventana);
        self.poner(20, 15, 15, mat.ventana);
        // plataforma de hierro y barandal
        self.disco(fx, fz, 3.6, tope_faro, mat.hierro);
        {
            var bx: i32 = 17;
            while (bx <= 26) : (bx += 1) {
                var bz: i32 = 9;
                while (bz <= 18) : (bz += 1) {
                    const dx = @as(f32, @floatFromInt(bx)) + 0.5 - fx;
                    const dz = @as(f32, @floatFromInt(bz)) + 0.5 - fz;
                    const r = @sqrt(dx * dx + dz * dz);
                    if (r > 3.0 and r <= 3.6 and @mod(bx + bz, 2) == 0)
                        self.poner(bx, tope_faro + 1, bz, mat.hierro);
                }
            }
        }

        // Objetos analíticos del faro (coordenadas locales = grilla + ORIGEN)
        const centro_faro = Vec3.new(fx, 0, fz).add(ORIGEN);
        self.pos_lampara = Vec3.new(centro_faro.x, 20.3, centro_faro.z);
        // linterna de vidrio (cilindro)
        self.agregarObjeto(.{
            .forma = .{ .cilindro = .{ .base = Vec3.new(centro_faro.x, 19.0, centro_faro.z), .altura = 2.6, .radio = 1.7 } },
            .material = mat.vidrio,
        });
        // bombilla (esfera que brilla, no proyecta sombra)
        self.agregarObjeto(.{
            .forma = .{ .esfera = .{ .centro = self.pos_lampara, .radio = 0.55 } },
            .material = mat.lampara,
            .proyecta_sombra = false,
        });
        // techo de cobre (cono)
        self.agregarObjeto(.{
            .forma = .{ .cono = .{ .base = Vec3.new(centro_faro.x, 21.6, centro_faro.z), .altura = 2.2, .radio = 2.4 } },
            .material = mat.cobre,
        });

        // ---------------- Casa del farero ----------------
        // paredes blancas de x 10..14, z 13..17, alto y 7..9
        {
            var hx: i32 = 10;
            while (hx <= 14) : (hx += 1) {
                var hz: i32 = 13;
                while (hz <= 17) : (hz += 1) {
                    const borde = hx == 10 or hx == 14 or hz == 13 or hz == 17;
                    var hy: i32 = 7;
                    while (hy <= 9) : (hy += 1) {
                        if (borde) self.poner(hx, hy, hz, mat.pared);
                    }
                }
            }
            // ventanas que brillan
            self.poner(12, 8, 17, mat.ventana);
            self.poner(14, 8, 15, mat.ventana);
            self.poner(10, 8, 15, mat.ventana);
            // puerta
            self.poner(14, 7, 14, mat.madera);
            self.poner(14, 8, 14, mat.madera);
            // techo de madera escalonado
            var ry: i32 = 10;
            var margen: i32 = 0;
            while (ry <= 12) : (ry += 1) {
                var rx: i32 = 9 + margen;
                while (rx <= 15 - margen) : (rx += 1) {
                    var rz: i32 = 12;
                    while (rz <= 18) : (rz += 1) self.poner(rx, ry, rz, mat.madera);
                }
                margen += 1;
            }
            // chimenea de ladrillo
            self.columna(13, 14, 10, 14, mat.ladrillo_rojo);
        }

        // Bote rojo parado junto a la pared oeste de la casa: el sol le pega al
        // bote y su luz rebotada pinta de rojo la pared blanca (color bleeding)
        {
            var bz: i32 = 15;
            while (bz <= 20) : (bz += 1) {
                self.poner(7, 7, bz, mat.bote_rojo);
                self.poner(7, 8, bz, mat.bote_rojo);
            }
        }

        // ---------------- Muelle ----------------
        {
            var mz: i32 = 23;
            while (mz <= 31) : (mz += 1) {
                self.poner(20, 4, mz, mat.madera);
                self.poner(21, 4, mz, mat.madera);
                if (@mod(mz, 3) == 0) {
                    self.columna(20, mz, 1, 4, mat.madera);
                }
            }
            // farol de alabastro al final del muelle, con una luz adentro
            self.poner(21, 5, 30, mat.madera);
            self.poner(21, 6, 30, mat.alabastro);
            self.pos_farol = Vec3.new(21.5, 6.5, 30.5).add(ORIGEN);
        }

        // ---------------- Esmeraldas en la playa ----------------
        self.poner(25, 5, 22, mat.esmeralda);
        self.poner(26, 5, 22, mat.esmeralda);
        self.poner(25, 6, 22, mat.esmeralda);
        self.poner(26, 5, 23, mat.esmeralda);
        self.poner(25, 5, 23, mat.esmeralda);

        // otro bloque de alabastro decorativo junto al faro
        self.poner(24, 7, 17, mat.alabastro);
        self.poner(24, 8, 17, mat.alabastro);
    }

    fn columna(self: *Escena, x: i32, z: i32, y0: i32, y1: i32, m: u8) void {
        var y = y0;
        while (y < y1) : (y += 1) self.poner(x, y, z, m);
    }

    fn disco(self: *Escena, cx: f32, cz: f32, r: f32, y: i32, m: u8) void {
        var x: i32 = @intFromFloat(cx - r - 1);
        while (@as(f32, @floatFromInt(x)) <= cx + r + 1) : (x += 1) {
            var z: i32 = @intFromFloat(cz - r - 1);
            while (@as(f32, @floatFromInt(z)) <= cz + r + 1) : (z += 1) {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const dz = @as(f32, @floatFromInt(z)) + 0.5 - cz;
                if (dx * dx + dz * dz <= r * r) self.poner(x, y, z, m);
            }
        }
    }

    // ------------------------------------------------------------------
    // Intersección de rayos
    // ------------------------------------------------------------------

    /// Intersección con la caja que contiene la grilla. Devuelve [t_entrada, t_salida]
    /// y el eje por el que entra el rayo.
    fn cajaGrilla(o: Vec3, d: Vec3) ?struct { t0: f32, t1: f32, eje: u2 } {
        const minimo = [3]f32{ ORIGEN.x, ORIGEN.y, ORIGEN.z };
        const maximo = [3]f32{ ORIGEN.x + ANCHO, ORIGEN.y + ALTO, ORIGEN.z + PROF };
        const oo = [3]f32{ o.x, o.y, o.z };
        const dd = [3]f32{ d.x, d.y, d.z };
        var t0: f32 = -1e30;
        var t1: f32 = 1e30;
        var eje: u2 = 0;
        for (0..3) |i| {
            if (@abs(dd[i]) < 1e-9) {
                if (oo[i] < minimo[i] or oo[i] > maximo[i]) return null;
                continue;
            }
            var a = (minimo[i] - oo[i]) / dd[i];
            var b = (maximo[i] - oo[i]) / dd[i];
            if (a > b) {
                const tmp = a;
                a = b;
                b = tmp;
            }
            if (a > t0) {
                t0 = a;
                eje = @intCast(i);
            }
            if (b < t1) t1 = b;
        }
        if (t0 > t1 or t1 < 0) return null;
        return .{ .t0 = t0, .t1 = t1, .eje = eje };
    }

    /// Recorre la grilla con DDA. `medio` es el material en el que viaja el rayo
    /// (aire o agua/esmeralda): el primer cubo con material distinto es un choque.
    pub fn trazarVoxeles(self: *const Escena, o: Vec3, d: Vec3, medio: u8, tmax: f32) ?Golpe {
        const caja = cajaGrilla(o, d) orelse return null;
        const dentro = caja.t0 < 0;
        const t_inicio: f32 = if (dentro) 0 else caja.t0;
        if (t_inicio > tmax) return null;

        // posición inicial en coordenadas de grilla
        const p = o.add(d.scale(t_inicio)).sub(ORIGEN);
        const pp = [3]f32{ p.x, p.y, p.z };
        const dd = [3]f32{ d.x, d.y, d.z };
        const lim = [3]i32{ ANCHO, ALTO, PROF };
        var celda: [3]i32 = undefined;
        var paso: [3]i32 = undefined;
        var t_max: [3]f32 = undefined;
        var t_delta: [3]f32 = undefined;
        for (0..3) |i| {
            var c: i32 = @intFromFloat(@floor(pp[i]));
            // si entramos desde afuera, aseguramos que la celda quede dentro
            if (c < 0) c = 0;
            if (c >= lim[i]) c = lim[i] - 1;
            celda[i] = c;
            if (dd[i] > 0) {
                paso[i] = 1;
                t_delta[i] = 1.0 / dd[i];
                t_max[i] = t_inicio + (@as(f32, @floatFromInt(c + 1)) - pp[i]) / dd[i];
            } else if (dd[i] < 0) {
                paso[i] = -1;
                t_delta[i] = -1.0 / dd[i];
                t_max[i] = t_inicio + (@as(f32, @floatFromInt(c)) - pp[i]) / dd[i];
            } else {
                paso[i] = 0;
                t_delta[i] = 1e30;
                t_max[i] = 1e30;
            }
        }

        // Si el rayo viene de afuera, el primer cubo ya puede ser un choque.
        if (!dentro) {
            const v = self.voxel(celda[0], celda[1], celda[2]);
            if (v != medio) {
                return self.armarGolpe(o, d, t_inicio, caja.eje, -paso[caja.eje], v, medio);
            }
        }

        var iter: usize = 0;
        while (iter < 200) : (iter += 1) {
            // eje con el siguiente borde más cercano
            var eje: usize = 0;
            if (t_max[1] < t_max[eje]) eje = 1;
            if (t_max[2] < t_max[eje]) eje = 2;
            const t = t_max[eje];
            if (t > tmax) return null;
            celda[eje] += paso[eje];
            t_max[eje] += t_delta[eje];

            const fuera = celda[eje] < 0 or celda[eje] >= lim[eje];
            if (fuera) {
                // salimos de la grilla: si veníamos dentro del agua, es la superficie de salida
                if (medio != mat.aire) {
                    return self.armarGolpe(o, d, t, @intCast(eje), -paso[eje], mat.aire, medio);
                }
                return null;
            }
            const v = self.voxel(celda[0], celda[1], celda[2]);
            if (v != medio) {
                return self.armarGolpe(o, d, t, @intCast(eje), -paso[eje], v, medio);
            }
        }
        return null;
    }

    fn armarGolpe(self: *const Escena, o: Vec3, d: Vec3, t: f32, eje: u2, signo: i32, v: u8, medio: u8) Golpe {
        _ = self;
        const punto = o.add(d.scale(t));
        const s: f32 = @floatFromInt(signo);
        const normal = switch (eje) {
            0 => Vec3.new(s, 0, 0),
            1 => Vec3.new(0, s, 0),
            else => Vec3.new(0, 0, s),
        };
        const g = punto.sub(ORIGEN);
        var u: f32 = 0;
        var vv: f32 = 0;
        switch (eje) {
            0 => {
                u = g.z;
                vv = 1.0 - (g.y - @floor(g.y));
            },
            1 => {
                u = g.x;
                vv = g.z;
            },
            else => {
                u = g.x;
                vv = 1.0 - (g.y - @floor(g.y));
            },
        }
        const saliendo = (v == mat.aire);
        return .{
            .t = t,
            .punto = punto,
            .normal = normal,
            .material = if (saliendo) medio else v,
            .u = u,
            .v = vv,
            .cara_arriba = eje == 1 and (if (saliendo) signo < 0 else signo > 0),
            .saliendo = saliendo,
            .es_objeto = false,
        };
    }

    /// Intersección completa: voxeles + formas analíticas, el más cercano.
    pub fn intersectar(self: *const Escena, o: Vec3, d: Vec3, medio: u8, tmax: f32) ?Golpe {
        var mejor = self.trazarVoxeles(o, d, medio, tmax);
        var limite = if (mejor) |g| g.t else tmax;
        for (self.objetos[0..self.num_objetos]) |*obj| {
            if (formas.intersectar(obj, o, d, EPS, limite)) |imp| {
                const desde_adentro = imp.normal.dot(d) > 0;
                limite = imp.t;
                mejor = .{
                    .t = imp.t,
                    .punto = o.add(d.scale(imp.t)),
                    .normal = if (desde_adentro) imp.normal.neg() else imp.normal,
                    .material = obj.material,
                    .u = imp.u,
                    .v = imp.v,
                    .cara_arriba = false,
                    .saliendo = desde_adentro,
                    .es_objeto = true,
                };
            }
        }
        return mejor;
    }

    /// Cuánta luz llega desde `o` en la dirección `d` hasta la distancia `dist`.
    /// Los materiales opacos bloquean (sombra), los transparentes o translúcidos
    /// dejan pasar parte de la luz con su color (sombras de color).
    pub fn transmitancia(self: *const Escena, bib: *const mat.Biblioteca, o: Vec3, d: Vec3, dist: f32) Vec3 {
        var T = Vec3.uno;

        // --- formas analíticas ---
        for (self.objetos[0..self.num_objetos]) |*obj| {
            if (!obj.proyecta_sombra) continue;
            if (formas.intersectar(obj, o, d, EPS, dist)) |_| {
                T = T.mul(bib.tinte_sombra[obj.material]);
                if (T.esCero()) return Vec3.cero;
            }
        }

        // --- voxeles (DDA) ---
        const caja = cajaGrilla(o, d) orelse return T;
        const t_inicio: f32 = @max(0.0, caja.t0);
        const t_fin = @min(dist, caja.t1);
        if (t_inicio > t_fin) return T;

        const p = o.add(d.scale(t_inicio)).sub(ORIGEN);
        const pp = [3]f32{ p.x, p.y, p.z };
        const dd = [3]f32{ d.x, d.y, d.z };
        const lim = [3]i32{ ANCHO, ALTO, PROF };
        var celda: [3]i32 = undefined;
        var paso: [3]i32 = undefined;
        var t_max: [3]f32 = undefined;
        var t_delta: [3]f32 = undefined;
        for (0..3) |i| {
            var c: i32 = @intFromFloat(@floor(pp[i]));
            if (c < 0) c = 0;
            if (c >= lim[i]) c = lim[i] - 1;
            celda[i] = c;
            if (dd[i] > 0) {
                paso[i] = 1;
                t_delta[i] = 1.0 / dd[i];
                t_max[i] = t_inicio + (@as(f32, @floatFromInt(c + 1)) - pp[i]) / dd[i];
            } else if (dd[i] < 0) {
                paso[i] = -1;
                t_delta[i] = -1.0 / dd[i];
                t_max[i] = t_inicio + (@as(f32, @floatFromInt(c)) - pp[i]) / dd[i];
            } else {
                paso[i] = 0;
                t_delta[i] = 1e30;
                t_max[i] = 1e30;
            }
        }

        var anterior = self.voxel(celda[0], celda[1], celda[2]);
        if (anterior != mat.aire) {
            const tinte = bib.tinte_sombra[anterior];
            // si el punto de partida quedó dentro de algo opaco, lo ignoramos
            if (!tinte.esCero()) T = T.mul(tinte) else anterior = mat.aire;
        }

        var iter: usize = 0;
        while (iter < 200) : (iter += 1) {
            var eje: usize = 0;
            if (t_max[1] < t_max[eje]) eje = 1;
            if (t_max[2] < t_max[eje]) eje = 2;
            if (t_max[eje] > t_fin) break;
            celda[eje] += paso[eje];
            t_max[eje] += t_delta[eje];
            if (celda[eje] < 0 or celda[eje] >= lim[eje]) break;
            const v = self.voxel(celda[0], celda[1], celda[2]);
            if (v != anterior and v != mat.aire) {
                T = T.mul(bib.tinte_sombra[v]);
                if (T.esCero()) return Vec3.cero;
            }
            anterior = v;
        }
        return T;
    }
};
