# Branch-local review comments

Status: the first milestone is implemented in `treemacs-magit-review.el`.
Tree counts, blob capture, Git-assisted relocation, and optional lifecycle
commands remain future work. See `README.md` for the supported workflow.

## Intended behavior

Add a companion `treemacs-magit-review-mode` that lets you attach review
comments to a line or selected region, list them for the current project and
branch, and keep them across Emacs restarts. The project/branch comment list is
the primary workflow; a full set of bookmark-like commands is optional.
Each Git repository owns its review data, and each
branch has a separate comment file. Switching branches switches the visible
comments; switching back restores them.

For example, a comment on `pkg/controller.go` while reviewing `feature/retry`
belongs to that branch. It disappears when you check out `main`, but remains
saved. Returning to `feature/retry` restores it, even if its line has moved. If
the code has disappeared or its new location is ambiguous, the comment remains
available in the review list with an explanation.

The interaction takes inspiration from `~/new_emacs/custom/09bm.el`: visible
markers, annotations, and a project list. The new mode
owns its records, persistence, overlays, and commands independently of
`bookmark-alist`, `bookmark-default-file`, and the user's bookmark configuration.

## Project and branch identity

Use Git's repository boundary, as treeview-magit already does. Projectile can
provide a display name, but does not determine storage or ownership. Nested Git
repositories and submodules have separate stores.

Distinguish three identities:

- Repository: canonical absolute Git common directory. Linked worktrees share
  this identity; separate clones do not, even with the same remote URL.
- Checkout: canonical working-tree root. Branch discovery, visiting files, and
  live buffer markers belong to this checkout.
- Review scope: full local ref, such as `refs/heads/feature/retry`. Detached HEAD
  uses a separate `detached:<full-commit-id>` scope.

The persistent key is `(repository, review-scope)`. Runtime locations additionally
include the checkout and buffer, so edits in one worktree cannot move overlays
in another. Never use a single global "current review" variable.

A normal commit, amend, or rebase does not create a new branch review. Keep the
original commit in each comment as provenance, not as the primary branch key.
For the first version, suspend new captures during a detected rebase or other
sequenced history operation; retain existing comments and resume after it ends.
This avoids accidentally creating a detached review for an intermediate commit.

Branch rename and deletion retain data. Optional later lifecycle commands are:

- `treemacs-magit-review-move-scope` transfers a review to another branch,
  including after a rename. Refuse to overwrite an existing destination review.
- `treemacs-magit-review-archive` retains a completed review outside the active
  scope file, allowing a fresh review on the same branch.
- Deleting a branch never deletes its comments. A later repository review browser
  can list retained scopes, including branches that no longer exist. The initial
  list is limited to the current project and branch.

Git does not provide a permanent branch identity. Recreating a branch with the
same name therefore reuses its active review unless it was archived. Show the
review creation time and original HEAD so this is visible; do not guess a branch
rename from similar commit history.

## Storage

Default layout, resolved through Git rather than assuming `.git` is a directory:

```text
<git-common-dir>/treemacs-magit-review/
  scopes/
    <sha256-of-scope-key>.json
  archives/
    <review-id>.json
```

This keeps data local to the repository, survives checkout, and does not add
review files to the working-tree diff. Hashing the full scope key handles slashes
and other branch-name characters; the JSON contains the readable scope and is
checked against the requested key when loaded. Each branch's active review is
self-contained in one file; no global index is required.

The tradeoff is explicit: these files are private local metadata. Git push,
clone, and normal tracked-file backups do not transfer them. Document the metadata
directory for backups. An optional later export command produces a readable
Markdown report. Export includes project, branch, review status, locations, and full
comment text; it does not publish anything to a hosting service.

Use UTF-8 JSON with a schema version, stable comment IDs, and deterministic
formatting. Store repository-relative file paths, never absolute source paths.
Treat loaded data as data, validate its shape, reject paths escaping the
repository, and report unsupported schema versions without overwriting them.

A review file contains:

- `schema_version`, `review_id`, `scope`, `created_at`, `updated_at`.
- `initial_head` and optional review context such as PR number or comparison
  base. These describe the review but do not change its ownership.
- `comments`, each containing an ID, body, `open` or `resolved` status,
  timestamps, an original anchor, and an optional last confirmed anchor.

Each anchor contains:

- Repository-relative path and source kind: `worktree` or `blob`.
- Full HEAD at capture, when one exists; exact source revision and blob object
  ID when the comment targets committed contents.
- Start/end line and column: one-based lines, zero-based character columns,
  exclusive range end. With no selection, anchor the whole current line.
- Exact selected text and a few surrounding lines, plus a hash of the complete
  buffer text at capture. This hash is a text fingerprint, not a Git object ID.
- Whether capture included unsaved buffer edits. Untracked files and unborn
  branches have no committed source blob; represent that explicitly.

Original anchors remain available after relocation. A deliberate reattach
updates the confirmed anchor without losing where the comment originated.
Location validity is computed per checkout and buffer; it is separate from the
persisted `open`/`resolved` review status.

## Locating comments after changes

