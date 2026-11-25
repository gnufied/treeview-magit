;;; treemacs-magit-review-github.el --- Upload review comments to GitHub PRs -*- lexical-binding: t; -*-

;; Author: Hemant Kumar
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/gnufied/treeview-magit

;;; Commentary:
;; Upload branch-local review comments from `treemacs-magit-review' to a
;; GitHub pull request as a pending review via `gh'.  This library depends
;; only on `treemacs-magit-review' and built-in Emacs libraries so it does
;; not eagerly load Magit or Treemacs.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'treemacs-magit-review)

(defcustom treemacs-magit-review-gh-program "gh"
  "GitHub CLI executable used for pull request lookups and review uploads."
  :type 'file
  :group 'treemacs-magit-review)

(cl-defstruct (treemacs-magit--review-gh-pr
               (:constructor treemacs-magit--review-gh-pr-create))
  url host owner repo number title state base-oid head-oid
  head-owner head-repo changed-files)

(cl-defstruct (treemacs-magit--review-gh-account
               (:constructor treemacs-magit--review-gh-account-create))
  id login)

(cl-defstruct (treemacs-magit--review-gh-item
               (:constructor treemacs-magit--review-gh-item-create))
  comment comment-id body body-digest status reason
  selected confirmed
  path start-line line side start-side
  saved-snippet proposed-snippet
  previous-upload)

(cl-defstruct (treemacs-magit--review-gh-preview
               (:constructor treemacs-magit--review-gh-preview-create))
  context snapshot receipt target pr account local-head
  files-truncated existing-pending-review existing-review-ids
  unresolved-attempt items last-message last-error)

(defvar-local treemacs-magit--review-gh-preview nil)

;;; Standalone Git and GitHub CLI helpers

(defun treemacs-magit--review-gh-run (directory args &optional input)
  "Run `treemacs-magit-review-gh-program' in DIRECTORY with ARGS.
Optional INPUT is piped to standard input.  Returns a plist
\(:exit EXIT :stdout STDOUT :stderr STDERR) with separated streams."
  (let* ((default-directory directory)
         (stderr-file (make-temp-file "treemacs-magit-gh-stderr-"))
         (coding-system-for-read 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         exit-code stdout stderr)
    (unwind-protect
        (progn
          (with-temp-buffer
            (let ((stdout-buf (current-buffer)))
              (setq exit-code
                    (condition-case err
                        (if (stringp input)
                            (with-temp-buffer
                              (insert input)
                              (apply #'call-process-region
                                     (point-min) (point-max)
                                     treemacs-magit-review-gh-program
                                     nil (list stdout-buf stderr-file) nil args))
                          (apply #'call-process
                                 treemacs-magit-review-gh-program
                                 nil (list stdout-buf stderr-file) nil args))
                      (file-missing
                       (user-error "Cannot run %s: %s"
                                   treemacs-magit-review-gh-program
                                   (error-message-string err))))))
            (setq stdout (buffer-string)))
          (setq stderr
                (with-temp-buffer
                  (insert-file-contents stderr-file)
                  (buffer-string))))
      (when (file-exists-p stderr-file)
        (delete-file stderr-file)))
    (list :exit exit-code :stdout stdout :stderr stderr)))

(defun treemacs-magit--review-gh-parse-json (text)
  "Parse JSON TEXT into alists and vectors."
  (json-parse-string text
                     :object-type 'alist
                     :array-type 'array
                     :null-object nil
                     :false-object :json-false))

(defun treemacs-magit--review-gh-encode-json (data)
  "Encode DATA as UTF-8 JSON without pretty-printing."
  (let ((json-false :json-false)
        (json-null :null))
    (json-encode data)))

(defun treemacs-magit--review-gh-parse-http-response (raw)
  "Split RAW `--include' HTTP response into (:status INT :headers STR :body STR)."
  (let ((pos 0)
        status headers body)
    (while (and (< pos (length raw))
                (string-match "\\`HTTP/[0-9.]+ \\([0-9][0-9][0-9]\\)[^\r\n]*"
                              (substring raw pos)))
      (let* ((code (string-to-number (match-string 1 (substring raw pos))))
             (rest (substring raw pos))
             (sep (or (string-match "\r\n\r\n" rest)
                      (string-match "\n\n" rest))))
        (if (not sep)
            (setq status code headers rest body "" pos (length raw))
          (let* ((sep-len (if (string-prefix-p "\r\n\r\n" (substring rest sep)) 4 2))
                 (hdr (substring rest 0 sep))
                 (next (+ pos sep sep-len)))
            (setq status code
                  headers hdr
                  body (substring raw next)
                  pos (if (or (and (>= code 100) (< code 200))
                              (string-prefix-p "HTTP/" (substring raw next)))
                          next
                        (length raw)))))))
    (list :status status :headers headers :body (or body raw))))

(defun treemacs-magit--review-gh-api
    (directory host method endpoint &optional input paginate-slurp include-headers)
  "Call `gh api' in DIRECTORY against HOST with METHOD and ENDPOINT.
When INPUT is a string, pass it on stdin via `--input -'.
When PAGINATE-SLURP is non-nil, pass `--paginate --slurp'.
When INCLUDE-HEADERS is non-nil, pass `--include'."
  (let ((args (list "api" "--hostname" host "--method" method)))
    (when paginate-slurp
      (setq args (append args (list "--paginate" "--slurp"))))
    (when include-headers
      (setq args (append args (list "--include"))))
    (when (stringp input)
      (setq args (append args (list "--input" "-"))))
    (setq args (append args (list endpoint)))
    (treemacs-magit--review-gh-run directory args input)))

(defun treemacs-magit--review-gh-api-json
    (directory host method endpoint &optional input paginate-slurp)
  "Call `gh api' and return parsed JSON, signaling a `user-error' on failure."
  (let* ((result (treemacs-magit--review-gh-api
                  directory host method endpoint input paginate-slurp nil))
         (exit (plist-get result :exit))
         (stdout (plist-get result :stdout))
         (stderr (plist-get result :stderr)))
    (unless (and (integerp exit) (zerop exit))
      (user-error "gh api %s failed: %s"
                  endpoint
                  (string-trim (if (string-empty-p (string-trim stderr))
                                   stdout
                                 stderr))))
    (if (and paginate-slurp (string-empty-p (string-trim stdout)))
        nil
      (let ((parsed (treemacs-magit--review-gh-parse-json stdout)))
        (if paginate-slurp
            (cl-mapcan (lambda (page)
                         (if (vectorp page)
                             (append page nil)
                           (list page)))
                       (append parsed nil))
          parsed)))))

(defun treemacs-magit--review-gh-git-raw (directory &rest args)
  "Run git ARGS in DIRECTORY and return raw unibyte output, or nil on failure."
  (let ((default-directory directory)
        (coding-system-for-read 'binary))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (when (zerop (apply #'call-process "git" nil '(t nil) nil args))
        (buffer-string)))))

(defun treemacs-magit--review-gh-decode-bytes (bytes)
  "Decode raw unibyte BYTES using Emacs UTF-8 and automatic EOL decoding."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert bytes)
    (decode-coding-region (point-min) (point-max) 'utf-8)
    (set-buffer-multibyte t)
    (buffer-string)))

(defun treemacs-magit--review-gh-normalize-body (text)
  "Normalize CRLF and CR line endings in TEXT to LF."
  (replace-regexp-in-string "\r\n?" "\n" (or text "")))

;;; PR target parsing & metadata lookup

(defun treemacs-magit--review-gh-parse-target (target)
  "Parse user-supplied TARGET into (:selector STR-OR-NIL :repo STR-OR-NIL).
Accepts nil/empty (current branch), integer or numeric string, full PR URL,
or `[HOST/]OWNER/REPO#NUMBER' / `[HOST/]OWNER/REPO NUMBER'."
  (cond
   ((null target) (list :selector nil :repo nil))
   ((integerp target)
    (unless (> target 0)
      (user-error "Pull request number must be positive"))
    (list :selector (number-to-string target) :repo nil))
   ((stringp target)
    (let ((trimmed (string-trim target)))
      (cond
       ((string-empty-p trimmed)
        (list :selector nil :repo nil))
       ((string-match "\\`[0-9]+\\'" trimmed)
        (when (= (string-to-number trimmed) 0)
          (user-error "Pull request number must be positive"))
        (list :selector trimmed :repo nil))
       ((string-match "\\`https?://[^/]+/[^/]+/[^/]+/pull/[0-9]+\\(?:[/?#].*\\)?\\'" trimmed)
        (list :selector trimmed :repo nil))
       ((string-match "\\`\\([^[:space:]#]+/[^[:space:]#]+\\)\\(?:#\\|[[:space:]]+\\)\\([0-9]+\\)\\'"
                      trimmed)
        (let ((repo (match-string 1 trimmed))
              (num (match-string 2 trimmed)))
          (when (= (string-to-number num) 0)
            (user-error "Pull request number must be positive"))
          (list :selector num :repo repo)))
       (t
        (user-error "Unrecognized PR target %S (use PR number, URL, or OWNER/REPO#NUMBER)"
                    target)))))
   (t
    (user-error "Invalid PR target: %S" target))))

(defun treemacs-magit--review-gh-parse-pr-url (url)
  "Parse canonical PR URL into (:host :owner :repo :number :url)."
  (unless (and (stringp url)
               (string-match
                "\\`https?://\\([^/]+\\)/\\([^/]+\\)/\\([^/]+\\)/pull/\\([0-9]+\\)\\(?:[/?#].*\\)?\\'"
                url))
    (user-error "gh did not return a canonical pull request URL: %S" url))
  (let ((host (match-string 1 url))
        (owner (match-string 2 url))
        (repo (match-string 3 url))
        (number (string-to-number (match-string 4 url))))
    (list :host host
          :owner owner
          :repo repo
          :number number
          :url (format "https://%s/%s/%s/pull/%d" host owner repo number))))

;;;###autoload
(defun treemacs-magit--review-gh-pr-metadata (&optional target directory)
  "Return GitHub PR metadata alist for TARGET in DIRECTORY via `gh pr view'.
Uses separated stdout/stderr and never invokes a checkout helper."
  (let* ((parsed (treemacs-magit--review-gh-parse-target target))
         (selector (plist-get parsed :selector))
         (repo (plist-get parsed :repo))
         (args (append (list "pr" "view")
                       (and selector (list selector))
                       (and repo (list "-R" repo))
                       (list "--json"
                             (concat "url,number,title,state,"
                                     "baseRefOid,headRefName,headRefOid,"
                                     "headRepository,headRepositoryOwner,"
                                     "changedFiles"))))
         (result (treemacs-magit--review-gh-run (or directory default-directory) args))
         (exit (plist-get result :exit))
         (stdout (plist-get result :stdout))
         (stderr (plist-get result :stderr)))
    (unless (and (integerp exit) (zerop exit))
      (user-error "gh pr view failed: %s"
                  (string-trim (if (string-empty-p (string-trim stderr))
                                   stdout
                                 stderr))))
    (treemacs-magit--review-gh-parse-json stdout)))

