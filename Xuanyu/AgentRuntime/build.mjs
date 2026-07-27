import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)));
const sourceDir = resolve(root, "src");
const distDir = resolve(root, "dist");
const resourceDir = resolve(root, "../Sources/Xuanyu/Resources/AgentRuntime");

const sources = (await readdir(sourceDir)).filter((name) => name.endsWith(".ts")).sort();

await mkdir(distDir, { recursive: true });
await mkdir(resourceDir, { recursive: true });

const built = [];
for (const name of sources) {
  const text = await readFile(resolve(sourceDir, name), "utf8");
  const generated = text
    .replace(/^\/\/ @ts-check\n?/, `// Generated from src/${name}\n`)
    // 运行时加载的是同目录下的 .mjs 兄弟模块，import 说明符要跟着改。
    .replace(/(\bfrom\s+["']\.\/[^"']+)\.ts(["'])/g, "$1.mjs$2");
  const outputName = name.replace(/\.ts$/, ".mjs");
  await writeFile(resolve(distDir, outputName), generated);
  await writeFile(resolve(resourceDir, outputName), generated);
  built.push(outputName);
}

const check = spawnSync(process.execPath, ["--check", resolve(distDir, "runtime.mjs")], {
  encoding: "utf8",
});

if (check.status !== 0) {
  process.stderr.write(check.stderr || check.stdout);
  process.exit(check.status ?? 1);
}

console.log(`Built ${built.join(", ")} -> ${distDir}`);
console.log(`Synced ${resourceDir}`);
