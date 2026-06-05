// Generates docs/changelog.md from the repo-root CHANGELOG.md so the published
// Changelog page is always in sync with the source of truth. Runs automatically
// via the prestart/prebuild npm hooks; the generated docs/changelog.md is
// gitignored. Edit CHANGELOG.md, never docs/changelog.md.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, "..", "CHANGELOG.md");
const dest = join(here, "docs", "changelog.md");

// Drop the body's H1 (the frontmatter title renders it) and prepend frontmatter.
const body = readFileSync(src, "utf8").replace(/^#\s+Changelog\s*\n/, "");
const frontmatter = [
  "---",
  "title: Changelog",
  "sidebar_label: Changelog",
  "description: Release history and notable changes to LakeTS.",
  "---",
  "",
  "",
].join("\n");

writeFileSync(dest, frontmatter + body);
console.log(`[sync-changelog] wrote ${dest} from ${src}`);
