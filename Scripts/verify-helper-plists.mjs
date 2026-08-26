import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const resources = join(projectRoot, "Resources");
const configurations = [
  {
    hostBundleIdentifier: "ai.lovstudio.lumos",
    machServiceName: "ai.lovstudio.lumos.power-helper",
  },
  {
    hostBundleIdentifier: "ai.lovstudio.lumos.dev",
    machServiceName: "ai.lovstudio.lumos.dev.power-helper",
  },
];

const seenServiceNames = new Set();
for (const configuration of configurations) {
  const plistName = `${configuration.machServiceName}.plist`;
  const plistPath = join(resources, plistName);
  const plist = readPlist(plistPath);

  assert(plist.Label === configuration.machServiceName, `${plistName}: Label mismatch`);
  assert(
    plist.BundleProgram === "Contents/Resources/LumosPrivilegedHelper",
    `${plistName}: BundleProgram mismatch`,
  );
  assert(
    JSON.stringify(plist.ProgramArguments) ===
      JSON.stringify([
        "Contents/Resources/LumosPrivilegedHelper",
        "--mach-service-name",
        configuration.machServiceName,
      ]),
    `${plistName}: ProgramArguments mismatch`,
  );
  assert(
    JSON.stringify(Object.keys(plist.MachServices || {})) ===
      JSON.stringify([configuration.machServiceName]) &&
      plist.MachServices[configuration.machServiceName] === true,
    `${plistName}: MachServices mismatch`,
  );
  assert(
    JSON.stringify(plist.AssociatedBundleIdentifiers) ===
      JSON.stringify([configuration.hostBundleIdentifier]),
    `${plistName}: helper must belong to exactly one host app`,
  );
  assert(
    !seenServiceNames.has(configuration.machServiceName),
    `${plistName}: duplicate helper service name`,
  );
  seenServiceNames.add(configuration.machServiceName);
}

assert(
  !existsSync(join(resources, "ai.lovstudio.lumos.privileged-helper.plist")),
  "legacy shared helper plist must not be packaged",
);

console.log("Privileged helper plists isolate production and development hosts.");

function readPlist(path) {
  const result = spawnSync("plutil", ["-convert", "json", "-o", "-", path], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`Unable to parse ${path}: ${(result.stderr || "").trim()}`);
  }
  return JSON.parse(result.stdout);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
