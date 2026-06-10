import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)));
const source = resolve(root, "src/runtime.ts");
const output = resolve(root, "dist/runtime.mjs");
const text = await readFile(source, "utf8");

await mkdir(dirname(output), { recursive: true });
await writeFile(
  output,
  text.replace(/^\/\/ @ts-check\n?/, "// Generated from src/runtime.ts\n"),
);

const check = spawnSync(process.execPath, ["--check", output], {
  encoding: "utf8",
});

if (check.status !== 0) {
  process.stderr.write(check.stderr || check.stdout);
  process.exit(check.status ?? 1);
}

console.log(`Built ${output}`);
