//! SUPLEX — Get-On-Top-style joined ragdoll wrestling.
//! Physics + match rules live in Zig; the browser only paints and feeds keys.

const std = @import("std");

const WORLD_W: f32 = 960;
const WORLD_H: f32 = 540;
const FLOOR_Y: f32 = 500;
const GRAVITY: f32 = 1380;
const DRAG: f32 = 0.984;
const WIN_SCORE: i32 = 11;
const CONSTRAINT_ITERS: usize = 18;
const SCORE_PAUSE: f32 = 1.25;
const RESET_PAUSE: f32 = 0.7;
const PIN_HOLD: f32 = 0.3;

const Particle = struct {
    x: f32,
    y: f32,
    px: f32,
    py: f32,
    r: f32,
    inv_mass: f32,
};

const Constraint = struct {
    a: usize,
    b: usize,
    rest: f32,
    stiffness: f32,
};

const Phase = enum(u32) {
    playing = 0,
    scored = 1,
    match_over = 2,
};

const Input = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
};

// Particle indices
const P1_HEAD: usize = 0;
const P1_TORSO: usize = 1;
const P1_HIPS: usize = 2;
const P2_HEAD: usize = 3;
const P2_TORSO: usize = 4;
const P2_HIPS: usize = 5;
const GRIP: usize = 6;
const PARTICLE_COUNT: usize = 7;

var particles: [PARTICLE_COUNT]Particle = undefined;
var constraints: [12]Constraint = undefined;
var constraint_count: usize = 0;

var p1_input: Input = .{};
var p2_input: Input = .{};
var p1_up_prev: bool = false;
var p2_up_prev: bool = false;
var p1_score: i32 = 0;
var p2_score: i32 = 0;
var phase: Phase = .playing;
var phase_timer: f32 = 0;
var last_scorer: i32 = 0;
var shake: f32 = 0;
var p1_pin_timer: f32 = 0;
var p2_pin_timer: f32 = 0;

/// Flat snapshot for JS
var state_buf: [48]f32 = undefined;

fn setParticle(i: usize, x: f32, y: f32, r: f32, mass: f32) void {
    particles[i] = .{
        .x = x,
        .y = y,
        .px = x,
        .py = y,
        .r = r,
        .inv_mass = if (mass <= 0) 0 else 1 / mass,
    };
}

fn addConstraint(a: usize, b: usize, stiffness: f32) void {
    const dx = particles[a].x - particles[b].x;
    const dy = particles[a].y - particles[b].y;
    constraints[constraint_count] = .{
        .a = a,
        .b = b,
        .rest = @sqrt(dx * dx + dy * dy),
        .stiffness = stiffness,
    };
    constraint_count += 1;
}

fn spawnFighters() void {
    constraint_count = 0;
    const cx = WORLD_W * 0.5;
    const base = FLOOR_Y - 58;

    // Tall stance — room to lean before anyone kisses the mat.
    setParticle(P1_HEAD, cx - 86, base - 142, 16, 0.9);
    setParticle(P1_TORSO, cx - 68, base - 94, 15, 2.05);
    setParticle(P1_HIPS, cx - 60, base - 40, 14, 1.95);

    setParticle(P2_HEAD, cx + 86, base - 142, 16, 0.9);
    setParticle(P2_TORSO, cx + 68, base - 94, 15, 2.05);
    setParticle(P2_HIPS, cx + 60, base - 40, 14, 1.95);

    setParticle(GRIP, cx, base - 100, 10, 0.7);

    addConstraint(P1_HEAD, P1_TORSO, 1.0);
    addConstraint(P1_TORSO, P1_HIPS, 1.0);
    addConstraint(P1_HEAD, P1_HIPS, 0.82);
    addConstraint(P1_TORSO, GRIP, 0.75);
    addConstraint(P1_HIPS, GRIP, 0.3);
    addConstraint(P1_HEAD, GRIP, 0.16);

    addConstraint(P2_HEAD, P2_TORSO, 1.0);
    addConstraint(P2_TORSO, P2_HIPS, 1.0);
    addConstraint(P2_HEAD, P2_HIPS, 0.82);
    addConstraint(P2_TORSO, GRIP, 0.75);
    addConstraint(P2_HIPS, GRIP, 0.3);
    addConstraint(P2_HEAD, GRIP, 0.16);

    p1_pin_timer = 0;
    p2_pin_timer = 0;
    p1_up_prev = false;
    p2_up_prev = false;
}

