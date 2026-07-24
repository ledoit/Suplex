/**
 * Thin host: load Zig WASM, feed keyboard, paint Verlet bodies.
 * All match rules + physics stay in suplex.wasm.
 */

const PARTICLE_COUNT = 7;
const P1_HEAD = 0;
const P1_TORSO = 1;
const P1_HIPS = 2;
const P2_HEAD = 3;
const P2_TORSO = 4;
const P2_HIPS = 5;
const GRIP = 6;

const PHASE = { playing: 0, scored: 1, match_over: 2 };

const keys = new Set();

const canvas = document.getElementById("game");
const ctx = canvas.getContext("2d");
const score1El = document.getElementById("score1");
const score2El = document.getElementById("score2");
const winScoreEl = document.getElementById("winScore");
const bannerEl = document.getElementById("banner");
const restartBtn = document.getElementById("restart");

let api;
let state;
let lastBanner = "";
let lastTs = performance.now();

function readParticle(i) {
  const o = 10 + i * 3;
  return { x: state[o], y: state[o + 1], r: state[o + 2] };
}

async function boot() {
  const result = await WebAssembly.instantiateStreaming(fetch("./suplex.wasm"), {
    env: {},
  });
  api = result.instance.exports;
  api.game_init();

  const ptr = api.game_state_ptr();
  const len = api.game_state_len();
  state = new Float32Array(api.memory.buffer, ptr, len);

  restartBtn.addEventListener("click", () => {
    api.game_reset_match();
    hideBanner();
  });

  window.addEventListener("keydown", (e) => {
    keys.add(e.code);
    if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space"].includes(e.code)) {
      e.preventDefault();
    }
    if (e.code === "KeyR") {
      api.game_reset_match();
      hideBanner();
    }
  });
  window.addEventListener("keyup", (e) => keys.delete(e.code));

  requestAnimationFrame(frame);
}

function pushInput() {
  api.game_set_input(
    keys.has("KeyA") ? 1 : 0,
    keys.has("KeyD") ? 1 : 0,
    keys.has("KeyW") ? 1 : 0,
    keys.has("KeyS") ? 1 : 0,
    keys.has("ArrowLeft") ? 1 : 0,
    keys.has("ArrowRight") ? 1 : 0,
    keys.has("ArrowUp") ? 1 : 0,
    keys.has("ArrowDown") ? 1 : 0,
  );
}

function frame(ts) {
  // memory may grow; refresh view if detached
  if (state.buffer.byteLength === 0) {
    const ptr = api.game_state_ptr();
    const len = api.game_state_len();
    state = new Float32Array(api.memory.buffer, ptr, len);
  }

  const dt = Math.min(0.033, (ts - lastTs) / 1000);
  lastTs = ts;

  pushInput();
  api.game_update(dt);
  paint();
  syncHud();
  requestAnimationFrame(frame);
}

function syncHud() {
  const s1 = state[0] | 0;
  const s2 = state[1] | 0;
  const phase = state[2] | 0;
  const scorer = state[4] | 0;
  const win = state[9] | 0;

  score1El.textContent = String(s1);
  score2El.textContent = String(s2);
  winScoreEl.textContent = String(win);

  if (phase === PHASE.scored) {
    const text = scorer === 1 ? "SUPLEX — P1" : "SUPLEX — P2";
    showBanner(text, scorer === 1 ? "p1" : "p2");
  } else if (phase === PHASE.match_over) {
    const text = s1 > s2 ? "CYAN WINS" : "CORAL WINS";
    showBanner(text, "match");
  } else if (state[3] > 0.2 && phase === PHASE.playing) {
    // brief reset beat — keep quiet
  } else {
    hideBanner();
  }
}

function showBanner(text, cls) {
  const key = text + cls;
  if (lastBanner === key) return;
  lastBanner = key;
  bannerEl.textContent = text;
  bannerEl.className = `banner ${cls}`;
}

function hideBanner() {
  lastBanner = "";
  bannerEl.className = "banner hidden";
}

