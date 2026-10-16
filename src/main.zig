// main.zig
// Diorama "El Faro" con raytracing en Zig + Raylib.
// Raylib solo se usa para la ventana, el teclado/mouse, cargar los PNG y
// mostrar la imagen; todo el raytracing está hecho a mano en la CPU,
// repartido entre varios hilos (concurrencia).

const std = @import("std");
const rl = @import("raylib");
const vec = @import("vec.zig");
const Vec3 = vec.Vec3;
const Rng = vec.Rng;
const mat = @import("materiales.zig");
const esc = @import("escena.zig");
const render = @import("render.zig");
const Skybox = @import("texturas.zig").Skybox;

const VENTANA_W = 960;
const VENTANA_H = 540;

// Video: cuadros que se renderizan con más calidad y se guardan como PNG
const VIDEO_CUADROS: u32 = 300;
const VIDEO_MUESTRAS: u32 = 10;

const MAX_HILOS = 64;

/// Trabajo compartido entre los hilos: cada hilo toma la siguiente fila libre
/// (contador atómico) hasta que se acaban las filas.
pub const Trabajo = struct {
    ctx: *const render.Contexto,
    acumulado: []Vec3,
    rgba: []u8,
    ancho: usize,
    alto: usize,
    /// Peso del cuadro nuevo al mezclarlo con lo acumulado (1 = reemplazar).
    peso: f32,
    semilla: u32,
    siguiente_fila: std.atomic.Value(u32),
};

fn trabajador(tr: *Trabajo) void {
    while (true) {
        const fila = tr.siguiente_fila.fetchAdd(1, .monotonic);
        if (fila >= tr.alto) break;
        var rng = Rng.init(tr.semilla ^ (fila *% 2654435761));
        const y: usize = fila;
        for (0..tr.ancho) |x| {
            const i = y * tr.ancho + x;
            const c = render.pixel(tr.ctx, x, y, tr.ancho, tr.alto, &rng);
            const a = tr.acumulado[i].lerp(c, tr.peso);
            tr.acumulado[i] = a;
            tr.rgba[i * 4 + 0] = render.aByte(a.x);
            tr.rgba[i * 4 + 1] = render.aByte(a.y);
            tr.rgba[i * 4 + 2] = render.aByte(a.z);
            tr.rgba[i * 4 + 3] = 255;
        }
    }
}

pub fn renderizarEnParalelo(tr: *Trabajo, hilos: []std.Thread) void {
    tr.siguiente_fila.store(0, .monotonic);
    var lanzados: usize = 0;
    for (hilos) |*h| {
        h.* = std.Thread.spawn(.{}, trabajador, .{tr}) catch break;
        lanzados += 1;
    }
    // si no se pudo lanzar ningún hilo, renderizamos en el hilo principal
    if (lanzados == 0) trabajador(tr);
    for (hilos[0..lanzados]) |h| h.join();
}

/// Estado de la cámara y del diorama controlado por el usuario.
pub const Vista = struct {
    rotacion: f32 = -0.785, // ángulo del diorama alrededor de Y
    inclinacion: f32 = 0.42, // ángulo de la cámara hacia abajo
    distancia: f32 = 52.0, // zoom
    /// Dirección fija hacia donde apunta el reflector del faro.
    angulo_haz: f32 = 0.15,
    tiempo: f32 = 0.0,
};

