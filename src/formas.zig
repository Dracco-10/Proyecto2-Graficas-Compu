// formas.zig
// Formas analíticas además de los cubos: esfera, cilindro y cono.
// El cilindro y el cono son las "formas no vistas en clase" del diorama
// (la linterna de vidrio y el techo del faro).

const std = @import("std");
const vec = @import("vec.zig");
const Vec3 = vec.Vec3;

pub const Forma = union(enum) {
    esfera: struct { centro: Vec3, radio: f32 },
    /// Cilindro vertical con tapas. base = centro de la tapa de abajo.
    cilindro: struct { base: Vec3, altura: f32, radio: f32 },
    /// Cono vertical con la punta hacia arriba y tapa abajo.
    cono: struct { base: Vec3, altura: f32, radio: f32 },
};

pub const Objeto = struct {
    forma: Forma,
    material: u8,
    proyecta_sombra: bool = true,
};

pub const Impacto = struct {
    t: f32,
    /// Normal hacia afuera de la forma.
    normal: Vec3,
    u: f32,
    v: f32,
};

const PI: f32 = 3.14159265;

pub fn intersectar(obj: *const Objeto, o: Vec3, d: Vec3, tmin: f32, tmax: f32) ?Impacto {
    return switch (obj.forma) {
        .esfera => |e| esfera(e.centro, e.radio, o, d, tmin, tmax),
        .cilindro => |c| cilindro(c.base, c.altura, c.radio, o, d, tmin, tmax),
        .cono => |c| cono(c.base, c.altura, c.radio, o, d, tmin, tmax),
    };
}

fn esfera(c: Vec3, r: f32, o: Vec3, d: Vec3, tmin: f32, tmax: f32) ?Impacto {
    const oc = o.sub(c);
    const b = oc.dot(d);
    const cc = oc.dot(oc) - r * r;
    const disc = b * b - cc;
    if (disc < 0) return null;
    const s = @sqrt(disc);
    var t = -b - s;
    if (t < tmin) t = -b + s;
    if (t < tmin or t > tmax) return null;
    const p = o.add(d.scale(t));
    const n = p.sub(c).scale(1.0 / r);
    return .{
        .t = t,
        .normal = n,
        .u = 0.5 + std.math.atan2(n.z, n.x) / (2.0 * PI),
        .v = 0.5 - n.y * 0.5,
    };
}

fn cilindro(base: Vec3, h: f32, r: f32, o: Vec3, d: Vec3, tmin: f32, tmax: f32) ?Impacto {
    var mejor: ?Impacto = null;
    var limite = tmax;
    const ox = o.x - base.x;
    const oz = o.z - base.z;

    // Pared lateral: (ox + t dx)^2 + (oz + t dz)^2 = r^2
    const a = d.x * d.x + d.z * d.z;
    if (a > 1e-8) {
        const b = 2.0 * (ox * d.x + oz * d.z);
        const c = ox * ox + oz * oz - r * r;
        const disc = b * b - 4.0 * a * c;
        if (disc >= 0) {
            const s = @sqrt(disc);
            const raices = [2]f32{ (-b - s) / (2.0 * a), (-b + s) / (2.0 * a) };
            for (raices) |t| {
                if (t < tmin or t > limite) continue;
                const y = o.y + d.y * t - base.y;
                if (y < 0 or y > h) continue;
                const px = ox + d.x * t;
                const pz = oz + d.z * t;
                mejor = .{
                    .t = t,
                    .normal = Vec3.new(px / r, 0, pz / r),
                    .u = 0.5 + std.math.atan2(pz, px) / (2.0 * PI) * 2.0,
                    .v = 1.0 - y / h,
                };
                limite = t;
                break;
            }
        }
    }

    // Tapas de arriba y abajo
    if (@abs(d.y) > 1e-8) {
        const tapas = [2]f32{ base.y, base.y + h };
        for (tapas, 0..) |ty, i| {
            const t = (ty - o.y) / d.y;
            if (t < tmin or t > limite) continue;
            const px = ox + d.x * t;
            const pz = oz + d.z * t;
            if (px * px + pz * pz > r * r) continue;
            mejor = .{
                .t = t,
                .normal = if (i == 0) Vec3.new(0, -1, 0) else Vec3.new(0, 1, 0),
                .u = px / (2.0 * r) + 0.5,
                .v = pz / (2.0 * r) + 0.5,
            };
            limite = t;
        }
    }
    return mejor;
}

fn cono(base: Vec3, h: f32, r: f32, o: Vec3, d: Vec3, tmin: f32, tmax: f32) ?Impacto {
    var mejor: ?Impacto = null;
    var limite = tmax;
    const k = r / h;
    const k2 = k * k;
    const punta_y = base.y + h;
    const ox = o.x - base.x;
    const oz = o.z - base.z;
    const oy = punta_y - o.y; // distancia vertical desde la punta
    const dy = -d.y;

    // Superficie: x^2 + z^2 = k^2 * (punta_y - y)^2
    const a = d.x * d.x + d.z * d.z - k2 * dy * dy;
    const b = 2.0 * (ox * d.x + oz * d.z - k2 * oy * dy);
    const c = ox * ox + oz * oz - k2 * oy * oy;
    var raices = [2]f32{ -1, -1 };
    if (@abs(a) < 1e-8) {
        if (@abs(b) > 1e-8) raices[0] = -c / b;
    } else {
        const disc = b * b - 4.0 * a * c;
        if (disc >= 0) {
            const s = @sqrt(disc);
            const t1 = (-b - s) / (2.0 * a);
            const t2 = (-b + s) / (2.0 * a);
            raices = .{ @min(t1, t2), @max(t1, t2) };
        }
    }
    for (raices) |t| {
        if (t < tmin or t > limite) continue;
        const y = o.y + d.y * t;
        if (y < base.y or y > punta_y) continue;
        const px = ox + d.x * t;
        const pz = oz + d.z * t;
        const n = Vec3.new(px, k2 * (punta_y - y), pz).normalize();
        mejor = .{
            .t = t,
            .normal = n,
            .u = 0.5 + std.math.atan2(pz, px) / (2.0 * PI) * 2.0,
            .v = 1.0 - (y - base.y) / h,
        };
        limite = t;
        break;
    }

    // Tapa de abajo
    if (@abs(d.y) > 1e-8) {
        const t = (base.y - o.y) / d.y;
        if (t >= tmin and t <= limite) {
            const px = ox + d.x * t;
            const pz = oz + d.z * t;
            if (px * px + pz * pz <= r * r) {
                mejor = .{
                    .t = t,
                    .normal = Vec3.new(0, -1, 0),
                    .u = px / (2.0 * r) + 0.5,
                    .v = pz / (2.0 * r) + 0.5,
                };
            }
        }
    }
    return mejor;
}
