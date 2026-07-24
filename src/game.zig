//! SUPLEX — Get-On-Top-style joined ragdoll wrestling.
//! Verlet units: velocity is pixels/frame. Keep impulses tiny.

const std = @import("std");

const WORLD_W: f32 = 960;
const WORLD_H: f32 = 540;
const FLOOR_Y: f32 = 500;
const GRAVITY: f32 = 0.42; // px/frame² at 60fps (≈1500 px/s²)
const DRAG: f32 = 0.97;
const MAX_SPEED: f32 = 11; // px/frame ≈ 660 px/s hard cap
const WIN_SCORE: i32 = 11;
const CONSTRAINT_ITERS: usize = 8;
const SCORE_PAUSE: f32 = 1.2;
const RESET_PAUSE: f32 = 0.55;
const PIN_HOLD: f32 = 0.28;
const SUBSTEPS: usize = 2;

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

const P1_HEAD: usize = 0;
const P1_TORSO: usize = 1;
const P1_HIPS: usize = 2;
const P2_HEAD: usize = 3;
const P2_TORSO: usize = 4;
const P2_HIPS: usize = 5;
const GRIP: usize = 6;
const PARTICLE_COUNT: usize = 7;

var particles: [PARTICLE_COUNT]Particle = undefined;
var constraints: [10]Constraint = undefined;
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
    const floor = FLOOR_Y;

    // Compact stance, feet near the mat — Get-On-Top energy.
    setParticle(P1_HEAD, cx - 70, floor - 108, 16, 1.0);
    setParticle(P1_TORSO, cx - 55, floor - 68, 15, 2.2);
    setParticle(P1_HIPS, cx - 48, floor - 28, 14, 2.0);

    setParticle(P2_HEAD, cx + 70, floor - 108, 16, 1.0);
    setParticle(P2_TORSO, cx + 55, floor - 68, 15, 2.2);
    setParticle(P2_HIPS, cx + 48, floor - 28, 14, 2.0);

    setParticle(GRIP, cx, floor - 72, 10, 1.2);

    // Moderate stiffness — 1.0 + over-iteration was detonating the chain.
    addConstraint(P1_HEAD, P1_TORSO, 0.7);
    addConstraint(P1_TORSO, P1_HIPS, 0.7);
    addConstraint(P1_HEAD, P1_HIPS, 0.35);
    addConstraint(P1_TORSO, GRIP, 0.55);
    addConstraint(P1_HIPS, GRIP, 0.25);

    addConstraint(P2_HEAD, P2_TORSO, 0.7);
    addConstraint(P2_TORSO, P2_HIPS, 0.7);
    addConstraint(P2_HEAD, P2_HIPS, 0.35);
    addConstraint(P2_TORSO, GRIP, 0.55);
    addConstraint(P2_HIPS, GRIP, 0.25);

    p1_pin_timer = 0;
    p2_pin_timer = 0;
    p1_up_prev = false;
    p2_up_prev = false;
}

fn hipsGrounded(hips: usize) bool {
    return particles[hips].y + particles[hips].r > FLOOR_Y - 6;
}

/// Impulse in px/frame. y+ is down, so negative = jump up.
fn addVelocity(i: usize, dvx: f32, dvy: f32) void {
    // v = pos - prev  ⇒  prev' = prev - dv  so v' = v + dv
    particles[i].px -= dvx;
    particles[i].py -= dvy;
}

fn applyInput(torso: usize, head: usize, hips: usize, input: Input, up_prev: *bool) void {
    // Accelerations in px/frame² — small on purpose.
    const push: f32 = 0.55;
    const lean: f32 = 0.40;
    const crouch: f32 = 0.45;
    const hold_up: f32 = 0.25;
    const jump_impulse: f32 = -7.5; // upward

    if (input.left) {
        addVelocity(torso, -push, 0);
        addVelocity(head, -lean, 0);
        addVelocity(hips, -push * 0.35, 0);
        addVelocity(GRIP, -push * 0.15, 0);
    }
    if (input.right) {
        addVelocity(torso, push, 0);
        addVelocity(head, lean, 0);
        addVelocity(hips, push * 0.35, 0);
        addVelocity(GRIP, push * 0.15, 0);
    }

    const jump_pressed = input.up and !up_prev.*;
    if (jump_pressed and hipsGrounded(hips)) {
        addVelocity(hips, 0, jump_impulse);
        addVelocity(torso, 0, jump_impulse * 0.75);
        addVelocity(head, 0, jump_impulse * 0.35);
        addVelocity(GRIP, 0, jump_impulse * 0.4);
    } else if (input.up) {
        addVelocity(torso, 0, -hold_up);
        addVelocity(head, 0, -hold_up * 1.1);
    }
    up_prev.* = input.up;

    if (input.down) {
        addVelocity(torso, 0, crouch);
        addVelocity(hips, 0, crouch * 0.4);
        addVelocity(GRIP, 0, crouch * 0.7);
        // Slight head tuck without planting yourself.
        addVelocity(head, 0, crouch * 0.15);
    }
}