fn hipsGrounded(hips: usize) bool {
    return particles[hips].y + particles[hips].r > FLOOR_Y - 10;
}

/// Soft anti-pancake: keep head above torso above hips when possible.
fn postureAssist(head: usize, torso: usize, hips: usize, dt: f32) void {
    const k: f32 = 900 * dt;
    if (particles[head].y > particles[torso].y - 18) {
        particles[head].y -= k * 0.55 * particles[head].inv_mass;
        particles[torso].y += k * 0.2 * particles[torso].inv_mass;
    }
    if (particles[torso].y > particles[hips].y - 22) {
        particles[torso].y -= k * 0.4 * particles[torso].inv_mass;
        particles[hips].y += k * 0.15 * particles[hips].inv_mass;
    }
}

fn applyInput(torso: usize, head: usize, hips: usize, input: Input, up_prev: *bool, dt: f32) void {
    const push: f32 = 1950 * dt;
    const lean: f32 = 1250 * dt;
    const jump: f32 = 600;
    const crouch: f32 = 1350 * dt;
    const lift: f32 = 800 * dt;

    if (input.left) {
        particles[torso].x -= push * particles[torso].inv_mass;
        particles[head].x -= lean * particles[head].inv_mass;
        particles[hips].x -= push * 0.35 * particles[hips].inv_mass;
        particles[GRIP].x -= push * 0.14 * particles[GRIP].inv_mass;
    }
    if (input.right) {
        particles[torso].x += push * particles[torso].inv_mass;
        particles[head].x += lean * particles[head].inv_mass;
        particles[hips].x += push * 0.35 * particles[hips].inv_mass;
        particles[GRIP].x += push * 0.14 * particles[GRIP].inv_mass;
    }

    // Jump is edge-triggered — holding W used to rocket every frame.
    const jump_pressed = input.up and !up_prev.*;
    if (jump_pressed and hipsGrounded(hips)) {
        particles[hips].py += jump;
        particles[torso].py += jump * 0.7;
        particles[head].py += jump * 0.28;
        particles[GRIP].py += jump * 0.35;
    } else if (input.up) {
        particles[torso].y -= lift * 0.45 * particles[torso].inv_mass;
        particles[head].y -= lift * 0.55 * particles[head].inv_mass;
    }
    up_prev.* = input.up;

    if (input.down) {
        // Crush the opponent via grip/torso — don't drive your own head into the mat.
        particles[torso].y += crouch * particles[torso].inv_mass;
        particles[hips].y += crouch * 0.35 * particles[hips].inv_mass;
        particles[GRIP].y += crouch * 0.55 * particles[GRIP].inv_mass;
    }
}

fn integrate(dt: f32) void {
    for (&particles) |*p| {
        if (p.inv_mass == 0) continue;
        const vx = (p.x - p.px) * DRAG;
        const vy = (p.y - p.py) * DRAG;
        p.px = p.x;
        p.py = p.y;
        p.x += vx;
        p.y += vy + GRAVITY * dt * dt;
    }
}

