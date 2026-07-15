;;; treemacs-magit-mode.el --- Changed files as a Treemacs tree -*- lexical-binding: t -*-

;; Author: Hemant Kumar
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (magit "3.0.0") (treemacs "3.0"))
;; URL: https://github.com/gnufied/treeview-magit

;;; Commentary:
;;
;; Display the files changed in the current repository, or the files changed
;; by the commit at point in a Magit history/revision buffer.

;;; Code:

(require 'cl-lib)
(require 'magit)
(require 'seq)
(require 'subr-x)
(require 'treemacs)
(require 'treemacs-treelib)

(declare-function treemacs-define-doubleclick-action "treemacs-mouse-interface"
                  (state action))

(cl-defstruct (treemacs-magit-node
               (:constructor treemacs-magit-node-create))
  name key path children status root revision repository)

(defconst treemacs-magit--buffer-name "*Treemacs Magit*")

(defcustom treemacs-magit-fold-min-depth 3
  "Rendered tree depth beyond which directory chains are folded.

When files sit deeper than this many levels below the repository root,
directory nodes with a single directory child are merged with it and
rendered as one \"parent/child\" node, repeatedly, until the subtree
either fans out or fits within the limit.  Set to 0 to always fold, or
nil to disable folding."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'treemacs)

(defcustom treemacs-magit-status-icons
  '((unstaged . "󰏫")
    (staged . "󰄬")
    (both . "󰏫󰄬")
    (untracked . "󰈔"))
  "Nerd Font icons shown for changed files in a Magit status tree.

Each entry maps a status symbol to its indicator.  Remove an entry or
use an empty string to hide its indicator.  Commit and log views do not
display status icons."
  :type '(alist :key-type symbol :value-type string)
  :group 'treemacs)

(defcustom treemacs-magit-status-icon-position 'prefix
  "Where to display file status icons in a Magit status tree."
  :type '(choice (const :tag "Before file name" prefix)
                 (const :tag "After file name" suffix)
                 (const :tag "Hide icons" none))
  :group 'treemacs)

(defcustom treemacs-magit-status-icon-separator " "
  "Text between a file status icon and its name."
  :type 'string
  :group 'treemacs)

(defvar treemacs-magit--contexts nil)
(defvar-local treemacs-magit--repository nil)
(defvar-local treemacs-magit--revision nil)

(defun treemacs-magit--tree-window ()
  "Return the window displaying the Treemacs Magit buffer."
  (get-buffer-window treemacs-magit--buffer-name))

(defun treemacs-magit--target-window ()
  "Return the window to the right of the Treemacs Magit window."
  (let ((tree-window (treemacs-magit--tree-window)))
    (or (and tree-window
            (car (treemacs-magit--windows-to-right tree-window)))
        (and tree-window
            (next-window tree-window nil 'no-minibuffer))
        (user-error "No window available for the Magit view"))))

(defun treemacs-magit--windows-overlap-vertically-p (left-window right-window)
  "Return non-nil when LEFT-WINDOW and RIGHT-WINDOW share vertical space."
  (let ((left-edges (window-edges left-window))
        (right-edges (window-edges right-window)))
    (< (max (nth 1 left-edges) (nth 1 right-edges))
       (min (nth 3 left-edges) (nth 3 right-edges)))))

(defun treemacs-magit--windows-to-right (window)
  "Return windows directly or indirectly to the right of WINDOW.

The result is sorted from nearest to farthest.  Geometry is used instead of
`window-in-direction' so the diff target remains the immediate middle window
in a three-column layout."
  (let* ((edges (window-edges window))
        (right-edge (nth 2 edges))
        (windows (window-list (window-frame window) 'nomini)))
    (sort (cl-remove-if-not
          (lambda (candidate)
            (let ((candidate-edges (window-edges candidate)))
              (and (not (eq candidate window))
                   (>= (car candidate-edges) right-edge)
                   (treemacs-magit--windows-overlap-vertically-p
                    window candidate))))
          windows)
         (lambda (left right)
           (let ((left-edges (window-edges left))
                 (right-edges (window-edges right)))
             (or (< (car left-edges) (car right-edges))
                 (and (= (car left-edges) (car right-edges))
                      (< (nth 1 left-edges) (nth 1 right-edges)))))))))

(defun treemacs-magit--rightmost-window-from (window)
  "Return the rightmost window reachable from WINDOW."
  (car (last (cons window (treemacs-magit--windows-to-right window)))))

(defun treemacs-magit--file-target-window ()
  "Return the window where file contents should be displayed.

Use an already-existing third vertical split when present.  Otherwise reuse the
normal diff target window."
  (let* ((diff-window (treemacs-magit--target-window))
         (rightmost-window (treemacs-magit--rightmost-window-from diff-window)))
    (if (eq diff-window rightmost-window)
        diff-window
      rightmost-window)))

(defun treemacs-magit--run-in-window (window bury-current function &rest arguments)
  "Run FUNCTION with ARGUMENTS in WINDOW.

When BURY-CURRENT is non-nil, bury the buffer currently displayed in WINDOW
before running FUNCTION."
  (with-selected-window window
    (when bury-current
      (bury-buffer (window-buffer window)))
    (let ((display-buffer-overriding-action '(display-buffer-same-window)))
      (apply function arguments))))

(defun treemacs-magit--run-in-target (function &rest arguments)
  "Run FUNCTION with ARGUMENTS in the window beside the tree."
  (apply #'treemacs-magit--run-in-window
         (treemacs-magit--target-window) nil function arguments))

(defun treemacs-magit--run-in-file-target (function &rest arguments)
  "Run FUNCTION with ARGUMENTS in the file-content target window."
  (apply #'treemacs-magit--run-in-window
         (treemacs-magit--file-target-window) t function arguments))

(defun treemacs-magit--has-separate-file-target-p ()
  "Return non-nil when file contents can use a window separate from diffs."
  (not (eq (treemacs-magit--target-window)
           (treemacs-magit--file-target-window))))

(defun treemacs-magit--revision-at-point ()
  "Return the commit represented by the current Magit buffer, if any."
  (cond
   ((derived-mode-p 'magit-revision-mode)
    magit-buffer-revision)
   ((derived-mode-p 'magit-log-mode)
    (magit-commit-at-point))))

(defun treemacs-magit--current-context ()
  "Return the repository and revision for the current command invocation."
  (let ((tree-buffer-p (equal (buffer-name) treemacs-magit--buffer-name)))
    (cons (or (and tree-buffer-p treemacs-magit--repository)
              (magit-toplevel))
          (if tree-buffer-p
              treemacs-magit--revision
            (treemacs-magit--revision-at-point)))))

(defun treemacs-magit--status-kind (status)
  "Return a useful status symbol for Magit STATUS."
  (let ((x (nth 2 status))
        (y (nth 3 status)))
    (cond
     ((and (eq x ??) (eq y ??)) 'untracked)
     ((and (eq x ?\s) (not (eq y ?\s))) 'unstaged)
     ((and (not (eq x ?\s)) (eq y ?\s)) 'staged)
     ((and (not (eq x ?\s)) (not (eq y ?\s))) 'both)
     (t 'changed))))

(defun treemacs-magit--untracked-directory-files (directory)
  "Return untracked files under DIRECTORY."
  (magit-git-items "ls-files" "-z" "--others" "--exclude-standard"
                   "--" (file-name-as-directory directory)))

(defun treemacs-magit--insert-file (root file status)
  "Insert FILE with STATUS below ROOT, creating directory nodes as needed."
  (let ((parts (split-string file "/" t))
        (parent root)
        (relative ""))
    (dolist (part parts)
      (setq relative (if (string-empty-p relative)
                         part
                       (concat relative "/" part)))
      (let ((node (seq-find (lambda (child)
                              (equal (treemacs-magit-node-name child) part))
                            (treemacs-magit-node-children parent))))
        (unless node
          (setq node
                (treemacs-magit-node-create
                 :name part
                 :key relative
                 :path (expand-file-name relative
                                         (treemacs-magit-node-repository root))
                 :repository (treemacs-magit-node-repository root)
                 :children nil))
          (setf (treemacs-magit-node-children parent)
                (append (treemacs-magit-node-children parent) (list node))))
        (setf parent node)))
    (setf (treemacs-magit-node-status parent) status)))

(defun treemacs-magit--node-height (node)
  "Return the number of levels below NODE."
  (let ((children (treemacs-magit-node-children node)))
    (if children
        (1+ (apply #'max (mapcar #'treemacs-magit--node-height children)))
      0)))

(defun treemacs-magit--fold-node (node depth)
  "Fold single-child directory chains into NODE, rendered at DEPTH.

While the deepest leaf under NODE would render beyond
`treemacs-magit-fold-min-depth' and NODE's only child is another
directory, NODE absorbs that child and displays both names as
\"parent/child\".  Children are folded recursively at their rendered
depth, so each fold makes room for the levels below it."
  (when (treemacs-magit-node-children node)
    (when (and treemacs-magit-fold-min-depth
               (not (treemacs-magit-node-root node)))
      (let (child)
        (while (and (> (+ depth (treemacs-magit--node-height node))
                       treemacs-magit-fold-min-depth)
                    (null (cdr (treemacs-magit-node-children node)))
                    (setq child (car (treemacs-magit-node-children node)))
                    (treemacs-magit-node-children child))
          (setf (treemacs-magit-node-name node)
                (concat (treemacs-magit-node-name node) "/"
                        (treemacs-magit-node-name child))
                (treemacs-magit-node-key node) (treemacs-magit-node-key child)
                (treemacs-magit-node-path node) (treemacs-magit-node-path child)
                (treemacs-magit-node-children node)
                (treemacs-magit-node-children child)))))
    (dolist (child (treemacs-magit-node-children node))
      (treemacs-magit--fold-node child (1+ depth)))))

(defun treemacs-magit--dirty-root (repository)
  "Build a tree of all dirty files in REPOSITORY."
  (let ((root (treemacs-magit-node-create
               :name (file-name-nondirectory
                      (directory-file-name repository))
               :key repository
               :path repository
               :root t
               :repository repository)))
    (let ((default-directory repository))
      (dolist (status (magit-file-status))
        (let* ((file (car status))
               (kind (treemacs-magit--status-kind status))
               (path (expand-file-name file repository)))
          (if (and (eq kind 'untracked)
                   (file-directory-p path))
              (let ((files (treemacs-magit--untracked-directory-files file)))
                (if files
                    (dolist (untracked-file files)
                      (treemacs-magit--insert-file
                       root untracked-file 'untracked))
                  (treemacs-magit--insert-file root file kind)))
            (treemacs-magit--insert-file root file kind)))))
    (treemacs-magit--fold-node root 0)
    root))

(defun treemacs-magit--commit-files (revision)
  "Return files changed by REVISION."
  (magit-git-items "show" "-z" "--format=" "--name-only" revision))

(defun treemacs-magit--commit-root (repository revision)
  "Build a tree of files changed by REVISION in REPOSITORY."
  (let ((root (treemacs-magit-node-create
               :name (format "%s (%s)"
                             (file-name-nondirectory
                              (directory-file-name repository))
                             (substring revision 0 (min 8 (length revision))))
               :key repository
               :path repository
               :root t
               :revision revision
               :repository repository)))
    (let ((default-directory repository))
      (dolist (file (treemacs-magit--commit-files revision))
        (treemacs-magit--insert-file root file 'committed)))
    (treemacs-magit--fold-node root 0)
    root))

(defun treemacs-magit--roots ()
  "Return the root node for the current Magit context."
  (let* ((context (cdr (assq (current-buffer) treemacs-magit--contexts)))
         (repository (or (car context) treemacs-magit--repository
                         (magit-toplevel))))
    (unless repository
      (user-error "The current buffer is not in a Git repository"))
    (let ((revision (or (cdr context) treemacs-magit--revision)))
      (list (if revision
                (treemacs-magit--commit-root repository revision)
              (treemacs-magit--dirty-root repository))))))

(defun treemacs-magit--node-children (btn item)
  "Return children for ITEM, refreshing the dirty root when it is expanded."
  (ignore btn)
  (treemacs-magit-node-children item))

(defun treemacs-magit--node-face (node)
  "Return the face for NODE."
  (cond
   ((treemacs-magit-node-root node) 'treemacs-root-face)
   ((treemacs-magit-node-children node) 'treemacs-directory-face)
   ((eq (treemacs-magit-node-status node) 'untracked)
    'font-lock-warning-face)
   ((memq (treemacs-magit-node-status node) '(staged committed))
    'font-lock-constant-face)
   (t 'font-lock-keyword-face)))

(defun treemacs-magit--label (node)
  "Return the display label for NODE."
  (let* ((status (treemacs-magit-node-status node))
        (name (treemacs-magit-node-name node))
        (icon (and status
                   (not (treemacs-magit-node-children node))
                   (not (eq status 'committed))
                   (alist-get status treemacs-magit-status-icons))))
    (propertize
     (pcase treemacs-magit-status-icon-position
       ('prefix (if (string-empty-p (or icon ""))
                   name
                 (concat icon treemacs-magit-status-icon-separator name)))
       ('suffix (if (string-empty-p (or icon ""))
                   name
                 (concat name treemacs-magit-status-icon-separator icon)))
       (_ name))
     'face (treemacs-magit--node-face node))))

(defun treemacs-magit--visit-current (&optional view-file)
  "Open the node at point.

With VIEW-FILE, visit the file contents instead of displaying its diff."
  (let* ((node (treemacs-current-button))
         (data (and node (treemacs-button-get node :node)))
         (root (and node (treemacs-magit--root-for-button node))))
    (unless (treemacs-magit-node-p data)
      (user-error "No Treemacs Magit node at point"))
    (let ((default-directory (treemacs-magit-node-repository data)))
      (if (treemacs-magit-node-root data)
          (if (treemacs-magit-node-revision data)
              (treemacs-magit--run-in-target
               #'magit-show-commit (treemacs-magit-node-revision data))
            (treemacs-magit--run-in-target
             #'magit-status-setup-buffer
             (treemacs-magit-node-repository data)))
        (if (treemacs-magit-node-children data)
            (treemacs-toggle-node)
          (let ((file (file-relative-name
                       (treemacs-magit-node-path data)
                       (treemacs-magit-node-repository data)))
                (status (treemacs-magit-node-status data)))
            (when (or (not view-file)
                      (treemacs-magit--has-separate-file-target-p))
              (treemacs-magit--visit-diff data root file status))
            (when view-file
              (treemacs-magit--visit-file-node data root file status))))))))

(defun treemacs-magit--visit-diff (data root file status)
  "Display the diff for DATA with ROOT, FILE, and STATUS."
  (pcase status
    ('committed
     (treemacs-magit--run-in-target
      #'magit-show-commit
      (treemacs-magit-node-revision root)
      nil (list file)))
    ('staged
     (treemacs-magit--run-in-target
      #'magit-diff-staged nil nil (list file)))
    ('unstaged
     (treemacs-magit--run-in-target
      #'magit-diff-unstaged nil (list file)))
    ('both
     (treemacs-magit--run-in-target
      #'magit-diff-working-tree nil nil (list file)))
    ('untracked
     (treemacs-magit--run-in-target
      #'magit-diff-paths "/dev/null"
      (treemacs-magit-node-path data)))
    (_
     (treemacs-magit--run-in-target
      #'magit-diff-working-tree nil nil (list file)))))

(defun treemacs-magit--visit-file-node (data root file status)
  "Visit the file for DATA with ROOT, FILE, and STATUS."
  (if (eq status 'committed)
      (treemacs-magit--run-in-file-target
       #'magit-find-file
       (treemacs-magit-node-revision root) file)
    (treemacs-magit--run-in-file-target
     #'find-file (treemacs-magit-node-path data))))

;; The commit is stored on the root node.  Find it through the node's
;; Treemacs parent chain.
(defun treemacs-magit--root-for-button (button)
  "Return the root data object for BUTTON."
  (let ((parent button)
        result)
    (while parent
      (let ((node (treemacs-button-get parent :node)))
        (when (and (treemacs-magit-node-p node)
                   (treemacs-magit-node-root node))
          (setq result node
                parent nil))
        (when parent
          (setq parent (treemacs-button-get parent :parent)))))
    (and (treemacs-magit-node-p result) result)))

(defun treemacs-magit--mouse-action (event &optional view-file)
  "Visit the node at EVENT, optionally opening the file itself.

This handles both GUI and terminal mouse events, including modifier-bearing
events when the terminal reports them to Emacs."
  (interactive "e")
  (let* ((position (event-end event))
         (window (posn-window position))
         (point (posn-point position)))
    (when (and (windowp window) (integer-or-marker-p point))
      (with-selected-window window
        (goto-char point)
        (treemacs-magit--visit-current view-file)))))

(defun treemacs-magit--bind-buffer-keys ()
  "Bind default and alternate visit actions in the current tree buffer."
  (let ((map (current-local-map)))
    (define-key map (kbd "S-<return>") #'treemacs-magit--visit-file)
    (define-key map [S-return] #'treemacs-magit--visit-file)
    (define-key map [mouse-1] #'treemacs-magit--mouse-diff)
    (define-key map [C-mouse-1] #'treemacs-magit--mouse-file)
    (define-key map [C-down-mouse-1] #'treemacs-magit--mouse-file)
    (define-key map (kbd "s") #'treemacs-magit-stage-file-at-point)
    (define-key map (kbd "q") #'treemacs-magit-quit)))

(defun treemacs-magit-quit ()
  "Quit the Treemacs Magit view, delete its window, and kill its buffer."
  (interactive)
  (let ((buffer (current-buffer))
        (window (selected-window)))
    (when (and (window-live-p window)
               (not (one-window-p t (window-frame window))))
      (delete-window window))
    (kill-buffer buffer)))

(defun treemacs-magit--leftmost-window ()
  "Return the leftmost non-minibuffer window."
  (car (sort (window-list nil 'nomini)
             (lambda (left right)
               (< (window-left-column left)
                  (window-left-column right))))))

(defun treemacs-magit--display-buffer (buffer)
  "Display BUFFER in the left tree pane, creating it when necessary."
  (let ((tree-window (get-buffer-window buffer))
        (windows (window-list nil 'nomini))
        replaced-buffer)
    (unless tree-window
      (setq tree-window
            (if (= (length windows) 1)
                (let* ((left-window (selected-window))
                       (width (window-total-width))
                       (tree-width (max window-min-width
                                        (floor (* width 0.2)))))
                  (split-window-right tree-width)
                  left-window)
              (let ((left-window (treemacs-magit--leftmost-window)))
                (setq replaced-buffer (window-buffer left-window))
                left-window))))
    (set-window-buffer tree-window buffer)
    (when (and replaced-buffer
               (buffer-live-p replaced-buffer)
               (not (eq replaced-buffer buffer)))
      (bury-buffer replaced-buffer))
    (set-window-dedicated-p tree-window nil)
    (set-window-parameter tree-window 'no-delete-other-windows nil)
    (set-window-parameter tree-window 'window-side nil)
    (set-window-parameter tree-window 'window-slot nil)
    (select-window tree-window)))

(defun treemacs-magit--visit-file ()
  "Visit the file represented by the node at point."
  (interactive)
  (treemacs-magit--visit-current t))

(defun treemacs-magit--mouse-diff (event)
  "Display the default diff for the node clicked by EVENT."
  (interactive "e")
  (treemacs-magit--mouse-action event nil))

(defun treemacs-magit--mouse-file (event)
  "Visit the file represented by the modified click EVENT."
  (interactive "e")
  (treemacs-magit--mouse-action event t))

(defun treemacs-magit-stage-file-at-point ()
  "Toggle staging for the file node at point."
  (interactive)
  (let* ((button (treemacs-current-button))
         (node (and button (treemacs-button-get button :node)))
         (root (and button (treemacs-magit--root-for-button button)))
         (path (and button (treemacs-button-get button :path))))
    (unless (and (treemacs-magit-node-p node)
                 (not (treemacs-magit-node-root node))
                 (not (treemacs-magit-node-children node)))
      (user-error "Point is not on a file node"))
    (when (or (treemacs-magit-node-revision root)
              (eq (treemacs-magit-node-status node) 'committed))
      (user-error "Cannot stage a file from a commit view"))
    (let ((default-directory (treemacs-magit-node-repository node))
          (file (file-relative-name
                 (treemacs-magit-node-path node)
                 (treemacs-magit-node-repository node)))
          (status (treemacs-magit-node-status node)))
      (pcase status
        ('staged
         (magit-unstage-files (list file)))
        ('untracked
         (user-error "Cannot stage an untracked file"))
        (_
         (magit-stage-files (list file)))))
    (treemacs-initialize treemacs-magit-root
      :with-expand-depth t)
    (treemacs-goto-extension-node path)))

(treemacs-define-expandable-node-type treemacs-magit-node
  :closed-icon (if (treemacs-magit-node-root item)
                   (treemacs-get-icon-value 'root-closed)
                 (if (treemacs-magit-node-children item)
                     (treemacs-get-icon-value 'dir-closed)
                   (treemacs-get-icon-value 'tag-leaf)))
  :open-icon (if (treemacs-magit-node-root item)
                 (treemacs-get-icon-value 'root-open)
               (if (treemacs-magit-node-children item)
                   (treemacs-get-icon-value 'dir-open)
                 (treemacs-get-icon-value 'tag-leaf)))
  :label (treemacs-magit--label item)
  :key (treemacs-magit-node-key item)
  :children (treemacs-magit--node-children btn item)
  :child-type 'treemacs-magit-node
  :more-properties `(:node ,item :path ,(treemacs-magit-node-path item))
  :ret-action #'treemacs-magit--visit-current
  :double-click-action #'treemacs-magit--visit-current)

(treemacs-define-variadic-entry-node-type treemacs-magit-root
  :key 'treemacs-magit
  :children (treemacs-magit--roots)
  :child-type 'treemacs-magit-node
  )

;;;###autoload
(defun treemacs-magit ()
  "Display changed files from Magit in a Treemacs side buffer."
  (interactive)
  (let* ((context (treemacs-magit--current-context))
         (repository (car context))
         (revision (cdr context)))
    (unless repository
      (user-error "The current buffer is not in a Git repository"))
    (let ((buffer (get-buffer-create treemacs-magit--buffer-name)))
      (treemacs-magit--display-buffer buffer)
      (setq-local treemacs-magit--repository repository
                  treemacs-magit--revision revision)
      (setq treemacs-magit--contexts
            (cons (cons buffer (cons repository revision))
                  (assq-delete-all buffer treemacs-magit--contexts)))
      (treemacs-initialize treemacs-magit-root
        :with-expand-depth t)
      (setq-local treemacs-magit--repository repository
                  treemacs-magit--revision revision)
      (setq-local window-size-fixed nil)
      (set-window-parameter (selected-window) 'no-delete-other-windows nil)
      (treemacs-magit--bind-buffer-keys)
      (when (null (treemacs-magit--roots))
        (message "No changes found")))))

(provide 'treemacs-magit-mode)

;;; treemacs-magit-mode.el ends here
