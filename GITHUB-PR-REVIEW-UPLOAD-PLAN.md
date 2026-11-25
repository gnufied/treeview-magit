# Upload branch-local review comments to a GitHub PR

Add an opt-in command to the review list that takes selected comments from the
same branch-local JSON linked in its header and creates a pending GitHub review
through `gh`. Each uploaded comment must point to a verified line or range in
the PR's **Files changed** view. The first version will use the worktree anchors
already captured by `treemacs-magit-review-comment` and support the PR's new-file
side, including added lines and unchanged context visible in the diff.

## Review workflow

1. Run the proposed `treemacs-magit-review-upload-to-pr` command from the review
   list. Offer the PR associated with the current branch as a default and allow
   an explicit PR URL or repository and number. Show the canonical PR URL,
   title, PR state (warning clearly when the PR is closed or merged), and head
   commit and authenticated GitHub account so the user can verify the
   destination and author, including for fork PRs. Note when local `HEAD`
   differs from the PR's `headRefOid` so the user can see why unpushed commits
   or local edits may be ineligible.
2. Open a local preview pinned to the displayed review context (repository,
   scope file, and `review_id`) showing the exact comment text and proposed
   GitHub path and line range. Preselect open comments whose locations are
   verified and let the user toggle individual items. For text-only
   relocations, show the saved snippet and proposed code with surrounding
   lines, and require the user to confirm the location before selecting it.
   Explain skips such as resolved, ambiguous, or outside-diff comments.
   During this read-only preview, also inspect the authenticated user's
   existing reviews on the PR:
   - Because GitHub allows only one pending review per user per PR, surface any
     existing pending review upfront in the preview with a link and block
     creating a second pending review in v1 until the user submits or deletes it
     on GitHub. (Appending to an existing pending review via GraphQL
     `addPullRequestReviewThread` is deferred.)
   - Show previously uploaded comments with their recorded review ID and leave
     them deselected by default. If the recorded review ID no longer exists on
     GitHub or the local comment was edited since upload, indicate that clearly
     and allow explicit re-selection.
   Preparing the preview performs only read requests to GitHub.