Line numbers are hints. An in-range line number alone is insufficient evidence
that a comment still refers to the same code.

Resolve lazily when a file is visited or a comment is opened:

1. Within the same buffer and review scope, use Emacs markers to track insertions
   and deletions. Revalidate if edits overlap the anchored text. Invalidate live
   markers on revert or scope change.
2. If the complete text fingerprint still matches, use the saved range directly.
3. Otherwise search for the anchored text with its surrounding context. Accept
   only a uniquely supported match. Proximity to the old line can rank candidates
   for the user, but cannot resolve ambiguity by itself.
4. When committed provenance is available, Git rename detection and diff line
   mapping can suggest another path or range. Verify text and context before
   accepting it. Treat changed or deleted hunks conservatively.
5. If evidence is insufficient, retain the record as `ambiguous`, `outdated`,
   `missing-file`, or `unavailable`. Show the old snippet and candidate locations
   where available. A later `treemacs-magit-review-reattach` command can explicitly
   select a new line or region; its absence must not prevent listing or reading
   the comment.

An automatically found new location is a runtime result, not a reason to rewrite
the comment's original anchor on every visit. Capture a confirmed replacement
only through reattach or an explicit acceptance of a relocation suggestion.

Never clamp a stale location to EOF, silently attach it to a nearby line, or
purge the comment because its file is gone. Navigation to an unresolved location
opens its details first. A historical blob can be shown when still available;
garbage collection may eventually remove it, so the saved snippet is retained.

Comments created against unsaved contents are saved immediately with their text
context. Saving the comment does not save the source file. Discarding those
source edits can leave an outdated comment, which remains recoverable.

## Mode and interaction

Implement a buffer-local `treemacs-magit-review-mode` in
`treemacs-magit-review.el`, providing feature `treemacs-magit-review`. Use public
names under `treemacs-magit-review-` and internal names under
`treemacs-magit--review-`. Keep lexical binding and the existing package's
dependency compatibility requirements.

Keep the initial public workflow small:

- `treemacs-magit-review-comment`: add a comment at point or over the region,
  or edit an existing comment there. If several comments occupy the location,
  offer a selector; a prefix argument adds another comment.
- `treemacs-magit-review-list`: list saved comments for the current Git project
  and checked-out branch. This is the main entry point and works after an Emacs
  restart without first enabling the minor mode or opening the tree.
- `treemacs-magit-review-mode`: toggle review markers in a source buffer.
  Adding a comment enables the mode there. Disabling it removes its overlays
  without deleting data. Enabling it creates storage only on a comment save.

Expose editing and deletion as actions within the list rather than requiring
separate global commands. A package-wide prefix map, source-buffer next/previous
commands, completion-based jumping, resolve/reopen, reattach, archive/move-scope,
cross-branch browsing, and export are optional later additions. Do not claim
`C-x p` or `C-c p`.

All supplied bindings must be local to the comment editor, review list, or tree
buffer. The source-buffer minor mode supplies no default bindings. Global
bindings for the public commands belong to the user's configuration.

Invoking the comment command again must not erase review text. Use a multiline
editor with `C-c C-c` to save and `C-c C-k` to cancel.
The editor displays and retains its repository, branch, comment ID, and captured
anchor. If the checkout changes while it is open, saving still targets that
original scope and reports where it was saved.

Use an owned review-list buffer with an xref-like layout: relative file headers,
locations, and comment text. Show full comment bodies, including multiline text,
so the user can read the review in one place. Clearly label uncertain locations.
The header identifies the repository root, current branch, and comment count.
Group by relative path and order by location, with stable IDs breaking ties.

The list includes every saved comment in this scope, including unchanged files,
unvisited files, and missing or ambiguous locations. Building it reads the review
file without requiring every source file to be visited or resolved first.
Validate the destination on navigation. Unsaved editor drafts are not listed as
saved comments. An empty scope shows "No review comments for this branch".

`RET` visits a verified location or opens details for an unresolved entry;
`n`/`p` move between comments, `e` edits, `d` deletes with confirmation, and `g`
reloads the list. These local actions are sufficient for the first version.
Preview and status filters can be added later.

Keep one list buffer per checkout, with the full root in its identity to avoid
project-name collisions. Invoking the command reads that checkout's current
branch afresh. A detected checkout change or `g` refresh replaces the list's
scope and header; a list mutation checks the scope before acting and asks the
user to select again if it changed. A list belonging to one checkout never
follows the branch of another checkout just because focus moved there.

Source buffers show a dedicated review margin marker, distinguishable from
bookmarks by shape as well as color. The default is Nerd Font U+EC37, with `!` as
its ASCII fallback; the current bookmark configuration uses `` and `>`.
Provide independent `defcustom` options for
`treemacs-magit-review-margin-marker`,
`treemacs-magit-review-margin-ascii-marker`, and
`treemacs-magit-review-margin-use-ascii-marker`, plus a separate
`treemacs-magit-review-margin-face`. Do not inherit the bookmark marker settings.

