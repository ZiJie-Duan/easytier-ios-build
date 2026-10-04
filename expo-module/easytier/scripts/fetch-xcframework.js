#!/usr/bin/env node
/**
 * Downloads EasyTierFFI.xcframework (built by ZiJie-Duan/easytier-ios-build) into
 * modules/easytier/ios/Frameworks/ so that EasyTier.podspec can vendor it.
 *
 * Runs from:
 *   - package.json `postinstall`        -> best effort, NEVER fails `npm install`
 *   - package.json `eas-build-pre-install` with `--strict`
 *       EAS runs this hook before `npm install`, i.e. before `expo prebuild` and
 *       `pod install` (eas-build-post-install would be too late: it runs after
 *       `pod install`, and the podspec only vendors the framework if it exists
 *       when CocoaPods evaluates it). In strict mode an iOS build fails loudly
 *       instead of silently producing an app without EasyTier.
 *
 * Only Node built-ins are used, so it also works before node_modules exists.
 *
 * Configuration: ../xcframework.json (tag, url, sha256), overridable with env vars:
 *   EASYTIER_SKIP_FETCH=1             skip entirely
 *   EASYTIER_FORCE_FETCH=1            also fetch on non-macOS hosts
 *   EASYTIER_XCFRAMEWORK_URL=...      download URL (pinned sha256 from json is then ignored)
 *   EASYTIER_XCFRAMEWORK_SHA256=...   expected sha256 of the zip
 *   EASYTIER_XCFRAMEWORK_ZIP=path     use a local zip instead of downloading
 *   EASYTIER_REQUIRE_SHA256=1         refuse to install without a pinned sha256
 */
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');

const MODULE_ROOT = path.resolve(__dirname, '..');
const CONFIG_PATH = path.join(MODULE_ROOT, 'xcframework.json');
const FRAMEWORKS_DIR = path.join(MODULE_ROOT, 'ios', 'Frameworks');
const FRAMEWORK_NAME = 'EasyTierFFI.xcframework';
const FRAMEWORK_DIR = path.join(FRAMEWORKS_DIR, FRAMEWORK_NAME);
const MARKER_PATH = path.join(FRAMEWORKS_DIR, '.fetched.json');
const DOWNLOAD_TIMEOUT_MS = 5 * 60 * 1000;

const strict = process.argv.includes('--strict');
const env = process.env;

function log(message) {
  console.log(`[easytier] ${message}`);
}

function warn(message) {
  console.warn(`[easytier] WARNING: ${message}`);
}

function isSha256(value) {
  return typeof value === 'string' && /^[0-9a-f]{64}$/i.test(value.trim());
}

function readConfig() {
  const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  const tag = String(config.tag || '');
  const envUrl = env.EASYTIER_XCFRAMEWORK_URL;
  const url = envUrl || String(config.url || '').replace('{tag}', tag);
  if (!url) {
    throw new Error(`no download url configured in ${CONFIG_PATH}`);
  }
  // A pinned hash only applies to the pinned URL.
  const pinned = env.EASYTIER_XCFRAMEWORK_SHA256 || (envUrl ? undefined : config.sha256);
  return {
    tag,
    url,
    sha256: isSha256(pinned) ? pinned.trim().toLowerCase() : null,
  };
}

function skipReason() {
  if (env.EASYTIER_SKIP_FETCH === '1') {
    return 'EASYTIER_SKIP_FETCH=1';
  }
  if (env.EAS_BUILD_PLATFORM && env.EAS_BUILD_PLATFORM !== 'ios') {
    return `EAS build for ${env.EAS_BUILD_PLATFORM}`;
  }
  if (process.platform !== 'darwin' && env.EASYTIER_FORCE_FETCH !== '1' && !env.EAS_BUILD_PLATFORM) {
    return `host is ${process.platform}; the iOS framework is only needed on macOS (set EASYTIER_FORCE_FETCH=1 to fetch anyway)`;
  }
  return null;
}

function alreadyInstalled(config) {
  try {
    if (!fs.existsSync(path.join(FRAMEWORK_DIR, 'Info.plist'))) {
      return false;
    }
    const marker = JSON.parse(fs.readFileSync(MARKER_PATH, 'utf8'));
    if (marker.url !== config.url) {
      return false;
    }
    return !config.sha256 || marker.sha256 === config.sha256;
  } catch {
    return false;
  }
}

async function download(url, destination) {
  log(`downloading ${url}`);
  const response = await fetch(url, {
    redirect: 'follow',
    signal: AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS),
    headers: { 'User-Agent': 'trinity-easytier-fetch' },
  });
  if (!response.ok || !response.body) {
    throw new Error(`download failed: HTTP ${response.status} ${response.statusText}`);
  }
  await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(destination));
}

