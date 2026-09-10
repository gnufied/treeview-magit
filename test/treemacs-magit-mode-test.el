;;; treemacs-magit-mode-test.el --- Tests for treemacs-magit-mode -*- lexical-binding: t; -*-

(require 'ert)
(require 'treemacs-magit-mode)

(ert-deftest treemacs-magit-test-status-kind ()
  (dolist (case `((,(list nil nil ?? ??) untracked)
                  (,(list nil nil ?\s ?M) unstaged)
                  (,(list nil nil ?M ?\s) staged)
                  (,(list nil nil ?M ?M) both)
                  (,(list nil nil ?\s ?\s) changed)))
    (should (eq (treemacs-magit--status-kind (car case)) (cadr case)))))

(ert-deftest treemacs-magit-test-insert-file-builds-shared-tree ()
  (let ((root (treemacs-magit-node-create
               :name "repo" :key "/repo/" :path "/repo/"
               :root t :repository "/repo/")))
    (treemacs-magit--insert-file root "src/a.go" 'staged)
    (treemacs-magit--insert-file root "src/b.go" 'unstaged)
    (let* ((src (car (treemacs-magit-node-children root)))
           (files (treemacs-magit-node-children src)))
      (should (equal (treemacs-magit-node-name src) "src"))
      (should (equal (mapcar #'treemacs-magit-node-name files)
                     '("a.go" "b.go")))
      (should (equal (mapcar #'treemacs-magit-node-status files)
                     '(staged unstaged)))
      (should (equal (treemacs-magit-node-path (car files))
                     "/repo/src/a.go")))))

(ert-deftest treemacs-magit-test-fold-node-honors-depth ()
  (let ((treemacs-magit-fold-min-depth 2)
        (root (treemacs-magit-node-create
               :name "repo" :key "/repo/" :path "/repo/"
               :root t :repository "/repo/")))
    (treemacs-magit--insert-file root "a/b/c/file.go" 'committed)
    (treemacs-magit--fold-node root 0)
    (let ((directory (car (treemacs-magit-node-children root))))
      (should (equal (treemacs-magit-node-name directory) "a/b/c"))
      (should (equal (treemacs-magit-node-name
                      (car (treemacs-magit-node-children directory)))
                     "file.go")))))

(ert-deftest treemacs-magit-test-collapsed-directories-are-normalized ()
  (let ((treemacs-magit-pr-collapsed-directories
         '("./vendor/" "vendor" "third_party/generated/")))
    (should (equal (treemacs-magit--normalized-collapsed-directories)
                   '("vendor" "third_party/generated"))))
  (dolist (directory '("/vendor" "../vendor" "vendor/../generated"))
    (let ((treemacs-magit-pr-collapsed-directories (list directory)))
      (should-error (treemacs-magit--normalized-collapsed-directories)
                    :type 'user-error))))

(ert-deftest treemacs-magit-test-pr-and-branch-roots ()
  (let ((treemacs-magit-pr-collapsed-directories '("vendor")))
    (cl-letf (((symbol-function 'treemacs-magit--range-files)
               (lambda (_range) '("vendor/a.go" "src/main.go"))))
      (let* ((pr-root (treemacs-magit--pr-root
                       "/repo/" "base...head" "head" 17))
             (vendor (car (treemacs-magit-node-children pr-root)))
             (file (treemacs-magit--first-file-node pr-root)))
        (should (equal (treemacs-magit-node-name pr-root) "repo (PR #17)"))
        (should (treemacs-magit-node-collapsed vendor))
        (should-not (treemacs-magit-node-children vendor))
        (should (equal (treemacs-magit-node-key file) "src/main.go")))
      (let* ((branch-root (treemacs-magit--branch-root
                           "/repo/" "base...head" "head"
                           "feature vs main"))
             (vendor (car (treemacs-magit-node-children branch-root))))
        (should (equal (treemacs-magit-node-name branch-root)
                       "repo (feature vs main)"))
        (should-not (treemacs-magit-node-collapsed vendor))
        (should (treemacs-magit-node-children vendor))))))

(ert-deftest treemacs-magit-test-commit-root ()
  (cl-letf (((symbol-function 'treemacs-magit--commit-files)
             (lambda (_revision) '("src/main.go" "README.md"))))
    (let* ((root (treemacs-magit--commit-root
                  "/repo/" "1234567890abcdef"))
           (first (treemacs-magit--first-file-node root)))
      (should (equal (treemacs-magit-node-name root)
                     "repo (12345678)"))
      (should (equal (treemacs-magit-node-revision root)
                     "1234567890abcdef"))
      (should (eq (treemacs-magit-node-status first) 'committed)))))

(ert-deftest treemacs-magit-test-visit-diff-dispatch ()
  (let ((data (treemacs-magit-node-create
               :name "file.go" :key "file.go" :path "/repo/file.go"
               :repository "/repo/")))
    (cl-labels
        ((check (status root expected)
           (setf (treemacs-magit-node-status data) status)
           (let (called)
             (cl-letf (((symbol-function 'treemacs-magit--run-in-target)
                        (lambda (&rest arguments) (setq called arguments))))
               (treemacs-magit--visit-diff data root "file.go" status))
             (should (equal called expected)))))
      (check 'committed
             (treemacs-magit-node-create :range "base...head")
             '(magit-diff-range "base...head" nil ("file.go")))
      (check 'committed
             (treemacs-magit-node-create :revision "commit")
             '(magit-show-commit "commit" nil ("file.go")))
      (check 'staged nil '(magit-diff-staged nil nil ("file.go")))
      (check 'unstaged nil '(magit-diff-unstaged nil ("file.go")))
      (check 'both nil '(magit-diff-working-tree nil nil ("file.go")))
      (check 'untracked nil '(magit-diff-paths "/dev/null" "/repo/file.go")))))

(ert-deftest treemacs-magit-test-visit-file-node-dispatch ()
  (let ((existing (treemacs-magit-node-create
                   :path "/tmp" :repository "/"))
        (missing (treemacs-magit-node-create
                  :path "/treemacs-magit-missing-file" :repository "/"))
        called)
    (cl-letf (((symbol-function 'treemacs-magit--run-in-file-target)
               (lambda (&rest arguments) (setq called arguments))))
      (treemacs-magit--visit-file-node
       existing (treemacs-magit-node-create
             :range "base...head" :revision "head")
       "tmp" 'committed))
    (should (equal called '(find-file "/tmp")))
    (cl-letf (((symbol-function 'treemacs-magit--run-in-file-target)
               (lambda (&rest arguments) (setq called arguments))))
      (treemacs-magit--visit-file-node
       missing (treemacs-magit-node-create
             :range "base...head" :revision "head")
       "treemacs-magit-missing-file" 'committed))
    (should (equal called
                   '(magit-find-file "head" "treemacs-magit-missing-file")))
    (cl-letf (((symbol-function 'treemacs-magit--run-in-file-target)
               (lambda (&rest arguments) (setq called arguments))))
      (treemacs-magit--visit-file-node existing nil "tmp" 'unstaged))
    (should (equal called '(find-file "/tmp")))))

(ert-deftest treemacs-magit-test-branch-command-builds-three-dot-range ()
  (let (display-arguments)
    (cl-letf (((symbol-function 'magit-toplevel) (lambda () "/repo/"))
              ((symbol-function 'magit-rev-verify)
               (lambda (revision)
                 (pcase revision
                   ("HEAD" "head-oid")
                   ("main" "base-oid"))))
              ((symbol-function 'magit-get-current-branch)
               (lambda () "feature"))
              ((symbol-function 'treemacs-magit--display-range)
               (lambda (&rest arguments)
                 (setq display-arguments arguments))))
      (treemacs-magit-branch "main"))
    (should (equal display-arguments
                   '("/repo/" "head-oid" "base-oid...head-oid"
                     nil "feature vs main")))))

(ert-deftest treemacs-magit-test-branch-command-rejects-missing-branch ()
  (cl-letf (((symbol-function 'magit-toplevel) (lambda () "/tmp/"))
            ((symbol-function 'magit-rev-verify)
             (lambda (revision) (and (equal revision "HEAD") "head-oid"))))
    (should-error (treemacs-magit-branch "missing") :type 'user-error)))

(ert-deftest treemacs-magit-test-pr-command-keeps-range-flow ()
  (let (checkout-arguments display-arguments)
    (cl-letf (((symbol-function 'magit-toplevel) (lambda () "/repo/"))
              ((symbol-function 'treemacs-magit--pr-metadata)
               (lambda (_pull-request)
                 '((number . 17)
                   (baseRefOid . "base-oid")
                   (headRefName . "feature")
                   (headRefOid . "head-oid"))))
              ((symbol-function 'treemacs-magit--checkout-pr)
               (lambda (&rest arguments) (setq checkout-arguments arguments)))
              ((symbol-function 'magit-rev-verify) #'identity)
              ((symbol-function 'treemacs-magit--display-range)
               (lambda (&rest arguments)
                 (setq display-arguments arguments))))
      (treemacs-magit-pr 17))
    (should (equal (car checkout-arguments) 17))
    (should (equal display-arguments
                   '("/repo/" "head-oid" "base-oid...head-oid" 17)))))

(ert-deftest treemacs-magit-test-pr-checkout-guards-worktree ()
  (let ((metadata '((headRefOid . "head-oid")))
        process-called)
    (cl-letf (((symbol-function 'magit-rev-parse) (lambda (_rev) "head-oid"))
              ((symbol-function 'treemacs-magit--process-string)
               (lambda (&rest _) (setq process-called t))))
      (treemacs-magit--checkout-pr 17 metadata))
    (should-not process-called)
    (cl-letf (((symbol-function 'magit-rev-parse) (lambda (_rev) "old-oid"))
              ((symbol-function 'magit-git-items)
               (lambda (&rest _) '("dirty")))
              ((symbol-function 'treemacs-magit--process-string)
               (lambda (&rest _) (setq process-called t))))
      (should-error (treemacs-magit--checkout-pr 17 metadata)
                    :type 'user-error))
    (should-not process-called)))

(ert-deftest treemacs-magit-test-main-command-empty-tree-selects-root ()
  (let ((treemacs-magit--contexts nil)
        (treemacs-magit-min-content-window-width 1000)
        buffer)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (cl-letf (((symbol-function 'treemacs-magit--current-context)
                     (lambda () (cons "/repo/" nil)))
                    ((symbol-function 'treemacs-magit--dirty-root)
                     (lambda (repository)
                       (treemacs-magit-node-create
                        :name "repo" :key repository :path repository
                        :root t :repository repository))))
            (treemacs-magit))
          (setq buffer (get-buffer treemacs-magit--buffer-name))
          (with-current-buffer buffer
            (let* ((button (treemacs-current-button))
                   (node (and button (treemacs-button-get button :node))))
              (should (treemacs-magit-node-root node))
              (should-not treemacs-magit--revision)
              (should-not treemacs-magit--range)))
          (kill-buffer buffer)
          (setq buffer nil)
          (should-not treemacs-magit--contexts))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest treemacs-magit-test-display-range-empty-tree-and-lifecycle ()
  (let ((treemacs-magit--contexts nil)
        (treemacs-magit-min-content-window-width 1000)
        (shared-map treemacs-mode-map)
        (shared-binding (lookup-key treemacs-mode-map [mouse-1]))
        buffer)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (cl-letf (((symbol-function 'treemacs-magit--range-files)
                     (lambda (_range) nil)))
            (treemacs-magit--display-range
             "/repo/" "head" "base...head" nil "feature vs main"))
          (setq buffer (get-buffer treemacs-magit--buffer-name))
          (should (buffer-live-p buffer))
          (with-current-buffer buffer
            (let* ((button (treemacs-current-button))
                   (node (and button (treemacs-button-get button :node))))
              (should (treemacs-magit-node-root node))
              (should (equal treemacs-magit--range "base...head"))
              (should (equal treemacs-magit--range-label "feature vs main"))
              (should-not (eq (current-local-map) shared-map))
              (should (eq (key-binding [mouse-1])
                          #'treemacs-magit--mouse-diff))))
          (should (eq (lookup-key shared-map [mouse-1]) shared-binding))
          (kill-buffer buffer)
          (setq buffer nil)
          (should-not treemacs-magit--contexts))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest treemacs-magit-test-display-replaces-dedicated-tree-window ()
  (let ((treemacs-magit-min-content-window-width 1000)
        (ordinary (generate-new-buffer " *ordinary-treemacs-test*"))
        (custom (generate-new-buffer treemacs-magit--buffer-name)))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((left (selected-window))
                 (right (split-window-right)))
            (set-window-buffer left ordinary)
            (set-window-dedicated-p left t)
            (select-window right)
            (treemacs-magit--display-buffer custom)
            (should (eq (window-buffer left) custom))
            (should (window-dedicated-p left))))
      (when (buffer-live-p custom)
        (kill-buffer custom))
      (when (buffer-live-p ordinary)
        (kill-buffer ordinary)))))

(provide 'treemacs-magit-mode-test)

;;; treemacs-magit-mode-test.el ends here
