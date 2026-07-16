# PROJECT MAINTENANCE PROTOCOL

You are assisting with the development of a macOS application (Swift/SPM). Keep the project pristine — but scale the effort to the change.

## When to run the 4-step protocol

Run the full 4-step protocol below **whenever a change is substantial** — a new feature, a refactor, a structural/file move, or anything touching multiple files or the public surface (Settings, menus, Catalog, data models). After a substantial change, complete all four steps before considering the task done.

**Do NOT run the full protocol on trivial turns** — questions, one-line fixes, copy/color/icon tweaks, or exploratory iterations. Forcing a whole-project restructure (and especially *permanent file deletion*) on a small change is wasteful and risky.

**Always**, however small the change: update any docs whose accuracy the change affects (step 4), and never leave the tree worse than you found it.

Judgment and the standing rules still apply: don't commit/push or bump versions unless asked; treat file deletion/moves as reversible-with-care, not reflexive.

---

## 1. Global Project Scan, Restructure & Deduplication
* **Scan & Restructure:** Analyze the entire directory tree. Automatically move misaligned files into their proper folders (`/Utils`, `/Services`, `/Views`, `/Models`, etc.) to maintain a pristine, highly organized project architecture and layout view.
* **Purge Dead Code & Maximize Reusability:** Identify unused variables, redundant logic, dead functions, and orphaned files across the codebase. 
  * Purge them **only** after verifying they're genuinely unreferenced (grep for usages, including selectors and string-based lookups). Don't leave commented-out legacy code. When in doubt, flag rather than delete.
  * Actively look for duplicates or near-identical logic. Refactor these into clean, centralized, and highly reusable functions or utilities.
* **Code Review:** Perform a silent, automated code review on all modified and affected files. Fix performance bottlenecks, eliminate redundancy, and reformat code to match standard Swift/macOS guidelines.

## 2. Settings Configuration 
* **Completeness:** Ensure every new feature, variable, capability, or configurable possibility is fully exposed as a user toggle or option in the app's Settings.
* **Layout Organization:** If the Settings view becomes too large or complex, you must automatically reorganize it into a clean, intuitive hierarchy using dedicated sections, tabs, or forms. Never leave a cluttered Settings page.

## 3. UI/UX, Navigation & Menu Optimization
* **Catalog & Sidebar Overhaul:** Review all catalogs, sidebars, and navigation structures. Reorganize and group elements intuitively based on the best user experience and Apple's Human Interface Guidelines (HIG).
* **Global Menu Reorganization:** Systematically go through and restructure the entire app menu item architecture. Ensure sidebars, menus, and navigation lists remain clean, modern, logically grouped, and optimized for an exceptional desktop flow.

## 4. Comprehensive Documentation Update
* **README Sync:** Automatically verify and update the root `README.md` to perfectly reflect the entire project's current state, including new features, structural changes, or setup instructions.
* **Docs Folder:** Review all markdown files within the `/docs` directory. Update, create, or reorganize `.md` files to ensure technical documentation flawlessly matches the current state of the codebase.
* **Code Comments:** Add standard Swift inline documentation for any new, heavily refactored, or newly consolidated services and utility functions.