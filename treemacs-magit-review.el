;;; treemacs-magit-review.el --- Branch-local code review comments -*- lexical-binding: t; -*-

;; Author: Hemant Kumar
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (magit "3.0.0"))
;; URL: https://github.com/gnufied/treeview-magit

;;; Commentary:
;; Record private review comments independently of Emacs bookmarks.  Comments
;; live in one JSON file per branch under the repository's Git common directory.
;; Start with `treemacs-magit-review-comment' or `treemacs-magit-review-list'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defgroup treemacs-magit-review nil
  "Private, branch-local code review comments."
  :group 'tools)

(defcustom treemacs-magit-review-margin-marker "󰗣"
  "Left-margin marker for review comments.
The default is Nerd Font U+EC37.  Use the ASCII option without a Nerd Font."
  :type 'string :group 'treemacs-magit-review)

(defcustom treemacs-magit-review-margin-ascii-marker "!"
  "ASCII alternative to the review marker."
  :type 'string :group 'treemacs-magit-review)

(defcustom treemacs-magit-review-margin-use-ascii-marker nil
  "Whether to use the ASCII review marker."
  :type 'boolean :group 'treemacs-magit-review)

(defface treemacs-magit-review-margin-face
  '((t (:inherit warning :weight bold)))
  "Face of review markers, independent of bookmark faces."
  :group 'treemacs-magit-review)

(define-error 'treemacs-magit-review-conflict
	      "Review changed on disk; draft retained. Reload with C-c C-r before saving"
	      'user-error)

(cl-defstruct (treemacs-magit--review-context
               (:constructor treemacs-magit--review-context-create))
  root repository gitdir scope head file)

(cl-defstruct (treemacs-magit--review-snapshot
               (:constructor treemacs-magit--review-snapshot-create))
  context data digest)

(defvar treemacs-magit--review-timer nil)
(defvar treemacs-magit--review-refreshing nil)
(defvar-local treemacs-magit--review-context nil)
(defvar-local treemacs-magit--review-snapshot nil)
(defvar-local treemacs-magit--review-comment nil)
(defvar-local treemacs-magit--review-overlays nil)
(defvar-local treemacs-magit--review-locations nil)
(defvar-local treemacs-magit--review-suspended nil)
(defvar-local treemacs-magit--review-tick nil)
(defvar-local treemacs-magit--review-margin nil)
(defvar-local treemacs-magit--review-window-margins nil)
(defvar-local treemacs-magit--review-error nil)
(defvar-local treemacs-magit--review-count 0)
(defvar-local treemacs-magit--review-display-options nil)
(defvar treemacs-magit-review-mode)

;; A revert may rerun the major mode.  Do not lose the checkout identity or
;; silently adopt a previously suspended buffer during that reinitialization.
(dolist (variable '(treemacs-magit-review-mode treemacs-magit--review-context
					       treemacs-magit--review-suspended))
  (put variable 'permanent-local t))

(defun treemacs-magit--review-git (directory &rest arguments)
  "Return Git output in DIRECTORY, or nil for a nonzero exit status."
  (let ((default-directory directory))
    (with-temp-buffer
      (when (zerop (apply #'process-file "git" nil '(t nil) nil arguments))
        (string-trim-right (buffer-string) "[\r\n]+")))))

(defun treemacs-magit--review-context (&optional directory)
  "Discover a fresh local checkout context for DIRECTORY.
Do not use Magit's refresh cache for branch identity."
  (let ((directory (or directory
                       (and (boundp 'treemacs-magit--repository)
                            (symbol-value 'treemacs-magit--repository))
                       default-directory)))
    (when (file-remote-p directory)
      (user-error "Review comments currently support local Git checkouts only"))
    (let ((root (treemacs-magit--review-git directory "rev-parse" "--show-toplevel")))
      (unless root (user-error "Not in a Git working tree"))
      (setq root (file-name-as-directory (file-truename root)))
      (let* ((common (treemacs-magit--review-git root "rev-parse" "--git-common-dir"))
             (gitdir (treemacs-magit--review-git root "rev-parse" "--git-dir"))
             (head (treemacs-magit--review-git root "rev-parse" "--verify" "HEAD"))
             (scope (or (treemacs-magit--review-git root "symbolic-ref" "-q" "HEAD")
                        (seq-some
                         (lambda (name)
                           (let ((file (expand-file-name name (expand-file-name gitdir root))))
                             (when (file-readable-p file)
                               (let ((ref (with-temp-buffer (insert-file-contents file)
                                                            (string-trim (buffer-string)))))
                                 (and (string-prefix-p "refs/heads/" ref) ref)))))
                         '("rebase-merge/head-name" "rebase-apply/head-name"))
                        (and head (concat "detached:" head))))
             (repository (file-name-as-directory
                          (file-truename (expand-file-name common root)))))
        (unless scope (user-error "Cannot determine review branch"))
        (treemacs-magit--review-context-create
         :root root :repository repository :head head :scope scope
         :gitdir (file-name-as-directory
                  (file-truename (expand-file-name gitdir root)))
         :file (expand-file-name
                (concat "treemacs-magit-review/scopes/"
                        (secure-hash 'sha256 scope) ".json") repository))))))

(defun treemacs-magit--review-same-scope-p (a b)
  "Whether contexts A and B identify the same checkout and scope."
  (and a b
       (equal (treemacs-magit--review-context-root a)
              (treemacs-magit--review-context-root b))
       (equal (treemacs-magit--review-context-file a)
              (treemacs-magit--review-context-file b))))

(defun treemacs-magit--review-path (context path)
  "Validate relative PATH in CONTEXT and return its absolute name."
  (unless (and (stringp path) (not (string-empty-p path))
               (not (file-name-absolute-p path)) (not (file-remote-p path))
               (not (member ".." (split-string path "/")))
               (not (string-match-p "\0" path)))
    (error "Invalid review path: %S" path))
  (let* ((root (treemacs-magit--review-context-root context))
         (absolute (expand-file-name path root)))
    (unless (file-in-directory-p (file-truename absolute) root)
      (error "Review path escapes checkout: %s" path))
    absolute))

(defun treemacs-magit--review-validate-anchor (context anchor)
  "Validate a persisted worktree ANCHOR in CONTEXT."
  (treemacs-magit--review-path context (alist-get 'path anchor))
  (unless (and (equal (alist-get 'source_kind anchor) "worktree")
               (cl-every (lambda (key)
                           (let ((n (alist-get key anchor)))
                             (and (integerp n) (>= n 1))))
                         '(start_line end_line))
               (cl-every (lambda (key)
                           (let ((n (alist-get key anchor)))
                             (and (integerp n) (>= n 0))))
                         '(start_column end_column))
               (or (< (alist-get 'start_line anchor) (alist-get 'end_line anchor))
                   (and (= (alist-get 'start_line anchor) (alist-get 'end_line anchor))
                        (<= (alist-get 'start_column anchor)
                            (alist-get 'end_column anchor))))
               (cl-every (lambda (key) (stringp (alist-get key anchor)))
                         '(text before after fingerprint)))
    (error "Malformed review anchor")))

(defun treemacs-magit--review-validate (context data)
  "Validate review DATA before reading or writing it for CONTEXT."
  (unless (eql (alist-get 'schema_version data) 1)
    (error "Unsupported review schema: %S" (alist-get 'schema_version data)))
  (unless (and (equal (alist-get 'scope data)
                      (treemacs-magit--review-context-scope context))
               (cl-every (lambda (key) (stringp (alist-get key data)))
                         '(review_id created_at updated_at))
               (vectorp (alist-get 'comments data)))
    (error "Malformed review file or mismatched scope"))
  (let ((ids (make-hash-table :test #'equal)))
    (seq-doseq (comment (alist-get 'comments data))
      (unless (and (stringp (alist-get 'id comment))
                   (not (gethash (alist-get 'id comment) ids))
                   (cl-every (lambda (key) (stringp (alist-get key comment)))
                             '(body created_at updated_at))
                   (member (alist-get 'status comment) '("open" "resolved")))
        (error "Malformed or duplicate review comment"))
      (puthash (alist-get 'id comment) t ids)
      (treemacs-magit--review-validate-anchor context (alist-get 'anchor comment))
      (when (alist-get 'confirmed_anchor comment)
        (treemacs-magit--review-validate-anchor
         context (alist-get 'confirmed_anchor comment)))))
  data)

(defun treemacs-magit--review-read (context)
  "Read a validated snapshot for CONTEXT, without creating storage."
  (let ((file (treemacs-magit--review-context-file context)) text data)
    (when (file-exists-p file)
      (setq text (with-temp-buffer
                   (let ((coding-system-for-read 'utf-8-unix))
                     (insert-file-contents file))
                   (buffer-string))
            data (treemacs-magit--review-validate
                  context (json-parse-string text :object-type 'alist
                                             :array-type 'array :null-object nil
                                             :false-object :json-false))))
    (treemacs-magit--review-snapshot-create
     :context context :data data :digest (and text (secure-hash 'sha256 text)))))

(defun treemacs-magit--review-now ()
  "Return a UTC timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))

(defun treemacs-magit--review-id ()
  "Return a new opaque identifier."
  (secure-hash 'sha256 (format "%s:%s:%s:%s" (current-time) (emacs-pid)
                               (random) (system-name))))

(defun treemacs-magit--review-new-data (context)
  "Make an empty review for CONTEXT."
  `((schema_version . 1) (review_id . ,(treemacs-magit--review-id))
    (scope . ,(treemacs-magit--review-context-scope context))
    (created_at . ,(treemacs-magit--review-now))
    (updated_at . ,(treemacs-magit--review-now))
    (initial_head . ,(treemacs-magit--review-context-head context))
    (comments . [])))

(defun treemacs-magit--review-write (snapshot mutate)
  "Apply MUTATE to SNAPSHOT data with a lock and optimistic concurrency check.
Return the saved snapshot.  Errors leave the previous file and draft intact."
  (let* ((context (treemacs-magit--review-snapshot-context snapshot))
         (file (treemacs-magit--review-context-file context))
         (directory (file-name-directory file))
         (lock (concat file ".lock")) temporary locked)
    (make-directory directory t)
    (unwind-protect
        (progn
          (condition-case nil
              (progn (make-directory lock) (setq locked t))
            (file-already-exists
             (user-error "Review locked: %s; recover a stale lock explicitly" lock)))
          (let* ((current (treemacs-magit--review-read context))
                 (data (copy-tree (or (treemacs-magit--review-snapshot-data current)
                                      (treemacs-magit--review-new-data context)) t)))
            (unless (equal (treemacs-magit--review-snapshot-digest snapshot)
                           (treemacs-magit--review-snapshot-digest current))
              (signal 'treemacs-magit-review-conflict nil))
            (funcall mutate data)
            (setf (alist-get 'updated_at data) (treemacs-magit--review-now))
            (treemacs-magit--review-validate context data)
            (setq temporary (make-temp-file (expand-file-name ".review-" directory)))
            (let ((coding-system-for-write 'utf-8-unix)
                  (json-encoding-pretty-print t)
                  (json-false :json-false))
              (with-temp-file temporary (insert (json-encode data) "\n")))
            (rename-file temporary file t)
            (setq temporary nil)
            (treemacs-magit--review-read context)))
      (when temporary (delete-file temporary))
      (when locked (delete-directory lock)))))

(defun treemacs-magit--review-anchor (context)
  "Capture point or the active region in the current source buffer for CONTEXT."
  (save-restriction
    (widen)
    (let* ((start (if (use-region-p) (region-beginning) (line-beginning-position)))
           (end (if (use-region-p) (region-end) (line-end-position)))
           (path (file-relative-name (file-truename buffer-file-name)
                                     (treemacs-magit--review-context-root context)))
           (head (treemacs-magit--review-context-head context)))
      (treemacs-magit--review-path context path)
      `((path . ,path) (source_kind . "worktree") (head . ,head)
        (source_revision . ,head)
        (blob . ,(and head (treemacs-magit--review-git
                            (treemacs-magit--review-context-root context)
                            "rev-parse" "--verify" (concat head ":" path))))
        (start_line . ,(line-number-at-pos start t))
        (start_column . ,(save-excursion (goto-char start) (- start (line-beginning-position))))
        (end_line . ,(line-number-at-pos end t))
        (end_column . ,(save-excursion (goto-char end) (- end (line-beginning-position))))
        (text . ,(buffer-substring-no-properties start end))
        (before . ,(buffer-substring-no-properties
                    (save-excursion (goto-char start) (forward-line -2) (point)) start))
        (after . ,(buffer-substring-no-properties
                   end (save-excursion (goto-char end) (forward-line 3) (point))))
        (fingerprint . ,(secure-hash 'sha256 (buffer-substring-no-properties (point-min) (point-max))))
        (unsaved . ,(if (buffer-modified-p) t :json-false))))))

(defun treemacs-magit--review-range-point (line column)
  "Return exact position for LINE and COLUMN, or nil if outside buffer."
  (save-excursion
    (goto-char (point-min))
    (when (and (zerop (forward-line (1- line)))
               (<= column (- (line-end-position) (point))))
      (+ (point) column))))

(defun treemacs-magit--review-resolve (anchor)
  "Resolve ANCHOR in current widened buffer to (STATE START END).
Only exact fingerprints or unique text with context are accepted."
  (save-restriction
    (widen)
    (let* ((text (alist-get 'text anchor))
           (fingerprint (secure-hash 'sha256
                                     (buffer-substring-no-properties (point-min) (point-max))))
           (start (treemacs-magit--review-range-point
                   (alist-get 'start_line anchor) (alist-get 'start_column anchor)))
           (end (treemacs-magit--review-range-point
                 (alist-get 'end_line anchor) (alist-get 'end_column anchor))))
      (if (and (equal fingerprint (alist-get 'fingerprint anchor)) start end
               (equal text (buffer-substring-no-properties start end)))
          (list 'located start end)
        (let* ((before (alist-get 'before anchor))
               (after (alist-get 'after anchor))
               (needle (concat before text after)) matches)
          (unless (string-empty-p needle)
            (save-excursion
              (goto-char (point-min))
              (while (search-forward needle nil t)
                (let ((a (+ (match-beginning 0) (length before))))
                  (push (list 'located a (+ a (length text))) matches))
                (goto-char (1+ (match-beginning 0))))))
          (cond ((= (length matches) 1) (car matches))
                ((> (length matches) 1) '(ambiguous))
                (t '(outdated))))))))

(defun treemacs-magit--review-clear ()
  "Remove owned overlays and markers in the current source buffer."
  (mapc #'delete-overlay treemacs-magit--review-overlays)
  (setq treemacs-magit--review-overlays nil treemacs-magit--review-count 0)
  (dolist (entry treemacs-magit--review-locations)
    (set-marker (nth 1 entry) nil)
    (set-marker (nth 2 entry) nil))
  (setq treemacs-magit--review-locations nil))

(defun treemacs-magit--review-source-ready (context &optional adopt)
  "Check whether the current source buffer belongs to CONTEXT.
With ADOPT, offer explicit adoption after a suspended buffer is saved/reverted."
  (unless (treemacs-magit--review-same-scope-p context treemacs-magit--review-context)
    (treemacs-magit--review-clear)
    (setq treemacs-magit--review-suspended
          (or treemacs-magit--review-suspended
              (and treemacs-magit--review-context (buffer-modified-p))
              (not (verify-visited-file-modtime (current-buffer))))
          treemacs-magit--review-context context))
  (when (and adopt treemacs-magit--review-suspended
             (not (buffer-modified-p)) (verify-visited-file-modtime (current-buffer))
             (yes-or-no-p "Adopt this saved buffer for the current review branch? "))
    (setq treemacs-magit--review-suspended nil))
  (and (not treemacs-magit--review-suspended)
       (verify-visited-file-modtime (current-buffer))))

(defun treemacs-magit--review-anchor-of (comment)
  "Return COMMENT's confirmed or original anchor."
  (or (alist-get 'confirmed_anchor comment) (alist-get 'anchor comment)))

(defun treemacs-magit--review-location (comment)
  "Resolve COMMENT in current source buffer, using valid live markers."
  (save-restriction
    (widen)
    (let* ((id (alist-get 'id comment))
           (anchor (treemacs-magit--review-anchor-of comment))
           (cached (assoc id treemacs-magit--review-locations))
           (start (and cached (marker-position (nth 1 cached))))
           (end (and cached (marker-position (nth 2 cached)))))
      (if (and start end (<= start end) (equal anchor (nth 3 cached))
               (equal (alist-get 'text anchor)
                      (buffer-substring-no-properties start end)))
          (list 'located start end)
	(when cached
          (set-marker (nth 1 cached) nil) (set-marker (nth 2 cached) nil)
          (setq treemacs-magit--review-locations
		(delete cached treemacs-magit--review-locations)))
	(let ((result (treemacs-magit--review-resolve anchor)))
          (when (eq (car result) 'located)
            (push (list id (copy-marker (nth 1 result) t)
			(copy-marker (nth 2 result) nil) anchor)
                  treemacs-magit--review-locations))
          result)))))

(defun treemacs-magit--review-restore-margins ()
  "Restore owned margin changes, preserving subsequent unrelated changes."
  (when treemacs-magit--review-margin
    (when (equal left-margin-width (cdr treemacs-magit--review-margin))
      (setq left-margin-width (car treemacs-magit--review-margin)))
    (setq treemacs-magit--review-margin nil))
  (dolist (entry treemacs-magit--review-window-margins)
    (let ((window (nth 0 entry)))
      (when (and (window-live-p window) (eq (window-buffer window) (current-buffer))
                 (equal (car (window-margins window)) (car (nth 2 entry))))
        (set-window-margins window (car (nth 1 entry)) (cdr (window-margins window))))))
  (setq treemacs-magit--review-window-margins nil))

(defun treemacs-magit--review-ensure-margins (width)
  "Ensure WIDTH columns without reducing existing left or right margins."
  (unless treemacs-magit--review-margin
    (setq treemacs-magit--review-margin (cons left-margin-width nil)))
  (setq left-margin-width (max (or left-margin-width 0) width))
  (setcdr treemacs-magit--review-margin left-margin-width)
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (let* ((old (window-margins window))
           (entry (assq window treemacs-magit--review-window-margins)))
      (unless entry
        (setq entry (list window old nil))
        (push entry treemacs-magit--review-window-margins))
      (let ((new (cons (max (or (car old) 0) (or left-margin-width 0) width) (cdr old))))
        (set-window-margins window (car new) (cdr new))
        (setf (nth 2 entry) new)))))

(defun treemacs-magit--review-other-marker-width (position)
  "Measure other packages' left-margin strings on the line at POSITION."
  (let ((width 0))
    (dolist (overlay (overlays-in position (min (1+ position) (point-max))))
      (unless (overlay-get overlay 'treemacs-magit-review)
        (let ((string (overlay-get overlay 'before-string)))
          (when (and (stringp string) (> (length string) 0))
            (let ((display (get-text-property 0 'display string)))
              (when (and (equal (car-safe display) '(margin left-margin))
                         (stringp (cadr display)))
                (cl-incf width (string-width (cadr display)))))))))
    width))

(defun treemacs-magit--review-render (snapshot)
  "Reconcile review overlays from SNAPSHOT in the current source buffer."
  (mapc #'delete-overlay treemacs-magit--review-overlays)
  (setq treemacs-magit--review-overlays nil treemacs-magit--review-count 0)
  (setq treemacs-magit--review-locations
        (cl-delete-if
         (lambda (entry)
           (unless (seq-find (lambda (c) (equal (car entry) (alist-get 'id c)))
                             (alist-get 'comments (treemacs-magit--review-snapshot-data snapshot)))
             (set-marker (nth 1 entry) nil) (set-marker (nth 2 entry) nil) t))
         treemacs-magit--review-locations))
  (let* ((context (treemacs-magit--review-snapshot-context snapshot))
         (path (file-relative-name (file-truename buffer-file-name)
                                   (treemacs-magit--review-context-root context)))
         (lines (make-hash-table :test #'eql)) (width 0)
         (marker (if treemacs-magit-review-margin-use-ascii-marker
                     treemacs-magit-review-margin-ascii-marker
                   treemacs-magit-review-margin-marker)))
    (save-restriction
      (widen)
      (seq-doseq (comment (alist-get 'comments (treemacs-magit--review-snapshot-data snapshot)))
        (when (and (equal path (alist-get 'path (treemacs-magit--review-anchor-of comment)))
                   (equal (alist-get 'status comment) "open"))
          (cl-incf treemacs-magit--review-count)
          (let ((location (treemacs-magit--review-location comment)))
            (when (eq (car location) 'located)
              (let ((line (save-excursion (goto-char (nth 1 location))
                                          (line-beginning-position))))
                (puthash line (cons comment (gethash line lines)) lines))))))
      (maphash
       (lambda (position comments)
         (let* ((label (concat marker (if (> (length comments) 1)
                                          (number-to-string (length comments)) "")))
                (overlay (make-overlay position (min (1+ position) (point-max)))))
           (overlay-put overlay 'treemacs-magit-review t)
           (overlay-put overlay 'priority 100)
           (overlay-put overlay 'before-string
                        (propertize " " 'display
                                    `((margin left-margin)
                                      ,(propertize label 'face 'treemacs-magit-review-margin-face))
                                    'help-echo (mapconcat (lambda (c) (alist-get 'body c)) comments "\n\n")))
           (setq width (max width (+ (string-width label)
                                     (treemacs-magit--review-other-marker-width position))))
           (push overlay treemacs-magit--review-overlays))) lines))
    (if (> width 0) (treemacs-magit--review-ensure-margins width)
      (treemacs-magit--review-restore-margins))))

(defun treemacs-magit--review-refresh-source (&optional context snapshot force)
  "Refresh source from optional CONTEXT and SNAPSHOT; FORCE rebuilds its display."
  (let* ((context (or context (treemacs-magit--review-context)))
         (snapshot (or snapshot (treemacs-magit--review-read context)))
         (options (list treemacs-magit-review-margin-marker
                        treemacs-magit-review-margin-ascii-marker
                        treemacs-magit-review-margin-use-ascii-marker))
         (changed (or force
                      treemacs-magit--review-error
                      (not (equal options treemacs-magit--review-display-options))
                      (not (treemacs-magit--review-same-scope-p context treemacs-magit--review-context))
                      (not (equal treemacs-magit--review-tick (buffer-chars-modified-tick)))
                      (not (and treemacs-magit--review-snapshot
                                (equal (treemacs-magit--review-snapshot-digest snapshot)
                                       (treemacs-magit--review-snapshot-digest treemacs-magit--review-snapshot)))))))
    (if (treemacs-magit--review-source-ready context)
        (progn (when changed (treemacs-magit--review-render snapshot))
               (setq treemacs-magit--review-error nil))
      (treemacs-magit--review-clear)
      (treemacs-magit--review-restore-margins))
    (setq treemacs-magit--review-snapshot snapshot
          treemacs-magit--review-display-options options
          treemacs-magit--review-tick (buffer-chars-modified-tick))
    (force-mode-line-update)))

(defun treemacs-magit--review-before-revert ()
  "Forget live locations before a source buffer is reverted."
  (treemacs-magit--review-clear)
  (treemacs-magit--review-restore-margins)
  (setq treemacs-magit--review-tick nil))

(defun treemacs-magit--review-before-change (begin end)
  "Invalidate cached ranges when an edit from BEGIN to END touches their text."
  (setq treemacs-magit--review-locations
        (cl-delete-if
         (lambda (entry)
           (let ((a (marker-position (nth 1 entry)))
                 (b (marker-position (nth 2 entry))))
             (when (and a b
                        (or (and (< begin b) (> end a))
                            (and (= a b) (<= begin a) (>= end b))
                            (and (= begin end) (> begin a) (< begin b))))
               (set-marker (nth 1 entry) nil)
               (set-marker (nth 2 entry) nil)
               t)))
         treemacs-magit--review-locations)))

(defun treemacs-magit--review-stop-buffer ()
  "Clean up display state when a review source buffer is disabled or killed."
  (treemacs-magit--review-clear)
  (treemacs-magit--review-restore-margins))

(dolist (hook '(treemacs-magit--review-before-revert
                treemacs-magit--review-before-change
                treemacs-magit--review-refresh-source
                treemacs-magit--review-stop-buffer))
  (put hook 'permanent-local-hook t))

;;;###autoload
(define-minor-mode treemacs-magit-review-mode
  "Show independent, branch-local review markers in a local source buffer.
Use `treemacs-magit-review-comment' to capture a comment and
`treemacs-magit-review-list' to read all comments on the current branch."
  :lighter (:eval (format " Review:%s(%s)"
                          (if treemacs-magit--review-context
                              (string-remove-prefix "refs/heads/"
						    (treemacs-magit--review-context-scope treemacs-magit--review-context)) "?")
                          (cond (treemacs-magit--review-error "error")
				(treemacs-magit--review-suspended "suspended")
				(t treemacs-magit--review-count))))
  (if treemacs-magit-review-mode
      (condition-case err
          (progn
            (unless (and buffer-file-name (not (derived-mode-p 'magit-blob-mode)))
              (user-error "Review markers require a worktree source buffer"))
            (treemacs-magit--review-refresh-source nil nil t)
            (add-hook 'before-revert-hook #'treemacs-magit--review-before-revert nil t)
            (add-hook 'before-change-functions #'treemacs-magit--review-before-change nil t)
            (add-hook 'after-revert-hook #'treemacs-magit--review-refresh-source nil t)
            (add-hook 'after-save-hook #'treemacs-magit--review-refresh-source nil t)
            (add-hook 'kill-buffer-hook #'treemacs-magit--review-stop-buffer nil t)
            (treemacs-magit--review-start-monitor))
        (error (treemacs-magit-review-mode -1) (signal (car err) (cdr err))))
    (remove-hook 'before-revert-hook #'treemacs-magit--review-before-revert t)
    (remove-hook 'before-change-functions #'treemacs-magit--review-before-change t)
    (remove-hook 'after-revert-hook #'treemacs-magit--review-refresh-source t)
    (remove-hook 'after-save-hook #'treemacs-magit--review-refresh-source t)
    (remove-hook 'kill-buffer-hook #'treemacs-magit--review-stop-buffer t)
    (treemacs-magit--review-stop-buffer)))

(defvar treemacs-magit-review-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'treemacs-magit--review-save-editor)
    (define-key map (kbd "C-c C-k") #'treemacs-magit--review-cancel-editor)
    (define-key map (kbd "C-c C-r") #'treemacs-magit--review-reload-editor)
    map))

(define-derived-mode treemacs-magit-review-edit-mode text-mode "Review Comment"
  "Edit a review comment.  Save with C-c C-c, cancel with C-c C-k.
C-c C-r reloads the saved generation after a conflict, retaining your draft."
  (setq-local require-final-newline nil))

(defun treemacs-magit--review-edit (snapshot comment)
  "Open COMMENT with its pinned SNAPSHOT."
  (let* ((context (treemacs-magit--review-snapshot-context snapshot))
         (buffer (generate-new-buffer "*Review Comment*")))
    (with-current-buffer buffer
      (treemacs-magit-review-edit-mode)
      (setq treemacs-magit--review-snapshot snapshot
            treemacs-magit--review-comment (copy-tree comment t)
            default-directory (treemacs-magit--review-context-root context))
      (setq header-line-format
            (format "%s | %s | %s:%d | %.8s | C-c C-c save; C-c C-k cancel"
                    default-directory (treemacs-magit--review-context-scope context)
                    (alist-get 'path (treemacs-magit--review-anchor-of comment))
                    (alist-get 'start_line (treemacs-magit--review-anchor-of comment))
                    (alist-get 'id comment)))
      (insert (alist-get 'body comment))
      (set-buffer-modified-p nil))
    (pop-to-buffer buffer)
    buffer))

(defun treemacs-magit--review-reload-editor ()
  "Explicitly accept the latest saved generation while retaining draft text."
  (interactive)
  (unless (yes-or-no-p "Reload saved generation and keep draft for replacement? ")
    (user-error "Draft unchanged"))
  (setq treemacs-magit--review-snapshot
        (treemacs-magit--review-read
         (treemacs-magit--review-snapshot-context treemacs-magit--review-snapshot)))
  (message "Latest generation loaded; draft retained. C-c C-c saves it"))

(defun treemacs-magit--review-save-editor ()
  "Save this editor's comment to its captured branch, retaining draft on error."
  (interactive)
  (let* ((comment (copy-tree treemacs-magit--review-comment t))
         (body (buffer-substring-no-properties (point-min) (point-max))))
    (when (string-empty-p (string-trim body)) (user-error "Comment is empty"))
    (setf (alist-get 'body comment) body
          (alist-get 'updated_at comment) (treemacs-magit--review-now))
    (let* ((saved (treemacs-magit--review-write
                   treemacs-magit--review-snapshot
                   (lambda (data)
                     (setf (alist-get 'comments data)
                           (vconcat (seq-remove
                                     (lambda (c) (equal (alist-get 'id c) (alist-get 'id comment)))
                                     (alist-get 'comments data))
                                    (vector comment))))))
           (scope (treemacs-magit--review-context-scope
                   (treemacs-magit--review-snapshot-context saved))))
      (set-buffer-modified-p nil)
      (quit-window t)
      (treemacs-magit--review-refresh-all)
      (message "Review comment saved to %s" scope))))

(defun treemacs-magit--review-cancel-editor ()
  "Cancel this draft, asking before discarding edits."
  (interactive)
  (when (or (not (buffer-modified-p)) (yes-or-no-p "Discard this comment draft? "))
    (set-buffer-modified-p nil) (quit-window t)))

;;;###autoload
(defun treemacs-magit-review-comment (&optional new)
  "Add or edit a review comment at point or the active region.
With prefix NEW, add another comment even if one already occupies this line."
  (interactive "P")
  (unless (and buffer-file-name (not (derived-mode-p 'magit-blob-mode 'magit-diff-mode)))
    (user-error "Capture review comments from a worktree source buffer"))
  (let* ((context (treemacs-magit--review-context))
         (gitdir (treemacs-magit--review-context-gitdir context)))
    (when (seq-some (lambda (p) (file-exists-p (expand-file-name p gitdir)))
                    '("rebase-merge" "rebase-apply" "sequencer" "CHERRY_PICK_HEAD" "REVERT_HEAD"))
      (user-error "Finish the current rebase/cherry-pick/revert before capturing comments"))
    (unless (treemacs-magit--review-source-ready context t)
      (user-error "Review suspended: save/revert the source, then explicitly adopt its branch"))
    (treemacs-magit-review-mode 1)
    (let ((snapshot (treemacs-magit--review-read context)) matches)
      (unless new
        (seq-doseq (comment (alist-get 'comments (treemacs-magit--review-snapshot-data snapshot)))
          (when (equal (alist-get 'path (treemacs-magit--review-anchor-of comment))
                       (file-relative-name (file-truename buffer-file-name)
                                           (treemacs-magit--review-context-root context)))
            (let ((location (treemacs-magit--review-location comment)))
              (when (and (eq (car location) 'located)
                         (= (line-number-at-pos (nth 1 location) t) (line-number-at-pos nil t)))
                (push comment matches))))))
      (let ((comment
             (cond ((= (length matches) 1) (car matches))
                   (matches
                    (let ((choices (mapcar (lambda (c) (cons (concat (alist-get 'id c) " "
                                                                     (alist-get 'body c)) c)) matches)))
                      (cdr (assoc (completing-read "Comment: " choices nil t) choices))))
                   (t `((id . ,(treemacs-magit--review-id)) (body . "") (status . "open")
                        (created_at . ,(treemacs-magit--review-now))
                        (updated_at . ,(treemacs-magit--review-now))
                        (anchor . ,(treemacs-magit--review-anchor context)))))))
        (treemacs-magit--review-edit snapshot comment)))))

(defvar treemacs-magit-review-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (binding '(("RET" . treemacs-magit--review-list-visit)
                       ("n" . treemacs-magit--review-list-next)
                       ("p" . treemacs-magit--review-list-previous)
                       ("e" . treemacs-magit--review-list-edit)
                       ("d" . treemacs-magit--review-list-delete)
                       ("g" . treemacs-magit--review-refresh-list)))
      (define-key map (kbd (car binding)) (cdr binding))) map))

(define-derived-mode treemacs-magit-review-list-mode special-mode "Review Comments"
  "All review comments for this checkout's current branch.
RET visits, n/p move, e edits, d deletes, and g reloads the current branch."
  (setq-local revert-buffer-function (lambda (&rest _) (treemacs-magit--review-refresh-list))))

(defun treemacs-magit--review-sort-key (comment)
  "Return stable sort key for COMMENT."
  (let ((anchor (treemacs-magit--review-anchor-of comment)))
    (format "%s\0%012d:%012d:%s" (alist-get 'path anchor)
            (alist-get 'start_line anchor) (alist-get 'start_column anchor)
            (alist-get 'id comment))))

(defun treemacs-magit--review-refresh-list (&optional context snapshot)
  "Reload this checkout's current branch list using CONTEXT and SNAPSHOT if given."
  (interactive)
  (let* ((id (get-text-property (point) 'treemacs-magit-review-id))
         (context (or context (treemacs-magit--review-context default-directory)))
         (snapshot (or snapshot (treemacs-magit--review-read context)))
         (data (treemacs-magit--review-snapshot-data snapshot))
         (comments (sort (append (alist-get 'comments data) nil)
                         (lambda (a b) (string-lessp (treemacs-magit--review-sort-key a)
                                                     (treemacs-magit--review-sort-key b)))))
         (inhibit-read-only t) last-path)
    (setq treemacs-magit--review-context context treemacs-magit--review-snapshot snapshot)
    (erase-buffer)
    (insert (propertize (format "Review: %s\nBranch: %s\n%d comment(s)\n"
                                (treemacs-magit--review-context-root context)
                                (treemacs-magit--review-context-scope context) (length comments))
                        'face 'bold))
    (when data
      (insert (format "Created: %s | Original HEAD: %s\n"
                      (alist-get 'created_at data) (or (alist-get 'initial_head data) "unborn"))))
    (insert "\nRET visit | n/p move | e edit | d delete | g reload\n\n")
    (unless comments (insert "No review comments for this branch\n"))
    (dolist (comment comments)
      (let* ((anchor (treemacs-magit--review-anchor-of comment))
             (path (alist-get 'path anchor)) (start (point))
             (file (treemacs-magit--review-path context path)))
        (unless (equal path last-path)
          (insert (propertize (concat path "\n") 'face 'font-lock-function-name-face))
          (setq last-path path start (point)))
        (insert (format "  %d:%d [%s; %s]\n"
                        (alist-get 'start_line anchor) (alist-get 'start_column anchor)
                        (alist-get 'status comment)
                        (if (file-exists-p file) "location unverified" "missing-file")))
        (insert (replace-regexp-in-string "^" "    " (alist-get 'body comment)) "\n\n")
        (add-text-properties start (point) `(treemacs-magit-review-id ,(alist-get 'id comment)))))
    (goto-char (or (cdr (assoc id (treemacs-magit--review-list-entries)))
                   (text-property-not-all (point-min) (point-max) 'treemacs-magit-review-id nil)
                   (point-min)))
    (set-buffer-modified-p nil)
    (when (called-interactively-p 'interactive)
      (treemacs-magit--review-refresh-all))))

;;;###autoload
(defun treemacs-magit-review-list ()
  "List full review comments for the current local Git project and branch."
  (interactive)
  (let* ((context (treemacs-magit--review-context))
         (root (treemacs-magit--review-context-root context))
         (buffer (get-buffer-create (format "*Review Comments: %s*" root))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'treemacs-magit-review-list-mode)
        (treemacs-magit-review-list-mode))
      (setq default-directory root)
      (treemacs-magit--review-refresh-list context))
    (treemacs-magit--review-start-monitor)
    (pop-to-buffer buffer)))

(defun treemacs-magit--review-list-current ()
  "Return selected comment after checking the list's current scope."
  (let ((context (treemacs-magit--review-context default-directory)))
    (unless (treemacs-magit--review-same-scope-p context treemacs-magit--review-context)
      (treemacs-magit--review-refresh-list context)
      (user-error "Branch changed; select a comment again")))
  (let* ((id (get-text-property (point) 'treemacs-magit-review-id))
         (comment (seq-find (lambda (c) (equal id (alist-get 'id c)))
                            (alist-get 'comments
                                       (treemacs-magit--review-snapshot-data treemacs-magit--review-snapshot)))))
    (or comment (user-error "No review comment here"))))

(defun treemacs-magit--review-list-next (&optional backwards)
  "Move to the next comment, or previous with BACKWARDS."
  (interactive)
  (let* ((entries (treemacs-magit--review-list-entries))
         (id (get-text-property (point) 'treemacs-magit-review-id))
         (start (or (cdr (assoc id entries)) (point)))
         (candidates (seq-filter (lambda (entry) (if backwards (< (cdr entry) start)
                                                   (> (cdr entry) start))) entries))
         (found (cdr (if backwards (car (last candidates)) (car candidates)))))
    (unless found (user-error "No %s comment" (if backwards "previous" "next")))
    (goto-char found)))

(defun treemacs-magit--review-list-entries ()
  "Return (ID . START) pairs for comment blocks in display order."
  (let ((position (point-min)) entries)
    (while (< position (point-max))
      (let ((id (get-text-property position 'treemacs-magit-review-id)))
        (when id (push (cons id position) entries)))
      (setq position (or (next-single-property-change position 'treemacs-magit-review-id)
                         (point-max))))
    (nreverse entries)))

(defun treemacs-magit--review-list-previous ()
  "Move to the previous review comment."
  (interactive) (treemacs-magit--review-list-next t))

(defun treemacs-magit--review-list-edit ()
  "Edit the selected comment in its captured scope."
  (interactive)
  (treemacs-magit--review-edit treemacs-magit--review-snapshot
                               (treemacs-magit--review-list-current)))

(defun treemacs-magit--review-list-delete ()
  "Delete the selected comment with confirmation and a generation check."
  (interactive)
  (let ((comment (treemacs-magit--review-list-current)))
    (when (yes-or-no-p "Delete this review comment? ")
      (treemacs-magit--review-write
       treemacs-magit--review-snapshot
       (lambda (data)
         (setf (alist-get 'comments data)
               (vconcat (seq-remove (lambda (c) (equal (alist-get 'id comment) (alist-get 'id c)))
                                    (alist-get 'comments data))))))
      (treemacs-magit--review-refresh-list)
      (treemacs-magit--review-refresh-all))))

(defun treemacs-magit--review-details (comment state)
  "Show COMMENT with unresolved location STATE without a speculative jump."
  (let ((anchor (treemacs-magit--review-anchor-of comment)))
    (with-help-window "*Review Location*"
      (princ (format "%s:%d — %s\n\n%s\n\nOriginal code:\n%s\n"
                     (alist-get 'path anchor) (alist-get 'start_line anchor) state
                     (alist-get 'body comment) (alist-get 'text anchor))))))

(defun treemacs-magit--review-list-visit ()
  "Visit a verified destination, or show details when it cannot be located."
  (interactive)
  (let* ((comment (treemacs-magit--review-list-current))
         (context treemacs-magit--review-context)
         (anchor (treemacs-magit--review-anchor-of comment))
         (file (treemacs-magit--review-path context (alist-get 'path anchor))))
    (if (not (and (file-regular-p file) (file-readable-p file)))
        (treemacs-magit--review-details comment (if (file-exists-p file) 'unavailable 'missing-file))
      (let* ((buffer (find-file-noselect file))
             (location
              (with-current-buffer buffer
                (treemacs-magit-review-mode 1)
                (if (treemacs-magit--review-source-ready context)
                    (save-restriction (widen) (treemacs-magit--review-location comment))
                  '(unavailable)))))
        (if (not (eq (car location) 'located))
            (treemacs-magit--review-details comment (car location))
          (let ((window
                 (seq-find (lambda (w)
                             (and (not (window-dedicated-p w))
                                  (not (window-parameter w 'window-side))
                                  (with-current-buffer (window-buffer w)
                                    (not (derived-mode-p 'special-mode 'treemacs-mode)))))
                           (window-list))))
            (if window (select-window window)
              ;; A list in a regular window can itself be replaced.
              (when (window-dedicated-p) (user-error "No regular window available")))
            (switch-to-buffer buffer)
            (widen) (goto-char (nth 1 location))))))))

(defun treemacs-magit--review-refresh-all (&rest _)
  "Refresh participating buffers, sharing one Git discovery per checkout."
  (unless treemacs-magit--review-refreshing
    (let ((treemacs-magit--review-refreshing t)
          (snapshots (make-hash-table :test #'equal)) active)
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (or treemacs-magit-review-mode (derived-mode-p 'treemacs-magit-review-list-mode))
            (setq active t)
            (condition-case err
                (let* ((root (if treemacs-magit--review-context
                                 (treemacs-magit--review-context-root treemacs-magit--review-context)
                               default-directory))
                       (snapshot (or (gethash root snapshots)
                                     (puthash root (treemacs-magit--review-read
                                                    (treemacs-magit--review-context root)) snapshots)))
                       (context (treemacs-magit--review-snapshot-context snapshot)))
                  (if (derived-mode-p 'treemacs-magit-review-list-mode)
                      (unless (and (treemacs-magit--review-same-scope-p context treemacs-magit--review-context)
                                   (equal (treemacs-magit--review-snapshot-digest snapshot)
                                          (treemacs-magit--review-snapshot-digest treemacs-magit--review-snapshot)))
                        (treemacs-magit--review-refresh-list context snapshot))
                    (treemacs-magit--review-refresh-source context snapshot))
                  (setq treemacs-magit--review-error nil))
              (error
               (when treemacs-magit-review-mode
                 (treemacs-magit--review-clear)
                 (treemacs-magit--review-restore-margins))
               (unless (equal treemacs-magit--review-error (error-message-string err))
                 (setq treemacs-magit--review-error (error-message-string err))
                 (message "Review refresh: %s" treemacs-magit--review-error)))))))
      (unless active
        (when (timerp treemacs-magit--review-timer) (cancel-timer treemacs-magit--review-timer))
        (setq treemacs-magit--review-timer nil)))))

(defun treemacs-magit--review-maybe-enable ()
  "Enable markers on newly visited files in participating checkouts."
  (when (and buffer-file-name (not (file-remote-p buffer-file-name))
             (not (derived-mode-p 'magit-blob-mode)))
    (let ((roots (delete-dups
                  (delq nil (mapcar (lambda (buffer)
                                      (with-current-buffer buffer
                                        (and treemacs-magit-review-mode treemacs-magit--review-context
                                             (treemacs-magit--review-context-root treemacs-magit--review-context))))
                                    (buffer-list))))))
      (when (and (seq-some (lambda (root) (file-in-directory-p buffer-file-name root)) roots)
                 ;; Git metadata files such as COMMIT_EDITMSG are below the
                 ;; checkout root, but are not worktree source files.
                 (equal (treemacs-magit--review-git
                         (file-name-directory buffer-file-name)
                         "rev-parse" "--is-inside-work-tree")
                        "true"))
        (let ((context (treemacs-magit--review-context)))
          (when (member (treemacs-magit--review-context-root context) roots)
            (treemacs-magit-review-mode 1)))))))

(defun treemacs-magit--review-start-monitor ()
  "Install inexpensive idle and event refresh triggers once."
  (unless (timerp treemacs-magit--review-timer)
    (setq treemacs-magit--review-timer
          (run-with-timer 2 2 #'treemacs-magit--review-idle-refresh)))
  (add-hook 'find-file-hook #'treemacs-magit--review-maybe-enable)
  (add-hook 'window-buffer-change-functions #'treemacs-magit--review-window-change)
  (add-function :after after-focus-change-function #'treemacs-magit--review-refresh-all))

(defun treemacs-magit--review-idle-refresh ()
  "Poll between input, including multiple checkouts in one continuous idle period."
  ;; Repeating idle timers run once per idle period, which misses a checkout
  ;; after their first firing when Emacs remains idle in another terminal.
  ;; Ordinary timers and other packages can reset reported idleness.  Checking
  ;; pending input instead keeps this poll running without delaying keystrokes.
  (unless (or (active-minibuffer-window) (input-pending-p))
    (treemacs-magit--review-refresh-all)))

(defun treemacs-magit--review-window-change (window)
  "Apply existing review margin width when WINDOW starts displaying a source."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (and treemacs-magit-review-mode treemacs-magit--review-margin)
        (treemacs-magit--review-ensure-margins (cdr treemacs-magit--review-margin))))))

;; Do not eagerly load Magit (which can install its own global bindings), or
;; initialize its refresh hook before Magit has established the default value.
(with-eval-after-load 'magit-mode
  (add-hook 'magit-post-refresh-hook #'treemacs-magit--review-refresh-all))

(provide 'treemacs-magit-review)
;;; treemacs-magit-review.el ends here