async function fetchSidecarSha256(url) {
  try {
    const response = await fetch(`${url}.sha256`, {
      redirect: 'follow',
      signal: AbortSignal.timeout(30 * 1000),
      headers: { 'User-Agent': 'trinity-easytier-fetch' },
    });
    if (!response.ok) {
      return null;
    }
    const token = (await response.text()).trim().split(/\s+/)[0];
    return isSha256(token) ? token.toLowerCase() : null;
  } catch {
    return null;
  }
}

function sha256File(file) {
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(file));
  return hash.digest('hex');
}

function unzip(zipPath, destination) {
  if (process.platform === 'darwin') {
    // `ditto` preserves the symlinks/permissions the CI zipped with `ditto -c -k`.
    execFileSync('ditto', ['-x', '-k', zipPath, destination], { stdio: 'inherit' });
  } else {
    execFileSync('unzip', ['-q', '-o', zipPath, '-d', destination], { stdio: 'inherit' });
  }
}

function findFramework(root) {
  const direct = path.join(root, FRAMEWORK_NAME);
  if (fs.existsSync(path.join(direct, 'Info.plist'))) {
    return direct;
  }
  // Tolerate one extra directory level in the archive.
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const nested = path.join(root, entry.name, FRAMEWORK_NAME);
    if (entry.isDirectory() && fs.existsSync(path.join(nested, 'Info.plist'))) {
      return nested;
    }
  }
  return null;
}

async function main() {
  const reason = skipReason();
  if (reason) {
    log(`skipping xcframework fetch (${reason})`);
    return;
  }

  const config = readConfig();
  if (alreadyInstalled(config)) {
    log(`${FRAMEWORK_NAME} already present (${config.url})`);
    return;
  }

  fs.mkdirSync(FRAMEWORKS_DIR, { recursive: true });
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'easytier-xcframework-'));
  try {
    let zipPath = env.EASYTIER_XCFRAMEWORK_ZIP;
    let source = zipPath;
    if (zipPath) {
      log(`using local archive ${zipPath}`);
    } else {
      zipPath = path.join(workDir, `${FRAMEWORK_NAME}.zip`);
      source = config.url;
      await download(config.url, zipPath);
    }

    const actual = sha256File(zipPath);
    let expected = config.sha256;
    if (!expected && !env.EASYTIER_XCFRAMEWORK_ZIP) {
      expected = await fetchSidecarSha256(config.url);
      if (expected) {
        warn(
          'no sha256 pinned in xcframework.json; verified against the release\'s .sha256 file instead ' +
            '(integrity only, not authenticity). Pin it: "sha256": "' + actual + '"'
        );
      }
    }
    if (expected) {
      if (expected !== actual) {
        throw new Error(`sha256 mismatch for ${source}: expected ${expected}, got ${actual}`);
      }
      log(`sha256 ok (${actual})`);
    } else if (env.EASYTIER_REQUIRE_SHA256 === '1') {
      throw new Error(`no sha256 available for ${source} and EASYTIER_REQUIRE_SHA256=1 (actual: ${actual})`);
    } else {
      warn(`installing UNVERIFIED archive (sha256 ${actual}); pin it in modules/easytier/xcframework.json`);
    }

    const extractDir = path.join(workDir, 'extract');
    fs.mkdirSync(extractDir);
    unzip(zipPath, extractDir);
    const extracted = findFramework(extractDir);
    if (!extracted) {
      throw new Error(`${FRAMEWORK_NAME} not found inside ${source}`);
    }

    fs.rmSync(FRAMEWORK_DIR, { recursive: true, force: true });
    // Copy instead of rename: the temp dir may be on another volume.
    fs.cpSync(extracted, FRAMEWORK_DIR, { recursive: true, verbatimSymlinks: true });
    fs.writeFileSync(
      MARKER_PATH,
      JSON.stringify({ url: config.url, tag: config.tag, sha256: actual, fetchedAt: new Date().toISOString() }, null, 2) +
        '\n'
    );
    log(`installed ${FRAMEWORK_NAME} -> ${path.relative(process.cwd(), FRAMEWORK_DIR)}`);
  } finally {
    fs.rmSync(workDir, { recursive: true, force: true });
  }
}

main().catch((error) => {
  const message = error && error.message ? error.message : String(error);
  if (strict) {
    console.error(`[easytier] ERROR: ${message}`);
    process.exitCode = 1;
  } else {
    warn(`${message}`);
    warn('continuing without EasyTierFFI.xcframework; the EasyTier module will report isAvailable() === false.');
  }
});
