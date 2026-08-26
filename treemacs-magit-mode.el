;;; treemacs-magit-mode.el --- Changed files as a Treemacs tree -*- lexical-binding: t -*-

;; Author: Hemant Kumar
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (magit "3.0.0") (treemacs "3.0"))
;; URL: https://github.com/gnufied/treeview-magit

;;; Commentary:
;;
;; Display the files changed in the current repository, or the files changed
;; by the commit at point in a Magit history/revision buffer.  Pull request
;; changes can also be displayed after checking out the pull request with gh.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'magit)
(require 'magit-commit)
(require 'seq)
(require 'subr-x)
(require 'treemacs)
(require 'treemacs-treelib)

(declare-function treemacs-define-doubleclick-action "treemacs-mouse-interface"
                  (state action))

(cl-defstruct (treemacs-magit-node
               (:constructor treemacs-magit-node-create))
  name key path children status root revision range pull-request repository
  collapsed)

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

(defcustom treemacs-magit-pr-collapsed-directories '("vendor")
  "Root-relative directories to collapse in pull request trees.

Each matching directory is rendered as a single directory node.  Its changed
files are not inserted into the tree, and expanding the node shows no children.
Entries must be relative to the repository root."
  :type '(repeat string)
  :group 'treemacs)

(defcustom treemacs-magit-pr-checkout-program
  (or (executable-find "sake") "sake")
  "Program providing the `prc' task used to check out pull requests.

This is the executable behind the shell command `s prc'; `s' itself is a shell
alias and therefore cannot be invoked directly by Emacs."
  :type 'file
  :group 'treemacs)

(defcustom treemacs-magit-min-content-window-width 50
  "Minimum width of each content pane in an automatic three-pane layout.

The value is measured in character columns in both terminal and graphical
Emacs.  A separate file pane is created only when the space to the right of
the tree can be divided into two windows at least this wide."
  :type 'integer
  :group 'treemacs)

(defvar treemacs-magit--contexts nil)
(defvar-local treemacs-magit--repository nil)
(defvar-local treemacs-magit--revision nil)
(defvar-local treemacs-magit--range nil)
(defvar-local treemacs-magit--pull-request nil)
(defvar-local treemacs-magit--rendered-root nil)

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
  (let ((directory default-directory))
    (with-selected-window window
      (when bury-current
        (bury-buffer (window-buffer window)))
      (let ((default-directory directory)
            (display-buffer-overriding-action '(display-buffer-same-window)))
        (apply function arguments)))))

(defun treemacs-magit--run-in-target (function &rest arguments)
  "Run FUNCTION with ARGUMENTS in the window beside the tree."
  (apply #'treemacs-magit--run-in-window
         (treemacs-magit--target-window) nil function arguments))

(defun treemacs-magit--run-in-file-target (function &rest arguments)
  "Run FUNCTION with ARGUMENTS in the file-content target window."
  (apply #'treemacs-magit--run-in-window
         (treemacs-magit--file-target-window) t function arguments))

(defun treemacs-magit--display-commit-message (buffer)
  "Display commit message BUFFER in the window beside the tree."
  (if (treemacs-magit--tree-window)
      (progn
        (select-window (treemacs-magit--target-window))
        (switch-to-buffer buffer))
    (switch-to-buffer buffer)))

(add-to-list 'with-editor-server-window-alist
             (cons git-commit-filename-regexp
                   #'treemacs-magit--display-commit-message))

(defun treemacs-magit--has-separate-file-target-p ()
  "Return non-nil when file contents can use a window separate from diffs."
  (not (eq (treemacs-magit--target-window)
           (treemacs-magit--file-target-window))))

(defun treemacs-magit--resize-tree-window (tree-window)
  "Shrink TREE-WINDOW to its preferred width when possible."
  (when (window-combined-p tree-window t)
    (let* ((frame-width
            (window-total-width (frame-root-window (window-frame tree-window))))
           (preferred-width (max window-min-width
                                 (floor (* frame-width 0.2))))
           (delta (- preferred-width (window-total-width tree-window))))
      (when (< delta 0)
        (let ((resizable (window-resizable tree-window delta t)))
          (when (< resizable 0)
            (window-resize tree-window resizable t)))))))

(defun treemacs-magit--ensure-wide-layout (tree-window)
  "Create a separate file pane to the right of TREE-WINDOW when it fits."
  (let ((right-windows (treemacs-magit--windows-to-right tree-window)))
    (when (and (= (length right-windows) 1)
               (>= (window-total-width (car right-windows))
                   (* 2 treemacs-magit-min-content-window-width)))
      (split-window-right nil (car right-windows)))))

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

(defun treemacs-magit--insert-file (root file status &optional collapsed)
  "Insert FILE with STATUS below ROOT, creating directory nodes as needed.

When COLLAPSED is non-nil, mark the final node as an intentionally empty
directory node."
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
    (setf (treemacs-magit-node-status parent) status
          (treemacs-magit-node-collapsed parent) collapsed)))

(defun treemacs-magit--normalized-collapsed-directories ()
  "Return configured pull request collapsed directories in normalized form."
  (delete-dups
   (mapcar
    (lambda (directory)
      (let ((normalized
             (string-remove-prefix "./" (directory-file-name directory))))
        (when (or (string-empty-p normalized)
                  (file-name-absolute-p normalized)
                  (member ".." (split-string normalized "/" t)))
          (user-error "Collapsed PR directory must be root-relative: %s"
                      directory))
        normalized))
    treemacs-magit-pr-collapsed-directories)))

(defun treemacs-magit--collapsed-directory-for-file (file)
  "Return the configured collapsed directory containing FILE, if any."
  (seq-find (lambda (directory)
              (or (equal file directory)
                  (string-prefix-p (file-name-as-directory directory) file)))
            (sort (treemacs-magit--normalized-collapsed-directories)
                  (lambda (left right) (< (length left) (length right))))))

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

(defun treemacs-magit--pr-files (range)
  "Return files changed by pull request RANGE."
  (magit-git-items "diff" "-z" "--name-only" range "--"))

(defun treemacs-magit--pr-root (repository range revision pull-request)
  "Build a pull request tree in REPOSITORY.

RANGE is the pull request's three-dot revision range, REVISION is its head
commit, and PULL-REQUEST is its number."
  (let ((root (treemacs-magit-node-create
               :name (format "%s (PR #%s)"
                             (file-name-nondirectory
                              (directory-file-name repository))
                             pull-request)
               :key repository
               :path repository
               :root t
               :revision revision
               :range range
               :pull-request pull-request
               :repository repository)))
    (let ((default-directory repository))
      (dolist (file (treemacs-magit--pr-files range))
        (if-let* ((directory
                   (treemacs-magit--collapsed-directory-for-file file)))
            (treemacs-magit--insert-file root directory nil t)
          (treemacs-magit--insert-file root file 'committed))))
    (treemacs-magit--fold-node root 0)
    root))

(defun treemacs-magit--roots ()
  "Return the root node for the current Magit context."
  (let* ((context (cdr (assq (current-buffer) treemacs-magit--contexts)))
         (repository (or (plist-get context :repository)
                         treemacs-magit--repository
                         (magit-toplevel))))
    (unless repository
      (user-error "The current buffer is not in a Git repository"))
    (let* ((revision (or (plist-get context :revision)
                         treemacs-magit--revision))
           (range (or (plist-get context :range) treemacs-magit--range))
           (pull-request (or (plist-get context :pull-request)
                             treemacs-magit--pull-request))
           (root
            (cond
             (range
              (treemacs-magit--pr-root
               repository range revision pull-request))
             (revision
              (treemacs-magit--commit-root repository revision))
             (t
              (treemacs-magit--dirty-root repository)))))
      (setq-local treemacs-magit--rendered-root root)
      (list root))))

(defun treemacs-magit--node-children (btn item)
  "Return children for ITEM, refreshing the dirty root when it is expanded."
  (ignore btn)
  (treemacs-magit-node-children item))

(defun treemacs-magit--node-face (node)
  "Return the face for NODE."
  (cond
   ((treemacs-magit-node-root node) 'treemacs-root-face)
   ((or (treemacs-magit-node-children node)
        (treemacs-magit-node-collapsed node))
    'treemacs-directory-face)
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
                   (not (or (treemacs-magit-node-children node)
                            (treemacs-magit-node-collapsed node)))
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
          (cond
           ((treemacs-magit-node-range data)
            (treemacs-magit--run-in-target
             #'magit-diff-range (treemacs-magit-node-range data)))
           ((treemacs-magit-node-revision data)
            (treemacs-magit--run-in-target
             #'magit-show-commit (treemacs-magit-node-revision data)))
           (t
            (treemacs-magit--run-in-target
             #'magit-status-setup-buffer
             (treemacs-magit-node-repository data))))
        (if (or (treemacs-magit-node-children data)
                (treemacs-magit-node-collapsed data))
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
     (if (treemacs-magit-node-range root)
         (treemacs-magit--run-in-target
          #'magit-diff-range (treemacs-magit-node-range root) nil (list file))
       (treemacs-magit--run-in-target
        #'magit-show-commit
        (treemacs-magit-node-revision root)
        nil (list file))))
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
      (if (and (treemacs-magit-node-range root)
               (file-exists-p (treemacs-magit-node-path data)))
          (treemacs-magit--run-in-file-target
           #'find-file (treemacs-magit-node-path data))
        (treemacs-magit--run-in-file-target
         #'magit-find-file
         (treemacs-magit-node-revision root) file))
    (treemacs-magit--run-in-file-target
     #'find-file (treemacs-magit-node-path data))))

(defun treemacs-magit--first-file-node (node)
  "Return the first displayable file node below NODE."
  (if (and (not (treemacs-magit-node-root node))
           (not (treemacs-magit-node-children node))
           (not (treemacs-magit-node-collapsed node))
           (treemacs-magit-node-status node))
      node
    (seq-some #'treemacs-magit--first-file-node
              (treemacs-magit-node-children node))))

(defun treemacs-magit--display-initial-file ()
  "Select and display the first changed file in the rendered tree."
  (when-let* ((root treemacs-magit--rendered-root)
              (data (treemacs-magit--first-file-node root)))
    (let ((default-directory (treemacs-magit-node-repository data))
          (file (file-relative-name
                 (treemacs-magit-node-path data)
                 (treemacs-magit-node-repository data)))
          (status (treemacs-magit-node-status data)))
      (when-let* ((position
                   (text-property-any (point-min) (point-max) :node data))
                  (path (treemacs-button-get position :path)))
        (treemacs-goto-extension-node path))
      (treemacs-magit--visit-diff data root file status)
      (when (treemacs-magit--has-separate-file-target-p)
        (treemacs-magit--visit-file-node data root file status)))))

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
    (define-key map (kbd "c") #'treemacs-magit-commit)
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
    (set-window-dedicated-p tree-window t)
    (set-window-parameter tree-window 'no-delete-other-windows nil)
    (set-window-parameter tree-window 'window-side nil)
    (set-window-parameter tree-window 'window-slot nil)
    (treemacs-magit--resize-tree-window tree-window)
    (treemacs-magit--ensure-wide-layout tree-window)
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

(defun treemacs-magit-commit ()
  "Commit the currently staged changes from the Treemacs Magit view."
  (interactive)
  (let* ((context (cdr (assq (current-buffer) treemacs-magit--contexts)))
         (repository (or treemacs-magit--repository
                         (plist-get context :repository)))
         (revision (or treemacs-magit--revision
                       (plist-get context :revision)))
         (range (or treemacs-magit--range (plist-get context :range))))
    (unless (and (stringp repository) (file-directory-p repository))
      (user-error "The Treemacs Magit repository is no longer available"))
    (when (or revision range)
      (user-error "Cannot create a commit from a commit or pull request view"))
    (let ((default-directory repository))
      (magit-commit-create))))

(defun treemacs-magit-stage-file-at-point ()
  "Toggle staging for the file node at point."
  (interactive)
  (let* ((button (treemacs-current-button))
         (node (and button (treemacs-button-get button :node)))
         (root (and button (treemacs-magit--root-for-button button)))
         (path (and button (treemacs-button-get button :path))))
    (unless (and (treemacs-magit-node-p node)
                 (not (treemacs-magit-node-root node))
                 (not (treemacs-magit-node-children node))
                 (not (treemacs-magit-node-collapsed node)))
      (user-error "Point is not on a file node"))
    (when (or (treemacs-magit-node-revision root)
              (treemacs-magit-node-range root)
              (eq (treemacs-magit-node-status node) 'committed))
      (user-error "Cannot stage a file from a commit or pull request view"))
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

;; Always request Treemacs's text fallbacks so this tree never renders images.
(treemacs-define-expandable-node-type treemacs-magit-node
  :closed-icon (if (treemacs-magit-node-root item)
                   (treemacs-get-icon-value 'root-closed t)
                 (if (or (treemacs-magit-node-children item)
                         (treemacs-magit-node-collapsed item))
                     (treemacs-get-icon-value 'dir-closed t)
                   ""))
  :open-icon (if (treemacs-magit-node-root item)
                 (treemacs-get-icon-value 'root-open t)
               (if (or (treemacs-magit-node-children item)
                       (treemacs-magit-node-collapsed item))
                   (treemacs-get-icon-value 'dir-open t)
                 ""))
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
                  treemacs-magit--revision revision
                  treemacs-magit--range nil
                  treemacs-magit--pull-request nil)
      (setq treemacs-magit--contexts
            (cons (cons buffer (list :repository repository
                                     :revision revision))
                  (assq-delete-all buffer treemacs-magit--contexts)))
      (treemacs-initialize treemacs-magit-root
        :with-expand-depth t)
      (setq-local treemacs-magit--repository repository
                  treemacs-magit--revision revision
                  treemacs-magit--range nil
                  treemacs-magit--pull-request nil)
      (setq-local window-size-fixed nil)
      (set-window-parameter (selected-window) 'no-delete-other-windows nil)
      (treemacs-magit--bind-buffer-keys)
      (if (treemacs-magit--first-file-node treemacs-magit--rendered-root)
          (treemacs-magit--display-initial-file)
        (message "No changes found")))))

(defun treemacs-magit--process-string (program &rest arguments)
  "Run PROGRAM with ARGUMENTS and return its trimmed output.

Signal a user error containing the process output when the command fails."
  (with-temp-buffer
    (let ((status
           (condition-case error-data
               (apply #'process-file program nil '(t t) nil arguments)
             (file-missing
              (user-error "Cannot run %s: %s"
                          program (error-message-string error-data))))))
      (unless (and (integerp status) (zerop status))
        (user-error "%s failed: %s"
                    program (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun treemacs-magit--pr-metadata (pull-request)
  "Return GitHub metadata for PULL-REQUEST as an alist.

When PULL-REQUEST is nil, ask gh for the pull request associated with the
current branch."
  (json-parse-string
   (apply #'treemacs-magit--process-string
          "gh" "pr" "view"
          (append (and pull-request (list (number-to-string pull-request)))
                  (list "--json"
                        "number,baseRefOid,headRefName,headRefOid")))
   :object-type 'alist))

(defun treemacs-magit--pr-already-checked-out-p (metadata)
  "Return non-nil when METADATA describes the current checkout."
  (equal (magit-rev-parse "HEAD") (alist-get 'headRefOid metadata)))

(defun treemacs-magit--checkout-pr (pull-request metadata)
  "Check out PULL-REQUEST using the configured sake task when needed.

METADATA is used to avoid resetting a pull request that is already checked
out."
  (unless (treemacs-magit--pr-already-checked-out-p metadata)
    (when (magit-git-items "status" "--porcelain=v1" "-z")
      (user-error "Refusing to check out PR #%s with a dirty worktree"
                  pull-request))
    (message "Checking out PR #%s with sake prc..." pull-request)
    (treemacs-magit--process-string
     treemacs-magit-pr-checkout-program
     "prc" (number-to-string pull-request))))

;;;###autoload
(defun treemacs-magit-pr (&optional pull-request)
  "Check out and display all files changed by a GitHub pull request.

With no argument, use the pull request associated by GitHub with the current
branch.  With a prefix argument, prompt for PULL-REQUEST.

If the pull request's exact head commit is already checked out, do not run
the checkout helper again.  Otherwise use the `prc' task from
`treemacs-magit-pr-checkout-program'."
  (interactive
   (list (and current-prefix-arg
              (read-number "GitHub PR number: "))))
  (when (and pull-request (not (> pull-request 0)))
    (user-error "Pull request number must be positive"))
  (let ((repository (magit-toplevel)))
    (unless repository
      (user-error "The current buffer is not in a Git repository"))
    (let ((default-directory repository))
      (let* ((metadata (treemacs-magit--pr-metadata pull-request))
             (pull-request (alist-get 'number metadata))
             (base (alist-get 'baseRefOid metadata))
             (head (alist-get 'headRefOid metadata)))
        (unless (and (integerp pull-request) (> pull-request 0))
          (user-error "gh did not return a pull request number"))
        (treemacs-magit--checkout-pr pull-request metadata)
        (unless (and (magit-rev-verify base) (magit-rev-verify head))
          (user-error "PR #%s base or head commit is unavailable locally"
                      pull-request))
        (let* ((range (format "%s...%s" base head))
               (buffer (get-buffer-create treemacs-magit--buffer-name)))
          (treemacs-magit--display-buffer buffer)
          (setq-local treemacs-magit--repository repository
                      treemacs-magit--revision head
                      treemacs-magit--range range
                      treemacs-magit--pull-request pull-request)
          (setq treemacs-magit--contexts
                (cons (cons buffer (list :repository repository
                                         :revision head
                                         :range range
                                         :pull-request pull-request))
                      (assq-delete-all buffer treemacs-magit--contexts)))
          (treemacs-initialize treemacs-magit-root
            :with-expand-depth t)
          (setq-local treemacs-magit--repository repository
                      treemacs-magit--revision head
                      treemacs-magit--range range
                      treemacs-magit--pull-request pull-request)
          (setq-local window-size-fixed nil)
          (set-window-parameter (selected-window) 'no-delete-other-windows nil)
          (treemacs-magit--bind-buffer-keys)
          (if (treemacs-magit--first-file-node treemacs-magit--rendered-root)
              (treemacs-magit--display-initial-file)
            (message "No changes found")))))))

(provide 'treemacs-magit-mode)

;;; treemacs-magit-mode.el ends here
