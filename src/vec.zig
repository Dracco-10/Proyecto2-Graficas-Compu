// vec.zig
// Matemática básica de vectores 3D y un generador de números aleatorios
// pequeño (PCG), para no depender de nada fuera de la librería estándar.

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub const cero = Vec3{ .x = 0, .y = 0, .z = 0 };
    pub const uno = Vec3{ .x = 1, .y = 1, .z = 1 };

    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn splat(v: f32) Vec3 {
        return .{ .x = v, .y = v, .z = v };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    /// Multiplicación componente por componente (sirve para mezclar colores).
    pub fn mul(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn length(a: Vec3) f32 {
        return @sqrt(a.dot(a));
    }

    pub fn normalize(a: Vec3) Vec3 {
        const l = a.length();
        if (l == 0) return a;
        return a.scale(1.0 / l);
    }

    pub fn neg(a: Vec3) Vec3 {
        return .{ .x = -a.x, .y = -a.y, .z = -a.z };
    }

    pub fn maxComp(a: Vec3) f32 {
        return @max(a.x, @max(a.y, a.z));
    }

    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return a.add(b.sub(a).scale(t));
    }

    /// e^(-v) por componente, para la absorción dentro del agua o el cristal.
    pub fn expNeg(a: Vec3) Vec3 {
        return .{ .x = @exp(-a.x), .y = @exp(-a.y), .z = @exp(-a.z) };
    }

    pub fn esCero(a: Vec3) bool {
        return a.x <= 0.0001 and a.y <= 0.0001 and a.z <= 0.0001;
    }
};

/// Refleja la dirección d respecto a la normal n.
pub fn reflejar(d: Vec3, n: Vec3) Vec3 {
    return d.sub(n.scale(2.0 * d.dot(n)));
}

/// Ley de Snell. eta = n1 / n2. Devuelve null cuando hay reflexión total interna.
pub fn refractar(d: Vec3, n: Vec3, eta: f32) ?Vec3 {
    const cosi = -n.dot(d);
    const k = 1.0 - eta * eta * (1.0 - cosi * cosi);
    if (k < 0) return null;
    return d.scale(eta).add(n.scale(eta * cosi - @sqrt(k))).normalize();
}

/// Aproximación de Schlick para el término de Fresnel.
pub fn schlick(cosi: f32, n1: f32, n2: f32) f32 {
    var r0 = (n1 - n2) / (n1 + n2);
    r0 = r0 * r0;
    const c = 1.0 - @max(0.0, @min(1.0, cosi));
    return r0 + (1.0 - r0) * c * c * c * c * c;
}

/// Rota un vector alrededor del eje Y, dados coseno y seno del ángulo.
pub fn rotarY(v: Vec3, c: f32, s: f32) Vec3 {
    return .{ .x = v.x * c + v.z * s, .y = v.y, .z = -v.x * s + v.z * c };
}

pub fn suavizar(borde0: f32, borde1: f32, x: f32) f32 {
    const t = @max(0.0, @min(1.0, (x - borde0) / (borde1 - borde0)));
    return t * t * (3.0 - 2.0 * t);
}

/// Generador aleatorio PCG: rápido, cada hilo tiene el suyo.
pub const Rng = struct {
    estado: u32,

    pub fn init(semilla: u32) Rng {
        var r = Rng{ .estado = semilla *% 747796405 +% 2891336453 };
        _ = r.siguiente();
        return r;
    }

    pub fn siguiente(self: *Rng) u32 {
        const viejo = self.estado;
        self.estado = viejo *% 747796405 +% 2891336453;
        const palabra = ((viejo >> @intCast((viejo >> 28) +% 4)) ^ viejo) *% 277803737;
        return (palabra >> 22) ^ palabra;
    }

    /// Número aleatorio en [0, 1).
    pub fn float(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.siguiente() >> 8)) / 16777216.0;
    }
};

/// Dirección aleatoria en el hemisferio de la normal, con distribución coseno
/// (la que usa la iluminación indirecta para el color bleeding).
pub fn direccionCoseno(n: Vec3, rng: *Rng) Vec3 {
    const r1 = rng.float();
    const r2 = rng.float();
    const phi = 2.0 * 3.14159265 * r1;
    const r = @sqrt(r2);
    const lx = r * @cos(phi);
    const ly = r * @sin(phi);
    const lz = @sqrt(@max(0.0, 1.0 - r2));
    // base ortonormal alrededor de n
    const a = if (@abs(n.x) > 0.9) Vec3.new(0, 1, 0) else Vec3.new(1, 0, 0);
    const t = a.cross(n).normalize();
    const b = n.cross(t);
    return t.scale(lx).add(b.scale(ly)).add(n.scale(lz)).normalize();
}
