import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = dirname(scriptDirectory);
const packageMetadata = JSON.parse(
  readFileSync(join(projectRoot, "package.json"), "utf8"),
);
const version = packageMetadata.version;
const buildNumber = String(packageMetadata.buildNumber);
const shouldNotarize = process.argv.includes("--notarize");

if (!/^0\.[0-9]+\.[0-9]+$/.test(version)) {
  throw new Error(`Expected a pre-1.0 semantic version, received ${version}.`);
}
if (!/^[1-9][0-9]*$/.test(buildNumber)) {
  throw new Error(`Expected a positive buildNumber, received ${buildNumber}.`);
}

const releaseRoot = join(projectRoot, "dist", `v${version}`);
const appPath = join(releaseRoot, "Lumos.app");
const appZipPath = join(releaseRoot, `Lumos-${version}-arm64.zip`);
const dmgName = `Lumos-${version}-arm64.dmg`;
const dmgPath = join(releaseRoot, dmgName);
const checksumPath = `${dmgPath}.sha256`;
const dmgRoot = join(releaseRoot, "dmg-root");
const iconPath = join(releaseRoot, "AppIcon.icns");
const signingIdentity = resolveSigningIdentity();

rmSync(releaseRoot, { recursive: true, force: true });
mkdirSync(releaseRoot, { recursive: true });

run("swift", ["build", "-c", "release", "--product", "lumos-app"]);
run("swift", ["build", "-c", "release", "--product", "lumos-privileged-helper"]);
generateIcon(iconPath);
assembleApplication();
signApplication();
verifyApplicationSignature();
createApplicationArchive();

if (shouldNotarize) {
  submitForNotarization(appZipPath, "application");
  run("xcrun", ["stapler", "staple", appPath]);
  run("xcrun", ["stapler", "validate", appPath]);
}

createDiskImage();
run("codesign", ["--force", "--timestamp", "--sign", signingIdentity, dmgPath]);

if (shouldNotarize) {
  submitForNotarization(dmgPath, "disk image");
  run("xcrun", ["stapler", "staple", dmgPath]);
  run("xcrun", ["stapler", "validate", dmgPath]);
}

const checksum = sha256(dmgPath);
writeFileSync(checksumPath, `${checksum}  ${dmgName}\n`);
publishWebsiteDownload(dmgPath, checksumPath);
writeReleaseMetadata(checksum);

console.log(`\nLumos v${version} release artifact ready:`);
console.log(`  app: ${appPath}`);
console.log(`  dmg: ${dmgPath}`);
console.log(`  sha256: ${checksum}`);
console.log(`  notarized: ${shouldNotarize ? "yes" : "no"}`);

function assembleApplication() {
  const contents = join(appPath, "Contents");
  const macOS = join(contents, "MacOS");
  const resources = join(contents, "Resources");
  const daemons = join(contents, "Library", "LaunchDaemons");
  mkdirSync(macOS, { recursive: true });
  mkdirSync(resources, { recursive: true });
  mkdirSync(daemons, { recursive: true });

  const infoPlist = join(contents, "Info.plist");
  copyFileSync(join(projectRoot, "Resources", "AppInfo.plist"), infoPlist);
  run("plutil", ["-replace", "CFBundleShortVersionString", "-string", version, infoPlist]);
  run("plutil", ["-replace", "CFBundleVersion", "-string", buildNumber, infoPlist]);

  copyFileSync(join(projectRoot, ".build", "release", "lumos-app"), join(macOS, "Lumos"));
  copyFileSync(
    join(projectRoot, ".build", "release", "lumos-privileged-helper"),
    join(resources, "LumosPrivilegedHelper"),
  );
  copyFileSync(
    join(projectRoot, "Resources", "ai.lovstudio.lumos.privileged-helper.plist"),
    join(daemons, "ai.lovstudio.lumos.privileged-helper.plist"),
  );
  copyFileSync(iconPath, join(resources, "AppIcon.icns"));
}

function signApplication() {
  const helperPath = join(appPath, "Contents", "Resources", "LumosPrivilegedHelper");
  run("codesign", [
    "--force",
    "--timestamp",
    "--options",
    "runtime",
    "--identifier",
    "ai.lovstudio.lumos.privileged-helper",
    "--sign",
    signingIdentity,
    helperPath,
  ]);
  run("codesign", [
    "--force",
    "--timestamp",
    "--options",
    "runtime",
    "--sign",
    signingIdentity,
    appPath,
  ]);
}

function verifyApplicationSignature() {
  run("codesign", ["--verify", "--deep", "--strict", "--verbose=2", appPath]);
  run("codesign", ["--display", "--verbose=4", appPath]);
}

function createApplicationArchive() {
  rmSync(appZipPath, { force: true });
  run("ditto", [
    "-c",
    "-k",
    "--sequesterRsrc",
    "--keepParent",
    appPath,
    appZipPath,
  ]);
}

function createDiskImage() {
  rmSync(dmgRoot, { recursive: true, force: true });
  rmSync(dmgPath, { force: true });
  mkdirSync(dmgRoot, { recursive: true });
  run("ditto", [appPath, join(dmgRoot, "Lumos.app")]);
  symlinkSync("/Applications", join(dmgRoot, "Applications"));
  run("hdiutil", [
    "create",
    "-volname",
    "Lumos",
    "-srcfolder",
    dmgRoot,
    "-ov",
    "-format",
    "UDZO",
    dmgPath,
  ]);
  rmSync(dmgRoot, { recursive: true, force: true });
}

