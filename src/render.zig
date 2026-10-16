// render.zig
// El raytracer: lanza un rayo por píxel, calcula iluminación directa con
// sombras, reflexión, refracción (con Fresnel), translucidez, emisión,
// iluminación indirecta de un rebote (color bleeding) y el skybox.

const std = @import("std");
const vec = @import("vec.zig");
const Vec3 = vec.Vec3;
const Rng = vec.Rng;
const mat = @import("materiales.zig");
const esc = @import("escena.zig");
const Escena = esc.Escena;
const Golpe = esc.Golpe;
const Luz = esc.Luz;
const Skybox = @import("texturas.zig").Skybox;

pub const MAX_LUCES = 6;
const PROFUNDIDAD_MAX = 5;

/// Todo lo que necesita un hilo para renderizar un cuadro. Es de solo lectura
/// mientras se renderiza, así que lo pueden compartir todos los hilos.
pub const Contexto = struct {
    escena: *const Escena,
    biblioteca: *const mat.Biblioteca,
    skybox: *const Skybox,

    // Cámara, ya en el espacio local del diorama
    cam_pos: Vec3,
    cam_frente: Vec3,
    cam_derecha: Vec3,
    cam_arriba: Vec3,
    tan_fov: f32,

    // Rotación del diorama (para consultar el skybox en coordenadas del mundo)
    rot_cos: f32,
    rot_sin: f32,

    luces: [MAX_LUCES]Luz,
    num_luces: usize,
    /// Índice del reflector del faro en `luces` (para el haz volumétrico).
    idx_reflector: usize,

    tiempo: f32,
    muestras_gi: u32,
    fuerza_gi: f32,
    haz_volumetrico: bool,
    ambiente: Vec3,
};

/// Color del cielo para una dirección en espacio local.
fn cielo(ctx: *const Contexto, d: Vec3) Vec3 {
    // de local a mundo: rotamos con el ángulo del diorama
    const mundo = vec.rotarY(d, ctx.rot_cos, ctx.rot_sin);
    return ctx.skybox.muestrear(mundo);
}

/// Color de la textura en el punto golpeado.
fn colorTextura(ctx: *const Contexto, g: *const Golpe) Vec3 {
    const bib = ctx.biblioteca;
    const c = if (g.cara_arriba)
        bib.arriba[g.material].muestrear(g.u, g.v)
    else
        bib.lados[g.material].muestrear(g.u, g.v);

    // Bordes de los cubos: oscurecemos un poco cerca de las aristas para que
    // cada bloque se distinga (no aplica al agua, vidrio ni a lo que brilla).
    const m = &mat.lista[g.material];
    if (g.es_objeto or m.transparencia > 0 or m.emision > 0) return c;
    const fu = g.u - @floor(g.u);
    const fv = g.v - @floor(g.v);
    const borde = @min(@min(fu, 1.0 - fu), @min(fv, 1.0 - fv));
    const k = vec.suavizar(0.0, 0.07, borde);
    return c.scale(0.72 + 0.28 * k);
}

const MuestraLuz = struct { dir: Vec3, dist: f32, radiancia: Vec3 };

fn muestrearLuz(l: *const Luz, p: Vec3) ?MuestraLuz {
    switch (l.tipo) {
        .direccional => return .{ .dir = l.direccion, .dist = 200.0, .radiancia = l.color },
        .puntual => {
            const v = l.posicion.sub(p);
            const dist = v.length();
            const atn = 1.0 / (1.0 + l.atenuacion * dist * dist);
            return .{ .dir = v.scale(1.0 / dist), .dist = dist, .radiancia = l.color.scale(atn) };
        },
        .reflector => {
            const v = l.posicion.sub(p);
            const dist = v.length();
            const L = v.scale(1.0 / dist);
            const cos_ang = L.neg().dot(l.direccion);
            if (cos_ang <= l.cos_externo) return null;
            const cono = vec.suavizar(l.cos_externo, l.cos_interno, cos_ang);
            const atn = 1.0 / (1.0 + l.atenuacion * dist * dist);
            return .{ .dir = L, .dist = dist, .radiancia = l.color.scale(atn * cono) };
        },
    }
}

