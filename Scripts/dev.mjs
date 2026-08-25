import { spawn, spawnSync } from "node:child_process";
import {
  closeSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  unlinkSync,
  watch,
  writeFileSync,
} from "node:fs";
import { basename, join } from "node:path";

const projectRoot = process.cwd();
const buildRoot = join(projectRoot, ".build");
const appPath = join(buildRoot, "LumosDev.app");
const stagingPath = join(buildRoot, "LumosDev.app.next");
const lockPath = join(buildRoot, "lumos-dev-watch.lock");
const sourcesPath = join(projectRoot, "Sources");
const resourcesPath = join(projectRoot, "Resources");

let appProcess = null;
let rebuilding = false;
let rebuildQueued = false;
let shuttingDown = false;
let debounceTimer = null;
const watchers = [];

mkdirSync(buildRoot, { recursive: true });
await acquireLock();

process.on("SIGINT", () => shutdown(130));
process.on("SIGTERM", () => shutdown(143));
process.on("exit", cleanupLock);

await rebuildAndRestart("initial build");
startWatching();
console.log("Lumos dev watch ready — save a Swift file to rebuild and restart.");

async function acquireLock() {
  if (existsSync(lockPath)) {
    const existingPID = Number(readFileSync(lockPath, "utf8").trim());
    if (Number.isInteger(existingPID) && existingPID > 0) {
      if (isProcessRunning(existingPID)) {
        if (isProjectWatcher(existingPID)) {
          console.log(`Taking over the existing Lumos dev watch (pid ${existingPID})…`);
          process.kill(existingPID, "SIGTERM");
          if (!(await waitForProcessExit(existingPID, 5000))) {
            throw new Error(
              `The existing Lumos dev watch (pid ${existingPID}) did not stop. Stop it manually and retry.`,
            );
          }
        } else {
          console.warn(`Ignoring a stale Lumos dev lock that now belongs to pid ${existingPID}.`);
        }
      }
      removeLockOwnedBy(existingPID);
    } else {
      unlinkSync(lockPath);
    }
  }

  const descriptor = openSync(lockPath, "wx");
  writeFileSync(descriptor, `${process.pid}\n`);
  closeSync(descriptor);
}

function isProcessRunning(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function isProjectWatcher(pid) {
  const command = spawnSync("ps", ["-p", String(pid), "-o", "command="], {
    encoding: "utf8",
  }).stdout?.trim();
  if (!command || !/(^|\s)node\s+Scripts\/dev\.mjs(?:\s|$)/.test(command)) return false;

  const cwd = spawnSync("lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], {
    encoding: "utf8",
  }).stdout
    ?.split("\n")
    .find((line) => line.startsWith("n"))
    ?.slice(1);
  return cwd === projectRoot;
}

function waitForProcessExit(pid, timeoutMilliseconds) {
  const deadline = Date.now() + timeoutMilliseconds;
  return new Promise((resolve) => {
    const check = () => {
      if (!isProcessRunning(pid)) {
        resolve(true);
      } else if (Date.now() >= deadline) {
        resolve(false);
      } else {
        setTimeout(check, 50);
      }
    };
    check();
  });
}

function removeLockOwnedBy(pid) {
  try {
    if (existsSync(lockPath) && readFileSync(lockPath, "utf8").trim() === String(pid)) {
      unlinkSync(lockPath);
    }
  } catch {
    // The previous watcher may remove its own lock during shutdown.
  }
}

function cleanupLock() {
  try {
    if (existsSync(lockPath) && readFileSync(lockPath, "utf8").trim() === String(process.pid)) {
      unlinkSync(lockPath);
    }
  } catch {
    // Best-effort cleanup after terminal shutdown.
  }
}

function startWatching() {
  for (const directory of [sourcesPath, resourcesPath]) {
    watchers.push(
      watch(directory, { recursive: true }, (_event, filename) => {
        scheduleRebuild(filename || basename(directory));
      }),
    );
  }

  watchers.push(
    watch(join(projectRoot, "Package.swift"), () => scheduleRebuild("Package.swift")),
  );
}

function scheduleRebuild(changedPath) {
  if (shuttingDown) return;
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    rebuildAndRestart(`changed ${changedPath}`).catch((error) => {
      console.error(error instanceof Error ? error.message : String(error));
    });
  }, 180);
}

