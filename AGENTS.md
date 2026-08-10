# AGENTS.md

Guidance for AI agents working in this repository.

## Scope

This repository contains `treemacs-magit-mode`, a standalone Emacs Lisp package
that displays working-tree or commit changes as a Treemacs tree backed by Magit.
These instructions apply to the entire repository.

Agents should also treat the straight.el package checkout directory as available
source context:

```text
~/.emacs.d/straight/repos
```

When investigating dependency behavior, search both this repository and the
Magit and Treemacs sources under `~/.emacs.d/straight/repos`. Prefer reading
package source there instead of guessing APIs or behavior. Do not modify files
under `~/.emacs.d/straight/repos` unless explicitly asked; changes for this
package should normally be made here.

## Repository layout

- `treemacs-magit-mode.el` is the package implementation and public entry point.
- `README.md` documents installation, usage, key bindings, and customization.
- `list1.png` and `list2.png` are screenshots embedded in the README.
- There is currently no separate test directory or build configuration.

## Emacs Lisp conventions

- Preserve the library's `lexical-binding: t` file-local setting.
- Keep the package header, `Package-Requires`, autoload cookie, feature name,
  and footer consistent with the filename `treemacs-magit-mode.el`.
- Prefix package-owned functions and variables with `treemacs-magit-`; keep
  internal implementation details under `treemacs-magit--`.
- Use `defcustom` (with an appropriate type and group) for user-facing options
  and update `README.md` when public behavior, commands, bindings, installation,
  or customization changes.
- Follow the existing style and keep edits surgical. Avoid broad
  `ignore-errors` or silent compatibility fallbacks; failures should remain
  diagnosable.
- This package defines the command `treemacs-magit`, but provides the feature
  `treemacs-magit-mode`. Treemacs itself also ships a different
  `treemacs-magit` integration, so take care not to require, provide, or
  accidentally target that feature when changing this package.

## Working with straight.el packages

- Dependency source is expected at `~/.emacs.d/straight/repos/<package-name>`;
  in particular, inspect `magit`, `treemacs`, and `treemacs/src` when tracing
  APIs used here.
- straight.el build directories under `~/.emacs.d/straight/build` may be added
  to `load-path` for batch validation, but source checkouts remain the primary
  reference for functions, variables, hooks, and macros.
- If a dependency issue needs accommodation, prefer a focused compatibility
  change in this repository rather than editing a straight.el checkout.
- If a dependency source change is explicitly requested, call out that it is
  outside this repository and may be overwritten by straight.el updates unless
  maintained as a fork or patch.
- Keep the installation examples compatible with the package recipe documented
  in `README.md`; do not introduce package.el-specific installation machinery.

## Validation

Use the smallest check that covers the change. At minimum, load or byte-compile
the package with Magit and Treemacs available on `load-path`. With this checkout
installed through straight.el, useful commands include:

```sh
emacs --batch -Q \
  --eval '(let ((default-directory (expand-file-name "~/.emacs.d/straight/build/"))) (normal-top-level-add-subdirs-to-load-path))' \
  -L . \
  -l treemacs-magit-mode.el

emacs --batch -Q \
  --eval '(let ((default-directory (expand-file-name "~/.emacs.d/straight/build/"))) (normal-top-level-add-subdirs-to-load-path))' \
  -L . \
  -f batch-byte-compile treemacs-magit-mode.el
```

Build directory names and dependency layouts can vary by Emacs/straight.el
setup. If those commands fail because of local package state, report the exact
environmental failure and still perform narrower checks where possible. For
changes involving window placement, mouse events, staging, commit views, or
Treemacs node interaction, supplement batch checks with targeted interactive
testing in a disposable Git repository.

## Git hygiene

- Do not rewrite history or discard user changes.
- Keep edits focused and avoid reformatting unrelated Emacs Lisp or replacing
  screenshots unless the requested behavior changes them.
- Do not commit changes unless explicitly requested.
