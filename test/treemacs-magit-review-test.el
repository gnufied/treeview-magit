;;; treemacs-magit-review-test.el --- Review comment tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'treemacs-magit-review)
(require 'bookmark)

(defun treemacs-magit-review-test--git (&rest args)
  "Run Git ARGS in the disposable test checkout."
  (with-temp-buffer
    (unless (zerop (apply #'process-file "git" nil t nil args))
      (error "Test Git failed: %S: %s" args (buffer-string)))
    (string-trim (buffer-string))))

(defmacro treemacs-magit-review-test--repo (&rest body)
  "Run BODY in a disposable repository, cleaning up buffers and metadata."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (make-temp-file "review-test-" t)))
          (default-directory root))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer (current-buffer))
           (treemacs-magit-review-test--git "init" "-q" "-b" "review/a")
           (treemacs-magit-review-test--git "config" "user.name" "Review Test")
           (treemacs-magit-review-test--git "config" "user.email" "review@example.invalid")
           (treemacs-magit-review-test--git "config" "core.fsmonitor" "false")
           (with-temp-file "sample.txt" (insert "before\nalpha target\nafter\nlast\n"))
           (treemacs-magit-review-test--git "add" "sample.txt")
           (treemacs-magit-review-test--git "commit" "-qm" "Initial")
           ,@body)
       (dolist (buffer (buffer-list))
         (with-current-buffer buffer
           (when (or (and buffer-file-name (file-in-directory-p buffer-file-name root))
                     (and treemacs-magit--review-context
                          (equal root (treemacs-magit--review-context-root treemacs-magit--review-context)))
                     (and treemacs-magit--review-snapshot
                          (equal root (treemacs-magit--review-context-root
                                       (treemacs-magit--review-snapshot-context treemacs-magit--review-snapshot)))))
             (set-buffer-modified-p nil)
             (kill-buffer buffer))))
       (delete-directory root t))))

