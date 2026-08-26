import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const packageMetadata = JSON.parse(
  readFileSync(join(projectRoot, "package.json"), "utf8"),
);
const { version, buildNumber } = packageMetadata;

for (const plistName of ["AppInfo.plist", "DevAppInfo.plist"]) {
  const plistPath = join(projectRoot, "Resources", plistName);
  assert.equal(plistValue(plistPath, "CFBundleShortVersionString"), version);
  assert.equal(plistValue(plistPath, "CFBundleVersion"), String(buildNumber));
}

const artifactName = `Lumos-${version}-arm64.dmg`;
const publicURL = `https://lumos.lovstudio.ai/downloads/${artifactName}`;
const readme = readFileSync(join(projectRoot, "README.md"), "utf8");
const changelog = readFileSync(join(projectRoot, "CHANGELOG.md"), "utf8");
const website = readFileSync(join(projectRoot, "site", "index.html"), "utf8");
const releaseNotesPath = join(projectRoot, "docs", "releases", `v${version}.md`);

assert.match(readme, new RegExp(`当前版本：\\*\\*v${escapeRegExp(version)}\\*\\*`));
assert.ok(readme.includes(publicURL), "README download URL must use the current version");
assert.match(changelog, new RegExp(`^## ${escapeRegExp(version)} — `, "m"));
assert.ok(website.includes(`\"softwareVersion\": \"${version}\"`));
assert.ok(website.includes(`/downloads/${artifactName}`));
assert.ok(existsSync(releaseNotesPath), `Missing release notes: ${releaseNotesPath}`);

const releaseNotes = readFileSync(releaseNotesPath, "utf8");
assert.ok(releaseNotes.includes(`# Lumos v${version}`));
assert.ok(releaseNotes.includes(publicURL));

console.log(`Release version ${version} (build ${buildNumber}) is synchronized.`);

function plistValue(path, key) {
  const result = spawnSync(
    "plutil",
    ["-extract", key, "raw", "-o", "-", path],
    { encoding: "utf8" },
  );
  if (result.status !== 0) {
    throw new Error(result.stderr || `Unable to read ${key} from ${path}`);
  }
  return result.stdout.trim();
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
