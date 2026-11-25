;;; treemacs-magit-review-github-test.el --- GitHub PR review upload tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'treemacs-magit-review)
(require 'treemacs-magit-review-github)

(defconst treemacs-magit-gh-test--repo-dir
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))

;;; Test fixtures & helpers

(defun treemacs-magit-gh-test--git (&rest args)
  "Run git ARGS in `default-directory' and return trimmed stdout."
  (with-temp-buffer
    (unless (zerop (apply #'call-process "git" nil t nil args))
      (error "Test git failed: %S: %s" args (buffer-string)))
    (string-trim (buffer-string))))

(defmacro treemacs-magit-gh-test--repo (&rest body)
  "Run BODY in a fresh disposable Git repository."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (make-temp-file "gh-review-test-" t)))
          (default-directory root))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer (current-buffer))
           (treemacs-magit-gh-test--git "init" "-q" "-b" "feat/upload")
           (treemacs-magit-gh-test--git "config" "user.name" "Test User")
           (treemacs-magit-gh-test--git "config" "user.email" "test@example.invalid")
           (treemacs-magit-gh-test--git "config" "core.fsmonitor" "false")
           ,@body)
       (dolist (buffer (buffer-list))
         (with-current-buffer buffer
           (when (or (and buffer-file-name (file-in-directory-p buffer-file-name root))
                     (and treemacs-magit--review-context
                          (equal root (treemacs-magit--review-context-root
                                       treemacs-magit--review-context)))
                     (and treemacs-magit--review-gh-preview
                          (equal root (treemacs-magit--review-context-root
                                       (treemacs-magit--review-gh-preview-context
                                        treemacs-magit--review-gh-preview)))))
             (set-buffer-modified-p nil)
             (kill-buffer buffer))))
       (delete-directory root t))))

(defun treemacs-magit-gh-test--write-file (path content &optional binary)
  "Write CONTENT to PATH relative to `default-directory'."
  (when-let* ((dir (file-name-directory path)))
    (make-directory dir t))
  (let ((coding-system-for-write (if binary 'binary 'utf-8-unix)))
    (with-temp-file path
      (when binary (set-buffer-multibyte nil))
      (insert content))))

(defun treemacs-magit-gh-test--commit (msg)
  "Stage all files and commit with MSG; return full commit OID."
  (treemacs-magit-gh-test--git "add" "-A")
  (treemacs-magit-gh-test--git "commit" "-qm" msg)
  (treemacs-magit-gh-test--git "rev-parse" "HEAD"))