(defun treemacs-magit-review-test--comment (&optional body)
  "Capture a comment on the second line of sample.txt with BODY."
  (let ((context (treemacs-magit--review-context)))
    (with-current-buffer (find-file-noselect "sample.txt")
      (goto-char (point-min)) (forward-line 1)
      `((id . ,(treemacs-magit--review-id)) (body . ,(or body "Please check this.\nSecond paragraph."))
        (status . "open") (created_at . ,(treemacs-magit--review-now))
        (updated_at . ,(treemacs-magit--review-now))
        (anchor . ,(treemacs-magit--review-anchor context))))))

(defun treemacs-magit-review-test--save (snapshot comment)
  "Append COMMENT to SNAPSHOT, returning the saved snapshot."
  (treemacs-magit--review-write
   snapshot (lambda (data) (setf (alist-get 'comments data)
                                (vconcat (alist-get 'comments data) (vector comment))))))

(ert-deftest treemacs-magit-review-test-auto-enable-skips-git-metadata ()
  (treemacs-magit-review-test--repo
    (with-current-buffer (find-file-noselect "sample.txt")
      (treemacs-magit-review-mode 1))
    (dolist (name '("COMMIT_EDITMSG" "MERGE_MSG" "config" "sequencer/todo"))
      (let ((file (expand-file-name name (expand-file-name ".git" root))))
        (make-directory (file-name-directory file) t)
        (unless (file-exists-p file)
          (with-temp-file file (insert "# Git metadata\n")))
        (with-current-buffer (find-file-noselect file)
          (unwind-protect
              (should-not treemacs-magit-review-mode)
            ;; Magit protects commit buffers from ordinary kill-buffer calls.
            (remove-hook 'kill-buffer-query-functions
                         #'with-editor-kill-buffer-noop t)))))))

(ert-deftest treemacs-magit-review-test-auto-enable-source-files ()
  (treemacs-magit-review-test--repo
    (with-current-buffer (find-file-noselect "sample.txt")
      (treemacs-magit-review-mode 1))
    (dolist (name '("other.txt" ".gitignore"))
      (with-temp-file name (insert "source\n"))
      (with-current-buffer (find-file-noselect name)
        (should treemacs-magit-review-mode)
        (should (equal root (treemacs-magit--review-context-root
                             treemacs-magit--review-context)))))))

(ert-deftest treemacs-magit-review-test-storage-roundtrip-and-isolation ()
  (treemacs-magit-review-test--repo
    (let* ((context (treemacs-magit--review-context))
           (snapshot (treemacs-magit--review-read context))
           (comment (treemacs-magit-review-test--comment "Unicode: naïve ✎\nMultiline"))
           (bookmarks (copy-tree bookmark-alist))
           (saved (treemacs-magit-review-test--save snapshot comment)))
      (should-not (treemacs-magit--review-snapshot-data snapshot))
      (should (equal (treemacs-magit--review-snapshot-data saved)
                     (treemacs-magit--review-snapshot-data (treemacs-magit--review-read context))))
      (should (equal (alist-get 'body (aref (alist-get 'comments (treemacs-magit--review-snapshot-data saved)) 0))
                     "Unicode: naïve ✎\nMultiline"))
      (should (equal bookmarks bookmark-alist))
      (should (string-empty-p (treemacs-magit-review-test--git "status" "--porcelain")))
      (treemacs-magit-review-test--git "checkout" "-qb" "review/b")
      (should-not (treemacs-magit--review-snapshot-data
                   (treemacs-magit--review-read (treemacs-magit--review-context))))
      (treemacs-magit-review-test--git "checkout" "-q" "review/a")
      (should (equal (treemacs-magit--review-snapshot-data saved)
                     (treemacs-magit--review-snapshot-data
                      (treemacs-magit--review-read (treemacs-magit--review-context)))))
      (treemacs-magit-review-test--repo
        (should-not (treemacs-magit--review-snapshot-data
                     (treemacs-magit--review-read (treemacs-magit--review-context))))))))

(ert-deftest treemacs-magit-review-test-read-does-not-create-storage ()
  (treemacs-magit-review-test--repo
    (let ((context (treemacs-magit--review-context)))
      (treemacs-magit--review-read context)
      (should-not (file-exists-p (file-name-directory (treemacs-magit--review-context-file context)))))))

(ert-deftest treemacs-magit-review-test-lock-and-generation-conflicts ()
  (treemacs-magit-review-test--repo
    (let* ((context (treemacs-magit--review-context))
           (snapshot (treemacs-magit--review-read context))
           (comment (treemacs-magit-review-test--comment))
           (saved (treemacs-magit-review-test--save snapshot comment))
           (file (treemacs-magit--review-context-file context)))
      (should-error (treemacs-magit-review-test--save snapshot comment)
                    :type 'treemacs-magit-review-conflict)
      (should (equal (treemacs-magit--review-snapshot-digest saved)
                     (treemacs-magit--review-snapshot-digest (treemacs-magit--review-read context))))
      (make-directory (concat file ".lock"))
      (should-error (treemacs-magit-review-test--save saved comment) :type 'user-error)
      (should (file-directory-p (concat file ".lock")))
      (delete-directory (concat file ".lock"))
      (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "simulated write failure"))))
        (should-error (treemacs-magit--review-write saved #'identity)))
      (should-not (file-exists-p (concat file ".lock")))
      (should (equal (treemacs-magit--review-snapshot-digest saved)
                     (treemacs-magit--review-snapshot-digest (treemacs-magit--review-read context)))))))

(ert-deftest treemacs-magit-review-test-malformed-data-preserved ()
  (treemacs-magit-review-test--repo
    (let* ((context (treemacs-magit--review-context))
           (file (treemacs-magit--review-context-file context)))
      (make-directory (file-name-directory file) t)
      (dolist (contents '("{" "{\"schema_version\":999}"))
        (with-temp-file file (insert contents))
        (should-error (treemacs-magit--review-read context))
        (should (equal contents (with-temp-buffer (insert-file-contents file) (buffer-string)))))
      (dolist (path '("../outside" "/tmp/outside" "x/../../outside"))
        (should-error (treemacs-magit--review-path context path)))
      (make-symbolic-link "/tmp" "escape")
      (should-error (treemacs-magit--review-path context "escape/outside")))))

(ert-deftest treemacs-magit-review-test-relocation-and-ambiguity ()
  (treemacs-magit-review-test--repo
    (let ((anchor (alist-get 'anchor (treemacs-magit-review-test--comment))))
      (with-temp-buffer
        (insert-file-contents "sample.txt")
        (should (equal (treemacs-magit--review-resolve anchor) '(located 8 20)))
        (goto-char (point-min)) (insert "new header\n")
        (should (equal (treemacs-magit--review-resolve anchor) '(located 19 31)))
        (goto-char (point-max)) (insert-file-contents "sample.txt")
        (should (equal (treemacs-magit--review-resolve anchor) '(ambiguous)))
        (erase-buffer) (insert "different\n")
        (should (equal (treemacs-magit--review-resolve anchor) '(outdated)))))))

(ert-deftest treemacs-magit-review-test-live-markers-track-edits ()
  (treemacs-magit-review-test--repo
    (let ((comment (treemacs-magit-review-test--comment)))
      (with-current-buffer (find-file-noselect "sample.txt")
        (treemacs-magit-review-mode 1)
        (should (eq 'located (car (treemacs-magit--review-location comment))))
        (goto-char (point-min)) (insert "prefix\n")
        (should (= 15 (nth 1 (treemacs-magit--review-location comment))))
        (goto-char 17) (insert "changed")
        (should (equal '(outdated) (treemacs-magit--review-location comment)))
        (should-not treemacs-magit--review-locations)))))

(ert-deftest treemacs-magit-review-test-list-full-text-missing-files-and-branch-guard ()
  (treemacs-magit-review-test--repo
    (let* ((context (treemacs-magit--review-context))
           (comment (treemacs-magit-review-test--comment))
           (saved (treemacs-magit-review-test--save (treemacs-magit--review-read context) comment)))
      (delete-file "sample.txt")
      (with-temp-buffer
        (treemacs-magit-review-list-mode)
        (treemacs-magit--review-refresh-list context saved)
        (should (string-match-p "Second paragraph" (buffer-string)))
        (should (string-match-p "missing-file" (buffer-string)))
        (should (equal (treemacs-magit--review-list-current) comment))
        (with-temp-file "sample.txt" (insert "before\nalpha target\nafter\nlast\n"))
        (treemacs-magit-review-test--git "checkout" "-qb" "review/b")
        (should-error (treemacs-magit--review-list-current) :type 'user-error)
        (should (string-match-p "No review comments for this branch" (buffer-string)))
        (should (string-match-p "refs/heads/review/b" (buffer-string)))))))

(ert-deftest treemacs-magit-review-test-list-navigation ()
  (treemacs-magit-review-test--repo
    (let* ((context (treemacs-magit--review-context))
           (a (treemacs-magit-review-test--comment "A\nMultiline A"))
           (b (treemacs-magit-review-test--comment "B\nMultiline B"))
           (saved (treemacs-magit-review-test--save
                   (treemacs-magit-review-test--save (treemacs-magit--review-read context) a) b)))
      (with-temp-buffer
        (treemacs-magit-review-list-mode)
        (treemacs-magit--review-refresh-list context saved)
        (let ((first (alist-get 'id (treemacs-magit--review-list-current))))
          (treemacs-magit--review-list-next)
          (should-not (equal first (alist-get 'id (treemacs-magit--review-list-current))))
          (treemacs-magit--review-list-previous)
          (should (equal first (alist-get 'id (treemacs-magit--review-list-current)))))))))

(ert-deftest treemacs-magit-review-test-editor-pins-original-branch ()
  (treemacs-magit-review-test--repo
    (save-window-excursion
      (let* ((context (treemacs-magit--review-context))
             (comment (treemacs-magit-review-test--comment ""))
             (editor (treemacs-magit--review-edit (treemacs-magit--review-read context) comment)))
        (treemacs-magit-review-test--git "checkout" "-qb" "review/b")
        (with-current-buffer editor
          (insert "Saved to A, not B")
          (treemacs-magit--review-save-editor))
        (should (= 1 (length (alist-get 'comments (treemacs-magit--review-snapshot-data
                                                  (treemacs-magit--review-read context))))))
        (should-not (treemacs-magit--review-snapshot-data
                     (treemacs-magit--review-read (treemacs-magit--review-context))))))))

(ert-deftest treemacs-magit-review-test-editor-conflict-retains-draft ()
  (treemacs-magit-review-test--repo
    (save-window-excursion
      (let* ((context (treemacs-magit--review-context))
             (snapshot (treemacs-magit--review-read context))
             (a (treemacs-magit-review-test--comment "A"))
             (editor (treemacs-magit--review-edit snapshot a)))
        (treemacs-magit-review-test--save snapshot (treemacs-magit-review-test--comment "B"))
        (with-current-buffer editor
          (erase-buffer) (insert "Draft survives")
          (should-error (treemacs-magit--review-save-editor) :type 'treemacs-magit-review-conflict)
          (should (buffer-modified-p))
          (should (equal (buffer-string) "Draft survives")))))))

(ert-deftest treemacs-magit-review-test-source-suspends-after-external-checkout ()
  (treemacs-magit-review-test--repo
    (with-current-buffer (find-file-noselect "sample.txt")
      (treemacs-magit-review-mode 1)
      (goto-char (point-max)) (insert "unsaved old-branch edit\n")
      (treemacs-magit-review-test--git "checkout" "-qb" "review/b")
      (treemacs-magit--review-refresh-all)
      (should treemacs-magit--review-suspended)
      (should-not treemacs-magit--review-overlays)
      (should-error (treemacs-magit-review-comment) :type 'user-error)
      (revert-buffer t t)
      (should treemacs-magit--review-suspended)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (should (treemacs-magit--review-source-ready (treemacs-magit--review-context) t))))))

(ert-deftest treemacs-magit-review-test-stale-clean-buffer-blocks-capture ()
  (treemacs-magit-review-test--repo
    (with-current-buffer (find-file-noselect "sample.txt")
      (treemacs-magit-review-mode 1)
      (with-temp-file "sample.txt" (insert "different on disk\n"))
      (clear-visited-file-modtime)
      (set-visited-file-modtime '(0 0 0 0))
      (should-error (treemacs-magit-review-comment) :type 'user-error))))

(ert-deftest treemacs-magit-review-test-linked-worktree-and-detached-identity ()
  (treemacs-magit-review-test--repo
    (let* ((context (treemacs-magit--review-context))
           (worktree (expand-file-name "linked" root)))
      (treemacs-magit-review-test--git "worktree" "add" "-qb" "review/b" worktree)
      (let ((other (treemacs-magit--review-context worktree)))
        (should (equal (treemacs-magit--review-context-repository context)
                       (treemacs-magit--review-context-repository other)))
        (should-not (equal (treemacs-magit--review-context-gitdir context)
                           (treemacs-magit--review-context-gitdir other)))
        (should-not (equal (treemacs-magit--review-context-file context)
                           (treemacs-magit--review-context-file other))))
      (treemacs-magit-review-test--git "checkout" "--detach" "-q")
      (should (string-prefix-p "detached:" (treemacs-magit--review-context-scope
                                             (treemacs-magit--review-context)))))))

(ert-deftest treemacs-magit-review-test-unborn-and-rebase-guard ()
  (treemacs-magit-review-test--repo
    (treemacs-magit-review-test--git "checkout" "--orphan" "unborn")
    (let ((context (treemacs-magit--review-context)))
      (should-not (treemacs-magit--review-context-head context))
      (should (equal "refs/heads/unborn" (treemacs-magit--review-context-scope context)))
      (make-directory (expand-file-name "rebase-merge" (treemacs-magit--review-context-gitdir context)))
      (with-current-buffer (find-file-noselect "sample.txt")
        (should-error (treemacs-magit-review-comment) :type 'user-error)))))

(ert-deftest treemacs-magit-review-test-margin-coexistence-and-restoration ()
  (treemacs-magit-review-test--repo
    (let* ((comment (treemacs-magit-review-test--comment))
           (context (treemacs-magit--review-context))
           (saved (treemacs-magit-review-test--save (treemacs-magit--review-read context) comment)))
      (with-current-buffer (find-file-noselect "sample.txt")
        (setq-local left-margin-width 3)
        (let ((bookmark (make-overlay 8 9))
              (treemacs-magit-review-margin-use-ascii-marker t))
          (overlay-put bookmark 'before-string (propertize " " 'display '((margin left-margin) ">")))
          (treemacs-magit-review-mode 1)
          (treemacs-magit--review-render saved)
          (should (= 3 left-margin-width))
          (should (= 1 (length treemacs-magit--review-overlays)))
          (should (equal "!" (cadr (get-text-property 0 'display
                                      (overlay-get (car treemacs-magit--review-overlays) 'before-string)))))
          (should (overlay-buffer bookmark))
          (treemacs-magit-review-mode -1)
          (should (= 3 left-margin-width))
          (should (overlay-buffer bookmark))
          (delete-overlay bookmark))))))

(ert-deftest treemacs-magit-review-test-public-region-workflow ()
  (treemacs-magit-review-test--repo
    (save-window-excursion
      (let ((transient-mark-mode t)
            (source (find-file-noselect "sample.txt")))
        (switch-to-buffer source)
        (goto-char 8) (push-mark 13 t t)
        (call-interactively #'treemacs-magit-review-comment)
        (should (derived-mode-p 'treemacs-magit-review-edit-mode))
        (should (equal "alpha" (alist-get 'text (alist-get 'anchor treemacs-magit--review-comment))))
        (insert "First line\nSecond line")
        (execute-kbd-macro (kbd "C-c C-c"))
        (switch-to-buffer source)
        (call-interactively #'treemacs-magit-review-list)
        (should (derived-mode-p 'treemacs-magit-review-list-mode))
        (should (string-match-p "First line\n    Second line" (buffer-string)))
        (should (equal "review/a" (string-remove-prefix "refs/heads/"
                                    (treemacs-magit--review-context-scope treemacs-magit--review-context))))
        (call-interactively #'treemacs-magit--review-list-visit)
        (should (eq source (current-buffer)))
        (should (= 8 (point)))
        (treemacs-magit-review-list)
        (treemacs-magit-review-test--git "checkout" "-qb" "review/b")
        (treemacs-magit--review-refresh-all)
        (should (string-match-p "No review comments for this branch" (buffer-string)))
        (treemacs-magit-review-test--git "checkout" "-q" "review/a")
        (treemacs-magit--review-refresh-all)
        (should (string-match-p "First line" (buffer-string)))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (treemacs-magit--review-list-delete))
        (should (string-match-p "No review comments for this branch" (buffer-string)))
        (should-not (buffer-modified-p source))))))

(ert-deftest treemacs-magit-review-test-fresh-emacs-reloads-project-list ()
  (treemacs-magit-review-test--repo
    (treemacs-magit-review-test--save
     (treemacs-magit--review-read (treemacs-magit--review-context))
     (treemacs-magit-review-test--comment "Survives an Emacs restart"))
    (let ((program (expand-file-name invocation-name invocation-directory))
          (form `(progn
                   (setq load-path ',load-path default-directory ,root)
                   (require 'treemacs-magit-review)
                   (treemacs-magit-review-list)
                   (princ (buffer-string)))))
      (with-temp-buffer
        (should (zerop (process-file program nil t nil "--batch" "-Q"
                                     "--eval" (prin1-to-string form))))
        (should (string-match-p "Survives an Emacs restart" (buffer-string)))
        (should (string-match-p "refs/heads/review/a" (buffer-string)))))))