function paint() {
  const W = state[6];
  const H = state[7];
  const floorY = state[8];
  const shake = state[5];

  if (canvas.width !== W || canvas.height !== H) {
    canvas.width = W;
    canvas.height = H;
  }

  const ox = (Math.random() - 0.5) * shake * 10;
  const oy = (Math.random() - 0.5) * shake * 8;

  ctx.save();
  ctx.clearRect(0, 0, W, H);
  ctx.translate(ox, oy);

  // Atmosphere
  const sky = ctx.createLinearGradient(0, 0, 0, H);
  sky.addColorStop(0, "#1c222b");
  sky.addColorStop(1, "#12161c");
  ctx.fillStyle = sky;
  ctx.fillRect(0, 0, W, H);

  // Spotlights
  drawSpot(W * 0.28, -40, "#2ec4b633");
  drawSpot(W * 0.72, -40, "#ff6b4a33");

  // Floor
  ctx.fillStyle = "#252b33";
  ctx.fillRect(0, floorY, W, H - floorY);
  ctx.strokeStyle = "rgba(232,226,214,0.14)";
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(24, floorY);
  ctx.lineTo(W - 24, floorY);
  ctx.stroke();

  // Floor stripe
  ctx.fillStyle = "rgba(46,196,182,0.12)";
  ctx.fillRect(W * 0.5 - 40, floorY, 80, 6);
  ctx.fillStyle = "rgba(255,107,74,0.12)";
  ctx.fillRect(W * 0.5 - 40, floorY + 6, 80, 6);

  const p = [];
  for (let i = 0; i < PARTICLE_COUNT; i++) p.push(readParticle(i));

  // Joints
  drawBone(p[P1_HEAD], p[P1_TORSO], "#2ec4b6", 7);
  drawBone(p[P1_TORSO], p[P1_HIPS], "#2ec4b6", 8);
  drawBone(p[P1_TORSO], p[GRIP], "#1a8f86", 5);
  drawBone(p[P1_HIPS], p[GRIP], "#1a8f86", 4);

  drawBone(p[P2_HEAD], p[P2_TORSO], "#ff6b4a", 7);
  drawBone(p[P2_TORSO], p[P2_HIPS], "#ff6b4a", 8);
  drawBone(p[P2_TORSO], p[GRIP], "#c4452d", 5);
  drawBone(p[P2_HIPS], p[GRIP], "#c4452d", 4);

  // Bodies
  drawOrb(p[P1_HIPS], "#1a8f86");
  drawOrb(p[P1_TORSO], "#2ec4b6");
  drawHead(p[P1_HEAD], "#7ff5ea", "#2ec4b6");

  drawOrb(p[P2_HIPS], "#c4452d");
  drawOrb(p[P2_TORSO], "#ff6b4a");
  drawHead(p[P2_HEAD], "#ffb09e", "#ff6b4a");

  // Shared grip
  ctx.beginPath();
  ctx.arc(p[GRIP].x, p[GRIP].y, p[GRIP].r, 0, Math.PI * 2);
  ctx.fillStyle = "#e8e2d6";
  ctx.fill();
  ctx.strokeStyle = "rgba(18,21,26,0.55)";
  ctx.lineWidth = 2;
  ctx.stroke();

  ctx.restore();
}

function drawSpot(x, y, color) {
  const g = ctx.createRadialGradient(x, y, 10, x, y + 220, 280);
  g.addColorStop(0, color);
  g.addColorStop(1, "transparent");
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, canvas.width, canvas.height);
}

function drawBone(a, b, color, width) {
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  ctx.lineCap = "round";
  ctx.beginPath();
  ctx.moveTo(a.x, a.y);
  ctx.lineTo(b.x, b.y);
  ctx.stroke();
}

function drawOrb(p, color) {
  ctx.beginPath();
  ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
  ctx.fillStyle = color;
  ctx.fill();
}

function drawHead(p, fill, stroke) {
  ctx.beginPath();
  ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
  ctx.fillStyle = fill;
  ctx.fill();
  ctx.strokeStyle = stroke;
  ctx.lineWidth = 3;
  ctx.stroke();

  // Tiny face mark so orientation reads
  ctx.beginPath();
  ctx.arc(p.x, p.y + p.r * 0.15, p.r * 0.28, 0, Math.PI * 2);
  ctx.fillStyle = "rgba(18,21,26,0.22)";
  ctx.fill();
}

boot().catch((err) => {
  console.error(err);
  bannerEl.className = "banner match";
  bannerEl.textContent = "WASM LOAD FAILED";
});
