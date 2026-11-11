#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { deflateRawSync } from "node:zlib";

const packageVersion = process.argv[2] || "2.692.3";
const outputPath = resolve(
  process.argv[3] ||
    "Sources/TermPilotApp/Resources/AutocompleteSpecs.bundledata",
);
const temporaryDirectory = mkdtempSync(
  join(tmpdir(), "termpilot-autocomplete-specs-"),
);

function isExcluded(name) {
  return (
    name === "aws" ||
    name.startsWith("aws/") ||
    name === "gcloud" ||
    name.startsWith("gcloud/") ||
    name === "az" ||
    name.startsWith("az/")
  );
}

function cleanSuggestion(value) {
  if (typeof value === "string") return value;
  if (!value || typeof value !== "object") return null;

  const result = {};
  if (typeof value.name === "string" || Array.isArray(value.name)) {
    result.name = value.name;
  }
  if (typeof value.description === "string") {
    result.description = value.description;
  }
  return result.name ? result : null;
}

function cleanArgs(value) {
  if (Array.isArray(value)) {
    return value.map(cleanArgs).filter(Boolean);
  }
  if (!value || typeof value !== "object") return undefined;

  const result = {};
  for (const key of [
    "name",
    "description",
    "template",
    "isOptional",
    "isVariadic",
  ]) {
    if (value[key] !== undefined && typeof value[key] !== "function") {
      result[key] = value[key];
    }
  }
  if (Array.isArray(value.suggestions)) {
    result.suggestions = value.suggestions
      .map(cleanSuggestion)
      .filter(Boolean);
  }
  return result;
}

function cleanOption(value) {
  if (!value || typeof value !== "object") return null;

  const result = {};
  for (const key of ["name", "description", "isPersistent"]) {
    if (value[key] !== undefined && typeof value[key] !== "function") {
      result[key] = value[key];
    }
  }
  const args = cleanArgs(value.args);
  if (args !== undefined) result.args = args;
  return result.name ? result : null;
}

function cleanCommand(value) {
  if (!value || typeof value !== "object") return null;

  const result = {};
  for (const key of ["name", "description"]) {
    if (value[key] !== undefined && typeof value[key] !== "function") {
      result[key] = value[key];
    }
  }
  if (Array.isArray(value.subcommands)) {
    result.subcommands = value.subcommands.map(cleanCommand).filter(Boolean);
  }
  if (Array.isArray(value.options)) {
    result.options = value.options.map(cleanOption).filter(Boolean);
  }
  const args = cleanArgs(value.args);
  if (args !== undefined) result.args = args;
  return result.name ? result : null;
}

try {
  execFileSync(
    "npm",
    [
      "pack",
      `@withfig/autocomplete@${packageVersion}`,
      "--pack-destination",
      temporaryDirectory,
      "--silent",
    ],
    { stdio: "pipe" },
  );
  const archive = readdirSync(temporaryDirectory).find((name) =>
    name.endsWith(".tgz"),
  );
  if (!archive) throw new Error("npm pack did not produce an archive");

  execFileSync(
    "tar",
    ["-xzf", join(temporaryDirectory, archive), "-C", temporaryDirectory],
    { stdio: "pipe" },
  );

  const packageRoot = join(temporaryDirectory, "package");
  const index = JSON.parse(
    readFileSync(join(packageRoot, "build", "index.json"), "utf8"),
  );
  const commands = index.completions.filter(
    (name) => !name.includes("/") && !isExcluded(name),
  );
  const payloads = [];
  const entries = {};
  let offset = 0;

  for (const name of commands) {
    try {
      const moduleURL = pathToFileURL(
        join(packageRoot, "build", `${name}.js`),
      ).href;
      const module = await import(moduleURL);
      const spec = cleanCommand(module.default?.default ?? module.default);
      if (!spec) continue;

      const compressed = deflateRawSync(
        Buffer.from(JSON.stringify(spec)),
        { level: 9 },
      );
      entries[name] = { offset, length: compressed.length };
      payloads.push(compressed);
      offset += compressed.length;
    } catch {
      // Keep the command name available even when a dynamic spec cannot load.
    }
  }

  const header = Buffer.from(
    JSON.stringify({
      version: 1,
      source: `@withfig/autocomplete@${packageVersion}`,
      commands,
      entries,
    }),
  );
  const headerLength = Buffer.alloc(4);
  headerLength.writeUInt32BE(header.length);

  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(
    outputPath,
    Buffer.concat([headerLength, header, ...payloads]),
  );
  console.log(
    `Generated ${Object.keys(entries).length}/${commands.length} specs at ${outputPath}`,
  );
} finally {
  rmSync(temporaryDirectory, { recursive: true, force: true });
}