pub fn armarContexto(
    vista: Vista,
    escena: *const esc.Escena,
    bib: *const mat.Biblioteca,
    sky: *const Skybox,
    muestras_gi: u32,
    haz_on: bool,
) render.Contexto {
    // Cámara en el mundo: orbita en el plano YZ mirando al centro del diorama
    const objetivo = Vec3.new(0, 8.5, 0);
    const pos = objetivo.add(Vec3.new(0, @sin(vista.inclinacion), @cos(vista.inclinacion)).scale(vista.distancia));
    const frente = objetivo.sub(pos).normalize();
    const derecha = frente.cross(Vec3.new(0, 1, 0)).normalize();
    const arriba = derecha.cross(frente);

    // Rotar el diorama = llevar la cámara al espacio local del diorama con la rotación inversa
    const c = @cos(vista.rotacion);
    const s = @sin(vista.rotacion);

    var ctx = render.Contexto{
        .escena = escena,
        .biblioteca = bib,
        .skybox = sky,
        .cam_pos = vec.rotarY(pos, c, -s),
        .cam_frente = vec.rotarY(frente, c, -s),
        .cam_derecha = vec.rotarY(derecha, c, -s),
        .cam_arriba = vec.rotarY(arriba, c, -s),
        .tan_fov = @tan(0.5 * 45.0 * std.math.pi / 180.0),
        .rot_cos = c,
        .rot_sin = s,
        .luces = undefined,
        .num_luces = 0,
        .idx_reflector = 0,
        .tiempo = vista.tiempo,
        .muestras_gi = muestras_gi,
        .fuerza_gi = 1.4,
        .haz_volumetrico = haz_on,
        .ambiente = Vec3.new(0.03, 0.03, 0.045),
    };

    // Luz del atardecer (direccional, fija en el mundo: no gira con el diorama)
    const sol = Vec3.new(0.75, 0.2, 0.66).normalize();
    ctx.luces[0] = .{ .tipo = .direccional, .color = Vec3.new(1.0, 0.55, 0.28).scale(1.3), .direccion = vec.rotarY(sol, c, -s) };
    // Luz de luna (direccional, azulada)
    const luna = Vec3.new(-0.55, 0.42, -0.72).normalize();
    ctx.luces[1] = .{ .tipo = .direccional, .color = Vec3.new(0.3, 0.4, 0.7).scale(0.45), .direccion = vec.rotarY(luna, c, -s) };
    // Reflector del faro (spotlight): gira con el tiempo
    const inclinacion_haz: f32 = 0.75;
    const dir_haz = Vec3.new(
        @cos(vista.angulo_haz) * @cos(inclinacion_haz),
        -@sin(inclinacion_haz),
        @sin(vista.angulo_haz) * @cos(inclinacion_haz),
    );
    ctx.luces[2] = .{
        .tipo = .reflector,
        .color = Vec3.new(1.0, 0.92, 0.7).scale(16.0),
        .posicion = escena.pos_lampara,
        .direccion = dir_haz,
        .cos_interno = @cos(@as(f32, 8.0 * std.math.pi / 180.0)),
        .cos_externo = @cos(@as(f32, 14.0 * std.math.pi / 180.0)),
        .atenuacion = 0.004,
    };
    ctx.idx_reflector = 2;
    // Luz puntual dentro del farol de alabastro del muelle
    ctx.luces[3] = .{
        .tipo = .puntual,
        .color = Vec3.new(1.0, 0.62, 0.3).scale(6.0),
        .posicion = escena.pos_farol,
        .atenuacion = 0.12,
    };
    ctx.num_luces = 4;
    return ctx;
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    rl.SetTraceLogLevel(rl.LOG_WARNING);
    rl.InitWindow(VENTANA_W, VENTANA_H, "Diorama El Faro - Raytracing");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    // --- Carga de recursos y armado de la escena ---
    const bib = try alloc.create(mat.Biblioteca);
    bib.* = try mat.Biblioteca.cargar(alloc);
    const sky = try alloc.create(Skybox);
    sky.* = try Skybox.cargar(alloc);
    sky.intensidad = 1.0;
    const escena = try alloc.create(esc.Escena);
    escena.construir();

    // --- Hilos ---
    const num_cpus = std.Thread.getCpuCount() catch 4;
    const num_hilos = @max(1, @min(MAX_HILOS, num_cpus));
    var hilos_buf: [MAX_HILOS]std.Thread = undefined;
    const hilos = hilos_buf[0..num_hilos];

    // --- Buffers (dimensionados para la resolución máxima) ---
    const max_px = VENTANA_W * VENTANA_H;
    const acumulado = try alloc.alloc(Vec3, max_px);
    @memset(acumulado, Vec3.cero);
    const rgba = try alloc.alloc(u8, max_px * 4);
    @memset(rgba, 0);

    // Resolución: mientras la cámara se mueve se usa la mitad (rápido) y cuando
    // se queda quieta se pasa a resolución completa y se acumulan muestras.
    // Con M se puede dejar fija en media para computadoras más lentas.
    var alta_calidad = true;
    var ancho: usize = VENTANA_W / 2;
    var alto: usize = VENTANA_H / 2;
    const textura_media = crearTextura(VENTANA_W / 2, VENTANA_H / 2);
    const textura_completa = crearTextura(VENTANA_W, VENTANA_H);

    var vista = Vista{};
    var vista_anterior = vista;
    var muestras_gi: u32 = 1;
    var haz_on = true;
    var animar = false; // olas del agua (el haz del faro queda fijo)
    var auto_rotar = false;
    var mostrar_ayuda = true;
    var cuadros_acumulados: u32 = 0;
    var cuadro: u32 = 0;
    var ms_render: f64 = 0;

    // estado del modo video
    var grabando = false;
    var cuadro_video: u32 = 0;
    var rotacion_inicio_video: f32 = 0;

    while (!rl.WindowShouldClose()) {
        const dt = rl.GetFrameTime();
        var reiniciar = false;

        // ---------------- Entrada ----------------
        if (rl.IsKeyPressed(rl.KEY_H)) mostrar_ayuda = !mostrar_ayuda;
        if (rl.IsKeyPressed(rl.KEY_P)) {
            animar = !animar;
            reiniciar = true;
        }
        if (rl.IsKeyPressed(rl.KEY_B)) {
            haz_on = !haz_on;
            reiniciar = true;
        }
        if (rl.IsKeyPressed(rl.KEY_SPACE)) auto_rotar = !auto_rotar;
        if (rl.IsKeyPressed(rl.KEY_G)) {
            muestras_gi = switch (muestras_gi) {
                0 => 1,
                1 => 2,
                2 => 4,
                else => 0,
            };
            reiniciar = true;
        }
        if (rl.IsKeyPressed(rl.KEY_M)) {
            alta_calidad = !alta_calidad;
            reiniciar = true;
        }
        if (rl.IsKeyPressed(rl.KEY_C)) {
            guardarPng(rgba, ancho, alto, "captura.png");
        }
        if (rl.IsKeyPressed(rl.KEY_R)) {
            if (!grabando) {
                _ = rl.MakeDirectory("video_frames");
                grabando = true;
                cuadro_video = 0;
                rotacion_inicio_video = vista.rotacion;
            } else {
                grabando = false;
                reiniciar = true;
            }
        }

        // rotación del diorama (A/D, flechas o arrastrando con el mouse)
        if (rl.IsKeyDown(rl.KEY_A) or rl.IsKeyDown(rl.KEY_LEFT)) vista.rotacion -= 1.2 * dt;
        if (rl.IsKeyDown(rl.KEY_D) or rl.IsKeyDown(rl.KEY_RIGHT)) vista.rotacion += 1.2 * dt;
        if (auto_rotar) vista.rotacion += 0.35 * dt;
        // inclinación de la cámara (W/S, flechas)
        if (rl.IsKeyDown(rl.KEY_W) or rl.IsKeyDown(rl.KEY_UP)) vista.inclinacion += 0.8 * dt;
        if (rl.IsKeyDown(rl.KEY_S) or rl.IsKeyDown(rl.KEY_DOWN)) vista.inclinacion -= 0.8 * dt;
        const arrastrando = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT);
        if (arrastrando) {
            const md = rl.GetMouseDelta();
            vista.rotacion += md.x * 0.008;
            vista.inclinacion += md.y * 0.006;
        }
        vista.inclinacion = @max(0.05, @min(1.45, vista.inclinacion));
        // zoom: rueda del mouse o Q/E
        const rueda = rl.GetMouseWheelMove();
        vista.distancia -= rueda * 3.0;
        if (rl.IsKeyDown(rl.KEY_Q)) vista.distancia -= 25.0 * dt;
        if (rl.IsKeyDown(rl.KEY_E)) vista.distancia += 25.0 * dt;
        vista.distancia = @max(14.0, @min(110.0, vista.distancia));

        if (animar) vista.tiempo += dt;

        // ---------------- Render ----------------
        const inicio = rl.GetTime();
        if (grabando) {
            // Modo video: cada cuadro da una vuelta completa al diorama y
            // se renderiza con varias muestras a resolución completa.
            var v = vista;
            const f: f32 = @floatFromInt(cuadro_video);
            const total: f32 = @floatFromInt(VIDEO_CUADROS);
            v.rotacion = rotacion_inicio_video + 2.0 * std.math.pi * f / total;
            v.tiempo = f / 30.0;
            const ctx = armarContexto(v, escena, bib, sky, @max(1, muestras_gi), haz_on);
            ancho = VENTANA_W;
            alto = VENTANA_H;
            var s: u32 = 0;
            while (s < VIDEO_MUESTRAS) : (s += 1) {
                var tr = Trabajo{
                    .ctx = &ctx,
                    .acumulado = acumulado[0 .. ancho * alto],
                    .rgba = rgba[0 .. ancho * alto * 4],
                    .ancho = ancho,
                    .alto = alto,
                    .peso = 1.0 / @as(f32, @floatFromInt(s + 1)),
                    .semilla = (cuadro_video *% 7919) ^ (s *% 104729) +% 17,
                    .siguiente_fila = std.atomic.Value(u32).init(0),
                };
                renderizarEnParalelo(&tr, hilos);
            }
            var nombre_buf: [64]u8 = undefined;
            const nombre = std.fmt.bufPrintZ(&nombre_buf, "video_frames/frame_{d:0>4}.png", .{cuadro_video}) catch unreachable;
            guardarPng(rgba, ancho, alto, nombre);
            cuadro_video += 1;
            if (cuadro_video >= VIDEO_CUADROS) {
                grabando = false;
                reiniciar = true;
            }
        } else {
            const cambio_vista = vista.rotacion != vista_anterior.rotacion or
                vista.inclinacion != vista_anterior.inclinacion or
                vista.distancia != vista_anterior.distancia;
            const en_movimiento = cambio_vista or arrastrando or auto_rotar;

            // En movimiento: media resolución y sin rebotes (imagen limpia y fluida).
            // Quieto: resolución completa con color bleeding, acumulando muestras.
            const nuevo_ancho: usize = if (en_movimiento or !alta_calidad) VENTANA_W / 2 else VENTANA_W;
            const nuevo_alto: usize = if (en_movimiento or !alta_calidad) VENTANA_H / 2 else VENTANA_H;
            if (nuevo_ancho != ancho) {
                ancho = nuevo_ancho;
                alto = nuevo_alto;
                reiniciar = true;
            }
            if (en_movimiento or reiniciar) cuadros_acumulados = 0;
            const gi_cuadro: u32 = if (en_movimiento) 0 else muestras_gi;

            // Si nada se mueve, promediamos cuadros (la imagen se va limpiando).
            // Si las olas están animadas, mezclamos un poco con el cuadro anterior.
            var peso: f32 = 1.0;
            if (cuadros_acumulados > 0) {
                peso = if (animar) 0.5 else 1.0 / @as(f32, @floatFromInt(cuadros_acumulados + 1));
            }
            const ctx = armarContexto(vista, escena, bib, sky, gi_cuadro, haz_on);
            var tr = Trabajo{
                .ctx = &ctx,
                .acumulado = acumulado[0 .. ancho * alto],
                .rgba = rgba[0 .. ancho * alto * 4],
                .ancho = ancho,
                .alto = alto,
                .peso = peso,
                .semilla = cuadro *% 2246822519 +% 3266489917,
                .siguiente_fila = std.atomic.Value(u32).init(0),
            };
            renderizarEnParalelo(&tr, hilos);
            if (cuadros_acumulados < 100000) cuadros_acumulados += 1;
        }
        ms_render = (rl.GetTime() - inicio) * 1000.0;
        vista_anterior = vista;
        cuadro +%= 1;

        const textura = if (ancho == VENTANA_W) textura_completa else textura_media;
        rl.UpdateTexture(textura, rgba.ptr);

        // ---------------- Dibujo ----------------
        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        const fuente = rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(ancho), .height = @floatFromInt(alto) };
        const destino = rl.Rectangle{ .x = 0, .y = 0, .width = VENTANA_W, .height = VENTANA_H };
        rl.DrawTexturePro(textura, fuente, destino, .{ .x = 0, .y = 0 }, 0, rl.WHITE);

        if (grabando) {
            rl.DrawRectangle(10, 10, 430, 40, rl.Fade(rl.BLACK, 0.7));
            rl.DrawText(rl.TextFormat("Grabando video: cuadro %d / %d  (R para cancelar)", @as(c_int, @intCast(cuadro_video)), @as(c_int, VIDEO_CUADROS)), 20, 22, 16, rl.RAYWHITE);
        } else if (mostrar_ayuda) {
            dibujarAyuda(num_hilos, ms_render, cuadros_acumulados, muestras_gi, haz_on, animar, alta_calidad, auto_rotar);
        }
        rl.EndDrawing();
    }
}