fn satisfyConstraints() void {
    var iter: usize = 0;
    while (iter < CONSTRAINT_ITERS) : (iter += 1) {
        for (constraints[0..constraint_count]) |c| {
            var a = &particles[c.a];
            var b = &particles[c.b];
            var dx = b.x - a.x;
            var dy = b.y - a.y;
            var dist = @sqrt(dx * dx + dy * dy);
            if (dist < 0.0001) {
                dx = 0.01;
                dy = 0;
                dist = 0.01;
            }
            const diff = (dist - c.rest) / dist;
            const inv = a.inv_mass + b.inv_mass;
            if (inv == 0) continue;
            const corr = diff * c.stiffness;
            const ax = dx * corr * (a.inv_mass / inv);
            const ay = dy * corr * (a.inv_mass / inv);
            const bx = dx * corr * (b.inv_mass / inv);
            const by = dy * corr * (b.inv_mass / inv);
            a.x += ax;
            a.y += ay;
            b.x -= bx;
            b.y -= by;
        }

        separate(P1_HEAD, P2_HEAD, 0.85);
        separate(P1_TORSO, P2_TORSO, 0.55);
        separate(P1_HIPS, P2_HIPS, 0.55);
        separate(P1_HEAD, P2_TORSO, 0.5);
        separate(P2_HEAD, P1_TORSO, 0.5);
        separate(P1_HEAD, P2_HIPS, 0.4);
        separate(P2_HEAD, P1_HIPS, 0.4);
    }
}

fn separate(i: usize, j: usize, strength: f32) void {
    var a = &particles[i];
    var b = &particles[j];
    var dx = b.x - a.x;
    var dy = b.y - a.y;
    var dist = @sqrt(dx * dx + dy * dy);
    const min_dist = a.r + b.r;
    if (dist < 0.0001) {
        dx = 1;
        dy = 0;
        dist = 1;
    }
    if (dist >= min_dist) return;
    const inv = a.inv_mass + b.inv_mass;
    if (inv == 0) return;
    const overlap = (min_dist - dist) * strength;
    const nx = dx / dist;
    const ny = dy / dist;
    a.x -= nx * overlap * (a.inv_mass / inv);
    a.y -= ny * overlap * (a.inv_mass / inv);
    b.x += nx * overlap * (b.inv_mass / inv);
    b.y += ny * overlap * (b.inv_mass / inv);
}

fn collideWorld() void {
    for (&particles) |*p| {
        if (p.y + p.r > FLOOR_Y) {
            p.y = FLOOR_Y - p.r;
            if (p.py > p.y) p.py = p.y + (p.py - p.y) * 0.15;
            // More floor friction so pins stick and slides feel heavy.
            p.px = p.x - (p.x - p.px) * 0.55;
        }
        if (p.x - p.r < 28) {
            p.x = 28 + p.r;
            p.px = p.x + (p.x - p.px) * 0.35;
        }
        if (p.x + p.r > WORLD_W - 28) {
            p.x = WORLD_W - 28 - p.r;
            p.px = p.x + (p.x - p.px) * 0.35;
        }
        if (p.y - p.r < 24) {
            p.y = 24 + p.r;
            p.py = p.y - (p.py - p.y) * 0.25;
        }
    }
}

fn headOnFloor(head: usize) bool {
    // Need a real mat kiss — grazes don't count.
    return particles[head].y + particles[head].r >= FLOOR_Y - 0.25;
}

fn awardPoint(scorer: i32) void {
    if (phase != .playing) return;
    if (scorer == 1) p1_score += 1 else p2_score += 1;
    last_scorer = scorer;
    shake = 1;
    p1_pin_timer = 0;
    p2_pin_timer = 0;
    if (p1_score >= WIN_SCORE or p2_score >= WIN_SCORE) {
        phase = .match_over;
        phase_timer = 0;
    } else {
        phase = .scored;
        phase_timer = SCORE_PAUSE;
    }
}

