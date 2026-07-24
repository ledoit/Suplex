#!/usr/bin/env bun
import { $ } from "bun";
import { copyFileSync, existsSync } from "fs";
import { homedir } from "os";
import { join } from "path";

function findZig(): string {
  const env = process.env.ZIG;
  if (env && existsSync(env)) return env;

  const candidates = [
    join(homedir(), ".zig/zig-x86_64-windows-0.17.0-dev.56+a8226cd53/zig.exe"),
    join(homedir(), ".zig/zig-x86_64-windows-0.17.0-dev.56+a8226cd53/zig"),
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  return "zig";
}

const zig = findZig();
const release = process.argv.includes("--debug") ? [] : ["--release=fast"];
console.log(`building SUPLEX with ${zig}`);
await $`${zig} build wasm ${release}`;

const built = "zig-out/web/suplex.wasm";
if (!existsSync(built)) {
  throw new Error(`missing ${built}`);
}
copyFileSync(built, "web/suplex.wasm");
console.log("synced web/suplex.wasm");
