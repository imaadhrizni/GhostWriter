# PROJECT MAINTENANCE PROTOCOL

You are assisting with the development of a macOS application (Swift/SPM). Keep the project pristine — but scale the effort to the change.

## When to run the 5-step protocol

Run the full 5-step protocol below **whenever a change is substantial** — a new feature, a refactor, a structural/file move, or anything touching multiple files or the public surface (Settings, menus, Catalog, data models). After a substantial change, complete all five steps before considering the task done.

**Do NOT run the full protocol on trivial turns** — questions, one-line fixes, copy/color/icon tweaks, or exploratory iterations. Forcing a whole-project restructure (and especially *permanent file deletion*) on a small change is wasteful and risky.

**Always**, however small the change: update any docs whose accuracy the change affects (step 5), and never leave the tree worse than you found it.

Judgment and the standing rules still apply: don't commit/push or bump versions unless asked; treat file deletion/moves as reversible-with-care, not reflexive.

---

## 1. Whole-Project Scan, Restructure, Reformat & Deduplication
Scan the **entire** project — every file and folder — not just what you touched.
* **Restructure & reformat files/folders:** Analyze the whole directory tree and move misaligned files into their proper homes (`/Utils`, `/Services`, `/Views`, `/Models`, `/Audio`, `/Meetings`, etc.) so the project layout reads cleanly at a glance. Reformat files to standard Swift/macOS style (imports, spacing, `// MARK:` sections, naming) as you pass through them.
* **Dead code & dead files:** Find unused variables, dead functions, unreachable branches, and orphaned files across the codebase and remove them — but **only** after verifying they're genuinely unreferenced (grep for usages, including `#selector`, key-paths, and string-based lookups like notification names, AppSettings keys, and SF Symbol / template ids). Never leave commented-out legacy code. When in doubt, flag rather than delete; treat deletion as reversible-with-care.
* **Redundancy, duplicates & reusability:** Actively hunt for duplicated or near-identical logic and consolidate it into a **single**, well-named, reusable function/utility/service (as was done for `MeetingRefinery`, `PocPlanGrounding`, `FilePanels`, `Clipboard`, `organizedFolder`). Prefer one good implementation reused everywhere over parallel copies that can drift.

## 2. Code Review
Perform a focused code review of the modified and affected files (and anything the scan in step 1 flags):
* Correctness bugs, performance bottlenecks, and Swift/concurrency pitfalls (main-actor, `@Sendable`, force-unwraps, retain cycles).
* The same hygiene lens as step 1 — **dead code, redundant logic, dead files, duplicates** — reported and fixed.
* Match the surrounding code's idiom and formatting; leave every file you touch at least as clean as you found it.

## 3. Settings — Completeness & Organization
* **Completeness:** Every new feature, variable, capability, or configurable possibility must be exposed as a user toggle/option in the app's Settings, with its `AppSettings` `Key`, `Default`, computed property, **and `Key.all` entry**. If something is deliberately *not* configurable, say why.
* **Layout organization:** Keep Settings scannable. When a pane grows too large or mixed, reorganize it into a clean hierarchy — dedicated `SettingsGroup` sections, tabs, or sub-forms grouped by concern. Never leave a cluttered or arbitrarily-ordered Settings page.

## 4. Catalog, Settings & Menu — UX Reorganization
Go through the **Catalog**, the **Settings**, and the **global menu** together and organize them for the best user experience:
* **Catalog & sidebars:** Review every catalog, sidebar, and navigation list. Group and order items intuitively (Overview → Records → Track → Explore, etc.), following Apple's HIG, so related things sit together and the primary records lead.
* **Menu architecture:** Restructure the entire app/menu-bar item hierarchy — logical grouping, sensible separators, consistent naming and shortcuts — for a clean, modern desktop flow.
* Keep the three surfaces **consistent** with each other (a capability in Settings, its Catalog section, and its menu entry should agree in name and grouping).

## 5. Comprehensive Documentation Update
* **README sync:** Verify and update the root `README.md` so it reflects the project's current state — features, structure, setup.
* **/docs folder:** Review every markdown file in `/docs` (`architecture.md`, `features.md`, `settings.md`, `usage.md`, …). Update, create, or reorganize them so the technical docs match the code exactly — including the file-table entries when files are added/moved/removed.
* **Code comments:** Add standard Swift doc comments for any new, heavily refactored, or newly consolidated services and utilities.