(ert-deftest treemacs-magit-review-test-load-preserves-global-bindings ()
  (let ((program (expand-file-name invocation-name invocation-directory))
        (form `(progn
                 (setq load-path ',load-path)
                 (let ((before (copy-keymap (current-global-map)))
                       (status-key (key-binding (kbd "C-x g"))))
                   (require 'treemacs-magit-review)
                   (unless (and (equal before (current-global-map))
                                (equal status-key (key-binding (kbd "C-x g")))
                                (not (featurep 'magit))
                                (not (assq 'treemacs-magit-review-mode minor-mode-map-alist)))
                     (error "Review load changed global bindings"))
                   (unless (eq (lookup-key treemacs-magit-review-edit-mode-map (kbd "C-c C-c"))
                               'treemacs-magit--review-save-editor)
                     (error "Editor-local binding missing")))
                 (require 'magit-mode)
                 (unless (and (memq 'magit-auto-revert-buffers magit-post-refresh-hook)
                              (memq 'treemacs-magit--review-refresh-all magit-post-refresh-hook))
                   (error "Deferred hook lost Magit defaults")))))
    (with-temp-buffer
      (let ((status (process-file program nil t nil "--batch" "-Q" "--eval" (prin1-to-string form))))
        (should (equal (cons status (buffer-string)) '(0 . "")))))))

(ert-deftest treemacs-magit-review-test-unsaved-source-capture-does-not-save-source ()
  (treemacs-magit-review-test--repo
    (save-window-excursion
      (switch-to-buffer (find-file-noselect "sample.txt"))
      (goto-char (point-max)) (insert "only in buffer")
      (let ((source (current-buffer)))
        (treemacs-magit-review-comment t)
        (should (eq t (alist-get 'unsaved (alist-get 'anchor treemacs-magit--review-comment))))
        (insert "Unsaved source review")
        (treemacs-magit--review-save-editor)
        (should (buffer-modified-p source))
        (should-not (with-temp-buffer (insert-file-contents "sample.txt")
                                      (string-match-p "only in buffer" (buffer-string))))))))

(ert-deftest treemacs-magit-review-test-conflict-reload-keeps-other-comments ()
  (treemacs-magit-review-test--repo
    (save-window-excursion
      (let* ((context (treemacs-magit--review-context))
             (snapshot (treemacs-magit--review-read context))
             (editor (treemacs-magit--review-edit snapshot (treemacs-magit-review-test--comment "draft A"))))
        (treemacs-magit-review-test--save snapshot (treemacs-magit-review-test--comment "saved B"))
        (with-current-buffer editor
          (should-error (treemacs-magit--review-save-editor) :type 'treemacs-magit-review-conflict)
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
            (treemacs-magit--review-reload-editor))
          (should (equal "draft A" (buffer-string)))
          (treemacs-magit--review-save-editor))
        (should (= 2 (length (alist-get 'comments
                                       (treemacs-magit--review-snapshot-data (treemacs-magit--review-read context))))))))))

(ert-deftest treemacs-magit-review-test-worktree-live-locations-are-independent ()
  (treemacs-magit-review-test--repo
    (let* ((context (treemacs-magit--review-context))
           (comment (treemacs-magit-review-test--comment))
           (worktree (expand-file-name "linked" root))
           (source (find-file-noselect "sample.txt")))
      (treemacs-magit-review-test--save (treemacs-magit--review-read context) comment)
      (treemacs-magit-review-test--git "worktree" "add" "--force" "-q" worktree "review/a")
      (let* ((other-context (treemacs-magit--review-context worktree))
             (other (find-file-noselect (expand-file-name "sample.txt" worktree))))
        (should (equal (treemacs-magit--review-context-file context)
                       (treemacs-magit--review-context-file other-context)))
        (with-current-buffer source
          (treemacs-magit-review-mode 1)
          (goto-char (point-min)) (insert "extra\n")
          (should (= 14 (nth 1 (treemacs-magit--review-location comment)))))
        (with-current-buffer other
          (treemacs-magit-review-mode 1)
          (should (= 8 (nth 1 (treemacs-magit--review-location comment)))))))))

(ert-deftest treemacs-magit-review-test-empty-line-edit-does-not-invert-markers ()
  (treemacs-magit-review-test--repo
    (with-current-buffer (find-file-noselect "sample.txt")
      (goto-char (point-min)) (forward-line 1) (insert "\n")
      (forward-line -1)
      (let ((comment (treemacs-magit-review-test--comment)))
        (setf (alist-get 'anchor comment) (treemacs-magit--review-anchor (treemacs-magit--review-context)))
        (treemacs-magit-review-mode 1)
        (should (eq 'located (car (treemacs-magit--review-location comment))))
        (insert "new code")
        (should (equal '(outdated) (treemacs-magit--review-location comment)))))))

(ert-deftest treemacs-magit-review-test-narrowed-source-location ()
  (treemacs-magit-review-test--repo
    (let ((comment (treemacs-magit-review-test--comment)))
      (with-current-buffer (find-file-noselect "sample.txt")
        (treemacs-magit--review-location comment)
        (narrow-to-region 1 7)
        (should (equal '(located 8 20) (treemacs-magit--review-location comment)))
        (should (= 7 (point-max)))))))

(ert-deftest treemacs-magit-review-test-rebase-keeps-original-scope ()
  (treemacs-magit-review-test--repo
    (let* ((original (treemacs-magit--review-context))
           (directory (expand-file-name "rebase-merge" (treemacs-magit--review-context-gitdir original))))
      (treemacs-magit-review-test--git "checkout" "--detach" "-q")
      (make-directory directory)
      (with-temp-file (expand-file-name "head-name" directory) (insert "refs/heads/review/a\n"))
      (should (equal (treemacs-magit--review-context-file original)
                     (treemacs-magit--review-context-file (treemacs-magit--review-context)))))))

(ert-deftest treemacs-magit-review-test-window-margins-preserve-other-changes ()
  (treemacs-magit-review-test--repo
    (save-window-excursion
      (switch-to-buffer (find-file-noselect "sample.txt"))
      (setq-local left-margin-width 3)
      (set-window-margins nil nil 2)
      (treemacs-magit--review-ensure-margins 1)
      (should (equal '(3 . 2) (window-margins)))
      (set-window-margins nil 3 4)
      (treemacs-magit--review-restore-margins)
      (should (equal '(nil . 4) (window-margins)))
      (should (= 3 left-margin-width)))))

(ert-deftest treemacs-magit-review-test-periodic-poll-skips-pending-input ()
  (let ((calls 0))
    (cl-letf (((symbol-function 'treemacs-magit--review-refresh-all) (lambda (&rest _) (cl-incf calls)))
              ((symbol-function 'active-minibuffer-window) (lambda () nil))
              ((symbol-function 'input-pending-p) (lambda () nil)))
      (treemacs-magit--review-idle-refresh)
      (treemacs-magit--review-idle-refresh)
      (should (= 2 calls)))
    (cl-letf (((symbol-function 'treemacs-magit--review-refresh-all) (lambda (&rest _) (cl-incf calls)))
              ((symbol-function 'input-pending-p) (lambda () t)))
      (treemacs-magit--review-idle-refresh)
      (should (= 2 calls)))))

(ert-deftest treemacs-magit-review-test-refresh-recovers-after-malformed-storage ()
  (treemacs-magit-review-test--repo
    (let* ((context (treemacs-magit--review-context))
           (file (treemacs-magit--review-context-file context))
           (comment (treemacs-magit-review-test--comment)))
      (treemacs-magit-review-test--save (treemacs-magit--review-read context) comment)
      (let ((contents (with-temp-buffer (insert-file-contents file) (buffer-string))))
        (with-current-buffer (find-file-noselect "sample.txt")
          (treemacs-magit-review-mode 1)
          (should (= 1 (length treemacs-magit--review-overlays)))
          (with-temp-file file (insert "{"))
          (treemacs-magit--review-refresh-all)
          (should treemacs-magit--review-error)
          (should-not treemacs-magit--review-overlays)
          (with-temp-file file (insert contents))
          (treemacs-magit--review-refresh-all)
          (should-not treemacs-magit--review-error)
          (should (= 1 (length treemacs-magit--review-overlays))))))))

(provide 'treemacs-magit-review-test)
;;; treemacs-magit-review-test.el ends here