Multiple comments at one location present a selector and count. When a bookmark
and review comment share a line, both markers must remain visible and separately
identifiable. Reuse the existing left margin when possible; preserve unrelated
window margins and bookmark overlays. Validate their placement together rather
than assuming independent overlays will not overlap. Optional range highlighting
and a user-selected highlight-only display supplement the marker. Display the
active scope and open count in a compact mode-line indicator.

## Checkout changes and persistence

Listen to `magit-post-refresh-hook`, file visits, buffer reverts, and focus
changes. A lightweight periodic check of participating checkouts catches branch
switches made from a terminal. Before a review command or mutation, re-read the
scope independently of cached Magit refresh state. Do not run Git after every
keystroke or scan every project file.

On a scope change, remove old overlays and marker caches before loading the new
scope. A clean source buffer must agree with the new on-disk file before comments
are positioned. If a buffer is modified or stale, suspend its overlays and new
captures until the user saves/reverts and explicitly adopts the current scope.
Do not automatically relabel unsaved old-branch contents as new-branch code.
Detection after an external checkout may lag until the next check; review
commands always perform the scope check themselves.

Save after every explicit comment mutation. Each operation captures its intended
store and scope before changing data; delayed callbacks must never derive a
destination from whichever branch is current later.

For multiple Emacs processes or linked worktrees, acquire an exclusive per-file
lock, re-read the file under that lock, and compare its generation/content hash
with the editor's base version. Apply the mutation only when its base is current;
otherwise preserve the draft and present a conflict/reload action. Write a
temporary file in the same directory and atomically rename it into place before
releasing the lock. Readers see either complete version. Atomic rename alone
does not prevent lost updates. A leftover lock is reported and requires explicit
recovery; never silently steal it.

Malformed JSON, permission errors, and failed writes remain visible. Preserve
the draft and last good file, and never claim a save succeeded before it did.
Disabling the mode does not discard open editors. Killing an unsaved comment
editor uses the normal modified-buffer confirmation behavior.

## Integration with treeview-magit

The current package already carries repository, revision, range, and PR context
in its tree buffer and root nodes. Its `treemacs-magit--label` function is a
natural place to append an optional open-comment count. Its file visitor opens
worktree files for range views when present and Magit blobs for commit views or
files with no worktree copy.

Add small explicit integration hooks for tree setup, label decoration, and file
visits, rather than advising private functions. Pass repository, checkout,
review scope, and source revision to the companion. Scope is captured separately
from a viewed historical revision: viewing an old commit must not silently switch
which branch owns a new comment. A blob comment stays attached to that exact
revision, with an explicit action if the user wants to reattach it to current code.

The tree shows open counts on files and aggregate counts on directories, with a
separate indication for unresolved locations. Include a scope label and a command
to open the full review list. That list also includes comments on unchanged,
deleted, or collapsed files that the current change tree does not display. Count
indexing uses persisted paths and any verified relocations, without reading every
source file or expanding collapsed vendor trees.

Keep the existing dedicated tree window and reuse the file content window for
comment jumps. Ordinary source-buffer navigation works without creating a tree
or extra splits. Because the package reuses a single tree buffer, reopening it
for another repository must replace its review context and mode registration;
source buffers in the previous repository retain their own context.

## Delivery plan and validation

First deliver the current-project/current-branch list, supported by local
worktree comment capture, editing, deletion, independent persistence, branch
switching, and distinct margin markers. The list must be useful on its own:
read all saved comment text, visit verified locations, and retain comments whose
locations no longer resolve. Exact text/context relocation is sufficient for
this milestone; unsupported moves remain visibly unresolved. Include
linked-worktree identity and write-conflict handling in this foundation.

The key acceptance scenario is: save comments on branch A, restart Emacs, list
them from any buffer in that project, switch to branch B and see only B's
comments, then return to A and recover its complete list. A second project with
the same branch name must show only its own comments.

Then add tree counts and source-visit integration, including explicit revision
metadata for blob comments. Until that integration exists, reject capture from
blob and diff buffers clearly. Git-assisted rename and diff relocation can follow.
Direct capture on the old/new sides of a Magit diff needs a separate mapping design;
initially capture from the visited file or supported blob instead.

The initial scope is local Git repositories. Remote/TRAMP storage, hosting-service
submission, shared discussions, and automatic cross-branch comment transfer are
future extensions. Reject unsupported remote activation explicitly.

Use ERT with disposable repositories to verify persistence round trips, isolation
between projects with identically named branches, branch switch/back, restart,
detached/unborn HEAD, linked worktrees, full-text listing, ambiguous text,
deleted files, unsaved contents, stale buffers, and concurrent-write conflicts.
Check that bookmark state is untouched. Test external checkout detection as well
as changes made through Magit, including a comment editor left open across checkout.

Run the existing `make test` suite and load/byte-compile with Magit and Treemacs on
the load path. Supplement this with interactive checks in a disposable repository
for terminal markers alongside normal bookmarks (including both on the same
line, ASCII fallbacks, and preserved margin widths), region capture, list
navigation, and window reuse. Test rename/archive, extra navigation commands,
and tree counts when those optional features are added. The current regression
suite is in `test/treemacs-magit-review-test.el` and runs through `make test`.