function generateIcon(outputPath) {
  const source = join(projectRoot, "site", "assets", "lumos-icon.svg");
  const iconset = join(releaseRoot, "AppIcon.iconset");
  const master = join(releaseRoot, "AppIcon-1024.png");
  mkdirSync(iconset, { recursive: true });

  const directConversion = tryRun("sips", [
    "-s",
    "format",
    "png",
    source,
    "--out",
    master,
  ]);
  if (!directConversion || !existsSync(master)) {
    const previewDirectory = join(releaseRoot, "icon-preview");
    mkdirSync(previewDirectory, { recursive: true });
    run("qlmanage", ["-t", "-s", "1024", "-o", previewDirectory, source]);
    const preview = join(previewDirectory, "lumos-icon.svg.png");
    if (!existsSync(preview)) throw new Error("Unable to render the Lumos app icon.");
    copyFileSync(preview, master);
  }

  const variants = [
    [16, "icon_16x16.png"],
    [32, "icon_16x16@2x.png"],
    [32, "icon_32x32.png"],
    [64, "icon_32x32@2x.png"],
    [128, "icon_128x128.png"],
    [256, "icon_128x128@2x.png"],
    [256, "icon_256x256.png"],
    [512, "icon_256x256@2x.png"],
    [512, "icon_512x512.png"],
    [1024, "icon_512x512@2x.png"],
  ];
  for (const [size, name] of variants) {
    run("sips", [
      "-z",
      String(size),
      String(size),
      master,
      "--out",
      join(iconset, name),
    ]);
  }
  run("iconutil", ["-c", "icns", iconset, "-o", outputPath]);
}

function submitForNotarization(path, label) {
  const credentials = notarizationCredentials();
  console.log(`$ xcrun notarytool submit <${label}> --wait --output-format json`);
  const result = spawnSync(
    "xcrun",
    [
      "notarytool",
      "submit",
      path,
      "--apple-id",
      credentials.appleID,
      "--password",
      credentials.password,
      "--team-id",
      credentials.teamID,
      "--wait",
      "--output-format",
      "json",
    ],
    { cwd: projectRoot, encoding: "utf8" },
  );
  const output = `${result.stdout || ""}\n${result.stderr || ""}`.trim();
  if (result.status !== 0) {
    throw new Error(`Notarization failed for ${label}: ${output}`);
  }
  const response = JSON.parse(result.stdout);
  if (response.status !== "Accepted") {
    throw new Error(
      `Notarization did not accept ${label}: ${response.status} (${response.id})`,
    );
  }
  console.log(`Notarization accepted: ${label} · ${response.id}`);
}

function notarizationCredentials() {
  const appleID = process.env.APPLE_ID;
  const password =
    process.env.APPLE_SPECIFIC_APP_PASSWORD || process.env.APPLE_PASSWORD;
  const teamID = process.env.APPLE_TEAM_ID;
  if (!appleID || !password || !teamID) {
    throw new Error(
      "Notarization requires APPLE_ID, APPLE_SPECIFIC_APP_PASSWORD (or APPLE_PASSWORD), and APPLE_TEAM_ID.",
    );
  }
  return { appleID, password, teamID };
}

function resolveSigningIdentity() {
  const configured =
    process.env.LUMOS_CODESIGN_IDENTITY || process.env.APPLE_SIGNING_IDENTITY;
  if (configured) {
    if (!configured.startsWith("Developer ID Application:")) {
      throw new Error("Release signing requires a Developer ID Application identity.");
    }
    return configured;
  }

  const result = spawnSync(
    "security",
    ["find-identity", "-v", "-p", "codesigning"],
    { encoding: "utf8" },
  );
  const match = (result.stdout || "").match(
    /"(Developer ID Application:[^"]+)"/,
  );
  if (!match) throw new Error("No Developer ID Application identity is available.");
  return match[1];
}

function sha256(path) {
  const result = run("shasum", ["-a", "256", path], { capture: true });
  return result.stdout.trim().split(/\s+/)[0];
}

function publishWebsiteDownload(sourceDmg, sourceChecksum) {
  const downloads = join(projectRoot, "site", "downloads");
  mkdirSync(downloads, { recursive: true });
  copyFileSync(sourceDmg, join(downloads, dmgName));
  copyFileSync(sourceChecksum, join(downloads, `${dmgName}.sha256`));
}

function writeReleaseMetadata(checksum) {
  const metadata = {
    version,
    buildNumber,
    architecture: "arm64",
    minimumSystemVersion: "14.0",
    bundleIdentifier: "ai.lovstudio.lumos",
    artifact: dmgName,
    sha256: checksum,
    notarized: shouldNotarize,
  };
  writeFileSync(
    join(releaseRoot, "release-metadata.json"),
    `${JSON.stringify(metadata, null, 2)}\n`,
  );
}

function tryRun(command, args) {
  const result = spawnSync(command, args, {
    cwd: projectRoot,
    encoding: "utf8",
  });
  return result.status === 0;
}

function run(command, args, options = {}) {
  console.log(`$ ${command} ${args.map(displayArgument).join(" ")}`);
  const result = spawnSync(command, args, {
    cwd: projectRoot,
    encoding: options.capture ? "utf8" : undefined,
    stdio: options.capture ? "pipe" : "inherit",
  });
  if (result.status !== 0) {
    const diagnostic = options.capture
      ? `${result.stdout || ""}\n${result.stderr || ""}`.trim()
      : `exit status ${result.status ?? "unknown"}`;
    throw new Error(`${command} failed: ${diagnostic}`);
  }
  return result;
}

function displayArgument(argument) {
  return /\s/.test(argument) ? JSON.stringify(argument) : argument;
}
