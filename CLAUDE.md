# PROJECT MAINTENANCE PROTOCOL

You are assisting with the development of a macOS application (Swift/SPM). Keep the project pristine — but scale the effort to the change.

## When to run the 4-step protocol

Run the full 4-step protocol below **whenever a change is substantial** — a new feature, a refactor, a structural/file move, or anything touching multiple files or the public surface (Settings, menus, Catalog, data models). After a substantial change, complete all four steps before considering the task done.

**Do NOT run the full protocol on trivial turns** — questions, one-line fixes, copy/color/icon tweaks, or exploratory iterations. Forcing a whole-project restructure (and especially *permanent file deletion*) on a small change is wasteful and risky.

**Always**, however small the change: update any docs whose accuracy the change affects (step 4), and never leave the tree worse than you found it.

Judgment and the standing rules still apply: don't commit/push or bump versions unless asked; treat file deletion/moves as reversible-with-care, not reflexive.

## 1. Project Scan & Aggressive Cleanup
* **Scan & Restructure:** Analyze the directory tree. Automatically move misaligned files into their proper folders (`/Utils`, `/Services`, `/Views`, `/Models`, etc.) to maintain a pristine project architecture.
* **Purge Dead Code:** Identify unused variables, redundant logic, dead functions, and orphaned files, and remove them — but only after verifying they're genuinely unreferenced (grep for usages, including selectors and string-based lookups). Don't leave commented-out legacy code. When in doubt, flag rather than delete.
* **Code Review:** Perform a silent, automated code review on any modified files. Fix performance bottlenecks and reformat code to match standard Swift/macOS guidelines.

## 2. Settings Configuration 
* **Completeness:** Ensure every new feature, variable, or capability is fully exposed as a user toggle or option in the app's Settings.
* **Layout Organization:** If the Settings view becomes too large, you must automatically reorganize it into a clean hierarchy using dedicated sections, tabs, or forms. Never leave a cluttered Settings page.

## 3. UI/UX & Navigation Optimization
* **Catalog & Menu Review:** Review all catalogs, sidebars, and app menu items.
* **UX Grouping:** Reorganize and group UI elements intuitively based on the best user experience and Apple's Human Interface Guidelines (HIG). 
* Ensure sidebars and navigation structures remain clean, modern, and logically grouped.

## 4. Comprehensive Documentation Update
* **README Sync:** Automatically verify and update the root `README.md` to reflect any new features, structural changes, or setup instructions.
* **Docs Folder:** Review all markdown files within the `/docs` directory. Update, create, or reorganize `.md` files to ensure technical documentation matches the current state of the codebase.
* **Code Comments:** Add standard inline documentation for any new or heavily refactored services and utilities.