(defun treemacs-magit--review-gh-resolve-pr (directory &optional target)
  "Resolve TARGET in DIRECTORY into a `treemacs-magit--review-gh-pr' struct."
  (let* ((data (treemacs-magit--review-gh-pr-metadata target directory))
         (url-parts (treemacs-magit--review-gh-parse-pr-url (alist-get 'url data)))
         (number (or (alist-get 'number data) (plist-get url-parts :number)))
         (base-oid (alist-get 'baseRefOid data))
         (head-oid (alist-get 'headRefOid data))
         (head-repo-obj (alist-get 'headRepository data))
         (head-owner-obj (alist-get 'headRepositoryOwner data))
         (head-owner (or (and (listp head-owner-obj) (alist-get 'login head-owner-obj))
                         (plist-get url-parts :owner)))
         (head-repo (or (and (listp head-repo-obj) (alist-get 'name head-repo-obj))
                        (plist-get url-parts :repo))))
    (unless (and (integerp number) (> number 0)
                 (stringp base-oid) (not (string-empty-p base-oid))
                 (stringp head-oid) (not (string-empty-p head-oid)))
      (user-error "gh pr view returned incomplete metadata"))
    (treemacs-magit--review-gh-pr-create
     :url (plist-get url-parts :url)
     :host (plist-get url-parts :host)
     :owner (plist-get url-parts :owner)
     :repo (plist-get url-parts :repo)
     :number number
     :title (or (alist-get 'title data) "")
     :state (or (alist-get 'state data) "UNKNOWN")
     :base-oid base-oid
     :head-oid head-oid
     :head-owner head-owner
     :head-repo head-repo
     :changed-files (alist-get 'changedFiles data))))

(defun treemacs-magit--review-gh-account (directory host)
  "Resolve the authenticated GitHub user on HOST from DIRECTORY."
  (let* ((data (treemacs-magit--review-gh-api-json directory host "GET" "user"))
         (id (alist-get 'id data))
         (login (alist-get 'login data)))
    (unless (and (or (integerp id) (and (stringp id) (not (string-empty-p id))))
                 (stringp login) (not (string-empty-p login)))
      (user-error "gh api user did not return an authenticated account ID and login"))
    (treemacs-magit--review-gh-account-create
     :id (if (integerp id) (number-to-string id) id)
     :login login)))

(defun treemacs-magit--review-gh-account-id-of (user-alist)
  "Return normalized string account ID from a GitHub USER-ALIST, or nil."
  (let ((id (and (listp user-alist) (alist-get 'id user-alist))))
    (cond ((integerp id) (number-to-string id))
          ((and (stringp id) (not (string-empty-p id))) id)
          (t nil))))

;;; Changed-files pagination with OID race detection & strict patch parsing

(defun treemacs-magit--review-gh-fetch-pr-and-files (directory target)
  "Fetch consistent PR metadata and paginated changed files in DIRECTORY.
Checks base and head OIDs before and after pagination; rebuilds if either
moved during pagination.  Returns (:pr PR :files LIST :truncated BOOL)."
  (let ((attempts 0)
        done result)
    (while (not done)
      (cl-incf attempts)
      (when (> attempts 3)
        (user-error "PR base or head moved repeatedly while fetching changed files"))
      (let* ((pr-before (treemacs-magit--review-gh-resolve-pr directory target))
             (endpoint (format "repos/%s/%s/pulls/%d/files?per_page=100"
                               (treemacs-magit--review-gh-pr-owner pr-before)
                               (treemacs-magit--review-gh-pr-repo pr-before)
                               (treemacs-magit--review-gh-pr-number pr-before)))
             (files (treemacs-magit--review-gh-api-json
                     directory (treemacs-magit--review-gh-pr-host pr-before)
                     "GET" endpoint nil t))
             (pr-after (treemacs-magit--review-gh-resolve-pr
                        directory (treemacs-magit--review-gh-pr-url pr-before))))
        (when (and (equal (treemacs-magit--review-gh-pr-base-oid pr-before)
                          (treemacs-magit--review-gh-pr-base-oid pr-after))
                   (equal (treemacs-magit--review-gh-pr-head-oid pr-before)
                          (treemacs-magit--review-gh-pr-head-oid pr-after)))
          (let* ((changed (treemacs-magit--review-gh-pr-changed-files pr-after))
                 (truncated (or (>= (length files) 3000)
                                (and (integerp changed)
                                     (> changed (length files))))))
            (setq result (list :pr pr-after :files files :truncated truncated)
                  done t)))))
    result))

(defun treemacs-magit--review-gh-parse-patch (file-entry)
  "Parse and strictly validate the unified diff patch for FILE-ENTRY.
Returns a plist (:status STATUS :hunks HUNKS :reason REASON).
STATUS is `ok', `deleted-file', `missing-patch', or `truncated-patch'."
  (let ((status (alist-get 'status file-entry))
        (patch (alist-get 'patch file-entry))
        (expected-adds (alist-get 'additions file-entry))
        (expected-dels (alist-get 'deletions file-entry)))
    (cond
     ((equal status "removed")
      (list :status 'deleted-file :reason "File is deleted in this PR"))
     ((or (null patch) (not (stringp patch)) (string-empty-p patch))
      (list :status 'missing-patch
            :reason "PR file has no diff patch (binary, unchanged rename, or omitted by GitHub)"))
     (t
      (let* ((raw-lines (split-string patch "\n"))
             (lines (if (and (string-suffix-p "\n" patch)
                             (equal (car (last raw-lines)) ""))
                        (butlast raw-lines)
                      raw-lines))
             (hunks nil)
             (cur-hunk nil)
             (cur-new 0)
             (exp-old 0)
             (exp-new 0)
             (seen-old 0)
             (seen-new 0)
             (total-adds 0)
             (total-dels 0)
             (invalid nil))
        (cl-flet ((finish-hunk ()
                    (when cur-hunk
                      (if (and (= seen-old exp-old) (= seen-new exp-new))
                          (push cur-hunk hunks)
                        (setq invalid t))
                      (setq cur-hunk nil))))
          (dolist (line lines)
            (unless invalid
              (cond
               ((string-match
                 "\\`@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
                 line)
                (finish-hunk)
                (unless invalid
                  (setq exp-old (if (match-string 2 line)
                                    (string-to-number (match-string 2 line))
                                  1)
                        cur-new (string-to-number (match-string 3 line))
                        exp-new (if (match-string 4 line)
                                    (string-to-number (match-string 4 line))
                                  1)
                        seen-old 0
                        seen-new 0
                        cur-hunk (list :new-start cur-new
                                       :new-count exp-new
                                       :right-lines (make-hash-table :test #'eql)))))
               ((null cur-hunk)
                (setq invalid t))
               ((string-prefix-p " " line)
                (puthash cur-new t (plist-get cur-hunk :right-lines))
                (cl-incf cur-new)
                (cl-incf seen-old)
                (cl-incf seen-new))
               ((string-prefix-p "+" line)
                (puthash cur-new t (plist-get cur-hunk :right-lines))
                (cl-incf cur-new)
                (cl-incf seen-new)
                (cl-incf total-adds))
               ((string-prefix-p "-" line)
                (cl-incf seen-old)
                (cl-incf total-dels))
               ((string-prefix-p "\\ No newline at end of file" line)
                nil)
               (t
                (setq invalid t)))))
          (finish-hunk))
        (cond
         (invalid
          (list :status 'truncated-patch
                :reason "PR file patch is malformed or truncated inside a hunk"))
         ((null hunks)
          (list :status 'missing-patch
                :reason "PR file patch contains no hunks"))
         ((and (integerp expected-adds) (/= total-adds expected-adds))
          (list :status 'truncated-patch
                :reason (format "PR file patch is incomplete (parsed %d additions, expected %d)"
                                total-adds expected-adds)))
         ((and (integerp expected-dels) (/= total-dels expected-dels))
          (list :status 'truncated-patch
                :reason (format "PR file patch is incomplete (parsed %d deletions, expected %d)"
                                total-dels expected-dels)))
         (t
          (list :status 'ok :hunks (nreverse hunks)))))))))

;;; Head tree and blob verification

(defun treemacs-magit--review-gh-local-commit-p (directory oid)
  "Return non-nil when OID is a local commit object in DIRECTORY."
  (equal (treemacs-magit--review-git directory "cat-file" "-t" oid) "commit"))

(defun treemacs-magit--review-gh-local-tree-blob-sha (directory commit-oid path)
  "Return blob SHA for PATH at COMMIT-OID in local Git DIRECTORY, or nil."
  (let ((raw (treemacs-magit--review-gh-git-raw
              directory "ls-tree" "-z" commit-oid "--" path)))
    (when (and raw (not (string-empty-p raw)))
      (let* ((decoded (decode-coding-string raw 'utf-8-unix))
             (entries (split-string decoded "\0" t)))
        (cl-loop for entry in entries
                 when (string-match "\\`[0-9]+ \\(blob\\) \\([0-9a-f]+\\)\t\\(.*\\)\\'" entry)
                 when (equal (match-string 3 entry) path)
                 return (match-string 2 entry))))))

(defun treemacs-magit--review-gh-remote-tree-blob-sha (directory pr path cache)
  "Resolve PATH to a blob SHA in PR's pinned head commit via GitHub Git API.
CACHE is a hash-table shared across files in one preview build.
Returns (:status ok :sha SHA) or (:status tree-unverified :reason MSG)."
  (let* ((host (treemacs-magit--review-gh-pr-host pr))
         (head-owner (treemacs-magit--review-gh-pr-head-owner pr))
         (head-repo (treemacs-magit--review-gh-pr-head-repo pr))
         (head-oid (treemacs-magit--review-gh-pr-head-oid pr)))
    (condition-case err
        (let* ((commit-key (cons 'commit head-oid))
               (root-tree-sha
                (or (gethash commit-key cache)
                    (let* ((commit (treemacs-magit--review-gh-api-json
                                    directory host "GET"
                                    (format "repos/%s/%s/git/commits/%s"
                                            head-owner head-repo head-oid)))
                           (sha (alist-get 'sha (alist-get 'tree commit))))
                      (unless (and (stringp sha) (not (string-empty-p sha)))
                        (error "Head commit has no tree SHA"))
                      (puthash commit-key sha cache))))
               (segments (split-string path "/" t))
               (cur-tree root-tree-sha)
               (result nil))
          (while (and segments (not result))
            (let* ((seg (car segments))
                   (last-p (null (cdr segments)))
                   (tree-key (cons 'tree cur-tree))
                   (tree-obj
                    (or (gethash tree-key cache)
                        (puthash tree-key
                                 (treemacs-magit--review-gh-api-json
                                  directory host "GET"
                                  (format "repos/%s/%s/git/trees/%s"
                                          head-owner head-repo cur-tree))
                                 cache)))
                   (entries (alist-get 'tree tree-obj))
                   (match (seq-find (lambda (e) (equal (alist-get 'path e) seg))
                                    entries)))
              (cond
               ((null match)
                (setq result
                      (list :status 'tree-unverified
                            :reason (if (eq (alist-get 'truncated tree-obj) t)
                                        "GitHub tree response was truncated before locating file"
                                      (format "Path %s not found in pinned PR head tree" path)))))
               (last-p
                (if (equal (alist-get 'type match) "blob")
                    (setq result (list :status 'ok :sha (alist-get 'sha match)))
                  (setq result (list :status 'tree-unverified
                                     :reason (format "Path %s is not a blob in pinned PR head" path)))))
               ((equal (alist-get 'type match) "tree")
                (setq cur-tree (alist-get 'sha match)
                      segments (cdr segments)))
               (t
                (setq result (list :status 'tree-unverified
                                   :reason (format "Path component %s is not a tree" seg)))))))
          (or result (list :status 'tree-unverified
                           :reason "Unable to resolve path in pinned PR head tree")))
      (error
       (list :status 'tree-unverified
             :reason (format "Cannot verify PR head tree: %s"
                             (error-message-string err)))))))

(defun treemacs-magit--review-gh-read-verified-blob (directory pr path expected-sha cache)
  "Verify PATH has EXPECTED-SHA at PR head and return decoded file text.
Returns (:status ok :text STR) or (:status ERR-SYM :reason MSG)."
  (let* ((cache-key (list 'verified-blob path expected-sha))
         (cached (gethash cache-key cache)))
    (or cached
        (puthash
         cache-key
         (if (not (and (stringp expected-sha) (not (string-empty-p expected-sha))))
             (list :status 'tree-unverified
                   :reason "PR changed-file entry has no blob SHA")
           (let* ((head-oid (treemacs-magit--review-gh-pr-head-oid pr))
                  (tree-check
                   (if (treemacs-magit--review-gh-local-commit-p directory head-oid)
                       (let ((local-sha (treemacs-magit--review-gh-local-tree-blob-sha
                                         directory head-oid path)))
                         (if local-sha
                             (list :status 'ok :sha local-sha)
                           (list :status 'tree-unverified
                                 :reason (format "Path %s not found in local pinned head commit" path))))
                     (treemacs-magit--review-gh-remote-tree-blob-sha
                      directory pr path cache))))
             (cond
              ((not (eq (plist-get tree-check :status) 'ok))
               tree-check)
              ((not (equal (plist-get tree-check :sha) expected-sha))
               (list :status 'blob-mismatch
                     :reason (format "Pinned PR head tree blob (%s) disagrees with changed-file entry (%s)"
                                     (plist-get tree-check :sha) expected-sha)))
              (t
               (condition-case err
                   (let* ((raw-local
                           (and (equal (treemacs-magit--review-git
                                        directory "cat-file" "-t" expected-sha)
                                       "blob")
                                (treemacs-magit--review-gh-git-raw
                                 directory "cat-file" "blob" expected-sha)))
                          (raw-bytes
                           (or raw-local
                               (let* ((blob (treemacs-magit--review-gh-api-json
                                             directory
                                             (treemacs-magit--review-gh-pr-host pr)
                                             "GET"
                                             (format "repos/%s/%s/git/blobs/%s"
                                                     (treemacs-magit--review-gh-pr-head-owner pr)
                                                     (treemacs-magit--review-gh-pr-head-repo pr)
                                                     expected-sha)))
                                      (encoding (alist-get 'encoding blob))
                                      (content (alist-get 'content blob)))
                                 (unless (and (equal encoding "base64") (stringp content))
                                   (error "Unsupported GitHub blob encoding: %S" encoding))
                                 (base64-decode-string content)))))
                     (list :status 'ok
                           :text (treemacs-magit--review-gh-decode-bytes raw-bytes)))
                 (error
                  (list :status 'tree-unverified
                        :reason (format "Failed to read PR head blob: %s"
                                        (error-message-string err)))))))))
         cache))))

;;; Capture-to-head diff line tracing

(defun treemacs-magit--review-gh-split-buffer-lines (text)
  "Split decoded buffer TEXT into a vector of 1-based line contents (0-indexed).
Each element is the text of that line without its terminating newline."
  (let ((lines nil))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (not (eobp))
        (push (buffer-substring-no-properties (line-beginning-position) (line-end-position))
              lines)
        (if (zerop (forward-line 1))
            nil
          (goto-char (point-max))))
      ;; When TEXT ends with a newline, Emacs considers the final empty line
      ;; reachable at point-max; represent only lines that exist before EOF,
      ;; except when TEXT is completely empty.
      (when (and (null lines) (string-empty-p text))
        (push "" lines)))
    (vconcat (nreverse lines))))

(defun treemacs-magit--review-gh-diff-line-map (directory old-lines new-lines)
  "Compute a 1-based line mapping vector from OLD-LINES to NEW-LINES via git diff.
Each index (1-based, stored at 0-based `i-1') maps to its unchanged 1-based
line in NEW-LINES, or nil if changed/deleted."
  (let* ((old-count (length old-lines))
         (file-a (make-temp-file "treemacs-magit-diff-a-"))
         (file-b (make-temp-file "treemacs-magit-diff-b-"))
         (coding-system-for-write 'utf-8-unix)
         (coding-system-for-read 'utf-8-unix)
         (result (make-vector old-count nil)))
    (unwind-protect
        (progn
          (with-temp-file file-a
            (dotimes (i old-count)
              (insert (aref old-lines i) "\n")))
          (with-temp-file file-b
            (dotimes (i (length new-lines))
              (insert (aref new-lines i) "\n")))
          (let ((default-directory directory)
                exit-code output)
            (with-temp-buffer
              (setq exit-code
                    (call-process "git" nil '(t nil) nil
                                  "diff" "--no-index" "--unified=0"
                                  "--no-renames" "--no-color"
                                  "--diff-algorithm=myers"
                                  "--" file-a file-b))
              (setq output (buffer-string)))
            (unless (memq exit-code '(0 1))
              (error "git diff --no-index failed with exit %S" exit-code))
            (let ((hunks nil))
              (dolist (line (split-string output "\n"))
                (when (string-match
                       "\\`@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
                       line)
                  (let ((os (string-to-number (match-string 1 line)))
                        (oc (if (match-string 2 line)
                                (string-to-number (match-string 2 line))
                              1))
                        (ns (string-to-number (match-string 3 line)))
                        (nc (if (match-string 4 line)
                                (string-to-number (match-string 4 line))
                              1)))
                    (push (list os oc ns nc) hunks))))
              (setq hunks (nreverse hunks))
              ;; Populate line mapping walking through hunks in order.
              (let ((delta 0)
                    (hunk-ptr hunks))
                (dotimes (idx old-count)
                  (let ((ln (1+ idx)))
                    (while (and hunk-ptr
                                (let* ((h (car hunk-ptr))
                                       (os (nth 0 h))
                                       (oc (nth 1 h)))
                                  (if (> oc 0)
                                      (> ln (+ os oc -1))
                                    ;; Pure insertion after line `os' (or before line 1 if os=0)
                                    (> ln os))))
                      (let* ((h (pop hunk-ptr))
                             (oc (nth 1 h))
                             (nc (nth 3 h)))
                        (cl-incf delta (- nc oc))))
                    (let ((in-deleted
                           (and hunk-ptr
                                (let* ((h (car hunk-ptr))
                                       (os (nth 0 h))
                                       (oc (nth 1 h)))
                                  (and (> oc 0)
                                       (>= ln os)
                                       (<= ln (+ os oc -1)))))))
                      (unless in-deleted
                        (aset result idx (+ ln delta))))))))))
      (when (file-exists-p file-a) (delete-file file-a))
      (when (file-exists-p file-b) (delete-file file-b)))
    result))

(defun treemacs-magit--review-gh-unique-line-map-p
    (old-lines new-lines line-map start-line end-line)
  "Check that every shortest line diff agrees with LINE-MAP over the range.
START-LINE and END-LINE are inclusive, 1-based positions in OLD-LINES.
Return nil when the proof would require too much work for a preview."
  (let* ((old-count (length old-lines))
         (new-count (length new-lines))
         ;; Count a valid ordered subsequence from Git's proposed mapping.
         ;; Its edit count bounds the distance of every shortest diff.
         (matches
          (cl-loop with previous = 0
                   for new-line across line-map
                   for index from 0
                   count (when (and new-line (< previous new-line)
                                    (<= new-line new-count)
                                    (equal (aref old-lines index)
                                           (aref new-lines (1- new-line))))
                           (setq previous new-line))))
         (max-edits (- (+ old-count new-count) (* 2 matches)))
         (width (min (1+ new-count) (1+ (* 2 max-edits)))))
    (when (<= (* (1+ old-count) width) 1000000)
      (let* ((unreachable (* 2 (+ old-count new-count 1)))
             (previous (make-vector (1+ new-count) unreachable))
             (current (make-vector (1+ new-count) unreachable)))
        ;; Twice the edit count, plus 1 if the alignment agrees with LINE-MAP.
        ;; On a tie, an alignment that skips or remaps a selected line wins.
        (dotimes (j (1+ (min max-edits new-count)))
          (aset previous j (1+ (* 2 j))))
        (cl-loop for i from 1 to old-count
                 for old-text = (aref old-lines (1- i))
                 for expected = (and (<= start-line i end-line)
                                     (aref line-map (1- i)))
                 for first-column = (max 0 (- i max-edits))
                 for last-column = (min new-count (+ i max-edits))
                 do
                 (when (> first-column 0)
                   (aset current (1- first-column) unreachable))
                 (when (< last-column new-count)
                   (aset current (1+ last-column) unreachable))
                 (cl-loop for j from first-column to last-column
                          for delete-cost = (+ 2 (aref previous j))
                          for best = (min unreachable (if expected
                                                         (logand delete-cost -2)
                                                       delete-cost))
                          do
                          (when (> j 0)
                            (setq best (min best (+ 2 (aref current (1- j)))))
                            (when (equal old-text (aref new-lines (1- j)))
                              (let ((match (aref previous (1- j))))
                                (setq best (min best (if (and expected (/= expected j))
                                                         (logand match -2)
                                                       match))))))
                          (aset current j best))
                 (cl-rotatef previous current))
        (cl-oddp (aref previous new-count))))))

(defun treemacs-magit--review-gh-inclusive-end-line (start-line end-line end-col)
  "Convert exclusive (END-LINE, END-COL) to inclusive end line >= START-LINE."
  (if (and (> end-line start-line) (= end-col 0))
      (1- end-line)
    end-line))

(defun treemacs-magit--review-gh-trace-shifted (directory anchor head-text)
  "Try to trace ANCHOR from its capture blob to HEAD-TEXT through a line diff.
Returns (:status shifted :start POS :end POS) when every selected line maps
unambiguously to a single unchanged contiguous range, or nil otherwise."
  (let* ((cap-blob (alist-get 'blob anchor))
         (cap-raw (and (stringp cap-blob)
                       (not (string-empty-p cap-blob))
                       (equal (treemacs-magit--review-git
                               directory "cat-file" "-t" cap-blob)
                              "blob")
                       (treemacs-magit--review-gh-git-raw
                        directory "cat-file" "blob" cap-blob))))
    (when cap-raw
      (let* ((cap-text (treemacs-magit--review-gh-decode-bytes cap-raw))
             (cap-fp (secure-hash 'sha256 cap-text))
             (saved-fp (alist-get 'fingerprint anchor))
             (saved-text (alist-get 'text anchor))
             (s-line (alist-get 'start_line anchor))
             (s-col (alist-get 'start_column anchor))
             (e-line (alist-get 'end_line anchor))
             (e-col (alist-get 'end_column anchor)))
        ;; Capture blob must prove the anchor was not from dirty/unsaved text.
        (when (and (equal cap-fp saved-fp)
                   (with-temp-buffer
                     (insert cap-text)
                     (let ((a (treemacs-magit--review-range-point s-line s-col))
                           (b (treemacs-magit--review-range-point e-line e-col)))
                       (and a b (equal saved-text
                                       (buffer-substring-no-properties a b))))))
          (let* ((inc-end (treemacs-magit--review-gh-inclusive-end-line
                           s-line e-line e-col))
                 (old-lines (treemacs-magit--review-gh-split-buffer-lines cap-text))
                 (new-lines (treemacs-magit--review-gh-split-buffer-lines head-text))
                 (old-n (length old-lines))
                 (new-n (length new-lines)))
            (when (and (>= s-line 1) (<= inc-end old-n) (> new-n 0))
              (let* ((line-map (treemacs-magit--review-gh-diff-line-map
                                directory old-lines new-lines))
                     (mapped-start (aref line-map (1- s-line))))
                (when (and mapped-start
                           (cl-loop for line from s-line to inc-end
                                    always (eql (aref line-map (1- line))
                                                (+ mapped-start (- line s-line))))
                           (treemacs-magit--review-gh-unique-line-map-p
                            old-lines new-lines line-map s-line inc-end))
                  (let ((target-e-line (+ mapped-start (- e-line s-line))))
                    (with-temp-buffer
                      (insert head-text)
                      (let ((a (treemacs-magit--review-range-point mapped-start s-col))
                            (b (treemacs-magit--review-range-point target-e-line e-col)))
                        (when (and a b (equal saved-text
                                              (buffer-substring-no-properties a b)))
                          (list :status 'shifted :start a :end b))))))))))))))

;;; Placement & snippet helpers

(defun treemacs-magit--review-gh-positions-to-lines (text start-pos end-pos)
  "Convert START-POS..END-POS in TEXT to (START-LINE . INCLUSIVE-END-LINE)."
  (with-temp-buffer
    (insert text)
    (let* ((s-line (line-number-at-pos start-pos t))
           (e-line (line-number-at-pos end-pos t))
           (e-col (save-excursion
                    (goto-char end-pos)
                    (- end-pos (line-beginning-position))))
           (inc-end (treemacs-magit--review-gh-inclusive-end-line
                     s-line e-line e-col)))
      (cons s-line inc-end))))

(defun treemacs-magit--review-gh-check-hunks (hunks start-line end-line)
  "Verify START-LINE..END-LINE all lie on the right side of a single hunk in HUNKS.
Returns (:status ok) or (:status outside-diff|crosses-hunks :reason MSG)."
  (let ((single-hunk nil)
        (all-in-diff t))
    (dolist (hunk hunks)
      (let ((rlines (plist-get hunk :right-lines))
            (in-this t))
        (cl-loop for ln from start-line to end-line
                 unless (gethash ln rlines)
                 do (setq in-this nil)
                 until (not in-this))
        (when in-this
          (setq single-hunk hunk))))
    (if single-hunk
        (list :status 'ok)
      (cl-loop for ln from start-line to end-line do
               (unless (seq-some (lambda (h) (gethash ln (plist-get h :right-lines)))
                                 hunks)
                 (setq all-in-diff nil)))
      (if all-in-diff
          (list :status 'crosses-hunks
                :reason (format "Lines %d-%d span multiple diff hunks" start-line end-line))
        (list :status 'outside-diff
              :reason (if (= start-line end-line)
                          (format "Line %d is outside the visible PR diff" start-line)
                        (format "Lines %d-%d include lines outside the visible PR diff"
                                start-line end-line)))))))

(defun treemacs-magit--review-gh-snippet (text start-line end-line &optional context-lines)
  "Return a numbered excerpt of TEXT around START-LINE..END-LINE."
  (let* ((ctx (or context-lines 2))
         (lines (treemacs-magit--review-gh-split-buffer-lines text))
         (total (length lines))
         (from (max 1 (- start-line ctx)))
         (to (min total (+ end-line ctx)))
         (out nil))
    (cl-loop for ln from from to to do
             (let ((mark (if (and (>= ln start-line) (<= ln end-line)) ">" " ")))
               (push (format "%s %4d | %s" mark ln (aref lines (1- ln))) out)))
    (mapconcat #'identity (nreverse out) "\n")))

(defun treemacs-magit--review-gh-saved-snippet (anchor)
  "Format ANCHOR's saved text and surrounding context for confirmation display."
  (let ((before (alist-get 'before anchor))
        (text (alist-get 'text anchor))
        (after (alist-get 'after anchor)))
    (concat (or before "") "<<<" (or text "") ">>>" (or after ""))))

(defun treemacs-magit--review-gh-resolve-in-file (directory anchor head-text)
  "Resolve ANCHOR in decoded HEAD-TEXT.
Returns (:tier exact|shifted|suggested|ambiguous|outdated :start POS :end POS)."
  (let* ((saved-fp (alist-get 'fingerprint anchor))
         (saved-text (alist-get 'text anchor))
         (s-line (alist-get 'start_line anchor))
         (s-col (alist-get 'start_column anchor))
         (e-line (alist-get 'end_line anchor))
         (e-col (alist-get 'end_column anchor))
         (head-fp (secure-hash 'sha256 head-text)))
    ;; Tier 1: exact whole-buffer fingerprint + exact text at saved coordinates.
    (or (when (equal head-fp saved-fp)
          (with-temp-buffer
            (insert head-text)
            (let ((a (treemacs-magit--review-range-point s-line s-col))
                  (b (treemacs-magit--review-range-point e-line e-col)))
              (when (and a b (equal saved-text (buffer-substring-no-properties a b)))
                (list :tier 'exact :start a :end b)))))
        ;; Tier 2: verified capture blob and a unique shortest-diff placement.
        (when-let* ((shifted (treemacs-magit--review-gh-trace-shifted
                              directory anchor head-text)))
          (list :tier 'shifted
                :start (plist-get shifted :start)
                :end (plist-get shifted :end)))
        ;; Tier 3: case-sensitive text-with-context search (requires confirmation).
        (with-temp-buffer
          (insert head-text)
          (let* ((case-fold-search nil)
                 ;; Force context search even if fingerprint happened to match
                 ;; (already handled above when coordinates matched).
                 (search-anchor (copy-alist anchor)))
            (setf (alist-get 'fingerprint search-anchor) "")
            (let ((res (treemacs-magit--review-resolve search-anchor)))
              (pcase (car res)
                ('located
                 (list :tier 'suggested :start (nth 1 res) :end (nth 2 res)))
                ('ambiguous
                 (list :tier 'ambiguous))
                (_
                 (list :tier 'outdated)))))))))

(defun treemacs-magit--review-gh-map-comment
    (directory pr comment files-index files-truncated blob-cache prev-upload)
  "Map local COMMENT against PR using FILES-INDEX and BLOB-CACHE.
Returns a `treemacs-magit--review-gh-item'."
  (let* ((comment-id (alist-get 'id comment))
         (body (alist-get 'body comment))
         (body-digest (secure-hash 'sha256 body))
         (anchor (treemacs-magit--review-anchor-of comment))
         (anchor-path (alist-get 'path anchor))
         (status-str (alist-get 'status comment)))
    (cl-flet ((make-skipped (sym reason)
                (treemacs-magit--review-gh-item-create
                 :comment comment :comment-id comment-id
                 :body body :body-digest body-digest
                 :status sym :reason reason
                 :selected nil :confirmed nil
                 :path anchor-path
                 :previous-upload prev-upload)))
      (if (not (equal status-str "open"))
          (make-skipped 'resolved (format "Local comment status is %s" status-str))
        (let* ((by-file (plist-get files-index :by-filename))
               (by-prev (plist-get files-index :by-previous))
               (direct (gethash anchor-path by-file))
               (renamed-list (gethash anchor-path by-prev)))
          (cond
           ((and (null direct) (null renamed-list))
            (if files-truncated
                (make-skipped 'pr-file-limit
                              "File not in GitHub's 3,000-file PR listing limit")
              (make-skipped 'file-not-in-pr
                            "File is not changed in this PR")))
           ((and (null direct) (> (length renamed-list) 1))
            (make-skipped 'ambiguous
                          "Multiple PR files share this previous filename"))
           (t
            (let ((candidates (delq nil (cons direct renamed-list))))
              (treemacs-magit--review-gh-map-against-candidates
               directory pr comment anchor candidates blob-cache prev-upload)))))))))

(defun treemacs-magit--review-gh-map-against-candidates
    (directory pr comment anchor candidates blob-cache prev-upload)
  "Resolve COMMENT with ANCHOR across one or two candidate PR file entries."
  (let* ((comment-id (alist-get 'id comment))
         (body (alist-get 'body comment))
         (body-digest (secure-hash 'sha256 body))
         (multi (> (length candidates) 1))
         (verified-hits nil)
         (suggested-hits nil)
         (ambiguous-hit nil)
         (first-skip nil))
    (dolist (entry candidates)
      (let* ((filename (alist-get 'filename entry))
             (sha (alist-get 'sha entry))
             (patch-info (treemacs-magit--review-gh-parse-patch entry)))
        (if (not (eq (plist-get patch-info :status) 'ok))
            (unless first-skip
              (setq first-skip (cons (plist-get patch-info :status)
                                     (plist-get patch-info :reason))))
          (let ((blob-info (treemacs-magit--review-gh-read-verified-blob
                            directory pr filename sha blob-cache)))
            (if (not (eq (plist-get blob-info :status) 'ok))
                (unless first-skip
                  (setq first-skip (cons (plist-get blob-info :status)
                                         (plist-get blob-info :reason))))
              (let* ((head-text (plist-get blob-info :text))
                     (resolved (treemacs-magit--review-gh-resolve-in-file
                                directory anchor head-text))
                     (tier (plist-get resolved :tier)))
                (pcase tier
                  ((or 'exact 'shifted)
                   (push (list :tier tier :entry entry :patch patch-info
                               :text head-text
                               :start (plist-get resolved :start)
                               :end (plist-get resolved :end))
                         verified-hits))
                  ('suggested
                   (push (list :tier 'suggested :entry entry :patch patch-info
                               :text head-text
                               :start (plist-get resolved :start)
                               :end (plist-get resolved :end))
                         suggested-hits))
                  ('ambiguous
                   (setq ambiguous-hit t))
                  (_ nil))))))))
    (cl-flet ((finish-hit (hit suggested-p)
                (let* ((entry (plist-get hit :entry))
                       (filename (alist-get 'filename entry))
                       (hunks (plist-get (plist-get hit :patch) :hunks))
                       (head-text (plist-get hit :text))
                       (line-pair (treemacs-magit--review-gh-positions-to-lines
                                   head-text (plist-get hit :start) (plist-get hit :end)))
                       (s-line (car line-pair))
                       (e-line (cdr line-pair))
                       (hunk-check (treemacs-magit--review-gh-check-hunks
                                    hunks s-line e-line)))
                  (if (not (eq (plist-get hunk-check :status) 'ok))
                      (treemacs-magit--review-gh-item-create
                       :comment comment :comment-id comment-id
                       :body body :body-digest body-digest
                       :status (plist-get hunk-check :status)
                       :reason (plist-get hunk-check :reason)
                       :selected nil :confirmed nil
                       :path filename :start-line (and (< s-line e-line) s-line)
                       :line e-line :side "RIGHT"
                       :start-side (and (< s-line e-line) "RIGHT")
                       :previous-upload prev-upload)
                    (let* ((prev-present (and prev-upload
                                              (plist-get prev-upload :review-id)))
                           (tier (plist-get hit :tier))
                           (item-status (if suggested-p 'suggested tier))
                           (preselect (and (not suggested-p) (not prev-present))))
                      (treemacs-magit--review-gh-item-create
                       :comment comment :comment-id comment-id
                       :body body :body-digest body-digest
                       :status item-status
                       :reason (when suggested-p
                                 "Text-with-context match; confirm location before selecting")
                       :selected preselect
                       :confirmed (not suggested-p)
                       :path filename
                       :start-line (and (< s-line e-line) s-line)
                       :line e-line
                       :side "RIGHT"
                       :start-side (and (< s-line e-line) "RIGHT")
                       :saved-snippet (when suggested-p
                                        (treemacs-magit--review-gh-saved-snippet anchor))
                       :proposed-snippet (when suggested-p
                                           (treemacs-magit--review-gh-snippet
                                            head-text s-line e-line 2))
                       :previous-upload prev-upload))))))
      (cond
       ((= (length verified-hits) 1)
        (finish-hit (car verified-hits) nil))
       ((> (length verified-hits) 1)
        (treemacs-magit--review-gh-item-create
         :comment comment :comment-id comment-id
         :body body :body-digest body-digest
         :status 'ambiguous
         :reason "Path matches both a renamed file and a new file at the old path"
         :selected nil :confirmed nil
         :path (alist-get 'path anchor)
         :previous-upload prev-upload))
       ((and (not ambiguous-hit) (= (length suggested-hits) 1)
             (not (and multi first-skip
                       (memq (car first-skip) '(tree-unverified blob-mismatch truncated-patch)))))
        (finish-hit (car suggested-hits) t))
       ((or ambiguous-hit (> (length suggested-hits) 1))
        (treemacs-magit--review-gh-item-create
         :comment comment :comment-id comment-id
         :body body :body-digest body-digest
         :status 'ambiguous
         :reason (if multi
                     "Anchor is ambiguous across renamed and recreated files"
                   "Multiple matching locations in PR head file")
         :selected nil :confirmed nil
         :path (alist-get 'path anchor)
         :previous-upload prev-upload))
       (first-skip
        (treemacs-magit--review-gh-item-create
         :comment comment :comment-id comment-id
         :body body :body-digest body-digest
         :status (car first-skip)
         :reason (cdr first-skip)
         :selected nil :confirmed nil
         :path (alist-get 'path anchor)
         :previous-upload prev-upload))
       (t
        (treemacs-magit--review-gh-item-create
         :comment comment :comment-id comment-id
         :body body :body-digest body-digest
         :status 'outdated
         :reason "Anchored text not found in PR head file"
         :selected nil :confirmed nil
         :path (alist-get 'path anchor)
         :previous-upload prev-upload))))))

(defun treemacs-magit--review-gh-index-files (files)
  "Index PR changed FILES by `filename' and `previous_filename'."
  (let ((by-filename (make-hash-table :test #'equal))
        (by-previous (make-hash-table :test #'equal)))
    (dolist (entry files)
      (when-let* ((name (alist-get 'filename entry)))
        (puthash name entry by-filename))
      (when-let* ((prev (alist-get 'previous_filename entry)))
        (puthash prev (cons entry (gethash prev by-previous)) by-previous)))
    (list :by-filename by-filename :by-previous by-previous)))

;;; Receipt storage, locking, and reconciliation

(defun treemacs-magit--review-gh-storage-dir (context)
  "Return GitHub upload metadata directory inside CONTEXT's Git common dir."
  (expand-file-name "treemacs-magit-review/github/"
                    (treemacs-magit--review-context-repository context)))

(defun treemacs-magit--review-gh-pr-account-hash (pr account)
  "Return stable hash keying lock and in-flight attempt by PR and ACCOUNT."
  (secure-hash 'sha256
               (format "%s\0%s"
                       (treemacs-magit--review-gh-pr-url pr)
                       (treemacs-magit--review-gh-account-id account))))

(defun treemacs-magit--review-gh-receipt-file (context pr review-id)
  "Return receipt JSON path for CONTEXT, canonical PR, and local REVIEW-ID."
  (let ((key (secure-hash 'sha256
                          (format "%s\0%s"
                                  (treemacs-magit--review-gh-pr-url pr)
                                  review-id))))
    (expand-file-name (concat "receipts/" key ".json")
                      (treemacs-magit--review-gh-storage-dir context))))

(defun treemacs-magit--review-gh-attempt-file (context pr account)
  "Return in-flight attempt JSON path for CONTEXT, PR, and ACCOUNT."
  (expand-file-name
   (concat "attempts/"
           (treemacs-magit--review-gh-pr-account-hash pr account)
           ".json")
   (treemacs-magit--review-gh-storage-dir context)))

(defun treemacs-magit--review-gh-lock-dir (context pr account)
  "Return dedicated upload lock directory for CONTEXT, PR, and ACCOUNT."
  (expand-file-name
   (concat "locks/"
           (treemacs-magit--review-gh-pr-account-hash pr account)
           ".lock")
   (treemacs-magit--review-gh-storage-dir context)))

(defun treemacs-magit--review-gh-write-json-file (file data)
  "Atomically write DATA as pretty UTF-8 JSON to FILE."
  (let* ((directory (file-name-directory file))
         (temporary nil))
    (make-directory directory t)
    (unwind-protect
        (progn
          (setq temporary (make-temp-file (expand-file-name ".gh-" directory)))
          (let ((coding-system-for-write 'utf-8-unix)
                (json-encoding-pretty-print t)
                (json-false :json-false)
                (json-null :null))
            (with-temp-file temporary
              (insert (json-encode data) "\n")))
          (rename-file temporary file t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun treemacs-magit--review-gh-read-json-file (file)
  "Read and parse JSON from FILE, or return nil if FILE does not exist."
  (when (file-exists-p file)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (insert-file-contents file))
      (treemacs-magit--review-gh-parse-json (buffer-string)))))

(defun treemacs-magit--review-gh-with-lock (context pr account thunk)
  "Call THUNK while holding the dedicated upload lock for PR and ACCOUNT."
  (let* ((lock (treemacs-magit--review-gh-lock-dir context pr account))
         (locked nil))
    (make-directory (file-name-directory lock) t)
    (unwind-protect
        (progn
          (condition-case nil
              (progn
                (make-directory lock)
                (setq locked t))
            (file-already-exists
             (user-error "GitHub upload locked for this PR and account: %s; recover a stale lock explicitly"
                         lock)))
          (funcall thunk))
      (when (and locked (file-directory-p lock))
        (delete-directory lock)))))

(defun treemacs-magit--review-gh-fetch-account-reviews (directory pr account)
  "Return paginated reviews authored by ACCOUNT on PR."
  (let* ((endpoint (format "repos/%s/%s/pulls/%d/reviews?per_page=100"
                           (treemacs-magit--review-gh-pr-owner pr)
                           (treemacs-magit--review-gh-pr-repo pr)
                           (treemacs-magit--review-gh-pr-number pr)))
         (all-reviews (treemacs-magit--review-gh-api-json
                       directory (treemacs-magit--review-gh-pr-host pr)
                       "GET" endpoint nil t))
         (account-id (treemacs-magit--review-gh-account-id account)))
    (seq-filter (lambda (rev)
                  (equal (treemacs-magit--review-gh-account-id-of
                          (alist-get 'user rev))
                         account-id))
                all-reviews)))

(defun treemacs-magit--review-gh-record-receipt
    (context pr account review-id gh-review-id gh-review-url commit-id items)
  "Record a completed upload receipt for CONTEXT, PR, and REVIEW-ID."
  (let* ((file (treemacs-magit--review-gh-receipt-file context pr review-id))
         (existing (treemacs-magit--review-gh-read-json-file file))
         (uploads (if existing
                      (append (alist-get 'uploads existing) nil)
                    nil))
         (entry `((github_review_id . ,gh-review-id)
                  (github_review_url . ,gh-review-url)
                  (account_id . ,(treemacs-magit--review-gh-account-id account))
                  (account_login . ,(treemacs-magit--review-gh-account-login account))
                  (commit_id . ,commit-id)
                  (uploaded_at . ,(treemacs-magit--review-now))
                  (comments . ,(vconcat
                                (mapcar
                                 (lambda (item)
                                   `((comment_id . ,(treemacs-magit--review-gh-item-comment-id item))
                                     (body_digest . ,(treemacs-magit--review-gh-item-body-digest item))
                                     (path . ,(treemacs-magit--review-gh-item-path item))
                                     (start_line . ,(treemacs-magit--review-gh-item-start-line item))
                                     (line . ,(treemacs-magit--review-gh-item-line item))))
                                 items)))))
         (data `((schema_version . 1)
                 (pr_url . ,(treemacs-magit--review-gh-pr-url pr))
                 (review_id . ,review-id)
                 (uploads . ,(vconcat (append uploads (list entry)))))))
    (treemacs-magit--review-gh-write-json-file file data)))

(defun treemacs-magit--review-gh-record-receipt-from-attempt
    (context pr account attempt gh-review-id gh-review-url)
  "Promote ATTEMPT into a completed receipt for GH-REVIEW-ID."
  (let* ((review-id (alist-get 'review_id attempt))
         (commit-id (alist-get 'commit_id attempt))
         (comment-ids (append (alist-get 'comment_ids attempt) nil))
         (comments (append (alist-get 'comments attempt) nil))
         (file (treemacs-magit--review-gh-receipt-file context pr review-id))
         (existing (treemacs-magit--review-gh-read-json-file file))
         (uploads (if existing (append (alist-get 'uploads existing) nil) nil))
         (entry `((github_review_id . ,gh-review-id)
                  (github_review_url . ,gh-review-url)
                  (account_id . ,(treemacs-magit--review-gh-account-id account))
                  (account_login . ,(treemacs-magit--review-gh-account-login account))
                  (commit_id . ,commit-id)
                  (uploaded_at . ,(treemacs-magit--review-now))
                  (comments . ,(vconcat
                                (cl-mapcar
                                 (lambda (cid payload)
                                   `((comment_id . ,cid)
                                     (body_digest . ,(secure-hash 'sha256 (alist-get 'body payload)))
                                     (path . ,(alist-get 'path payload))
                                     (start_line . ,(alist-get 'start_line payload))
                                     (line . ,(alist-get 'line payload))))
                                 comment-ids comments)))))
         (data `((schema_version . 1)
                 (pr_url . ,(treemacs-magit--review-gh-pr-url pr))
                 (review_id . ,review-id)
                 (uploads . ,(vconcat (append uploads (list entry)))))))
    (treemacs-magit--review-gh-write-json-file file data)))

(defun treemacs-magit--review-gh-previous-uploads (receipt account-reviews)
  "Return hash-table mapping comment-id -> latest upload status plist."
  (let ((live-ids (make-hash-table :test #'eql))
        (table (make-hash-table :test #'equal)))
    (dolist (rev account-reviews)
      (when-let* ((rid (alist-get 'id rev)))
        (puthash rid rev live-ids)))
    (when receipt
      (seq-doseq (upload (alist-get 'uploads receipt))
        (let* ((rid (alist-get 'github_review_id upload))
               (live-rev (gethash rid live-ids))
               (exists-on-gh (not (null live-rev)))
               (gh-state (and live-rev (alist-get 'state live-rev))))
          (seq-doseq (c (alist-get 'comments upload))
            (puthash (alist-get 'comment_id c)
                     (list :review-id rid
                           :review-url (alist-get 'github_review_url upload)
                           :body-digest (alist-get 'body_digest c)
                           :exists-on-github exists-on-gh
                           :github-state gh-state)
                     table)))))
    table))

;;; Reconciliation of uncertain POST outcomes

(defun treemacs-magit--review-gh-canonical-tuple-from-payload (payload)
  "Normalize submitted comment PAYLOAD alist to a canonical comparison tuple."
  (let ((path (alist-get 'path payload))
        (side (or (alist-get 'side payload) "RIGHT"))
        (line (alist-get 'line payload))
        (start-line (alist-get 'start_line payload))
        (start-side (when (alist-get 'start_line payload)
                      (or (alist-get 'start_side payload)
                          (alist-get 'side payload)
                          "RIGHT")))
        (body (treemacs-magit--review-gh-normalize-body (alist-get 'body payload))))
    (list path side start-line start-side line body)))

(defun treemacs-magit--review-gh-canonical-tuple-from-github (comment expected-commit)
  "Normalize a GitHub review COMMENT to a comparison tuple, or nil if unverifiable.
Prefer original coordinates when they belong to EXPECTED-COMMIT.
Use current coordinates only when verified against that commit."
  (let* ((path (alist-get 'path comment))
         (side (or (alist-get 'side comment) "RIGHT"))
         (orig-line (alist-get 'original_line comment))
         (cur-line (alist-get 'line comment))
         (orig-start (alist-get 'original_start_line comment))
         (cur-start (alist-get 'start_line comment))
         (orig-commit (alist-get 'original_commit_id comment))
         (cur-commit (alist-get 'commit_id comment))
         (verified-orig (and (integerp orig-line)
                             (equal orig-commit expected-commit)))
         (verified-cur (and (not verified-orig)
                            (integerp cur-line)
                            (equal cur-commit expected-commit)
                            (or (null orig-commit) (equal orig-commit expected-commit))))
         (line (cond (verified-orig orig-line)
                     (verified-cur cur-line)
                     (t nil)))
         (start-line (cond (verified-orig orig-start)
                           (verified-cur cur-start)
                           (t nil)))
         (start-side (when (integerp start-line)
                       (or (alist-get 'start_side comment) side)))
         (body (treemacs-magit--review-gh-normalize-body (alist-get 'body comment))))
    (when (and (stringp expected-commit) (stringp path) (integerp line))
      (list path side start-line start-side line body))))

(defun treemacs-magit--review-gh-sort-tuples (tuples)
  "Sort canonical comment TUPLES deterministically preserving duplicates."
  (sort (copy-sequence tuples)
        (lambda (a b)
          (string-lessp (prin1-to-string a) (prin1-to-string b)))))

(defun treemacs-magit--review-gh-reconcile-attempt (directory context pr account attempt)
  "Inspect ACCOUNT's reviews on PR to reconcile an uncertain ATTEMPT.
Returns (:status matched :review-id ID :review-url URL) when exactly one new
review matches the full payload, or (:status unresolved :reason MSG :matches N)."
  (let* ((expected-commit (alist-get 'commit_id attempt))
         (seen-ids (append (alist-get 'existing_review_ids attempt) nil))
         (expected-tuples
          (treemacs-magit--review-gh-sort-tuples
           (mapcar #'treemacs-magit--review-gh-canonical-tuple-from-payload
                   (append (alist-get 'comments attempt) nil)))))
    (condition-case err
        (let* ((account-reviews (treemacs-magit--review-gh-fetch-account-reviews
                                 directory pr account))
               (candidates
                (seq-filter (lambda (rev)
                              (and (not (member (alist-get 'id rev) seen-ids))
                                   (equal (alist-get 'commit_id rev) expected-commit)))
                            account-reviews))
               (matches nil))
          (dolist (rev candidates)
            (let* ((rid (alist-get 'id rev))
                   (endpoint (format "repos/%s/%s/pulls/%d/reviews/%d/comments?per_page=100"
                                     (treemacs-magit--review-gh-pr-owner pr)
                                     (treemacs-magit--review-gh-pr-repo pr)
                                     (treemacs-magit--review-gh-pr-number pr)
                                     rid))
                   (rev-comments (treemacs-magit--review-gh-api-json
                                  directory (treemacs-magit--review-gh-pr-host pr)
                                  "GET" endpoint nil t))
                   (actual-tuples
                    (mapcar (lambda (c)
                              (treemacs-magit--review-gh-canonical-tuple-from-github
                               c expected-commit))
                            rev-comments)))
              (when (and (= (length actual-tuples) (length expected-tuples))
                         (not (memq nil actual-tuples))
                         (equal (treemacs-magit--review-gh-sort-tuples actual-tuples)
                                expected-tuples))
                (push rev matches))))
          (cond
           ((= (length matches) 1)
            (let* ((matched (car matches))
                   (rid (alist-get 'id matched))
                   (rurl (or (alist-get 'html_url matched)
                             (treemacs-magit--review-gh-pr-url pr)))
                   (attempt-file (treemacs-magit--review-gh-attempt-file
                                  context pr account)))
              (treemacs-magit--review-gh-record-receipt-from-attempt
               context pr account attempt rid rurl)
              (when (file-exists-p attempt-file)
                (delete-file attempt-file))
              (list :status 'matched :review-id rid :review-url rurl
                    :state (alist-get 'state matched))))
           ((= (length matches) 0)
            (list :status 'unresolved
                  :matches 0
                  :reason "No matching GitHub review found after uncertain POST; verify on GitHub before clearing"))
           (t
            (list :status 'unresolved
                  :matches (length matches)
                  :reason (format "%d candidate GitHub reviews matched the payload; resolve manually"
                                  (length matches))))))
      (error
       (list :status 'unresolved
             :matches nil
             :reason (format "Reconciliation failed while reading GitHub reviews: %s"
                             (error-message-string err)))))))

;;; Preview construction & upload execution

(defun treemacs-magit--review-gh-build-preview (context target &optional last-message last-error)
  "Build a read-only preview for pinned CONTEXT and PR TARGET."
  (let* ((directory (treemacs-magit--review-context-root context))
         (snapshot (treemacs-magit--review-read context))
         (data (treemacs-magit--review-snapshot-data snapshot))
         (review-id (and data (alist-get 'review_id data)))
         (fetched (treemacs-magit--review-gh-fetch-pr-and-files directory target))
         (pr (plist-get fetched :pr))
         (files (plist-get fetched :files))
         (truncated (plist-get fetched :truncated))
         (account (treemacs-magit--review-gh-account
                   directory (treemacs-magit--review-gh-pr-host pr)))
         (local-head (treemacs-magit--review-git directory "rev-parse" "--verify" "HEAD"))
         (account-reviews (treemacs-magit--review-gh-fetch-account-reviews
                           directory pr account))
         (pending-review (seq-find (lambda (r) (equal (alist-get 'state r) "PENDING"))
                                   account-reviews))
         (existing-ids (delq nil (mapcar (lambda (r) (alist-get 'id r)) account-reviews)))
         (attempt-file (treemacs-magit--review-gh-attempt-file context pr account))
         (unresolved-attempt (treemacs-magit--review-gh-read-json-file attempt-file))
         (receipt (when review-id
                    (treemacs-magit--review-gh-read-json-file
                     (treemacs-magit--review-gh-receipt-file context pr review-id))))
         (prev-table (treemacs-magit--review-gh-previous-uploads receipt account-reviews))
         (files-index (treemacs-magit--review-gh-index-files files))
         (blob-cache (make-hash-table :test #'equal))
         (comments (sort (append (and data (alist-get 'comments data)) nil)
                         (lambda (a b)
                           (string-lessp (treemacs-magit--review-sort-key a)
                                         (treemacs-magit--review-sort-key b)))))
         (items (mapcar (lambda (comment)
                          (treemacs-magit--review-gh-map-comment
                           directory pr comment files-index truncated blob-cache
                           (gethash (alist-get 'id comment) prev-table)))
                        comments)))
    (treemacs-magit--review-gh-preview-create
     :context context
     :snapshot snapshot
     :receipt receipt
     :target (treemacs-magit--review-gh-pr-url pr)
     :pr pr
     :account account
     :local-head local-head
     :files-truncated truncated
     :existing-pending-review pending-review
     :existing-review-ids existing-ids
     :unresolved-attempt unresolved-attempt
     :items items
     :last-message last-message
     :last-error last-error)))

(defun treemacs-magit--review-gh-item-payload (item)
  "Construct the GitHub REST comment object alist for ITEM.
Omits `start_line' and `start_side' completely for single-line comments."
  (let ((obj `((path . ,(treemacs-magit--review-gh-item-path item))
               (body . ,(treemacs-magit--review-gh-item-body item))
               (line . ,(treemacs-magit--review-gh-item-line item))
               (side . ,(or (treemacs-magit--review-gh-item-side item) "RIGHT")))))
    (when (and (treemacs-magit--review-gh-item-start-line item)
               (< (treemacs-magit--review-gh-item-start-line item)
                  (treemacs-magit--review-gh-item-line item)))
      (setq obj (append obj
                        `((start_line . ,(treemacs-magit--review-gh-item-start-line item))
                          (start_side . ,(or (treemacs-magit--review-gh-item-start-side item)
                                             "RIGHT"))))))
    obj))

(defun treemacs-magit--review-gh-item-eligible-p (item)
  "Return non-nil when ITEM can be selected for upload."
  (memq (treemacs-magit--review-gh-item-status item) '(exact shifted suggested)))

(defun treemacs-magit--review-gh-upload-execute (preview)
  "Execute the pending-review upload for PREVIEW under the upload lock.
Returns a plist describing the outcome:
  (:status uploaded :review-id ID :review-url URL :pr-url URL :count N)
  (:status rebuilt :reason MSG :preview NEW-PREVIEW)
  (:status blocked :reason MSG :preview NEW-PREVIEW)
  (:status reconciled :review-id ID :review-url URL :preview NEW-PREVIEW)
  (:status error :reason MSG :preview NEW-PREVIEW)"
  (let* ((context (treemacs-magit--review-gh-preview-context preview))
         (directory (treemacs-magit--review-context-root context))
         (pr (treemacs-magit--review-gh-preview-pr preview))
         (account (treemacs-magit--review-gh-preview-account preview))
         (selected (seq-filter
                    (lambda (item)
                      (and (treemacs-magit--review-gh-item-selected item)
                           (treemacs-magit--review-gh-item-eligible-p item)
                           (treemacs-magit--review-gh-item-confirmed item)))
                    (treemacs-magit--review-gh-preview-items preview))))
    (unless selected
      (user-error "Select at least one eligible comment before uploading"))
    (treemacs-magit--review-gh-with-lock
     context pr account
     (lambda ()
       (let* ((attempt-file (treemacs-magit--review-gh-attempt-file context pr account))
              (existing-attempt (treemacs-magit--review-gh-read-json-file attempt-file)))
         (if existing-attempt
             (let ((rec (treemacs-magit--review-gh-reconcile-attempt
                         directory context pr account existing-attempt)))
               (if (eq (plist-get rec :status) 'matched)
                   (let* ((msg (format "Reconciled previous upload to GitHub review #%s"
                                       (plist-get rec :review-id)))
                          (fresh (treemacs-magit--review-gh-build-preview
                                  context (treemacs-magit--review-gh-pr-url pr) msg nil)))
                     (list :status 'reconciled
                           :review-id (plist-get rec :review-id)
                           :review-url (plist-get rec :review-url)
                           :preview fresh))
                 (let* ((reason (plist-get rec :reason))
                        (fresh (treemacs-magit--review-gh-build-preview
                                context (treemacs-magit--review-gh-pr-url pr) nil reason)))
                   (list :status 'blocked :reason reason :preview fresh))))
           ;; Revalidate preview inputs under the upload lock before posting.
           (let* ((cur-snapshot (treemacs-magit--review-read context))
                  (review-id (alist-get 'review_id
                                        (treemacs-magit--review-snapshot-data cur-snapshot)))
                  (cur-account (treemacs-magit--review-gh-account
                                directory (treemacs-magit--review-gh-pr-host pr)))
                  (cur-pr (treemacs-magit--review-gh-resolve-pr
                           directory (treemacs-magit--review-gh-pr-url pr)))
                  (changed-reason
                   (cond
                    ((not (equal (treemacs-magit--review-snapshot-digest cur-snapshot)
                                 (treemacs-magit--review-snapshot-digest
                                  (treemacs-magit--review-gh-preview-snapshot preview))))
                     "Local review changed since preview was built; rebuilt preview for review")
                    ((not (equal (treemacs-magit--review-gh-account-id cur-account)
                                 (treemacs-magit--review-gh-account-id account)))
                     (format "Authenticated GitHub account changed (%s -> %s); rebuilt preview"
                             (treemacs-magit--review-gh-account-login account)
                             (treemacs-magit--review-gh-account-login cur-account)))
                    ((not (and (equal (treemacs-magit--review-gh-pr-base-oid cur-pr)
                                      (treemacs-magit--review-gh-pr-base-oid pr))
                               (equal (treemacs-magit--review-gh-pr-head-oid cur-pr)
                                      (treemacs-magit--review-gh-pr-head-oid pr))))
                     "PR base or head commit moved since preview was built; rebuilt preview")
                    ((and review-id
                          (not (equal (treemacs-magit--review-gh-preview-receipt preview)
                                      (treemacs-magit--review-gh-read-json-file
                                       (treemacs-magit--review-gh-receipt-file
                                        context cur-pr review-id)))))
                     "Upload receipts changed since preview was built; review the refreshed selection"))))
             (if changed-reason
                 (let ((fresh (treemacs-magit--review-gh-build-preview
                               context (treemacs-magit--review-gh-pr-url pr)
                               nil changed-reason)))
                   (list :status 'rebuilt :reason changed-reason :preview fresh))
               (let* ((cur-reviews (treemacs-magit--review-gh-fetch-account-reviews
                                    directory cur-pr cur-account))
                      (cur-pending (seq-find (lambda (r) (equal (alist-get 'state r) "PENDING"))
                                             cur-reviews)))
                 (if cur-pending
                     (let* ((msg (format "Pending review #%s already exists on GitHub (%s); submit or delete it first"
                                         (alist-get 'id cur-pending)
                                         (or (alist-get 'html_url cur-pending)
                                             (treemacs-magit--review-gh-pr-url cur-pr))))
                            (fresh (treemacs-magit--review-gh-build-preview
                                    context (treemacs-magit--review-gh-pr-url cur-pr) nil msg)))
                       (list :status 'blocked :reason msg :preview fresh))
                   ;; Persist in-flight attempt BEFORE POST.
                   (let* ((commit-id (treemacs-magit--review-gh-pr-head-oid cur-pr))
                          (payload-comments (mapcar #'treemacs-magit--review-gh-item-payload
                                                    selected))
                          (request-body (treemacs-magit--review-gh-encode-json
                                         `((commit_id . ,commit-id)
                                           (comments . ,(vconcat payload-comments)))))
                          (seen-ids (delq nil (mapcar (lambda (r) (alist-get 'id r))
                                                      cur-reviews)))
                          (attempt `((schema_version . 1)
                                     (pr_url . ,(treemacs-magit--review-gh-pr-url cur-pr))
                                     (account_id . ,(treemacs-magit--review-gh-account-id cur-account))
                                     (account_login . ,(treemacs-magit--review-gh-account-login cur-account))
                                     (review_id . ,review-id)
                                     (commit_id . ,commit-id)
                                     (created_at . ,(treemacs-magit--review-now))
                                     (existing_review_ids . ,(vconcat seen-ids))
                                     (comment_ids . ,(vconcat
                                                      (mapcar #'treemacs-magit--review-gh-item-comment-id
                                                              selected)))
                                     (comments . ,(vconcat payload-comments))))
                          (endpoint (format "repos/%s/%s/pulls/%d/reviews"
                                            (treemacs-magit--review-gh-pr-owner cur-pr)
                                            (treemacs-magit--review-gh-pr-repo cur-pr)
                                            (treemacs-magit--review-gh-pr-number cur-pr))))
                     (treemacs-magit--review-gh-write-json-file attempt-file attempt)
                     (let* ((resp (treemacs-magit--review-gh-api
                                   directory (treemacs-magit--review-gh-pr-host cur-pr)
                                   "POST" endpoint request-body nil t))
                            (exit (plist-get resp :exit))
                            (parsed-http (treemacs-magit--review-gh-parse-http-response
                                          (plist-get resp :stdout)))
                            (http-status (plist-get parsed-http :status))
                            (body-str (plist-get parsed-http :body))
                            (stderr (string-trim (plist-get resp :stderr)))
                            (parsed-json
                             (condition-case nil
                                 (when (and (stringp body-str)
                                            (not (string-empty-p (string-trim body-str))))
                                   (treemacs-magit--review-gh-parse-json body-str))
                               (error nil))))
                       (cond
                        ;; Definite success: exit 0 + integer review ID.
                        ((and (integerp exit) (zerop exit)
                              (listp parsed-json)
                              (integerp (alist-get 'id parsed-json)))
                         (let* ((gh-rid (alist-get 'id parsed-json))
                                (gh-rurl (or (alist-get 'html_url parsed-json)
                                             (treemacs-magit--review-gh-pr-url cur-pr))))
                           (treemacs-magit--review-gh-record-receipt
                            context cur-pr cur-account review-id gh-rid gh-rurl commit-id selected)
                           (when (file-exists-p attempt-file)
                             (delete-file attempt-file))
                           (let* ((msg (format "Created pending review #%d (%d comment(s)) on %s"
                                               gh-rid (length selected) gh-rurl))
                                  (fresh (treemacs-magit--review-gh-build-preview
                                          context (treemacs-magit--review-gh-pr-url cur-pr)
                                          msg nil)))
                             (list :status 'uploaded
                                   :review-id gh-rid
                                   :review-url gh-rurl
                                   :pr-url (treemacs-magit--review-gh-pr-url cur-pr)
                                   :count (length selected)
                                   :preview fresh))))
                        ;; Definite 4xx rejection by GitHub (no review created).
                        ((and (integerp http-status)
                              (>= http-status 400) (< http-status 500))
                         (when (file-exists-p attempt-file)
                           (delete-file attempt-file))
                         (let* ((api-msg (or (and (listp parsed-json)
                                                  (alist-get 'message parsed-json))
                                             stderr
                                             (format "HTTP %d" http-status)))
                                (reason (format "GitHub rejected review (HTTP %d): %s"
                                                http-status api-msg))
                                (fresh (treemacs-magit--review-gh-build-preview
                                        context (treemacs-magit--review-gh-pr-url cur-pr)
                                        nil reason)))
                           (list :status 'error :http-status http-status
                                 :reason reason :preview fresh)))
                        ;; Uncertain outcome (timeout, 5xx, network error, bad JSON):
                        ;; keep attempt file intact and run reconciliation!
                        (t
                         (let ((rec (treemacs-magit--review-gh-reconcile-attempt
                                     directory context cur-pr cur-account attempt)))
                           (if (eq (plist-get rec :status) 'matched)
                               (let* ((msg (format "POST outcome was uncertain, but reconciled to GitHub review #%s"
                                                   (plist-get rec :review-id)))
                                      (fresh (treemacs-magit--review-gh-build-preview
                                              context (treemacs-magit--review-gh-pr-url cur-pr)
                                              msg nil)))
                                 (list :status 'reconciled
                                       :review-id (plist-get rec :review-id)
                                       :review-url (plist-get rec :review-url)
                                       :preview fresh))
                             (let* ((reason (format "Uncertain POST outcome (%s). %s"
                                                    (if (string-empty-p stderr)
                                                        (format "exit=%S http=%S" exit http-status)
                                                      stderr)
                                                    (plist-get rec :reason)))
                                    (fresh (treemacs-magit--review-gh-build-preview
                                            context (treemacs-magit--review-gh-pr-url cur-pr)
                                            nil reason)))
                               (list :status 'blocked
                                     :reason reason
                                     :preview fresh))))))))))))))))))

;;; Preview buffer major mode & interactive commands

(defvar treemacs-magit-review-upload-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "SPC") #'treemacs-magit--review-gh-toggle-item)
    (define-key map (kbd "m") #'treemacs-magit--review-gh-toggle-item)
    (define-key map (kbd "c") #'treemacs-magit--review-gh-confirm-item)
    (define-key map (kbd "n") #'treemacs-magit--review-gh-next-item)
    (define-key map (kbd "p") #'treemacs-magit--review-gh-previous-item)
    (define-key map (kbd "g") #'treemacs-magit--review-gh-refresh-preview)
    (define-key map (kbd "R") #'treemacs-magit--review-gh-reconcile-command)
    (define-key map (kbd "C-c C-c") #'treemacs-magit--review-gh-upload-command)
    (define-key map (kbd "U") #'treemacs-magit--review-gh-upload-command)
    map))

(define-derived-mode treemacs-magit-review-upload-mode special-mode "PR Review Upload"
  "Preview and upload branch-local review comments as a pending GitHub PR review.
SPC/m toggles selection, c confirms a suggested relocation, n/p moves,
g refreshes, R reconciles an uncertain upload, C-c C-c or U uploads."
  (setq-local revert-buffer-function
              (lambda (&rest _) (treemacs-magit--review-gh-refresh-preview))))

(defun treemacs-magit--review-gh-item-status-label (item)
  "Return a human-readable status string for preview ITEM."
  (let* ((status (treemacs-magit--review-gh-item-status item))
         (prev (treemacs-magit--review-gh-item-previous-upload item))
         (base
          (pcase status
            ('exact "verified (exact)")
            ('shifted "verified (shifted)")
            ('suggested
             (if (treemacs-magit--review-gh-item-confirmed item)
                 "confirmed suggestion"
               "suggested — confirm with c"))
            (_ (or (treemacs-magit--review-gh-item-reason item)
                   (symbol-name status)))))
         (prev-note
          (when prev
            (let* ((rid (plist-get prev :review-id))
                   (exists (plist-get prev :exists-on-github))
                   (edited (not (equal (plist-get prev :body-digest)
                                       (treemacs-magit--review-gh-item-body-digest item)))))
              (concat (format "previously uploaded in review #%s" rid)
                      (unless exists " [deleted on GitHub]")
                      (when edited " [edited locally]"))))))
    (if prev-note
        (format "%s; %s" base prev-note)
      base)))

(defun treemacs-magit--review-gh-render-preview (preview)
  "Render PREVIEW into the current buffer."
  (let* ((context (treemacs-magit--review-gh-preview-context preview))
         (pr (treemacs-magit--review-gh-preview-pr preview))
         (account (treemacs-magit--review-gh-preview-account preview))
         (local-head (treemacs-magit--review-gh-preview-local-head preview))
         (pending (treemacs-magit--review-gh-preview-existing-pending-review preview))
         (attempt (treemacs-magit--review-gh-preview-unresolved-attempt preview))
         (items (treemacs-magit--review-gh-preview-items preview))
         (selected-count (cl-count-if #'treemacs-magit--review-gh-item-selected items))
         (cur-id (get-text-property (point) 'treemacs-magit-review-gh-id))
         (inhibit-read-only t))
    (setq treemacs-magit--review-gh-preview preview)
    (erase-buffer)
    (insert (propertize "GitHub PR Review Upload Preview\n" 'face 'bold))
    (insert (format "Repository: %s\nScope:      %s\n"
                    (treemacs-magit--review-context-root context)
                    (treemacs-magit--review-context-scope context)))
    (insert "PR:         ")
    (let ((url (treemacs-magit--review-gh-pr-url pr)))
      (insert-text-button url 'follow-link t
                          'action (lambda (_) (browse-url url))))
    (insert (format " (%s)\n" (treemacs-magit--review-gh-pr-state pr)))
    (insert (format "Title:      %s\n" (treemacs-magit--review-gh-pr-title pr)))
    (insert (format "Account:    @%s (id %s)\n"
                    (treemacs-magit--review-gh-account-login account)
                    (treemacs-magit--review-gh-account-id account)))
    (insert (format "Base OID:   %s\nHead OID:   %s\n"
                    (treemacs-magit--review-gh-pr-base-oid pr)
                    (treemacs-magit--review-gh-pr-head-oid pr)))
    (unless (member (upcase (or (treemacs-magit--review-gh-pr-state pr) "")) '("OPEN"))
      (insert (propertize
               (format "WARNING: Pull request state is %s.\n"
                       (or (treemacs-magit--review-gh-pr-state pr) "UNKNOWN"))
               'face 'warning)))
    (when (and local-head
               (not (equal local-head (treemacs-magit--review-gh-pr-head-oid pr))))
      (insert (propertize
               (format "NOTE: Local HEAD (%s) differs from PR head (%s); unpushed or local edits may be ineligible.\n"
                       (substring local-head 0 (min 12 (length local-head)))
                       (substring (treemacs-magit--review-gh-pr-head-oid pr)
                                  0 (min 12 (length (treemacs-magit--review-gh-pr-head-oid pr)))))
               'face 'warning)))
    (when (treemacs-magit--review-gh-preview-files-truncated preview)
      (insert (propertize
               "NOTE: PR changed files hit GitHub's 3,000-file API listing limit.\n"
               'face 'warning)))
    (when pending
      (insert (propertize
               (format "BLOCKED: Pending review #%s already exists for @%s on this PR: %s\n"
                       (alist-get 'id pending)
                       (treemacs-magit--review-gh-account-login account)
                       (or (alist-get 'html_url pending)
                           (treemacs-magit--review-gh-pr-url pr)))
               'face 'error))
      (insert "Submit or delete the existing pending review on GitHub, then press g to refresh.\n"))
    (when attempt
      (insert (propertize
               (format "BLOCKED: Unresolved upload attempt from %s (commit %s).\n"
                       (alist-get 'created_at attempt)
                       (alist-get 'commit_id attempt))
               'face 'error))
      (insert "Press R to re-check GitHub reviews for reconciliation (or C-u R to clear manually after verifying on GitHub).\n"))
    (when-let* ((msg (treemacs-magit--review-gh-preview-last-message preview)))
      (insert (propertize (concat "Result: " msg "\n") 'face 'success)))
    (when-let* ((err (treemacs-magit--review-gh-preview-last-error preview)))
      (insert (propertize (concat "Error:  " err "\n") 'face 'error)))
    (insert (format "\nSelected: %d / %d | SPC toggle | c confirm suggestion | n/p move | g refresh | R reconcile | C-c C-c upload\n\n"
                    selected-count (length items)))
    (unless items
      (insert "No local review comments for this branch.\n"))
    (dolist (item items)
      (let* ((start (point))
             (elig (treemacs-magit--review-gh-item-eligible-p item))
             (confirmed (treemacs-magit--review-gh-item-confirmed item))
             (selected (treemacs-magit--review-gh-item-selected item))
             (mark (cond
                    ((not elig) "[-]")
                    ((not confirmed) "[?]")
                    (selected "[x]")
                    (t "[ ]")))
             (loc (if (treemacs-magit--review-gh-item-line item)
                      (if (treemacs-magit--review-gh-item-start-line item)
                          (format "%s:%d-%d (RIGHT)"
                                  (treemacs-magit--review-gh-item-path item)
                                  (treemacs-magit--review-gh-item-start-line item)
                                  (treemacs-magit--review-gh-item-line item))
                        (format "%s:%d (RIGHT)"
                                (treemacs-magit--review-gh-item-path item)
                                (treemacs-magit--review-gh-item-line item)))
                    (or (treemacs-magit--review-gh-item-path item) "<unknown>"))))
        (insert (propertize (format "%s %s — %s\n"
                                    mark loc
                                    (treemacs-magit--review-gh-item-status-label item))
                            'face (cond (selected 'bold)
                                        (elig 'default)
                                        (t 'shadow))))
        (insert (replace-regexp-in-string "^" "    "
                                          (treemacs-magit--review-gh-item-body item))
                "\n")
        (when (eq (treemacs-magit--review-gh-item-status item) 'suggested)
          (insert "    Saved snippet:\n")
          (insert (replace-regexp-in-string
                   "^" "      "
                   (or (treemacs-magit--review-gh-item-saved-snippet item) ""))
                  "\n")
          (insert "    Proposed PR code:\n")
          (insert (replace-regexp-in-string
                   "^" "      "
                   (or (treemacs-magit--review-gh-item-proposed-snippet item) ""))
                  "\n"))
        (insert "\n")
        (add-text-properties start (point)
                             `(treemacs-magit-review-gh-id
                               ,(treemacs-magit--review-gh-item-comment-id item)))))
    (let ((entries (treemacs-magit--review-gh-item-entries)))
      (goto-char (or (cdr (assoc cur-id entries))
                     (cdar entries)
                     (point-min))))
    (set-buffer-modified-p nil)))

(defun treemacs-magit--review-gh-item-entries ()
  "Return (COMMENT-ID . START) pairs for items in the preview buffer."
  (let ((pos (point-min)) entries)
    (while (< pos (point-max))
      (when-let* ((id (get-text-property pos 'treemacs-magit-review-gh-id)))
        (push (cons id pos) entries))
      (setq pos (or (next-single-property-change pos 'treemacs-magit-review-gh-id)
                    (point-max))))
    (nreverse entries)))

(defun treemacs-magit--review-gh-current-item ()
  "Return the preview item at point."
  (let* ((id (get-text-property (point) 'treemacs-magit-review-gh-id))
         (item (and treemacs-magit--review-gh-preview
                    (seq-find (lambda (it)
                                (equal id (treemacs-magit--review-gh-item-comment-id it)))
                              (treemacs-magit--review-gh-preview-items
                               treemacs-magit--review-gh-preview)))))
    (or item (user-error "No preview comment at point"))))

(defun treemacs-magit--review-gh-next-item (&optional backwards)
  "Move to the next item in the upload preview, or previous with BACKWARDS."
  (interactive)
  (let* ((entries (treemacs-magit--review-gh-item-entries))
         (id (get-text-property (point) 'treemacs-magit-review-gh-id))
         (start (or (cdr (assoc id entries)) (point)))
         (candidates (seq-filter (lambda (e) (if backwards (< (cdr e) start)
                                               (> (cdr e) start)))
                                 entries))
         (found (cdr (if backwards (car (last candidates)) (car candidates)))))
    (unless found (user-error "No %s comment" (if backwards "previous" "next")))
    (goto-char found)))

(defun treemacs-magit--review-gh-previous-item ()
  "Move to the previous item in the upload preview."
  (interactive)
  (treemacs-magit--review-gh-next-item t))

(defun treemacs-magit--review-gh-confirm-item ()
  "Confirm or unconfirm a text-only suggested relocation at point."
  (interactive)
  (let ((item (treemacs-magit--review-gh-current-item)))
    (unless (eq (treemacs-magit--review-gh-item-status item) 'suggested)
      (user-error "Only suggested text-with-context matches need confirmation"))
    (if (treemacs-magit--review-gh-item-confirmed item)
        (setf (treemacs-magit--review-gh-item-confirmed item) nil
              (treemacs-magit--review-gh-item-selected item) nil)
      (setf (treemacs-magit--review-gh-item-confirmed item) t
            (treemacs-magit--review-gh-item-selected item) t))
    (treemacs-magit--review-gh-render-preview treemacs-magit--review-gh-preview)))

(defun treemacs-magit--review-gh-toggle-item ()
  "Toggle upload selection of the preview item at point."
  (interactive)
  (let ((item (treemacs-magit--review-gh-current-item)))
    (unless (treemacs-magit--review-gh-item-eligible-p item)
      (user-error "Cannot select ineligible comment: %s"
                  (treemacs-magit--review-gh-item-status-label item)))
    (unless (treemacs-magit--review-gh-item-confirmed item)
      (user-error "Confirm this suggested location with `c' before selecting it"))
    (setf (treemacs-magit--review-gh-item-selected item)
          (not (treemacs-magit--review-gh-item-selected item)))
    (treemacs-magit--review-gh-render-preview treemacs-magit--review-gh-preview)))

(defun treemacs-magit--review-gh-refresh-preview ()
  "Rebuild the upload preview from fresh GitHub and local review data."
  (interactive)
  (unless treemacs-magit--review-gh-preview
    (user-error "No upload preview active"))
  (let ((fresh (treemacs-magit--review-gh-build-preview
                (treemacs-magit--review-gh-preview-context treemacs-magit--review-gh-preview)
                (treemacs-magit--review-gh-preview-target treemacs-magit--review-gh-preview))))
    (treemacs-magit--review-gh-render-preview fresh)))

(defun treemacs-magit--review-gh-reconcile-command (&optional manual-clear)
  "Reconcile an unresolved upload attempt against GitHub.
With prefix MANUAL-CLEAR, allow clearing the blocked attempt after explicit
confirmation that the user verified the PR on GitHub."
  (interactive "P")
  (unless treemacs-magit--review-gh-preview
    (user-error "No upload preview active"))
  (let* ((preview treemacs-magit--review-gh-preview)
         (context (treemacs-magit--review-gh-preview-context preview))
         (directory (treemacs-magit--review-context-root context))
         (pr (treemacs-magit--review-gh-preview-pr preview))
         (account (treemacs-magit--review-gh-preview-account preview)))
    (treemacs-magit--review-gh-with-lock
     context pr account
     (lambda ()
       (let* ((attempt-file (treemacs-magit--review-gh-attempt-file context pr account))
              (attempt (treemacs-magit--review-gh-read-json-file attempt-file)))
         (unless attempt
           (user-error "No unresolved upload attempt for this PR and account"))
         (if manual-clear
             (when (yes-or-no-p
                    "Have you verified on GitHub that no duplicate review will be created and want to clear this blocked attempt? ")
               (delete-file attempt-file)
               (let ((fresh (treemacs-magit--review-gh-build-preview
                             context (treemacs-magit--review-gh-pr-url pr)
                             "Cleared unresolved upload attempt manually" nil)))
                 (treemacs-magit--review-gh-render-preview fresh)))
           (let ((rec (treemacs-magit--review-gh-reconcile-attempt
                       directory context pr account attempt)))
             (if (eq (plist-get rec :status) 'matched)
                 (let* ((msg (format "Reconciled to GitHub review #%s (%s)"
                                     (plist-get rec :review-id)
                                     (plist-get rec :review-url)))
                        (fresh (treemacs-magit--review-gh-build-preview
                                context (treemacs-magit--review-gh-pr-url pr) msg nil)))
                   (treemacs-magit--review-gh-render-preview fresh)
                   (message "%s" msg))
               (let ((fresh (treemacs-magit--review-gh-build-preview
                             context (treemacs-magit--review-gh-pr-url pr)
                             nil (plist-get rec :reason))))
                 (treemacs-magit--review-gh-render-preview fresh)
                 (message "%s" (plist-get rec :reason)))))))))))

(defun treemacs-magit--review-gh-upload-command ()
  "Upload selected comments in the current preview as a pending GitHub review."
  (interactive)
  (unless treemacs-magit--review-gh-preview
    (user-error "No upload preview active"))
  (let* ((preview treemacs-magit--review-gh-preview)
         (pr (treemacs-magit--review-gh-preview-pr preview))
         (account (treemacs-magit--review-gh-preview-account preview))
         (selected (seq-filter
                    (lambda (item)
                      (and (treemacs-magit--review-gh-item-selected item)
                           (treemacs-magit--review-gh-item-eligible-p item)
                           (treemacs-magit--review-gh-item-confirmed item)))
                    (treemacs-magit--review-gh-preview-items preview))))
    (unless selected
      (user-error "Select at least one eligible comment before uploading"))
    (when (treemacs-magit--review-gh-preview-existing-pending-review preview)
      (user-error "An existing pending review blocks upload; submit or delete it on GitHub first"))
    (when (treemacs-magit--review-gh-preview-unresolved-attempt preview)
      (user-error "An unresolved upload attempt blocks upload; press R to reconcile first"))
    (unless (yes-or-no-p
             (format "Create pending review with %d comment(s) on %s as @%s? "
                     (length selected)
                     (treemacs-magit--review-gh-pr-url pr)
                     (treemacs-magit--review-gh-account-login account)))
      (user-error "Upload cancelled"))
    (let ((result (treemacs-magit--review-gh-upload-execute preview)))
      (when-let* ((fresh (plist-get result :preview)))
        (treemacs-magit--review-gh-render-preview fresh))
      (pcase (plist-get result :status)
        ('uploaded
         (message "Created pending review #%s on %s"
                  (plist-get result :review-id)
                  (plist-get result :review-url)))
        ('reconciled
         (message "Reconciled to existing review #%s on %s"
                  (plist-get result :review-id)
                  (plist-get result :review-url)))
        (_
         (message "%s" (plist-get result :reason)))))))

;;;###autoload
(defun treemacs-magit-review-upload-to-pr (&optional target)
  "Preview and upload branch-local review comments as a pending GitHub PR review.
With no TARGET, offer the PR associated with the current branch as the
default and allow entering a PR number, URL, or OWNER/REPO#NUMBER."
  (interactive
   (let* ((context (if (and (derived-mode-p 'treemacs-magit-review-list-mode)
                            treemacs-magit--review-context)
                       treemacs-magit--review-context
                     (treemacs-magit--review-context)))
          (default-pr
            (condition-case nil
                (treemacs-magit--review-gh-pr-url
                 (treemacs-magit--review-gh-resolve-pr
                  (treemacs-magit--review-context-root context) nil))
              (error nil)))
          (prompt (if default-pr
                      (format "GitHub PR (default %s): " default-pr)
                    "GitHub PR (URL, number, or OWNER/REPO#NUMBER): "))
          (input (read-string prompt nil nil default-pr)))
     (list (if (string-empty-p (string-trim input)) default-pr input))))
  (let* ((context (if (and (derived-mode-p 'treemacs-magit-review-list-mode)
                           treemacs-magit--review-context)
                      (let ((fresh (treemacs-magit--review-context default-directory)))
                        (unless (treemacs-magit--review-same-scope-p
                                 fresh treemacs-magit--review-context)
                          (treemacs-magit--review-refresh-list fresh)
                          (user-error "Branch changed; review the refreshed list and invoke upload again"))
                        treemacs-magit--review-context)
                    (treemacs-magit--review-context)))
         (snapshot (treemacs-magit--review-read context)))
    (unless (and (treemacs-magit--review-snapshot-data snapshot)
                 (> (length (alist-get 'comments
                                       (treemacs-magit--review-snapshot-data snapshot)))
                    0))
      (user-error "No saved review comments for %s"
                  (treemacs-magit--review-context-scope context)))
    (let* ((preview (treemacs-magit--review-gh-build-preview context target))
           (pr (treemacs-magit--review-gh-preview-pr preview))
           (buf-name (format "*Review Upload: %s#%d*"
                             (treemacs-magit--review-gh-pr-repo pr)
                             (treemacs-magit--review-gh-pr-number pr)))
           (buffer (get-buffer-create buf-name)))
      (with-current-buffer buffer
        (unless (derived-mode-p 'treemacs-magit-review-upload-mode)
          (treemacs-magit-review-upload-mode))
        (setq default-directory (treemacs-magit--review-context-root context))
        (treemacs-magit--review-gh-render-preview preview))
      (pop-to-buffer buffer)
      buffer)))

(provide 'treemacs-magit-review-github)

;;; treemacs-magit-review-github.el ends here