fn clampSpeed(p: *Particle) void {
    var vx = p.x - p.px;
    var vy = p.y - p.py;
    const sp = @sqrt(vx * vx + vy * vy);
    if (sp > MAX_SPEED) {
        const s = MAX_SPEED / sp;
        vx *= s;
        vy *= s;
        p.px = p.x - vx;
        p.py = p.y - vy;
    }
}

fn integrate() void {
    for (&particles) |*p| {
        if (p.inv_mass == 0) continue;
        clampSpeed(p);
        const vx = (p.x - p.px) * DRAG;
        const vy = (p.y - p.py) * DRAG;
        p.px = p.x;
        p.py = p.y;
        p.x += vx;
        // Gravity once per substep, scaled so 2 substeps ≈ one frame of g.
        p.y += vy + GRAVITY / @as(f32, SUBSTEPS);
        clampSpeed(p);
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

        separate(P1_HEAD, P2_HEAD, 0.6);
        separate(P1_TORSO, P2_TORSO, 0.45);
        separate(P1_HIPS, P2_HIPS, 0.45);
        separate(P1_HEAD, P2_TORSO, 0.4);
        separate(P2_HEAD, P1_TORSO, 0.4);
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
            // Kill downward velocity; keep a little bounce-free slide.
            if (p.py < p.y) p.py = p.y;
            p.px = p.x - (p.x - p.px) * 0.65;
        }
        if (p.x - p.r < 40) {
            p.x = 40 + p.r;
            if (p.px > p.x) p.px = p.x;
        }
        if (p.x + p.r > WORLD_W - 40) {
            p.x = WORLD_W - 40 - p.r;
            if (p.px < p.x) p.px = p.x;
        }
        if (p.y - p.r < 40) {
            p.y = 40 + p.r;
            if (p.py > p.y) p.py = p.y;
        }
    }
}

fn headOnFloor(head: usize) bool {
    return particles[head].y + particles[head].r >= FLOOR_Y - 0.5;
}

fn awardPoint(scorer: i32) void {
    if (phase != .playing) return;
    if (scorer == 1) p1_score += 1 else p2_score += 1;
    last_scorer = scorer;
    shake = 0.85;
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

fn simulateFrame() void {
    applyInput(P1_TORSO, P1_HEAD, P1_HIPS, p1_input, &p1_up_prev);
    applyInput(P2_TORSO, P2_HEAD, P2_HIPS, p2_input, &p2_up_prev);

    var s: usize = 0;
    while (s < SUBSTEPS) : (s += 1) {
        integrate();
        satisfyConstraints();
        collideWorld();
    }

    for (&particles) |*p| clampSpeed(p);
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
    _ = dt_raw; // fixed 60Hz feel; host still calls once per frame
    shake = @max(0, shake - 0.04);

    switch (phase) {
        .match_over => {
            writeState();
            return;
        },
        .scored => {
            phase_timer -= 1.0 / 60.0;
            integrate();
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
                phase_timer -= 1.0 / 60.0;
                writeState();
                return;
            }
        },
    }

    simulateFrame();

    const p1_down = headOnFloor(P1_HEAD);
    const p2_down = headOnFloor(P2_HEAD);
    // On top ≈ your hips clearly higher than their head (smaller y).
    const p2_on_top = particles[P2_HIPS].y + 20 < particles[P1_HEAD].y;
    const p1_on_top = particles[P1_HIPS].y + 20 < particles[P2_HEAD].y;

    if (p1_down and p2_on_top) p1_pin_timer += 1.0 / 60.0 else p1_pin_timer = 0;
    if (p2_down and p1_on_top) p2_pin_timer += 1.0 / 60.0 else p2_pin_timer = 0;

    if (p1_pin_timer >= PIN_HOLD and p2_pin_timer >= PIN_HOLD) {
        spawnFighters();
        phase_timer = RESET_PAUSE;
    } else if (p1_pin_timer >= PIN_HOLD) {
        awardPoint(2);
    } else if (p2_pin_timer >= PIN_HOLD) {
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
