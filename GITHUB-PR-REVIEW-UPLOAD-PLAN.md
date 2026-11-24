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
   commit so the user can verify the destination, including for fork PRs. Note
   when local `HEAD` differs from the PR's `headRefOid` so the user can see why
   unpushed commits or local edits may be ineligible.
2. Open a local preview pinned to the displayed review context (repository,
   scope file, and `review_id`) showing the exact comment text and proposed
   GitHub path and line range. Preselect eligible open comments and let the user
   toggle individual items; explain why each ineligible item (such as resolved,
   outdated, or outside-diff comments) was skipped. During this read-only
   preview, also inspect the authenticated user's existing reviews on the PR:
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
   `state`, `baseRefOid`, `headRefOid`, and `changedFiles` via `gh pr view
   --json`, and parse the canonical `HOST`, `OWNER`, `REPO`, and `NUMBER` from
   the returned `url` (since `gh pr view --json` does not expose
   `baseRepository`). Use that base repository and host for API requests even
   when the working branch is from a fork, and build the preview without
   invoking the checkout helper.
   [GitHub CLI PR lookup](https://cli.github.com/manual/gh_pr_view)
2. Read the PR's changed-file entries and patches through
   `gh api --hostname HOST --paginate --slurp repos/OWNER/REPO/pulls/NUMBER/files?per_page=100`
   and flatten the outer page arrays (`--slurp` is required because `--paginate`
   otherwise emits concatenated JSON arrays). Track right-side line numbers per
   hunk from unified diff headers (`@@ -a[,b] +c[,d] @@`, handling omitted
   counts as 1 and `+c,0` pure-deletion hunks), ignoring `\ No newline at end of
   file` lines and verifying each hunk's counted old/new lines against its
   header counts so missing or truncated patches are treated as unverified.
   GitHub's file listing is capped at 3,000 files; compare against `changedFiles`
   so unmapped paths on >3,000-file PRs report the API limit accurately. For
   renames, map an old path (`previous_filename`) to its new path (`filename`)
   when unambiguous; if the same path appears as both a `previous_filename` and
   a current `filename` (rename plus new file at the old path), treat it as
   ambiguous unless text-with-context matching resolves uniquely in exactly one
   of the two files.
   [GitHub PR changed files](https://docs.github.com/en/rest/pulls/pulls#list-pull-requests-files)
3. Read the validated snapshot for the pinned review and retain its digest. Use
   the confirmed anchor when present, otherwise the original. Resolve each
   anchor in the file contents at the pinned PR head using the changed file's
   blob `sha` from `/pulls/NUMBER/files`: read `git cat-file blob <sha>` when
   that object exists locally, falling back to
   `GET /repos/OWNER/REPO/git/blobs/<sha>` (which supports up to 100 MB, avoids
   the Contents API's 1 MB limit and path-escaping edge cases, and binds content
   directly to the PR file entry). Decode raw blob bytes using Emacs's
   UTF-8/line-ending decoding (matching `find-file`, including CRLF-to-LF
   decoding) before matching. Reuse the existing fingerprint and unique
   text-with-context matching in
   [`treemacs-magit-review.el`](treemacs-magit-review.el), explicitly binding
   `case-fold-search` to `nil` for case-sensitive matching. The recorded blob
   describes the committed version at capture, while the actual anchor can come
   from dirty or unsaved worktree text; require proof that the anchored text
   matches in the PR head even when the recorded blob matches.
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

- Before uploading, re-read the pinned review file (ignoring any branch switch
  made elsewhere while the preview stayed open) and compare the current PR base
  and head OIDs and the local review digest with the preview. If anything moved,
  rebuild the preview and require the user to review the new placements. Supply
  the verified head SHA as `commit_id` so the request stays tied to that
  revision even if the PR moves between the final check and the upload. GitHub
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
- Persist an upload receipt in the Git common directory alongside the review
  store, keyed by canonical PR and local `review_id`. Use the local writer's
  lock-directory pattern on the **receipt file** (never on the comment JSON's
  `.lock`, so network I/O never blocks editing or saving local comments) to stop
  concurrent uploads for the same review and PR. Before sending the request,
  record an in-flight attempt containing the selected comment IDs, exact
  submitted `(path, side, start_line, line, body)` tuples, `commit_id`, and
  timestamp; store the returned review ID on success. If the outcome is unknown,
  inspect the authenticated user's GitHub reviews on the PR (checking both
  `PENDING` reviews and recently submitted reviews in case the user already
  submitted it on GitHub) via `--paginate --slurp`, and compare each review's
  comments against the recorded attempt using `original_line` /
  `original_start_line` (falling back to `line` / `start_line`) and
  `\r\n`-normalized `body` before retrying. Ask the user to resolve an existing
  pending review that the command cannot confidently match. Keep receipts
  separate from the comment JSON so older reviews keep working without a schema
  migration.

## Implementation and verification

1. Implement standalone read-only `gh` execution (separated stdout/stderr,
   `--paginate --slurp`), PR discovery, blob fetching/decoding, patch parsing,
   and anchor mapping first. Use fixture tests for unchanged and shifted lines,
   repeated text, case sensitivity, CRLF files, unsaved edits, rename mappings
   (including rename plus new file at the old path), visible context, blank-line
   and single-line-with-newline boundaries, omitted hunk counts and
   `\ No newline at end of file` markers, missing or truncated patches,
   multi-page responses, and ranges crossing hunks.
2. Add the review-list preview and upload receipt. Test the workflow with a
   stubbed `gh` process, covering fork routing, closed/merged PR warnings,
   changed PR or local review snapshots, branch switch while preview is open,
   pre-existing pending reviews, deleted-on-GitHub receipts, retries, and
   request failure after GitHub accepts (and optionally after the user submits)
   the review, including `original_line` and `\r\n` body reconciliation.
3. With permission to use a disposable PR, create a pending review with a
   single-line and a multiline comment. Verify that GitHub accepts the batch
   payload's line and side fields and displays both comments on the exact lines.
   Confirm that retrying neither creates duplicate comments nor submits the
   pending review. Document the command and the reasons a comment can be skipped.