fn crearTextura(w: usize, h: usize) rl.Texture2D {
    const img = rl.GenImageColor(@intCast(w), @intCast(h), rl.BLACK);
    defer rl.UnloadImage(img);
    return rl.LoadTextureFromImage(img);
}

pub fn guardarPng(rgba: []u8, w: usize, h: usize, nombre: [*:0]const u8) void {
    const img = rl.Image{
        .data = @ptrCast(rgba.ptr),
        .width = @intCast(w),
        .height = @intCast(h),
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    };
    _ = rl.ExportImage(img, nombre);
}

fn dibujarAyuda(hilos: usize, ms: f64, acumulados: u32, gi: u32, haz_on: bool, animar: bool, alta: bool, auto_rot: bool) void {
    rl.DrawRectangle(8, 8, 300, 236, rl.Fade(rl.BLACK, 0.6));
    var y: c_int = 16;
    const x: c_int = 16;
    const t = 14;
    rl.DrawText(rl.TextFormat("Hilos: %d   Render: %.0f ms", @as(c_int, @intCast(hilos)), ms), x, y, t, rl.YELLOW);
    y += 18;
    rl.DrawText(rl.TextFormat("Muestras acumuladas: %d", @as(c_int, @intCast(acumulados))), x, y, t, rl.YELLOW);
    y += 24;
    rl.DrawText("A/D o arrastrar: rotar diorama", x, y, t, rl.RAYWHITE);
    y += 18;
    rl.DrawText("W/S: inclinar camara", x, y, t, rl.RAYWHITE);
    y += 18;
    rl.DrawText("Rueda o Q/E: acercar / alejar", x, y, t, rl.RAYWHITE);
    y += 18;
    rl.DrawText(rl.TextFormat("Espacio: rotacion automatica [%s]", onOff(auto_rot)), x, y, t, rl.RAYWHITE);
    y += 18;
    rl.DrawText(rl.TextFormat("P: olas del agua [%s]", onOff(animar)), x, y, t, rl.RAYWHITE);
    y += 18;
    rl.DrawText(rl.TextFormat("B: haz volumetrico [%s]", onOff(haz_on)), x, y, t, rl.RAYWHITE);
    y += 18;
    rl.DrawText(rl.TextFormat("G: muestras de color bleeding [%d]", @as(c_int, @intCast(gi))), x, y, t, rl.RAYWHITE);
    y += 18;
    rl.DrawText(rl.TextFormat("M: resolucion [%s]", @as([*:0]const u8, if (alta) "auto" else "media")), x, y, t, rl.RAYWHITE);
    y += 18;
    rl.DrawText("C: captura   R: grabar video   H: ayuda", x, y, t, rl.RAYWHITE);
}

fn onOff(b: bool) [*:0]const u8 {
    return if (b) "on" else "off";
}
