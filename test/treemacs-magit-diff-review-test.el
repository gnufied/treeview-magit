;;; treemacs-magit-diff-review-test.el --- Adapter tests -*- lexical-binding: t -*-
(require 'ert)
(require 'treemacs-magit-diff-review)
;; Review comments may be loaded after the inline adapter in a live session.
(require 'treemacs-magit-review)

(defvar-local treemacs-magit-test-client nil)
(defvar lsp-headerline-breadcrumb-mode)

(ert-deftest treemacs-magit-branch-visit-after-commit ()
  (let* ((directory (make-temp-file "tree-moving-branch-" t))
         (default-directory (file-name-as-directory directory))
         (file (expand-file-name "sample.el" directory))
         (treemacs-magit-file-display 'diff-review)
         (treemacs-magit-min-content-window-width 1000)
         (treemacs-magit--buffer-name "*Moving branch test*"))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (cl-labels ((commit (text)
                        (with-temp-file file (insert text))
                        (treemacs-magit--diff-review-git "add" ".")
                        (treemacs-magit--diff-review-git
                         "-c" "user.name=Test" "-c" "user.email=test@example.com"
                         "commit" "-qm" text)))
            (treemacs-magit--diff-review-git "init" "-q" "-b" "main")
            (commit "base")
            (treemacs-magit--diff-review-git "switch" "-qc" "feature")
            (commit "first")
            (treemacs-magit-branch "main")
            (let ((default-directory (file-name-as-directory directory)))
              (commit "second"))
            (treemacs-magit--visit-current)
            (let ((expected (with-temp-buffer
                              (setq default-directory (file-name-as-directory directory))
                              (magit-rev-verify "HEAD"))))
              (should (equal expected treemacs-magit--revision))
              (with-current-buffer (find-buffer-visiting file)
                (should diff-review-file-mode)
                (should (equal (buffer-string) "second"))
                (should (equal expected (buffer-local-value 'diff-review--tip
                                                             diff-review--review)))))
            (let ((default-directory (file-name-as-directory directory)))
              (treemacs-magit--diff-review-git "branch" "-f" "main" "HEAD"))
            (should-error (treemacs-magit--visit-current) :type 'user-error)
            (should-not (treemacs-magit-node-children treemacs-magit--rendered-root))))
      (when-let* ((tree (get-buffer treemacs-magit--buffer-name)))
        (kill-buffer tree))
      (when-let* ((buffer (find-buffer-visiting file)))
        (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest treemacs-magit-inline-snapshots ()
  (let* ((directory (make-temp-file "tree-inline-" t))
         (default-directory (file-name-as-directory directory))
         (file (expand-file-name "sample.el" directory))
         (root (treemacs-magit-node-create :repository default-directory :root t))
         (data (treemacs-magit-node-create :repository default-directory :path file))
         (treemacs-magit-file-display 'diff-review)
         buffers)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((tree (selected-window))
                (target (split-window-right)))
            (cl-labels ((write-text (text) (with-temp-file file (insert text)))
                        (show (status text removed)
                          (select-window tree)
                          (cl-letf (((symbol-function 'treemacs-magit--target-window)
                                     (lambda () target)))
                            (treemacs-magit--visit-diff data root "sample.el" status))
                          (should (eq (selected-window) tree))
                          (let ((buffer (window-buffer target)))
                            (cl-pushnew buffer buffers)
                            (with-current-buffer buffer
                              (should (equal (buffer-string) text))
                              (if (and (memq status '(unstaged both untracked)) (file-exists-p file))
                                  (unless (equal text "")
                                    (should (equal buffer-file-name file))
                                    (should-not buffer-read-only))
                                (should buffer-read-only))
                              (should (eq major-mode 'emacs-lisp-mode))
                              (should diff-review-file-mode)
                              (let ((header (diff-review--file-header)))
                                (dolist (entry '(("[Previous]" . diff-review-previous-hunk)
                                                 ("[Next]" . diff-review-next-hunk)
                                                 ("[Difftastic]" . treemacs-magit-difftastic-file)))
                                  (let* ((position (string-search (car entry) header))
                                         (map (get-text-property position 'local-map header))
                                         invoked)
                                    (should (eq (lookup-key map [header-line down-mouse-1]) #'ignore))
                                    (cl-letf (((symbol-function (cdr entry))
                                               (lambda () (interactive) (setq invoked t))))
                                      (let ((keys (vector 'header-line
                                                          `(mouse-1 (,target header-line (0 . 0) 0)))))
                                        (call-interactively (lookup-key map [header-line mouse-1])
                                                            nil keys)))
                                    (should invoked)))
                                (should-not (string-search "[Viewed]" header)))
                              (when (memq status '(staged unstaged both committed))
                                (let* ((review diff-review--review)
                                       (owner diff-review--review)
                                       (expected
                                        (with-current-buffer review
                                          (cond
                                           ((eq status 'unstaged) nil)
                                           ((eq status 'staged) diff-review--base)
                                           (diff-review--tip
                                            (concat diff-review--base ".." diff-review--tip))
                                           (t diff-review--base))))
                                       (source (current-buffer)))
                                  (save-window-excursion
                                    (with-current-buffer (treemacs-magit-difftastic-file)
                                      (should (derived-mode-p 'magit-diff-mode))
                                      (should buffer-read-only)
                                      (should (equal magit-buffer-diff-range expected))
                                      (should (equal magit-buffer-diff-files '("sample.el")))
                                      (should (equal magit-buffer-diff-typearg
                                                     (and (eq status 'staged) "--cached")))
                                      (let ((deadline (+ (float-time) 5)))
                                        (while (and (< (float-time) deadline)
                                                    (string-match-p "Rendering difftastic"
                                                                    (buffer-string)))
                                          (accept-process-output nil 0.05)))
                                      (should (string-match-p "@@" (buffer-string)))))
                                  (should (eq (current-buffer) source))
                                  (should (eq diff-review--review owner))
                                  (should diff-review-file-mode)))
                              (should (eq (key-binding (kbd "C-c _ n")) #'diff-review-next-hunk))
                              (should (eq (key-binding (kbd "C-c _ p")) #'diff-review-previous-hunk))
                              (should (eq (key-binding (kbd "C-c _ c")) #'diff-review-comment))
                              (should (eq (key-binding (kbd "C-c _ r")) #'diff-review-reply))
                              (should (seq-some
                                       (lambda (o) (string-match-p removed
                                                    (or (overlay-get o 'before-string) "")))
                                       diff-review--overlays))))
                          (setq default-directory (file-name-as-directory directory))))
              (treemacs-magit--diff-review-git "init" "-q")
              (write-text "old\n")
              (treemacs-magit--diff-review-git "add" ".")
              (treemacs-magit--diff-review-git "-c" "user.name=Test" "-c" "user.email=test@example.com"
                                         "commit" "-qm" "Initial")
              (write-text "staged\n")
              (treemacs-magit--diff-review-git "add" ".")
              (write-text "worktree\n")
              (show 'staged "staged\n" "old")
              (show 'unstaged "worktree\n" "staged")
              ;; Re-enter a plain file after its review mode was removed.
              (with-current-buffer (window-buffer target)
                (diff-review-file-mode -1)
                (should-not header-line-format))
              (show 'unstaged "worktree\n" "staged")
              (show 'both "worktree\n" "old")
              (with-selected-window target
                (let ((lsp-headerline-breadcrumb-mode t)
                      (breadcrumb '(t (:eval (window-parameter nil 'lsp-headerline--string)))))
                  ;; An existing LSP connection survives review re-entry.
                  (diff-review-file-mode 1)
                  (should (equal (cadr header-line-format) breadcrumb))
                  (let ((review-element (car header-line-format)))
                    (should (eq (car review-element) :eval))
                    ;; LSP can connect after the file has entered the review.
                    (setq header-line-format (list breadcrumb review-element))
                    (treemacs-magit--review-order-lsp-header)
                    (should (equal header-line-format (list review-element breadcrumb))))
                  (dolist (label '("[Hide removed]" "[Show removed]"))
                    (let* ((header (diff-review--file-header))
                           (position (string-search label header))
                           (map (get-text-property position 'local-map header))
                           (keys (vector 'header-line
                                         `(mouse-1 (,target header-line (0 . 0) 0)))))
                      (call-interactively (lookup-key map [header-line mouse-1]) nil keys)
                      (should (eq (and (seq-some
                                        (lambda (overlay)
                                          (string-search "old" (or (overlay-get overlay 'before-string) "")))
                                        diff-review--overlays)
                                       t)
                                  (equal label "[Show removed]")))))))
              (with-selected-window target
                (cl-letf (((symbol-function 'diff-review--read-body) (lambda (&rest _) "Please revise")))
                  (call-interactively (key-binding (kbd "C-c _ c"))))
                (should (diff-review--thread-overlays))
                (cl-letf (((symbol-function 'diff-review--read-body) (lambda (&rest _) "Reply")))
                  (call-interactively (key-binding (kbd "C-c _ r"))))
                (call-interactively (key-binding (kbd "C-c _ x")))
                (let ((review diff-review--review))
                  (with-current-buffer review
                    (should (= (length diff-review--comments) 1))
                    (should (file-exists-p buffer-file-name)))))
              (treemacs-magit--diff-review-git "-c" "user.name=Test" "-c" "user.email=test@example.com"
                                         "commit" "-qm" "Change")
              (setf (treemacs-magit-node-revision root) (magit-rev-verify "HEAD"))
              (show 'committed "staged\n" "old")
              (setf (treemacs-magit-node-range root) "HEAD^...HEAD")
              (show 'committed "staged\n" "old")
              (delete-file file)
              (show 'unstaged "staged\n" "")
              (write-text "untracked\n")
              (treemacs-magit--diff-review-git "rm" "--cached" "sample.el")
              (show 'untracked "untracked\n" ""))))
      (dolist (buffer (buffer-list))
        (when (and (buffer-live-p buffer)
                   (with-current-buffer buffer
                (or (string-prefix-p directory default-directory)
                    (and buffer-file-name (string-prefix-p directory buffer-file-name))
                    (and (boundp 'diff-review--root) diff-review--root
                         (string-prefix-p directory diff-review--root)))))
          (kill-buffer buffer)))
      (mapc (lambda (buffer) (when (buffer-live-p buffer) (kill-buffer buffer))) buffers)
      (delete-directory directory t))))

(ert-deftest treemacs-magit-review-follows-file-without-focus-change ()
  (save-window-excursion
    (let ((tree (generate-new-buffer " *review-tree-test*"))
          (review (generate-new-buffer " *review-session-test*")))
      (unwind-protect
          (let ((source-window (selected-window))
                (tree-window (split-window-right))
                selected)
            (set-window-buffer tree-window tree)
            (with-current-buffer tree
              (setq-local treemacs-magit--repository "/tmp/")
              (insert (propertize "file" :node
                                  (treemacs-magit-node-create :path "/tmp/next.el")
                                  :path '(root next))))
            (with-current-buffer review
              (setq-local treemacs-magit--review-tree tree))
            (with-temp-buffer
              (setq-local diff-review-file-mode t
                          diff-review--review review
                          diff-review--file-path "next.el")
              (cl-letf (((symbol-function 'treemacs--find-custom-node)
                         (lambda (path) (setq selected path) nil)))
                (treemacs-magit--review-follow))
              (should (equal selected '(root next)))
              (should (eq (selected-window) source-window))))
        (kill-buffer tree)
        (kill-buffer review)))))

(ert-deftest treemacs-magit-review-marker-without-tint ()
  (with-temp-buffer
    (insert "first\nsecond\nthird\n")
    (let ((treemacs-magit--opening-review-tree (current-buffer))
          (diff-review-buffer-mode t)
          (diff-review-inline-removed nil)
          (diff-review--hunks (list (list :line 1 :count 3 :removed nil))))
      ;; Repeated decoration must replace all markers, including the first.
      (dotimes (_ 2)
        (diff-review--decorate)
        (let ((markers
               (seq-filter
                (lambda (o)
                  (let ((s (overlay-get o 'before-string)))
                    (and s (> (length s) 0)
                         (get-text-property 0 'display s))))
                diff-review--overlays)))
          (should (= (length markers) 3))
          (should (equal (sort (mapcar #'overlay-start markers) #'<) '(1 7 14)))
          (dolist (overlay markers)
            (should (= (overlay-start overlay) (overlay-end overlay)))
            (let ((display (get-text-property 0 'display
                                             (overlay-get overlay 'before-string))))
              (should (equal (car display) '(margin left-margin)))
              (should (equal (substring-no-properties (cadr display)) "+")))))
        (dolist (overlay diff-review--overlays)
          (should-not (overlay-get overlay 'face)))))
    (should (= left-margin-width 1))))

(ert-deftest treemacs-magit-review-reuses-file-across-reviews ()
  (let* ((directory (make-temp-file "tree-review-owner-" t))
         (default-directory (file-name-as-directory directory))
         (path (expand-file-name "sample.el"))
         (tree (generate-new-buffer " *review-owner-tree*"))
         (treemacs-magit--opening-review-tree tree)
         source base first second)
    (unwind-protect
        (save-window-excursion
          (treemacs-magit--diff-review-git "init" "-q")
          (with-temp-file path (insert "old\n"))
          (treemacs-magit--diff-review-git "add" ".")
          (treemacs-magit--diff-review-git "-c" "user.name=Test" "-c" "user.email=t@example.com"
                                     "commit" "-qm" "Base")
          (setq base (string-trim (treemacs-magit--diff-review-git "rev-parse" "HEAD")))
          (with-temp-file path (insert "new\n"))
          (treemacs-magit--diff-review-git "add" ".")
          (treemacs-magit--diff-review-git "-c" "user.name=Test" "-c" "user.email=t@example.com"
                                     "commit" "-qm" "Change")
          (setq first (string-trim (treemacs-magit--diff-review-git "rev-parse" "HEAD")))
          (diff-review-open-file (expand-file-name ".git/first.json") "sample.el"
                                 default-directory base first "range")
          (set-buffer (window-buffer))
          (setq source (current-buffer))
          (should (equal buffer-file-name path))
          (should-not buffer-read-only)
          ;; Model an active language client: the file's major mode and local
          ;; state must survive transferring review ownership.
          (setq-local treemacs-magit-test-client 'connected)
          (setq default-directory (file-name-as-directory directory))
          (treemacs-magit--diff-review-git "-c" "user.name=Test" "-c" "user.email=t@example.com"
                                     "commit" "--allow-empty" "-qm" "New tip")
          (setq second (string-trim (treemacs-magit--diff-review-git "rev-parse" "HEAD")))
          (let ((fixed (symbol-function 'treemacs-magit--review-head-buffer))
                reproduced)
            (cl-letf (((symbol-function 'treemacs-magit--review-head-buffer)
                       (lambda (original file)
                         ;; Same clean disk file, same checked-out tip: the
                         ;; original still rejects the older review's owner.
                         (let ((baseline (funcall original file)))
                           (should-not (buffer-file-name baseline))
                           (should (buffer-local-value 'buffer-read-only baseline))
                           (setq reproduced t))
                         (funcall fixed original file))))
              (diff-review-open-file (expand-file-name ".git/second.json") "sample.el"
                                     default-directory base second "range"))
            (should reproduced))
          (set-buffer (window-buffer))
          (should (eq source (current-buffer)))
          (should-not buffer-read-only)
          (should (eq treemacs-magit-test-client 'connected))
          (should diff-review-file-mode)
          (should (equal (buffer-local-value 'diff-review--head diff-review--review) second))
          (let ((review diff-review--review))
            ;; An older commit with identical file contents also uses the file.
            (with-current-buffer review
              (let ((diff-review--tip first))
                (should (eq source (diff-review--head-buffer
                                    (list :path "sample.el"))))))
            ;; Unsaved and disk mismatches must retain the historical fallback.
            (goto-char (point-max))
            (insert "unsaved\n")
            (with-current-buffer review
              (should (eq :fallback
                          (treemacs-magit--review-head-buffer
                           (lambda (_) :fallback) (list :path "sample.el")))))
            (set-buffer-modified-p nil)
            (erase-buffer)
            (insert "new\n")
            (set-buffer-modified-p nil)
            (with-temp-file path (insert "disk differs\n"))
            (with-current-buffer review
              (should (eq :fallback
                          (treemacs-magit--review-head-buffer
                           (lambda (_) :fallback) (list :path "sample.el")))))
            (let ((snapshot (with-current-buffer review
                              (let ((buffer (diff-review--blob-for
                                             (list :path "sample.el" :hash second))))
                                (diff-review--enter buffer "sample.el")
                                buffer)))
                  (json (buffer-file-name review)))
              ;; q must close both old sessions and revision buffers, while
              ;; retaining the editable source, its local state, and comments.
              (set-visited-file-modtime)
              (goto-char (point-max))
              (insert "keep unsaved\n")
              (switch-to-buffer tree)
              (use-local-map (make-sparse-keymap))
              (treemacs-magit--bind-buffer-keys)
              (call-interactively (key-binding (kbd "q")))
              (should-not (buffer-live-p tree))
              (should-not (buffer-live-p review))
              (should-not (buffer-live-p snapshot))
              (should (file-exists-p json))
              (should (buffer-live-p source))
              (with-current-buffer source
                (should (buffer-modified-p))
                (should (string-suffix-p "keep unsaved\n" (buffer-string)))
                (should (eq treemacs-magit-test-client 'connected))
                (should-not diff-review-file-mode)
                (should-not diff-review--review)
                (should-not diff-review--overlays)
                ;; Outside review mode, compare disk to HEAD without saving
                ;; the unsaved source or reactivating review mode.
                (save-window-excursion
                  (with-current-buffer (treemacs-magit-difftastic-file)
                    (should buffer-read-only)
                    (should (equal magit-buffer-diff-range "HEAD"))
                    (should (equal magit-buffer-diff-files '("sample.el")))))
                (should (buffer-modified-p))
                (should (string-suffix-p "keep unsaved\n" (buffer-string)))
                (should (equal (with-temp-buffer
                                 (insert-file-contents path)
                                 (buffer-string))
                               "disk differs\n"))))))
      (dolist (buffer (buffer-list))
        (when (and (buffer-live-p buffer)
                   (with-current-buffer buffer
                (or (string-prefix-p directory default-directory)
                    (and buffer-file-name (string-prefix-p directory buffer-file-name))
                    (and (boundp 'diff-review--root) diff-review--root
                         (string-prefix-p directory diff-review--root)))))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (when (buffer-live-p tree) (kill-buffer tree))
      (delete-directory directory t))))

(ert-deftest treemacs-magit-review-close-respects-tree-and-comparison ()
  (let ((tree (generate-new-buffer " *review-close-tree*"))
        (old (generate-new-buffer " *review-close-old*"))
        (keep (generate-new-buffer " *review-close-keep*"))
        (other (generate-new-buffer " *review-close-other*")))
    (unwind-protect
        (progn
          (dolist (review (list old keep))
            (with-current-buffer review
              (setq treemacs-magit--review-tree tree)))
          (with-current-buffer keep (setq buffer-file-name "/tmp/keep-review.json"))
          (with-current-buffer other (setq treemacs-magit--review-tree other))
          (cl-letf (((symbol-function 'diff-review-quit)
                     (lambda () (kill-buffer (current-buffer)))))
            (with-current-buffer tree
              (treemacs-magit--review-close "/tmp/keep-review.json"))
            (should-not (buffer-live-p old))
            (should (buffer-live-p keep))
            (should (buffer-live-p other))
            (treemacs-magit--review-before-tree-display tree)
            (should-not (buffer-live-p keep))
            (should (buffer-live-p other))))
      (dolist (buffer (list tree old keep other))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'treemacs-magit-diff-review-test)
;;; treemacs-magit-diff-review-test.el ends here