/// Iluminación directa de todas las luces en un punto (difusa, especular y
/// translúcida), con sombras.
fn iluminacionDirecta(ctx: *const Contexto, g: *const Golpe, m: *const mat.Material, tex: Vec3, n: Vec3, vista: Vec3, con_especular: bool) Vec3 {
    var total = Vec3.cero;
    const color_especular = if (m.color_en_reflejo) tex else Vec3.uno;
    for (ctx.luces[0..ctx.num_luces]) |*l| {
        const s = muestrearLuz(l, g.punto) orelse continue;
        const ndl = n.dot(s.dir);
        if (ndl <= 0 and m.translucidez <= 0) continue;

        // el rayo de sombra sale un poquito separado de la superficie
        const lado: f32 = if (ndl > 0) 1.0 else -1.0;
        const origen = g.punto.add(n.scale(esc.EPS * 4.0 * lado));
        const T = ctx.escena.transmitancia(ctx.biblioteca, origen, s.dir, s.dist);
        if (T.esCero()) continue;
        const luz = s.radiancia.mul(T);

        // difusa (Lambert)
        var aporte = Vec3.cero;
        if (ndl > 0) aporte = tex.scale(ndl * m.albedo);

        // translúcida: la luz que llega por detrás atraviesa el material
        if (m.translucidez > 0) {
            const atras = @max(0.0, -ndl);
            const envolvente = (ndl + 0.5) / 1.5; // "wrap lighting" suave
            aporte = aporte.add(tex.scale(m.translucidez * (atras * 0.9 + @max(0.0, envolvente) * 0.2)));
        }

        // especular (Blinn-Phong)
        if (con_especular and m.especular > 0 and ndl > 0) {
            const h = s.dir.sub(vista).normalize();
            const spec = std.math.pow(f32, @max(0.0, n.dot(h)), m.brillo) * m.especular;
            aporte = aporte.add(color_especular.scale(spec));
        }
        total = total.add(aporte.mul(luz));
    }
    return total;
}

/// Lo que "se ve" en un punto alcanzado por un rayo de iluminación indirecta:
/// emisión o luz directa difusa. Es lo que produce el color bleeding.
fn radianciaRebote(ctx: *const Contexto, o: Vec3, d: Vec3, medio: u8) Vec3 {
    const g = ctx.escena.intersectar(o, d, medio, 1e30) orelse return cielo(ctx, d).scale(0.6);
    const m = &mat.lista[g.material];
    const tex = colorTextura(ctx, &g);
    if (m.emision > 0) return tex.scale(m.emision);
    // superficies muy transparentes: se ve casi lo que hay atrás, aproximamos con el cielo
    if (m.transparencia > 0.5) return cielo(ctx, d).scale(0.4).mul(tex);
    const directa = iluminacionDirecta(ctx, &g, m, tex, g.normal, d, false);
    return directa.add(tex.mul(ctx.ambiente).scale(m.albedo));
}

/// Traza un rayo y devuelve el color que trae.
pub fn trazar(ctx: *const Contexto, o: Vec3, d: Vec3, profundidad: u32, medio: u8, rng: *Rng) Vec3 {
    const g = ctx.escena.intersectar(o, d, medio, 1e30) orelse return cielo(ctx, d);
    var color = sombrear(ctx, &g, d, profundidad, medio, rng);
    // absorción dentro del agua / esmeralda (ley de Beer)
    if (medio != mat.aire) {
        color = color.mul(mat.lista[medio].absorcion.scale(g.t).expNeg());
    }
    return color;
}