fn writeState() void {
    state_buf[0] = @floatFromInt(p1_score);
    state_buf[1] = @floatFromInt(p2_score);
    state_buf[2] = @floatFromInt(@intFromEnum(phase));
    state_buf[3] = phase_timer;
    state_buf[4] = @floatFromInt(last_scorer);
    state_buf[5] = shake;
    state_buf[6] = WORLD_W;
    state_buf[7] = WORLD_H;
    state_buf[8] = FLOOR_Y;
    state_buf[9] = @floatFromInt(WIN_SCORE);

    var i: usize = 0;
    while (i < PARTICLE_COUNT) : (i += 1) {
        const o = 10 + i * 3;
        state_buf[o] = particles[i].x;
        state_buf[o + 1] = particles[i].y;
        state_buf[o + 2] = particles[i].r;
    }
}

export fn game_init() void {
    p1_score = 0;
    p2_score = 0;
    phase = .playing;
    phase_timer = 0;
    last_scorer = 0;
    shake = 0;
    p1_input = .{};
    p2_input = .{};
    spawnFighters();
    writeState();
}

export fn game_reset_match() void {
    game_init();
}

export fn game_set_input(
    p1_left: u32,
    p1_right: u32,
    p1_up: u32,
    p1_down: u32,
    p2_left: u32,
    p2_right: u32,
    p2_up: u32,
    p2_down: u32,
) void {
    p1_input = .{
        .left = p1_left != 0,
        .right = p1_right != 0,
        .up = p1_up != 0,
        .down = p1_down != 0,
    };
    p2_input = .{
        .left = p2_left != 0,
        .right = p2_right != 0,
        .up = p2_up != 0,
        .down = p2_down != 0,
    };
}

export fn game_update(dt_raw: f32) void {
    var dt = dt_raw;
    if (dt > 0.033) dt = 0.033;
    if (dt < 0) dt = 0;

    shake = @max(0, shake - dt * 2.2);

    switch (phase) {
        .match_over => {
            writeState();
            return;
        },
        .scored => {
            phase_timer -= dt;
            integrate(dt * 0.3);
            satisfyConstraints();
            collideWorld();
            if (phase_timer <= 0) {
                spawnFighters();
                phase = .playing;
                phase_timer = RESET_PAUSE;
            }
            writeState();
            return;
        },
        .playing => {
            if (phase_timer > 0) {
                phase_timer -= dt;
                writeState();
                return;
            }
        },
    }

    applyInput(P1_TORSO, P1_HEAD, P1_HIPS, p1_input, &p1_up_prev, dt);
    applyInput(P2_TORSO, P2_HEAD, P2_HIPS, p2_input, &p2_up_prev, dt);
    // Posture assist only when not actively crushing downward.
    if (!p1_input.down) postureAssist(P1_HEAD, P1_TORSO, P1_HIPS, dt);
    if (!p2_input.down) postureAssist(P2_HEAD, P2_TORSO, P2_HIPS, dt);
    integrate(dt);
    satisfyConstraints();
    collideWorld();

    const p1_down = headOnFloor(P1_HEAD);
    const p2_down = headOnFloor(P2_HEAD);
    // Scorer must be structurally higher (torso above pinned head).
    const p2_on_top = particles[P2_TORSO].y + 12 < particles[P1_HEAD].y;
    const p1_on_top = particles[P1_TORSO].y + 12 < particles[P2_HEAD].y;

    if (p1_down and p2_on_top) p1_pin_timer += dt else p1_pin_timer = 0;
    if (p2_down and p1_on_top) p2_pin_timer += dt else p2_pin_timer = 0;

    const p1_pinned = p1_pin_timer >= PIN_HOLD;
    const p2_pinned = p2_pin_timer >= PIN_HOLD;

    if (p1_pinned and p2_pinned) {
        spawnFighters();
        phase_timer = RESET_PAUSE;
    } else if (p1_pinned) {
        awardPoint(2);
    } else if (p2_pinned) {
        awardPoint(1);
    }

    writeState();
}

export fn game_state_ptr() [*]f32 {
    return &state_buf;
}

export fn game_state_len() u32 {
    return state_buf.len;
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    while (true) {}
}