3. On explicit upload (requiring at least one selected eligible comment), create
   one pending review with the selected inline comments. Return a link to the PR
   and the review ID. The user can inspect the inline placements and submit the
   review on GitHub. Local comments stay available for future reference.
   [GitHub pull request reviews](https://docs.github.com/en/rest/pulls/reviews#create-a-review-for-a-pull-request)

## Verify the target and map each anchor

1. Keep the shared read-only `gh` PR metadata lookup outside
   [`treemacs-magit-mode.el`](treemacs-magit-mode.el)'s Magit/Treemacs
   dependency chain (for example, in a dedicated companion module such as
   `treemacs-magit-review-github.el` or a small standalone `gh` helper) so
   [`treemacs-magit-review.el`](treemacs-magit-review.el) remains loadable
   without eagerly loading Magit or Treemacs. Separate stdout and stderr for all
   JSON-producing `gh` invocations instead of reusing
   `treemacs-magit--process-string`'s merged output stream, so warnings on
   stderr cannot corrupt JSON parsing. Resolve `url`, `number`, `title`,
   `state`, `baseRefOid`, `headRefOid`, `headRepository`,
   `headRepositoryOwner`, and `changedFiles` via `gh pr view --json`. Parse
   the canonical `HOST`, `OWNER`, `REPO`, and `NUMBER` from the returned
   `url` (since `gh pr view --json` does not expose `baseRepository`). Route
   PR API requests to the base repository and Git object reads to the head
   repository. Build the preview without invoking the checkout helper.
   Resolve the account's stable user ID with
   `gh api --hostname HOST user` and pin it with the PR in the preview.
   [GitHub CLI PR lookup](https://cli.github.com/manual/gh_pr_view) ·
   [Authenticated user API](https://docs.github.com/en/rest/users/users#get-the-authenticated-user)
2. Read the PR's changed-file entries and patches through
   `gh api --hostname HOST --paginate --slurp repos/OWNER/REPO/pulls/NUMBER/files?per_page=100`
   and flatten the outer page arrays (`--slurp` is required because `--paginate`
   otherwise emits concatenated JSON arrays). Check the PR's base and head
   OIDs immediately before and after pagination. If either changed, discard
   every page and rebuild the preview from fresh metadata. The changed-files
   endpoint serves the current
   PR diff and accepts no revision parameters. Track right-side line numbers per
   hunk from unified diff headers (`@@ -a[,b] +c[,d] @@`, handling omitted
   counts as 1 and `+c,0` pure-deletion hunks), ignoring `\ No newline at end of
   file` lines. Verify each hunk's old/new line counts against its header and
   the patch's total added and deleted lines against the file entry's
   `additions` and `deletions`. A patch can end after a complete hunk and still
   be truncated. Report missing patches and count mismatches as unverified.
   GitHub's file listing is capped at 3,000 files; compare against `changedFiles`
   so unmapped paths on >3,000-file PRs report the API limit accurately. For
   renames, map an old path (`previous_filename`) to its new path (`filename`)
   when unambiguous; if the same path appears as both a `previous_filename` and
   a current `filename` (rename plus new file at the old path), treat it as
   ambiguous unless the original location can be traced to one file. A unique
   text-with-context match across both files may be shown for confirmation.
   [GitHub PR changed files](https://docs.github.com/en/rest/pulls/pulls#list-pull-requests-files)
3. Read the validated snapshot for the pinned review and retain its digest. Use
   the confirmed anchor when present, otherwise the original. Resolve each
   anchor in the file contents at the pinned PR head. Resolve the changed
   file's path in the tree of that exact head commit using local Git or the
   GitHub Git commit and tree APIs for the head repository. Require the path's
   blob SHA to match the changed-file entry's `sha`. If the tree or entry
   cannot be verified, skip the file with a reason. Read
   `git cat-file blob <sha>` when the verified blob exists locally, falling
   back to `GET /repos/OWNER/REPO/git/blobs/<sha>` on the head repository,
   including the fork when applicable. Decode raw blob bytes using Emacs's
   UTF-8/line-ending decoding (matching `find-file`, including CRLF-to-LF
   decoding) before matching. The recorded capture blob represents the
   committed version at capture time. An anchor can come from dirty or unsaved
   worktree text, so a matching blob ID alone cannot verify its coordinates.
   [GitHub Git trees API](https://docs.github.com/en/rest/git/trees#get-a-tree) ·
   [GitHub Git blobs API](https://docs.github.com/en/rest/git/blobs#get-a-blob)
   - Verify the saved coordinates directly when the decoded PR-head file has
     the saved whole-buffer fingerprint and the selected text matches.
   - For a shifted location, first check that the captured whole-buffer
     fingerprint matches the decoded capture blob and that the saved
     coordinates select the expected text there. Then use a capture-to-head
     diff to trace every selected line to a single unchanged, contiguous
     range. Require every shortest line alignment to agree on that range.
     If the source block was changed or removed, another alignment maps it
     differently, or the proof exceeds the preview's work limit, treat the
     mapping as unverified.
   - Reuse the case-sensitive text-with-context search from
     [`treemacs-magit-review.el`](treemacs-magit-review.el) to propose a
     location when there is exactly one candidate. A unique match can be a
     different copy of the original block. Show it as an unselected
     suggestion until the user confirms the location. Bind `case-fold-search`
     to `nil` when calling the resolver. A suggestion still needs to meet the
     diff placement checks below.
4. Convert the resolved `(start-pos, end-pos)` in the PR-head buffer to 1-based
   lines and 0-based columns, then convert the exclusive end to an inclusive
   last file line: decrement `end_line` only when `end_line > start_line` and
   `end_col == 0` (so an empty-line anchor with `start_line == end_line` and
   `end_col == 0` stays on `start_line`). Require every selected line from
   `start_line` through `line` to be present on the right side of a single hunk
   for the first version. Always send `line` and `side: "RIGHT"`; include
   `start_line` and `start_side: "RIGHT"` only when `start_line < line`,
   omitting them completely (never sending `null`) when the range collapses to a
   single line. Keep deleted lines, lines outside the visible diff, ambiguous
   matches, and edits absent from the PR in the local list with a reason.
   [GitHub line and range parameters](https://docs.github.com/en/rest/pulls/comments#create-a-review-comment-for-a-pull-request)

## Upload and handle retries

- Under the upload lock, re-read the pinned review file (ignoring any branch switch
  made elsewhere while the preview stayed open) and compare the current PR base
  and head OIDs, authenticated user ID, local review digest, and upload
  receipt with the preview. Recheck for an existing pending review before the
  POST. If the preview inputs changed, rebuild it and require the user to
  review the new placements. If a pending review appeared, show its link and
  block the upload. Supply the verified head SHA as `commit_id` so the request
  stays tied to that revision even if the PR moves after the final check. GitHub
  can show comments as outdated after later changes (or reject with `422` if a
  force-push removed `commit_id` from the PR).
  [GitHub create-review parameters](https://docs.github.com/en/rest/pulls/reviews#create-a-review-for-a-pull-request)
- Pipe the generated UTF-8 JSON to
  `gh api --hostname HOST --method POST repos/OWNER/REPO/pulls/NUMBER/reviews --input -`
  via `call-process-region` with `utf-8-unix` coding systems and separated
  stdout/stderr. Omit `event` (do not serialize `"event": null`) to create a
  pending review. Send only the selected bodies and the verified GitHub
  locations. Report authentication and API validation errors in the preview.
  [GitHub CLI request input](https://cli.github.com/manual/gh_api) · [GitHub pending reviews](https://docs.github.com/en/rest/pulls/reviews#create-a-review-for-a-pull-request)
- Persist upload receipts in the Git common directory. Key the upload lock and
  in-flight attempt by canonical PR and authenticated user ID so different
  local review files for the same PR share the guard. Use the local writer's
  lock-directory pattern with a dedicated upload lock so comment saves can
  proceed during network requests. Before sending, record the local
  `review_id`, selected comment IDs, exact submitted paths, sides, ranges and
  bodies, `commit_id`, timestamp, and existing review IDs from the preflight
  check. On success, record the returned review ID with the local comment IDs.
  The local lock covers linked worktrees that share the Git common directory.
  For independent clones and GitHub web activity, also handle a pending-review
  conflict returned by GitHub.
- After an uncertain POST outcome, keep the attempt unresolved and block
  further uploads for that PR and account. Retrieve paginated pending and
  submitted reviews by that account and exclude review IDs seen before the
  POST. Compare each candidate's commit and full set of inline comments with
  the recorded payload, preserving duplicate counts and comparing
  `original_line` and `original_start_line` when available. Use the current
  coordinates only if they can be verified against the submitted commit.
  Normalize CRLF in bodies before comparing. If exactly one candidate matches,
  record its ID. If zero or multiple candidates match, or a read fails, keep
  the attempt blocked for manual reconciliation. An empty result after a
  timeout is insufficient evidence that a new POST is safe. Keep receipts
  separate from the comment JSON so older reviews work without a schema
  migration. [GitHub review comments by review ID](https://docs.github.com/en/rest/pulls/reviews#list-comments-for-a-pull-request-review)

## Implementation and verification

1. Before building the integration, use an authorized disposable PR to
   verify that the batch endpoint creates a pending review with both a
   single-line and a multiline inline comment on the exact intended lines.
   Read them back as the authenticated reviewer with the review-specific
   comments endpoint that reconciliation will use. Verify that the pending
   review and its comments can be identified before and after submission.
   Revisit the API design if the batch placement or readback does not work.
2. Implement standalone read-only `gh` execution (separated stdout/stderr,
   `--paginate --slurp`), PR discovery, tree and blob verification, patch
   parsing, and anchor mapping. Use fixture tests for unchanged and shifted
   lines, a changed original followed by a surviving duplicate, case
   sensitivity, CRLF files, unsaved edits, rename mappings
   (including rename plus new file at the old path), visible context, blank-line
   and single-line-with-newline boundaries, omitted hunk counts and
   `\ No newline at end of file` markers, missing or truncated patches,
   truncation between complete hunks, PR changes between pages, a blob SHA
   that disagrees with the pinned head tree, and ranges crossing hunks.
3. Add the review-list preview and upload receipt. Test the workflow with a
   stubbed `gh` process, covering fork routing, closed/merged PR warnings,
   changed PR or local review snapshots, branch switch while preview is open,
   account switches, a pending review appearing before POST, concurrent
   uploads from different review files, deleted-on-GitHub receipts, and
   timeouts after GitHub accepts the review. Verify reconciliation for one,
   zero, and multiple matching reviews, including submitted reviews, original
   coordinates, and CRLF normalization. Confirm that retrying creates no
   duplicate comments and leaves submission to the user. Document the
   command and the reasons a comment can be skipped.