(defun treemacs-magit-gh-test--capture-comment
    (file line &optional body end-line end-col start-col status)
  "Capture a review comment in FILE at LINE (optional region) and save it."
  (let* ((context (treemacs-magit--review-context))
         (snapshot (treemacs-magit--review-read context))
         comment)
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (forward-line (1- line))
      (when start-col (forward-char start-col))
      (if end-line
          (let ((start (point)))
            (goto-char (point-min))
            (forward-line (1- end-line))
            (when end-col (forward-char end-col))
            (push-mark start t t)
            (let ((transient-mark-mode t))
              (setq comment
                    `((id . ,(treemacs-magit--review-id))
                      (body . ,(or body "Review note"))
                      (status . ,(or status "open"))
                      (created_at . ,(treemacs-magit--review-now))
                      (updated_at . ,(treemacs-magit--review-now))
                      (anchor . ,(treemacs-magit--review-anchor context)))))
            (deactivate-mark))
        (setq comment
              `((id . ,(treemacs-magit--review-id))
                (body . ,(or body "Review note"))
                (status . ,(or status "open"))
                (created_at . ,(treemacs-magit--review-now))
                (updated_at . ,(treemacs-magit--review-now))
                (anchor . ,(treemacs-magit--review-anchor context))))))
    (treemacs-magit--review-write
     snapshot
     (lambda (data)
       (setf (alist-get 'comments data)
             (vconcat (alist-get 'comments data) (vector comment)))))
    comment))

(defun treemacs-magit-gh-test--make-pr-json
    (base-oid head-oid &rest overrides)
  "Build a `gh pr view --json' JSON string with BASE-OID, HEAD-OID, and OVERRIDES."
  (let ((obj `((url . ,(or (plist-get overrides :url)
                           "https://github.com/baseorg/proj/pull/42"))
               (number . ,(or (plist-get overrides :number) 42))
               (title . ,(or (plist-get overrides :title) "Add feature"))
               (state . ,(or (plist-get overrides :state) "OPEN"))
               (baseRefOid . ,base-oid)
               (headRefName . ,(or (plist-get overrides :head-ref) "feat/upload"))
               (headRefOid . ,head-oid)
               (headRepository . ((name . ,(or (plist-get overrides :head-repo) "proj-fork"))))
               (headRepositoryOwner . ((login . ,(or (plist-get overrides :head-owner) "forkuser"))))
               (changedFiles . ,(or (plist-get overrides :changed-files) 1)))))
    (treemacs-magit--review-gh-encode-json obj)))

(defun treemacs-magit-gh-test--make-file-entry
    (filename sha patch additions deletions &optional status previous-filename)
  "Build a GitHub `/pulls/N/files' entry alist."
  (let ((entry `((filename . ,filename)
                 (sha . ,sha)
                 (status . ,(or status "modified"))
                 (additions . ,additions)
                 (deletions . ,deletions))))
    (when patch
      (setq entry (append entry `((patch . ,patch)))))
    (when previous-filename
      (setq entry (append entry `((previous_filename . ,previous-filename)))))
    entry))

(defun treemacs-magit-gh-test--mock-gh (handler)
  "Return a replacement function for `treemacs-magit--review-gh-run'.
HANDLER is called with (ARGS INPUT) and returns (:exit :stdout :stderr)."
  (lambda (_dir args &optional input)
    (funcall handler args input)))

;;; 1. Real subprocess `gh` test: separated stdout/stderr, UTF-8 stdin, --paginate --slurp

(ert-deftest treemacs-magit-gh-test-real-process-stdout-stderr-and-stdin ()
  (treemacs-magit-gh-test--repo
    (let* ((script (expand-file-name "fake-gh.sh" root))
           (capture-file (expand-file-name "captured-stdin.txt" root)))
      (treemacs-magit-gh-test--write-file
       script
       (format "#!/bin/sh
echo 'WARNING: gh upgrade available' >&2
if [ \"$1\" = \"api\" ] && [ \"$6\" = \"--paginate\" ]; then
  printf '[[{\"filename\":\"a.go\"}],[{\"filename\":\"b.go\"}]]'
  exit 0
fi
if [ \"$1\" = \"api\" ] && [ \"$5\" = \"POST\" ]; then
  cat > %s
  printf 'HTTP/2 200\\r\\nContent-Type: application/json\\r\\n\\r\\n{\"id\":9001,\"html_url\":\"https://github.com/o/r/pull/1#pullrequestreview-9001\"}'
  exit 0
fi
printf '{\"ok\":true}'
" (shell-quote-argument capture-file)))
      (set-file-modes script #o755)
      (let ((treemacs-magit-review-gh-program script))
        ;; Stderr warnings must not corrupt JSON stdout; --paginate --slurp flattens pages.
        (let ((files (treemacs-magit--review-gh-api-json
                      root "github.com" "GET" "repos/o/r/pulls/1/files?per_page=100" nil t)))
          (should (equal (mapcar (lambda (e) (alist-get 'filename e)) files)
                         '("a.go" "b.go"))))
        ;; UTF-8 stdin piping via call-process-region and HTTP response splitting.
        (let* ((payload "{\"body\":\"naïve ✓\"}")
               (resp (treemacs-magit--review-gh-api
                      root "github.com" "POST" "repos/o/r/pulls/1/reviews" payload nil t))
               (parsed (treemacs-magit--review-gh-parse-http-response (plist-get resp :stdout))))
          (should (zerop (plist-get resp :exit)))
          (should (string-match-p "WARNING: gh upgrade" (plist-get resp :stderr)))
          (should (= (plist-get parsed :status) 200))
          (should (= (alist-get 'id (treemacs-magit--review-gh-parse-json
                                     (plist-get parsed :body)))
                     9001))
          (should (equal (with-temp-buffer
                           (let ((coding-system-for-read 'utf-8-unix))
                             (insert-file-contents capture-file))
                           (buffer-string))
                         payload)))))))

(ert-deftest treemacs-magit-gh-test-standalone-load-without-magit-or-treemacs ()
  (let ((emacs (expand-file-name invocation-name invocation-directory)))
    (with-temp-buffer
      (should (zerop (call-process
                      emacs nil t nil "--batch" "-Q"
                      "-L" treemacs-magit-gh-test--repo-dir
                      "-l" "treemacs-magit-review-github"
                      "--eval"
                      "(progn (when (featurep 'magit) (error \"magit loaded\"))
                              (when (featurep 'treemacs) (error \"treemacs loaded\")))"))))))

;;; 2. PR target & URL parsing

(ert-deftest treemacs-magit-gh-test-parse-target-and-url ()
  (should (equal (treemacs-magit--review-gh-parse-target nil)
                 '(:selector nil :repo nil)))
  (should (equal (treemacs-magit--review-gh-parse-target 17)
                 '(:selector "17" :repo nil)))
  (should (equal (treemacs-magit--review-gh-parse-target "https://ghe.corp.example/org/app/pull/88/files")
                 '(:selector "https://ghe.corp.example/org/app/pull/88/files" :repo nil)))
  (should (equal (treemacs-magit--review-gh-parse-target "org/app#88")
                 '(:selector "88" :repo "org/app")))
  (should (equal (treemacs-magit--review-gh-parse-target "ghe.corp.example/org/app 88")
                 '(:selector "88" :repo "ghe.corp.example/org/app")))
  (should-error (treemacs-magit--review-gh-parse-target 0) :type 'user-error)
  (should-error (treemacs-magit--review-gh-parse-target "not-a-pr") :type 'user-error)
  (let ((parsed (treemacs-magit--review-gh-parse-pr-url
                 "https://ghe.corp.example/org/app/pull/88/commits")))
    (should (equal (plist-get parsed :host) "ghe.corp.example"))
    (should (equal (plist-get parsed :owner) "org"))
    (should (equal (plist-get parsed :repo) "app"))
    (should (= (plist-get parsed :number) 88))
    (should (equal (plist-get parsed :url) "https://ghe.corp.example/org/app/pull/88"))))

;;; 3. Strict unified diff patch parser tests

(ert-deftest treemacs-magit-gh-test-patch-parsing-edge-cases ()
  ;; Omitted counts, pure deletion hunk, and "\ No newline at end of file".
  (let* ((patch (concat "@@ -1 +1 @@\n"
                        "-old\n"
                        "\\ No newline at end of file\n"
                        "+new\n"
                        "\\ No newline at end of file\n"
                        "@@ -5,2 +4,0 @@\n"
                        "-gone1\n"
                        "-gone2"))
         (entry (treemacs-magit-gh-test--make-file-entry "a.txt" "sha1" patch 1 3))
         (parsed (treemacs-magit--review-gh-parse-patch entry)))
    (should (eq (plist-get parsed :status) 'ok))
    (should (= (length (plist-get parsed :hunks)) 2))
    (should (gethash 1 (plist-get (nth 0 (plist-get parsed :hunks)) :right-lines)))
    (should (= (hash-table-count (plist-get (nth 1 (plist-get parsed :hunks)) :right-lines)) 0)))
  ;; Missing patch (binary / large / unchanged rename).
  (should (eq (plist-get (treemacs-magit--review-gh-parse-patch
                          (treemacs-magit-gh-test--make-file-entry "img.png" "sha" nil 0 0))
                         :status)
              'missing-patch))
  ;; Deleted file.
  (should (eq (plist-get (treemacs-magit--review-gh-parse-patch
                          (treemacs-magit-gh-test--make-file-entry "old.txt" "sha" "@@ -1 +0,0 @@\n-x" 0 1 "removed"))
                         :status)
              'deleted-file))
  ;; Truncated inside a hunk (header promises 2 new lines, only 1 present).
  (should (eq (plist-get (treemacs-magit--review-gh-parse-patch
                          (treemacs-magit-gh-test--make-file-entry
                           "a.txt" "sha" "@@ -1,1 +1,2 @@\n same" 1 0))
                         :status)
              'truncated-patch))
  ;; Truncated BETWEEN complete hunks (hunk 1 is complete, but additions total mismatches).
  (should (eq (plist-get (treemacs-magit--review-gh-parse-patch
                          (treemacs-magit-gh-test--make-file-entry
                           "a.txt" "sha" "@@ -1,1 +1,2 @@\n same\n+added1" 3 0))
                         :status)
              'truncated-patch)))

;;; 4. PR changes between pages -> discards pages and rebuilds

(ert-deftest treemacs-magit-gh-test-pr-moves-during-pagination-rebuilds ()
  (treemacs-magit-gh-test--repo
    (let ((view-calls 0)
          (files-calls 0))
      (cl-letf (((symbol-function 'treemacs-magit--review-gh-run)
                 (treemacs-magit-gh-test--mock-gh
                  (lambda (args _input)
                    (cond
                     ((equal (car args) "pr")
                      (cl-incf view-calls)
                      ;; Call 1: head1, Call 2 (after page 1): head2 (moved!),
                      ;; Call 3: head2, Call 4 (after page 2): head2 (stable!).
                      (let ((head (if (= view-calls 1) "head1" "head2")))
                        (list :exit 0
                              :stdout (treemacs-magit-gh-test--make-pr-json "base1" head)
                              :stderr "")))
                     ((member "repos/baseorg/proj/pulls/42/files?per_page=100" args)
                      (cl-incf files-calls)
                      (let ((fname (if (= files-calls 1) "stale.go" "fresh.go")))
                        (list :exit 0
                              :stdout (format "[[{\"filename\":\"%s\"}]]" fname)
                              :stderr ""))))))))
        (let ((res (treemacs-magit--review-gh-fetch-pr-and-files root nil)))
          (should (= view-calls 4))
          (should (= files-calls 2))
          (should (equal (treemacs-magit--review-gh-pr-head-oid (plist-get res :pr)) "head2"))
          (should (equal (alist-get 'filename (car (plist-get res :files))) "fresh.go")))))))

;;; 5. Fork routing, remote tree/blob verification, and blob SHA disagreement

(ert-deftest treemacs-magit-gh-test-fork-routing-and-blob-mismatch ()
  (treemacs-magit-gh-test--repo
    (treemacs-magit-gh-test--write-file "pkg/app.go" "package pkg\n\nfunc run() {}\n")
    (let ((base-oid (treemacs-magit-gh-test--commit "base")))
      (treemacs-magit-gh-test--capture-comment "pkg/app.go" 3 "Remote verified comment")
      ;; Use a remote-only head OID not present in local Git so remote Git API is exercised.
      (let* ((remote-head "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
             (remote-content "package pkg\n\nfunc run() {}\n")
             (good-sha "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
             (bad-sha "cccccccccccccccccccccccccccccccccccccccc")
             (called-endpoints nil)
             (patch "@@ -1,2 +1,3 @@\n package pkg\n \n+func run() {}")
             (make-handler
              (lambda (tree-blob-sha)
                (treemacs-magit-gh-test--mock-gh
                 (lambda (args _input)
                   (let ((endpoint (car (last args))))
                     (push endpoint called-endpoints)
                     (cond
                      ((equal (car args) "pr")
                       (list :exit 0
                             :stdout (treemacs-magit-gh-test--make-pr-json
                                      base-oid remote-head
                                      :head-owner "forkuser"
                                      :head-repo "proj-fork")
                             :stderr ""))
                      ((equal endpoint "user")
                       (list :exit 0 :stdout "{\"id\":77,\"login\":\"reviewer\"}" :stderr ""))
                      ((string-match-p "/pulls/42/reviews" endpoint)
                       (list :exit 0 :stdout "[[]]" :stderr ""))
                      ((string-match-p "/pulls/42/files" endpoint)
                       (list :exit 0
                             :stdout (treemacs-magit--review-gh-encode-json
                                      (vector (vector (treemacs-magit-gh-test--make-file-entry
                                                       "pkg/app.go" good-sha patch 1 0))))
                             :stderr ""))
                      ((equal endpoint (format "repos/forkuser/proj-fork/git/commits/%s" remote-head))
                       (list :exit 0 :stdout "{\"tree\":{\"sha\":\"root-tree\"}}" :stderr ""))
                      ((equal endpoint "repos/forkuser/proj-fork/git/trees/root-tree")
                       (list :exit 0
                             :stdout "{\"truncated\":false,\"tree\":[{\"path\":\"pkg\",\"type\":\"tree\",\"sha\":\"pkg-tree\"}]}"
                             :stderr ""))
                      ((equal endpoint "repos/forkuser/proj-fork/git/trees/pkg-tree")
                       (list :exit 0
                             :stdout (format "{\"truncated\":false,\"tree\":[{\"path\":\"app.go\",\"type\":\"blob\",\"sha\":\"%s\"}]}"
                                             tree-blob-sha)
                             :stderr ""))
                      ((equal endpoint (format "repos/forkuser/proj-fork/git/blobs/%s" good-sha))
                       (list :exit 0
                             :stdout (treemacs-magit--review-gh-encode-json
                                      `((encoding . "base64")
                                        (content . ,(base64-encode-string remote-content))))
                             :stderr ""))
                      (t (error "Unexpected endpoint: %S" args)))))))))
        ;; Happy fork path: PR endpoints hit baseorg/proj, Git objects hit forkuser/proj-fork.
        (cl-letf (((symbol-function 'treemacs-magit--review-gh-run)
                   (funcall make-handler good-sha)))
          (let* ((preview (treemacs-magit--review-gh-build-preview
                           (treemacs-magit--review-context) nil))
                 (item (car (treemacs-magit--review-gh-preview-items preview))))
            (should (eq (treemacs-magit--review-gh-item-status item) 'exact))
            (should (treemacs-magit--review-gh-item-selected item))
            (should (= (treemacs-magit--review-gh-item-line item) 3))
            (should (member "repos/baseorg/proj/pulls/42/files?per_page=100" called-endpoints))
            (should (member (format "repos/forkuser/proj-fork/git/commits/%s" remote-head)
                            called-endpoints))
            (should (member (format "repos/forkuser/proj-fork/git/blobs/%s" good-sha)
                            called-endpoints))))
        ;; Blob SHA disagrees with pinned head tree -> skipped as blob-mismatch.
        (cl-letf (((symbol-function 'treemacs-magit--review-gh-run)
                   (funcall make-handler bad-sha)))
          (let* ((preview (treemacs-magit--review-gh-build-preview
                           (treemacs-magit--review-context) nil))
                 (item (car (treemacs-magit--review-gh-preview-items preview))))
            (should (eq (treemacs-magit--review-gh-item-status item) 'blob-mismatch))
            (should-not (treemacs-magit--review-gh-item-selected item))))))))

;;; 6. Anchor mapping: shifted, changed-original+surviving-duplicate, case-sensitivity,
;;;    CRLF, unsaved edits, renames, boundaries, visible context, crossing hunks

(ert-deftest treemacs-magit-gh-test-anchor-mapping-tiers-and-duplicates ()
  (treemacs-magit-gh-test--repo
    ;; Commit 1 (capture): file with a normal block, two blocks with identical
    ;; 2-line surrounding context, and a case-sensitive line.
    (treemacs-magit-gh-test--write-file
     "code.txt"
     (concat "line1\n"
             "shift_target\n"
             "line3\n"
             "sepA\n"
             "ctx_b1\n"
             "ctx_b2\n"
             "dup_body\n"
             "ctx_a1\n"
             "ctx_a2\n"
             "sepB\n"
             "ctx_b1\n"
             "ctx_b2\n"
             "dup_body\n"
             "ctx_a1\n"
             "ctx_a2\n"
             "AlphaCase\n"))
    (let ((base-oid (treemacs-magit-gh-test--commit "capture")))
      (let* ((c-shift (treemacs-magit-gh-test--capture-comment "code.txt" 2 "Shifted"))
             ;; Anchor on first dup_body (line 7), which will be edited in head while line 13 survives.
             (c-dup (treemacs-magit-gh-test--capture-comment "code.txt" 7 "Changed orig + surviving dup"))
             (c-case (treemacs-magit-gh-test--capture-comment "code.txt" 16 "Case sensitive")))
        ;; Commit 2 (PR head): insert 2 lines at top (shifts line 2 -> line 4),
        ;; change first dup_body -> changed_body while second dup_body survives at line 15,
        ;; and lowercase AlphaCase -> alphacase.
        (treemacs-magit-gh-test--write-file
         "code.txt"
         (concat "hdr1\n"
                 "hdr2\n"
                 "line1\n"
                 "shift_target\n"
                 "line3\n"
                 "sepA\n"
                 "ctx_b1\n"
                 "ctx_b2\n"
                 "changed_body\n"
                 "ctx_a1\n"
                 "ctx_a2\n"
                 "sepB\n"
                 "ctx_b1\n"
                 "ctx_b2\n"
                 "dup_body\n"
                 "ctx_a1\n"
                 "ctx_a2\n"
                 "alphacase\n"))
        (let* ((head-oid (treemacs-magit-gh-test--commit "head"))
               (head-sha (treemacs-magit-gh-test--git "rev-parse" (concat head-oid ":code.txt")))
               ;; Make all 18 lines visible in one hunk for testing anchor resolution.
               (patch (concat "@@ -1,16 +1,18 @@\n"
                              "+hdr1\n+hdr2\n line1\n shift_target\n line3\n sepA\n"
                              " ctx_b1\n ctx_b2\n-dup_body\n+changed_body\n ctx_a1\n ctx_a2\n"
                              " sepB\n ctx_b1\n ctx_b2\n dup_body\n ctx_a1\n ctx_a2\n"
                              "-AlphaCase\n+alphacase"))
               (files (list (treemacs-magit-gh-test--make-file-entry
                             "code.txt" head-sha patch 4 2)))
               (idx (treemacs-magit--review-gh-index-files files))
               (pr (treemacs-magit--review-gh-pr-create
                    :url "https://github.com/o/r/pull/1" :host "github.com"
                    :owner "o" :repo "r" :number 1 :title "Test PR" :state "OPEN"
                    :base-oid base-oid :head-oid head-oid
                    :head-owner "o" :head-repo "r"))
               (cache (make-hash-table :test #'equal)))
          ;; 1. Unambiguously shifted line -> verified (`shifted`) and preselected at line 4.
          (let ((it (treemacs-magit--review-gh-map-comment
                     root pr c-shift idx nil cache nil)))
            (should (eq (treemacs-magit--review-gh-item-status it) 'shifted))
            (should (treemacs-magit--review-gh-item-selected it))
            (should (treemacs-magit--review-gh-item-confirmed it))
            (should (= (treemacs-magit--review-gh-item-line it) 4)))
          ;; 2. Changed original + surviving duplicate -> NOT auto-selected!
          ;;    Shown as unselected `suggested` (line 15) requiring confirmation.
          (let ((it (treemacs-magit--review-gh-map-comment
                     root pr c-dup idx nil cache nil)))
            (should (eq (treemacs-magit--review-gh-item-status it) 'suggested))
            (should-not (treemacs-magit--review-gh-item-selected it))
            (should-not (treemacs-magit--review-gh-item-confirmed it))
            (should (= (treemacs-magit--review-gh-item-line it) 15))
            (should (stringp (treemacs-magit--review-gh-item-saved-snippet it)))
            (should (string-match-p ">   15 | dup_body"
                                    (treemacs-magit--review-gh-item-proposed-snippet it)))
            ;; Interactive confirmation guard: cannot toggle until confirmed with `c'.
            (with-temp-buffer
              (treemacs-magit-review-upload-mode)
              (let ((preview (treemacs-magit--review-gh-preview-create
                              :context (treemacs-magit--review-context)
                              :pr pr
                              :account (treemacs-magit--review-gh-account-create :id "1" :login "u")
                              :items (list it))))
                (treemacs-magit--review-gh-render-preview preview)
                (should-error (treemacs-magit--review-gh-toggle-item) :type 'user-error)
                (treemacs-magit--review-gh-confirm-item)
                (should (treemacs-magit--review-gh-item-confirmed it))
                (should (treemacs-magit--review-gh-item-selected it))
                (treemacs-magit--review-gh-toggle-item)
                (should-not (treemacs-magit--review-gh-item-selected it)))))
          ;; 3. Case-sensitive search: "AlphaCase" does NOT match "alphacase".
          (let ((it (treemacs-magit--review-gh-map-comment
                     root pr c-case idx nil cache nil)))
            (should (eq (treemacs-magit--review-gh-item-status it) 'outdated))
            (should-not (treemacs-magit--review-gh-item-selected it))))))))

(ert-deftest treemacs-magit-gh-test-ambiguous-diff-alignment-not-auto-verified ()
  (dolist (fixture '(("X\nY\nX\nY\n" "X\nY\n" 3)
                     ;; Both the forward and reversed Git diffs map the first
                     ;; old "a" to line 2, but line 1 is an equally good match.
                     ("c\na\nb\nb\nb\na\n" "a\na\nb\nc\na\n" 2)))
    (treemacs-magit-gh-test--repo
      (pcase-let ((`(,old ,new ,line) fixture))
        (treemacs-magit-gh-test--write-file "rep.txt" old)
        (let* ((base (treemacs-magit-gh-test--commit "capture"))
               (comment (treemacs-magit-gh-test--capture-comment "rep.txt" line)))
          (treemacs-magit-gh-test--write-file "rep.txt" new)
          (let* ((head (treemacs-magit-gh-test--commit "PR head"))
                 (sha (treemacs-magit-gh-test--git "rev-parse" (concat head ":rep.txt")))
                 (diff (treemacs-magit-gh-test--git "diff" "--no-color" base head "--" "rep.txt"))
                 (patch (substring diff (string-match "^@@" diff)))
                 (lines (split-string patch "\n"))
                 (additions (cl-count-if (lambda (s) (string-prefix-p "+" s)) lines))
                 (deletions (cl-count-if (lambda (s) (string-prefix-p "-" s)) lines))
                 (entry (treemacs-magit-gh-test--make-file-entry
                         "rep.txt" sha patch additions deletions))
                 (index (treemacs-magit--review-gh-index-files (list entry)))
                 (pr (treemacs-magit--review-gh-pr-create :base-oid base :head-oid head))
                 (item (treemacs-magit--review-gh-map-comment
                        root pr comment index nil (make-hash-table :test #'equal) nil)))
            (should (memq (treemacs-magit--review-gh-item-status item)
                          '(ambiguous suggested outdated)))
            (should-not (treemacs-magit--review-gh-item-selected item))))))))

(ert-deftest treemacs-magit-gh-test-crlf-unsaved-edits-and-boundaries ()
  (treemacs-magit-gh-test--repo
    ;; CRLF file committed in Git.
    (treemacs-magit-gh-test--write-file "win.txt" "one\r\n\r\nthree\r\nfour\r\n" t)
    (let ((base-oid (treemacs-magit-gh-test--commit "crlf")))
      (let* (;; Blank line anchor (line 2, start=2:0, end=2:0, text="").
             (c-blank (treemacs-magit-gh-test--capture-comment "win.txt" 2 "Blank line"))
             ;; Single-line region ending at col 0 of next line (3:0 .. 4:0) -> collapses to single line 3.
             (c-one-nl (treemacs-magit-gh-test--capture-comment "win.txt" 3 "One with nl" 4 0 0))
             ;; Multiline region ending at col 0 of line 5 (3:0 .. 5:0) -> lines 3..4.
             (c-multi-nl (treemacs-magit-gh-test--capture-comment "win.txt" 3 "Multi with nl" 5 0 0))
             ;; Unsaved worktree edit absent from PR head (even though anchor.blob matches HEAD!).
             (c-unsaved
              (with-current-buffer (find-file-noselect "win.txt")
                (goto-char (point-min))
                (insert "UNSAVED_LOCAL_ONLY\n")
                (treemacs-magit-gh-test--capture-comment "win.txt" 1 "Unsaved edit"))))
        (with-current-buffer (find-file-noselect "win.txt")
          (set-buffer-modified-p nil)
          (revert-buffer t t))
        (let* ((head-sha (treemacs-magit-gh-test--git "rev-parse" (concat base-oid ":win.txt")))
               (patch "@@ -0,0 +1,4 @@\n+one\n+\n+three\n+four")
               (files (list (treemacs-magit-gh-test--make-file-entry
                             "win.txt" head-sha patch 4 0 "added")))
               (idx (treemacs-magit--review-gh-index-files files))
               (pr (treemacs-magit--review-gh-pr-create
                    :url "https://github.com/o/r/pull/1" :host "github.com"
                    :owner "o" :repo "r" :number 1 :base-oid base-oid :head-oid base-oid
                    :head-owner "o" :head-repo "r"))
               (cache (make-hash-table :test #'equal)))
          ;; Blank line on CRLF file stays on line 2, omits start_line/start_side.
          (let* ((it (treemacs-magit--review-gh-map-comment root pr c-blank idx nil cache nil))
                 (payload (treemacs-magit--review-gh-item-payload it)))
            (should (eq (treemacs-magit--review-gh-item-status it) 'exact))
            (should (= (treemacs-magit--review-gh-item-line it) 2))
            (should-not (treemacs-magit--review-gh-item-start-line it))
            (should-not (assq 'start_line payload))
            (should-not (assq 'start_side payload)))
          ;; Single-line region ending at col 0 of line 4 collapses to line 3 only.
          (let* ((it (treemacs-magit--review-gh-map-comment root pr c-one-nl idx nil cache nil))
                 (payload (treemacs-magit--review-gh-item-payload it)))
            (should (eq (treemacs-magit--review-gh-item-status it) 'exact))
            (should (= (treemacs-magit--review-gh-item-line it) 3))
            (should-not (treemacs-magit--review-gh-item-start-line it))
            (should-not (assq 'start_line payload)))
          ;; Multiline region ending at col 0 of line 5 becomes start_line=3, line=4.
          (let* ((it (treemacs-magit--review-gh-map-comment root pr c-multi-nl idx nil cache nil))
                 (payload (treemacs-magit--review-gh-item-payload it)))
            (should (eq (treemacs-magit--review-gh-item-status it) 'exact))
            (should (= (alist-get 'start_line payload) 3))
            (should (equal (alist-get 'start_side payload) "RIGHT"))
            (should (= (alist-get 'line payload) 4))
            (should (equal (alist-get 'side payload) "RIGHT")))
          ;; Unsaved edit absent from PR head is NOT verified even though recorded blob matches.
          (let ((it (treemacs-magit--review-gh-map-comment root pr c-unsaved idx nil cache nil)))
            (should (eq (treemacs-magit--review-gh-item-status it) 'outdated))
            (should-not (treemacs-magit--review-gh-item-selected it))))))))

(ert-deftest treemacs-magit-gh-test-renames-recreated-path-and-hunk-checks ()
  (treemacs-magit-gh-test--repo
    ;; Initial file a.go and multi-hunk file multi.go.
    (treemacs-magit-gh-test--write-file "a.go" "package p\nfunc oldFn() {}\n")
    (treemacs-magit-gh-test--write-file
     "multi.go"
     "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n")
    (let ((base-oid (treemacs-magit-gh-test--commit "base")))
      (let* ((c-rename (treemacs-magit-gh-test--capture-comment "a.go" 2 "Renamed comment"))
             (c-cross (treemacs-magit-gh-test--capture-comment "multi.go" 2 "Crosses hunks" 9 2 0))
             (c-outside (treemacs-magit-gh-test--capture-comment "multi.go" 5 "Outside diff"))
             (c-resolved (treemacs-magit-gh-test--capture-comment "multi.go" 2 "Resolved" nil nil nil "resolved")))
        ;; Rename a.go -> b.go AND create a brand-new a.go with different contents.
        (treemacs-magit-gh-test--write-file "b.go" "package p\nfunc oldFn() {}\n// added\n")
        (treemacs-magit-gh-test--write-file "a.go" "package p\nfunc brandNew() {}\n")
        (let* ((head-oid (treemacs-magit-gh-test--commit "rename-and-recreate"))
               (a-sha (treemacs-magit-gh-test--git "rev-parse" (concat head-oid ":a.go")))
               (b-sha (treemacs-magit-gh-test--git "rev-parse" (concat head-oid ":b.go")))
               (m-sha (treemacs-magit-gh-test--git "rev-parse" (concat head-oid ":multi.go")))
               (files (list
                       (treemacs-magit-gh-test--make-file-entry
                        "b.go" b-sha "@@ -1,2 +1,3 @@\n package p\n func oldFn() {}\n+// added" 1 0 "renamed" "a.go")
                       (treemacs-magit-gh-test--make-file-entry
                        "a.go" a-sha "@@ -0,0 +1,2 @@\n+package p\n+func brandNew() {}" 2 0 "added")
                       ;; multi.go has two separate hunks covering lines 1-3 and 8-10 (line 5 outside).
                       (treemacs-magit-gh-test--make-file-entry
                        "multi.go" m-sha
                        "@@ -1,2 +1,3 @@\n+l1\n l2\n l3\n@@ -8,2 +8,3 @@\n l8\n l9\n+l10"
                        2 0 "modified")))
               (idx (treemacs-magit--review-gh-index-files files))
               (pr (treemacs-magit--review-gh-pr-create
                    :url "https://github.com/o/r/pull/1" :host "github.com"
                    :owner "o" :repo "r" :number 1 :title "Test PR" :state "OPEN"
                    :base-oid base-oid :head-oid head-oid
                    :head-owner "o" :head-repo "r"))
               (cache (make-hash-table :test #'equal)))
          ;; Traced cleanly to b.go via capture blob -> head diff!
          (let ((it (treemacs-magit--review-gh-map-comment root pr c-rename idx nil cache nil)))
            (should (eq (treemacs-magit--review-gh-item-status it) 'shifted))
            (should (equal (treemacs-magit--review-gh-item-path it) "b.go"))
            (should (= (treemacs-magit--review-gh-item-line it) 2)))
          ;; Range 2..9 crosses two hunks -> skipped (actually includes line 5 outside diff too;
          ;; let's also test adjacent hunks covering every line).
          (let ((it (treemacs-magit--review-gh-map-comment root pr c-outside idx nil cache nil)))
            (should (eq (treemacs-magit--review-gh-item-status it) 'outside-diff)))
          (let ((it (treemacs-magit--review-gh-map-comment root pr c-resolved idx nil cache nil)))
            (should (eq (treemacs-magit--review-gh-item-status it) 'resolved)))
          ;; Adjacent hunks covering lines 2..5 in hunk 1 and 6..9 in hunk 2 -> crosses-hunks.
          (let* ((adj-files (list (treemacs-magit-gh-test--make-file-entry
                                   "multi.go" m-sha
                                   "@@ -2,3 +2,4 @@\n+l2\n l3\n l4\n l5\n@@ -6,3 +6,4 @@\n l6\n l7\n l8\n+l9"
                                   2 0 "modified")))
                 (adj-idx (treemacs-magit--review-gh-index-files adj-files))
                 (it (treemacs-magit--review-gh-map-comment root pr c-cross adj-idx nil cache nil)))
            (should (eq (treemacs-magit--review-gh-item-status it) 'crosses-hunks)))
          ;; File not in PR when files-truncated is t -> pr-file-limit.
          (let* ((other-comment (copy-tree c-outside t)))
            (setf (alist-get 'path (alist-get 'anchor other-comment)) "unlisted.go")
            (let ((it (treemacs-magit--review-gh-map-comment root pr other-comment idx t cache nil)))
              (should (eq (treemacs-magit--review-gh-item-status it) 'pr-file-limit)))))))))

;;; 7. End-to-end preview, preflight guards, concurrent locks, receipts, and reconciliation

(ert-deftest treemacs-magit-gh-test-upload-preflight-guards-and-receipt ()
  (treemacs-magit-gh-test--repo
    (treemacs-magit-gh-test--write-file "main.go" "package main\nfunc main() {\n\tprintln(1)\n}\n")
    (let ((base-oid (treemacs-magit-gh-test--commit "init")))
      (treemacs-magit-gh-test--capture-comment "main.go" 2 "Single line note")
      (treemacs-magit-gh-test--capture-comment "main.go" 2 "Multi line note" 3 10 0)
      (let* ((sha (treemacs-magit-gh-test--git "rev-parse" (concat base-oid ":main.go")))
             (patch "@@ -0,0 +1,4 @@\n+package main\n+func main() {\n+\tprintln(1)\n+}")
             (pr-state "MERGED")
             (pr-head base-oid)
             (account-id 101)
             (account-login "alice")
             (reviews-list nil)
             (post-payloads nil)
             (handler
              (treemacs-magit-gh-test--mock-gh
               (lambda (args input)
                 (let ((endpoint (car (last args))))
                   (cond
                    ((equal (car args) "pr")
                     (list :exit 0
                           :stdout (treemacs-magit-gh-test--make-pr-json
                                    base-oid pr-head :state pr-state)
                           :stderr ""))
                    ((equal endpoint "user")
                     (list :exit 0
                           :stdout (format "{\"id\":%d,\"login\":\"%s\"}" account-id account-login)
                           :stderr ""))
                    ((string-match-p "/pulls/42/files" endpoint)
                     (list :exit 0
                           :stdout (treemacs-magit--review-gh-encode-json
                                    (vector (vector (treemacs-magit-gh-test--make-file-entry
                                                     "main.go" sha patch 4 0 "added"))))
                           :stderr ""))
                    ((and (member "GET" args) (string-match-p "/pulls/42/reviews\\?" endpoint))
                     (list :exit 0
                           :stdout (treemacs-magit--review-gh-encode-json
                                    (vector (vconcat reviews-list)))
                           :stderr ""))
                    ((and (member "POST" args) (string-match-p "/pulls/42/reviews\\'" endpoint))
                     (push (treemacs-magit--review-gh-parse-json input) post-payloads)
                     (let ((created `((id . 555)
                                      (state . "PENDING")
                                      (commit_id . ,pr-head)
                                      (user . ((id . ,account-id) (login . ,account-login)))
                                      (html_url . "https://github.com/baseorg/proj/pull/42#pullrequestreview-555"))))
                       (push created reviews-list)
                       (list :exit 0
                             :stdout (concat "HTTP/2 200\r\n\r\n"
                                             (treemacs-magit--review-gh-encode-json created))
                             :stderr "")))
                    (t (error "Unexpected gh call: %S" args))))))))
        (cl-letf (((symbol-function 'treemacs-magit--review-gh-run) handler))
          (let* ((ctx (treemacs-magit--review-context))
                 (preview (treemacs-magit--review-gh-build-preview ctx nil)))
            ;; Preview renders merged warning and both comments preselected.
            (with-temp-buffer
              (treemacs-magit-review-upload-mode)
              (treemacs-magit--review-gh-render-preview preview)
              (should (string-match-p "WARNING: Pull request state is MERGED" (buffer-string)))
              (should (string-match-p "Account:    @alice (id 101)" (buffer-string))))
            ;; Guard 1: Account switch before POST -> rebuilds without posting.
            (setq account-id 202 account-login "bob")
            (let ((res (treemacs-magit--review-gh-upload-execute preview)))
              (should (eq (plist-get res :status) 'rebuilt))
              (should-not post-payloads))
            (setq account-id 101 account-login "alice")
            ;; Guard 2: PR head moves before POST -> rebuilds without posting.
            (setq pr-head "dddddddddddddddddddddddddddddddddddddddd")
            (let ((res (treemacs-magit--review-gh-upload-execute preview)))
              (should (eq (plist-get res :status) 'rebuilt))
              (should-not post-payloads))
            (setq pr-head base-oid)
            ;; Guard 3: Pending review appears before POST -> blocks without posting.
            (setq reviews-list `(((id . 444) (state . "PENDING")
                                  (user . ((id . 101) (login . "alice")))
                                  (html_url . "https://github.com/baseorg/proj/pull/42#pullrequestreview-444"))))
            (let ((res (treemacs-magit--review-gh-upload-execute preview)))
              (should (eq (plist-get res :status) 'blocked))
              (should-not post-payloads))
            (setq reviews-list nil)
            ;; Guard 4: Branch switch while preview is open still checks pinned scope file,
            ;; and modifying the pinned review JSON triggers rebuild!
            (treemacs-magit-gh-test--git "checkout" "-qb" "other/branch")
            (let ((res (treemacs-magit--review-gh-upload-execute preview)))
              ;; Pinned scope file did NOT change on branch switch -> upload succeeds!
              (should (eq (plist-get res :status) 'uploaded))
              (should (= (plist-get res :review-id) 555))
              (should (= (length post-payloads) 1))
              (let ((sent (car post-payloads)))
                ;; Must omit `event` (pending review) and supply `commit_id`.
                (should-not (assq 'event sent))
                (should (equal (alist-get 'commit_id sent) base-oid))
                (should (= (length (alist-get 'comments sent)) 2)))
              ;; Fresh preview shows previously uploaded comments deselected + pending review notice.
              (let ((fresh (plist-get res :preview)))
                (should (treemacs-magit--review-gh-preview-existing-pending-review fresh))
                (dolist (it (treemacs-magit--review-gh-preview-items fresh))
                  (should-not (treemacs-magit--review-gh-item-selected it))
                  (should (= (plist-get (treemacs-magit--review-gh-item-previous-upload it)
                                        :review-id)
                             555))))
              ;; Once the first review is submitted, an older preview must
              ;; still see the new receipt and require a fresh selection.
              (setf (alist-get 'state (car reviews-list)) "COMMENTED")
              (let* ((again (treemacs-magit--review-gh-upload-execute preview))
                     (fresh (plist-get again :preview)))
                (should (eq (plist-get again :status) 'rebuilt))
                (should (= (length post-payloads) 1))
                (should-not (treemacs-magit--review-gh-preview-existing-pending-review fresh))
                (dolist (item (treemacs-magit--review-gh-preview-items fresh))
                  (should-not (treemacs-magit--review-gh-item-selected item))))
              ;; If review #555 is deleted on GitHub, preview reports `[deleted on GitHub]`.
              (setq reviews-list nil)
              (let ((after-del (treemacs-magit--review-gh-build-preview ctx nil)))
                (with-temp-buffer
                  (treemacs-magit-review-upload-mode)
                  (treemacs-magit--review-gh-render-preview after-del)
                  (should (string-match-p "deleted on GitHub" (buffer-string))))))))))))

(ert-deftest treemacs-magit-gh-test-local-review-change-rebuilds-before-post ()
  (treemacs-magit-gh-test--repo
    (treemacs-magit-gh-test--write-file "f.txt" "hello\nworld\n")
    (let ((base-oid (treemacs-magit-gh-test--commit "init")))
      (treemacs-magit-gh-test--capture-comment "f.txt" 1 "First")
      (let* ((sha (treemacs-magit-gh-test--git "rev-parse" (concat base-oid ":f.txt")))
             (patch "@@ -0,0 +1,2 @@\n+hello\n+world")
             (posted nil)
             (handler
              (treemacs-magit-gh-test--mock-gh
               (lambda (args _input)
                 (let ((ep (car (last args))))
                   (cond
                    ((equal (car args) "pr")
                     (list :exit 0 :stdout (treemacs-magit-gh-test--make-pr-json base-oid base-oid) :stderr ""))
                    ((equal ep "user")
                     (list :exit 0 :stdout "{\"id\":10,\"login\":\"u\"}" :stderr ""))
                    ((string-match-p "/files" ep)
                     (list :exit 0
                           :stdout (treemacs-magit--review-gh-encode-json
                                    (vector (vector (treemacs-magit-gh-test--make-file-entry
                                                     "f.txt" sha patch 2 0 "added"))))
                           :stderr ""))
                    ((and (member "GET" args) (string-match-p "/reviews" ep))
                     (list :exit 0 :stdout "[[]]" :stderr ""))
                    ((member "POST" args) (setq posted t) (error "should not post"))))))))
        (cl-letf (((symbol-function 'treemacs-magit--review-gh-run) handler))
          (let ((preview (treemacs-magit--review-gh-build-preview
                          (treemacs-magit--review-context) nil)))
            ;; Mutate local review JSON after preview was built.
            (treemacs-magit-gh-test--capture-comment "f.txt" 2 "Second")
            (let ((res (treemacs-magit--review-gh-upload-execute preview)))
              (should (eq (plist-get res :status) 'rebuilt))
              (should-not posted))))))))

(ert-deftest treemacs-magit-gh-test-shared-lock-across-review-files-and-local-save-unblocked ()
  (treemacs-magit-gh-test--repo
    (treemacs-magit-gh-test--write-file "a.txt" "line1\nline2\n")
    (let ((base-oid (treemacs-magit-gh-test--commit "init")))
      (treemacs-magit-gh-test--capture-comment "a.txt" 1 "Branch A comment")
      (let ((ctx-a (treemacs-magit--review-context)))
        (treemacs-magit-gh-test--git "checkout" "-qb" "feat/second")
        (treemacs-magit-gh-test--capture-comment "a.txt" 2 "Branch B comment")
        (let* ((ctx-b (treemacs-magit--review-context))
               (pr (treemacs-magit--review-gh-pr-create
                    :url "https://github.com/o/r/pull/9" :host "github.com"
                    :owner "o" :repo "r" :number 9 :base-oid base-oid :head-oid base-oid
                    :head-owner "o" :head-repo "r"))
               (acct (treemacs-magit--review-gh-account-create :id "10" :login "u")))
          ;; Different review files share the exact same upload lock directory for the same PR+account.
          (should (equal (treemacs-magit--review-gh-lock-dir ctx-a pr acct)
                         (treemacs-magit--review-gh-lock-dir ctx-b pr acct)))
          (should (equal (treemacs-magit--review-gh-attempt-file ctx-a pr acct)
                         (treemacs-magit--review-gh-attempt-file ctx-b pr acct)))
          ;; Holding upload lock blocks another upload from ctx-b, but does NOT block local review saves!
          (treemacs-magit--review-gh-with-lock
           ctx-a pr acct
           (lambda ()
             (should-error
              (treemacs-magit--review-gh-with-lock ctx-b pr acct #'ignore)
              :type 'user-error)
             ;; Local comment save succeeds while upload lock is held.
             (should (treemacs-magit-gh-test--capture-comment "a.txt" 1 "Saved during upload")))))))))

(ert-deftest treemacs-magit-gh-test-reconciliation-one-zero-multiple-and-crlf-original ()
  (treemacs-magit-gh-test--repo
    (treemacs-magit-gh-test--write-file "x.txt" "one\ntwo\nthree\n")
    (let ((base-oid (treemacs-magit-gh-test--commit "init")))
      ;; Add two comments with identical body/location to verify duplicate-count preservation!
      (treemacs-magit-gh-test--capture-comment "x.txt" 2 "Check\nmultiline")
      (treemacs-magit-gh-test--capture-comment "x.txt" 2 "Check\nmultiline")
      (let* ((sha (treemacs-magit-gh-test--git "rev-parse" (concat base-oid ":x.txt")))
             (patch "@@ -0,0 +1,3 @@\n+one\n+two\n+three")
             (reviews-by-mode nil)
             (comments-by-review (make-hash-table :test #'eql))
             (post-calls 0)
             (handler
              (treemacs-magit-gh-test--mock-gh
               (lambda (args _input)
                 (let ((ep (car (last args))))
                   (cond
                    ((equal (car args) "pr")
                     (list :exit 0 :stdout (treemacs-magit-gh-test--make-pr-json base-oid base-oid) :stderr ""))
                    ((equal ep "user")
                     (list :exit 0 :stdout "{\"id\":50,\"login\":\"rev\"}" :stderr ""))
                    ((string-match-p "/files" ep)
                     (list :exit 0
                           :stdout (treemacs-magit--review-gh-encode-json
                                    (vector (vector (treemacs-magit-gh-test--make-file-entry
                                                     "x.txt" sha patch 3 0 "added"))))
                           :stderr ""))
                    ((and (member "GET" args)
                          (string-match "/pulls/42/reviews/\\([0-9]+\\)/comments" ep))
                     (let ((rid (string-to-number (match-string 1 ep))))
                       (list :exit 0
                             :stdout (treemacs-magit--review-gh-encode-json
                                      (vector (vconcat (gethash rid comments-by-review))))
                             :stderr "")))
                    ((and (member "GET" args) (string-match-p "/pulls/42/reviews\\?" ep))
                     (list :exit 0
                           :stdout (treemacs-magit--review-gh-encode-json
                                    (vector (vconcat reviews-by-mode)))
                           :stderr ""))
                    ((member "POST" args)
                     (cl-incf post-calls)
                     ;; Simulate timeout / dropped connection after server may have accepted!
                     (list :exit 1 :stdout "" :stderr "Post timed out"))
                    (t (error "Unexpected gh call: %S" args))))))))
        (cl-letf (((symbol-function 'treemacs-magit--review-gh-run) handler))
          (let* ((ctx (treemacs-magit--review-context))
                 (preview (treemacs-magit--review-gh-build-preview ctx nil))
                 (pr (treemacs-magit--review-gh-preview-pr preview))
                 (acct (treemacs-magit--review-gh-preview-account preview))
                 (attempt-file (treemacs-magit--review-gh-attempt-file ctx pr acct)))
            ;; Case A: Timeout with 0 matching reviews -> stays blocked, does NOT retry POST.
            (let ((res (treemacs-magit--review-gh-upload-execute preview)))
              (should (eq (plist-get res :status) 'blocked))
              (should (= post-calls 1))
              (should (file-exists-p attempt-file)))
            ;; Attempting upload again with 0 matches still refuses to POST!
            (let ((res (treemacs-magit--review-gh-upload-execute preview)))
              (should (eq (plist-get res :status) 'blocked))
              (should (= post-calls 1)))
            ;; Case B: Multiple (2) matching reviews -> stays blocked for manual reconciliation.
            (let ((gh-comment `((path . "x.txt") (side . "RIGHT")
                                (line . nil) (original_line . 2)
                                (commit_id . "later-commit") (original_commit_id . ,base-oid)
                                (body . "Check\r\nmultiline"))))
              (setq reviews-by-mode
                    `(((id . 701) (state . "COMMENTED") (commit_id . ,base-oid)
                       (user . ((id . 50) (login . "rev")))
                       (html_url . "https://github.com/baseorg/proj/pull/42#pullrequestreview-701"))
                      ((id . 702) (state . "PENDING") (commit_id . ,base-oid)
                       (user . ((id . 50) (login . "rev")))
                       (html_url . "https://github.com/baseorg/proj/pull/42#pullrequestreview-702"))))
              (puthash 701 (list gh-comment gh-comment) comments-by-review)
              (puthash 702 (list gh-comment gh-comment) comments-by-review)
              (let ((res (treemacs-magit--review-gh-upload-execute preview)))
                (should (eq (plist-get res :status) 'blocked))
                (should (= post-calls 1))
                (should (file-exists-p attempt-file)))
              ;; Neither a duplicate count mismatch nor matching coordinates
              ;; attached to a different original commit can settle the attempt.
              (let ((wrong-commit (copy-alist gh-comment)))
                (setf (alist-get 'original_commit_id wrong-commit) "different-commit")
                (puthash 701 (list wrong-commit wrong-commit) comments-by-review)
                (puthash 702 (list gh-comment) comments-by-review)
                (let ((res (treemacs-magit--review-gh-upload-execute preview)))
                  (should (eq (plist-get res :status) 'blocked))
                  (should (= post-calls 1))
                  (should (file-exists-p attempt-file))))
              ;; Duplicate count mismatch on 702 (only 1 comment instead of 2) leaves ONLY 701
              ;; (a submitted review using original_line + CRLF body!) matching -> reconciles!
              (puthash 701 (list gh-comment gh-comment) comments-by-review)
              (let ((res (treemacs-magit--review-gh-upload-execute preview)))
                (should (eq (plist-get res :status) 'reconciled))
                (should (= (plist-get res :review-id) 701))
                (should (= post-calls 1))
                (should-not (file-exists-p attempt-file))))))))))

(ert-deftest treemacs-magit-gh-test-definite-422-clears-attempt-and-reports-error ()
  (treemacs-magit-gh-test--repo
    (treemacs-magit-gh-test--write-file "a.txt" "hello\n")
    (let ((base-oid (treemacs-magit-gh-test--commit "init")))
      (treemacs-magit-gh-test--capture-comment "a.txt" 1 "Note")
      (let* ((sha (treemacs-magit-gh-test--git "rev-parse" (concat base-oid ":a.txt")))
             (patch "@@ -0,0 +1,1 @@\n+hello")
             (handler
              (treemacs-magit-gh-test--mock-gh
               (lambda (args _input)
                 (let ((ep (car (last args))))
                   (cond
                    ((equal (car args) "pr")
                     (list :exit 0 :stdout (treemacs-magit-gh-test--make-pr-json base-oid base-oid) :stderr ""))
                    ((equal ep "user")
                     (list :exit 0 :stdout "{\"id\":10,\"login\":\"u\"}" :stderr ""))
                    ((string-match-p "/files" ep)
                     (list :exit 0
                           :stdout (treemacs-magit--review-gh-encode-json
                                    (vector (vector (treemacs-magit-gh-test--make-file-entry
                                                     "a.txt" sha patch 1 0 "added"))))
                           :stderr ""))
                    ((and (member "GET" args) (string-match-p "/reviews" ep))
                     (list :exit 0 :stdout "[[]]" :stderr ""))
                    ((member "POST" args)
                     (list :exit 1
                           :stdout "HTTP/2 422\r\n\r\n{\"message\":\"Validation Failed\"}"
                           :stderr "gh: Validation Failed (HTTP 422)"))))))))
        (cl-letf (((symbol-function 'treemacs-magit--review-gh-run) handler))
          (let* ((ctx (treemacs-magit--review-context))
                 (preview (treemacs-magit--review-gh-build-preview ctx nil))
                 (pr (treemacs-magit--review-gh-preview-pr preview))
                 (acct (treemacs-magit--review-gh-preview-account preview))
                 (res (treemacs-magit--review-gh-upload-execute preview)))
            (should (eq (plist-get res :status) 'error))
            (should (= (plist-get res :http-status) 422))
            (should (string-match-p "Validation Failed" (plist-get res :reason)))
            (should-not (file-exists-p (treemacs-magit--review-gh-attempt-file ctx pr acct)))))))))

(provide 'treemacs-magit-review-github-test)

;;; treemacs-magit-review-github-test.el ends here