async function rebuildAndRestart(reason) {
  if (rebuilding) {
    rebuildQueued = true;
    return;
  }
  rebuilding = true;
  console.log(`\n[reload] ${reason}`);

  try {
    const appBuild = await run("swift", ["build", "--product", "lumos-app"]);
    if (appBuild !== 0) {
      console.error("[reload] build failed; keeping the previous Lumos instance running.");
      return;
    }
    const helperBuild = await run("swift", ["build", "--product", "lumos-privileged-helper"]);
    if (helperBuild !== 0) {
      console.error("[reload] helper build failed; keeping the previous Lumos instance running.");
      return;
    }

    assembleSignedAppBundle();
    await stopApp();
    replaceAppBundle();
    launchApp();
  } finally {
    rebuilding = false;
    if (rebuildQueued && !shuttingDown) {
      rebuildQueued = false;
      await rebuildAndRestart("changes received during build");
    }
  }
}

function assembleSignedAppBundle() {
  rmSync(stagingPath, { recursive: true, force: true });
  const contents = join(stagingPath, "Contents");
  const macOS = join(contents, "MacOS");
  const resources = join(contents, "Resources");
  const daemons = join(contents, "Library", "LaunchDaemons");
  mkdirSync(macOS, { recursive: true });
  mkdirSync(resources, { recursive: true });
  mkdirSync(daemons, { recursive: true });

  copyFileSync(join(resourcesPath, "DevAppInfo.plist"), join(contents, "Info.plist"));
  copyFileSync(join(buildRoot, "debug", "lumos-app"), join(macOS, "Lumos"));
  copyFileSync(
    join(buildRoot, "debug", "lumos-privileged-helper"),
    join(resources, "LumosPrivilegedHelper"),
  );
  copyFileSync(
    join(resourcesPath, "ai.lovstudio.lumos.privileged-helper.plist"),
    join(daemons, "ai.lovstudio.lumos.privileged-helper.plist"),
  );

  const identity = codesignIdentity();
  runSync("codesign", [
    "--force",
    "--sign",
    identity,
    "--timestamp=none",
    "--identifier",
    "ai.lovstudio.lumos.privileged-helper",
    join(resources, "LumosPrivilegedHelper"),
  ]);
  runSync("codesign", [
    "--force",
    "--sign",
    identity,
    "--timestamp=none",
    "--options",
    "runtime",
    stagingPath,
  ]);
  runSync("codesign", ["--verify", "--deep", "--strict", stagingPath]);
}

function codesignIdentity() {
  if (process.env.LUMOS_CODESIGN_IDENTITY) return process.env.LUMOS_CODESIGN_IDENTITY;
  const result = spawnSync("security", ["find-identity", "-v", "-p", "codesigning"], {
    encoding: "utf8",
  });
  const identities = result.stdout || "";
  const development = identities.match(/"(Apple Development:[^"]+)"/);
  if (development) return development[1];
  const developerID = identities.match(/"(Developer ID Application:[^"]+)"/);
  if (developerID) return developerID[1];
  console.warn("[reload] no signing identity found; using ad-hoc signing (helper approval may be unavailable).");
  return "-";
}

function replaceAppBundle() {
  rmSync(appPath, { recursive: true, force: true });
  renameSync(stagingPath, appPath);
  runSync(
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
    ["-f", appPath],
  );
}

function launchApp() {
  const executable = join(appPath, "Contents", "MacOS", "Lumos");
  appProcess = spawn(executable, [], {
    cwd: projectRoot,
    env: { ...process.env, LUMOS_DEV_WATCH: "1" },
    stdio: "inherit",
  });
  appProcess.once("exit", (code, signal) => {
    appProcess = null;
    if (!shuttingDown && !rebuilding) {
      console.log(`[app] Lumos exited (${signal || (code ?? 0)}); dev watch remains active.`);
    }
  });
}

async function stopApp() {
  const current = appProcess;
  if (!current || current.exitCode !== null) return;
  current.kill("SIGTERM");
  await Promise.race([
    new Promise((resolve) => current.once("exit", resolve)),
    new Promise((resolve) => setTimeout(resolve, 3000)),
  ]);
  if (current.exitCode === null && current.signalCode === null) current.kill("SIGKILL");
  appProcess = null;
}

async function shutdown(code) {
  if (shuttingDown) return;
  shuttingDown = true;
  clearTimeout(debounceTimer);
  watchers.forEach((watcher) => watcher.close());
  await stopApp();
  cleanupLock();
  process.exit(code);
}

function run(command, args) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { cwd: projectRoot, stdio: "inherit" });
    child.once("exit", (code) => resolve(code ?? 1));
  });
}

function runSync(command, args) {
  const result = spawnSync(command, args, { cwd: projectRoot, stdio: "inherit" });
  if (result.status !== 0) {
    throw new Error(`${command} failed with status ${result.status ?? "unknown"}`);
  }
}