fn sombrear(ctx: *const Contexto, g: *const Golpe, d: Vec3, profundidad: u32, medio: u8, rng: *Rng) Vec3 {
    const m = &mat.lista[g.material];
    const tex = colorTextura(ctx, g);

    // Materiales que brillan: devuelven su propia luz
    if (m.emision > 0) return tex.scale(m.emision);

    var n = g.normal;
    // olas: perturbamos un poco la normal de la superficie del agua
    if (g.material == mat.agua and g.cara_arriba) {
        const px = g.punto.x;
        const pz = g.punto.z;
        const t = ctx.tiempo;
        const ox = 0.06 * @sin(px * 2.1 + t * 1.3) + 0.03 * @sin(pz * 3.7 - t * 0.9);
        const oz = 0.06 * @cos(pz * 1.8 + t * 1.1) + 0.03 * @cos(px * 3.1 + t * 0.7);
        n = n.add(Vec3.new(ox, 0, oz)).normalize();
    }

    // --- iluminación local ---
    var local = iluminacionDirecta(ctx, g, m, tex, n, d, true);
    local = local.add(tex.mul(ctx.ambiente).scale(m.albedo));

    // --- iluminación indirecta (color bleeding) ---
    if (ctx.muestras_gi > 0 and profundidad <= 1 and m.transparencia < 0.5) {
        var suma = Vec3.cero;
        const origen = g.punto.add(n.scale(esc.EPS * 4.0));
        var i: u32 = 0;
        while (i < ctx.muestras_gi) : (i += 1) {
            const dir = vec.direccionCoseno(n, rng);
            suma = suma.add(radianciaRebote(ctx, origen, dir, medio));
        }
        const promedio = suma.scale(1.0 / @as(f32, @floatFromInt(ctx.muestras_gi)));
        local = local.add(tex.mul(promedio).scale(m.albedo * ctx.fuerza_gi));
    }

    if (profundidad >= PROFUNDIDAD_MAX) return local;

    // --- reflexión y refracción ---
    const kr = m.reflectividad;
    const kt = m.transparencia;
    var peso_reflejo = kr;
    var peso_refraccion: f32 = 0;
    var dir_refraccion: ?Vec3 = null;
    var n1: f32 = 1.0;
    var n2: f32 = 1.0;
    if (kt > 0) {
        if (g.saliendo) {
            n1 = m.ior;
        } else {
            n2 = m.ior;
        }
        const cosi = -d.dot(n);
        var F = vec.schlick(cosi, n1, n2);
        dir_refraccion = vec.refractar(d, n, n1 / n2);
        if (dir_refraccion == null) F = 1.0; // reflexión total interna
        peso_reflejo = @min(1.0, kr + kt * F);
        peso_refraccion = kt * (1.0 - F);
    }

    var color = local.scale((1.0 - kr) * (1.0 - kt));
    const tinte = if (m.color_en_reflejo) tex else Vec3.uno;

    if (peso_reflejo > 0.01) {
        const r = vec.reflejar(d, n);
        const origen = g.punto.add(g.normal.scale(esc.EPS * 4.0));
        const c = trazar(ctx, origen, r, profundidad + 1, medio, rng);
        color = color.add(c.mul(tinte).scale(peso_reflejo));
    }
    if (peso_refraccion > 0.01) {
        if (dir_refraccion) |rd| {
            const origen = g.punto.sub(g.normal.scale(esc.EPS * 4.0));
            // los cubos de agua/esmeralda cambian el medio; los objetos (vidrio) no
            var nuevo_medio = medio;
            if (!g.es_objeto) nuevo_medio = if (g.saliendo) mat.aire else g.material;
            const c = trazar(ctx, origen, rd, profundidad + 1, nuevo_medio, rng);
            color = color.add(c.mul(tinte).scale(peso_refraccion));
        }
    }
    return color;
}

/// Haz de luz del faro visible en el aire (aproximación volumétrica simple).
fn haz(ctx: *const Contexto, o: Vec3, d: Vec3, t_golpe: f32, rng: *Rng) Vec3 {
    const l = &ctx.luces[ctx.idx_reflector];
    const t_fin = @min(t_golpe, 120.0);
    const pasos: u32 = 24;
    const dt = t_fin / @as(f32, @floatFromInt(pasos));
    var t = dt * rng.float();
    var acum: f32 = 0;
    var i: u32 = 0;
    while (i < pasos) : (i += 1) {
        const p = o.add(d.scale(t));
        const v = p.sub(l.posicion);
        const dist = v.length();
        if (dist > 0.5) {
            const c = v.scale(1.0 / dist).dot(l.direccion);
            if (c > l.cos_externo) {
                const k = vec.suavizar(l.cos_externo, l.cos_interno, c);
                acum += k * dt / (1.0 + l.atenuacion * dist * dist);
            }
        }
        t += dt;
    }
    return l.color.scale(acum * 0.007);
}

/// Color de un píxel (x, y) de una imagen de ancho w y alto h.
pub fn pixel(ctx: *const Contexto, x: usize, y: usize, w: usize, h: usize, rng: *Rng) Vec3 {
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    // antialiasing: posición aleatoria dentro del píxel
    const sx = (@as(f32, @floatFromInt(x)) + rng.float()) / wf * 2.0 - 1.0;
    const sy = 1.0 - (@as(f32, @floatFromInt(y)) + rng.float()) / hf * 2.0;
    const aspecto = wf / hf;
    const d = ctx.cam_frente
        .add(ctx.cam_derecha.scale(sx * ctx.tan_fov * aspecto))
        .add(ctx.cam_arriba.scale(sy * ctx.tan_fov))
        .normalize();

    const g = ctx.escena.intersectar(ctx.cam_pos, d, mat.aire, 1e30);
    var color = if (g) |gg| sombrear(ctx, &gg, d, 0, mat.aire, rng) else cielo(ctx, d);
    if (ctx.haz_volumetrico) {
        color = color.add(haz(ctx, ctx.cam_pos, d, if (g) |gg| gg.t else 1e30, rng));
    }
    return color;
}

/// Mapeo de tonos (ACES aproximado) y corrección gamma: de color lineal HDR a 0..255.
pub fn aByte(c: f32) u8 {
    const a = 2.51;
    const b = 0.03;
    const cc = 2.43;
    const dd = 0.59;
    const e = 0.14;
    const x = @max(0.0, c);
    const t = @max(0.0, @min(1.0, (x * (a * x + b)) / (x * (cc * x + dd) + e)));
    const gamma = std.math.pow(f32, t, 1.0 / 2.2);
    return @intFromFloat(gamma * 255.0 + 0.5);
}
