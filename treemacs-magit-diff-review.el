;;; treemacs-magit-diff-review.el --- Inline review display -*- lexical-binding: t -*-

;;; Commentary:
;; Optional diff-review renderer for treeview-magit.

;;; Code:
(require 'treemacs-magit-mode)
(require 'diff-review)

(declare-function diff-review-open-file "diff-review"
                  (review-file path root base &optional head comparison))

(defvar treemacs-magit--opening-review-tree nil)
(defvar-local treemacs-magit--review-tree nil)

(defun treemacs-magit--review-close (&optional keep)
  "End reviews owned by the current tree, except the review file KEEP.
Use diff-review's lifecycle so real files and unsaved edits survive while
revision buffers, decorations, and review ownership are cleaned up."
  (let ((tree (current-buffer)))
    (dolist (review (buffer-list))
      (when (and (buffer-live-p review)
                 (eq (buffer-local-value 'treemacs-magit--review-tree review) tree)
                 (not (and keep (equal (buffer-local-value 'buffer-file-name review)
                                       keep))))
        (with-current-buffer review
          (unless (diff-review-quit)
            (user-error "Review could not be closed: %s" (buffer-name review))))))))

(advice-add 'treemacs-magit--cleanup-buffer :before #'treemacs-magit--review-close)

(defun treemacs-magit--review-before-tree-display (buffer)
  "End BUFFER's previous reviews before rebuilding the tree.
This also handles a new comparison with no changed files to open."
  (with-current-buffer buffer
    (treemacs-magit--review-close)))

(advice-add 'treemacs-magit--display-buffer :before
            #'treemacs-magit--review-before-tree-display)


(defun treemacs-magit--review-tree-buffer ()
  "Return the tree owning the current review, if any."
  (or treemacs-magit--opening-review-tree
      (and (buffer-live-p diff-review--review)
           (buffer-local-value 'treemacs-magit--review-tree diff-review--review))))

(defun treemacs-magit--review-follow ()
  "Follow review navigation without selecting the tree window."
  (when (and (bound-and-true-p diff-review-file-mode)
             diff-review--file-path)
    (let ((tree (treemacs-magit--review-tree-buffer))
          (file diff-review--file-path))
      (when (buffer-live-p tree)
        (with-current-buffer tree
          (let ((position (point-min)) found)
            (while (and (< position (point-max)) (not found))
              (let ((node (get-text-property position :node)))
                (when (and (treemacs-magit-node-p node)
                           (equal (treemacs-magit-node-path node)
                                  (expand-file-name file treemacs-magit--repository)))
                  (setq found (treemacs-button-get position :path))))
              (setq position (next-single-property-change position :node nil (point-max))))
            (when found
              (save-selected-window
                (when-let* ((window (get-buffer-window tree)))
                  (with-selected-window window
                    (treemacs-goto-extension-node found)))))))))))

(defun treemacs-magit--review-decorate (original &rest arguments)
  "Render tree-owned reviews with independent margin markers."
  (if (not (buffer-live-p (treemacs-magit--review-tree-buffer)))
      (apply original arguments)
    (when (buffer-live-p diff-review--review)
      (with-current-buffer diff-review--review
        (setq treemacs-magit--review-tree
              (or treemacs-magit--opening-review-tree treemacs-magit--review-tree))))
    (let ((diff-review-tint-added nil))
      (cl-letf (((symbol-function 'diff-review--fringe-mark)
                 (lambda (face)
                   ;; Keep added markers off the overlay spanning the hunk:
                   ;; margin before-strings there can repeat during redisplay.
                   (if (eq face 'diff-indicator-added)
                       ""
                     (propertize " " 'display
                                 `((margin left-margin)
                                   ,(propertize "−" 'face face)))))))
        (apply original arguments)))
    (save-excursion
      (dolist (hunk diff-review--hunks)
        (goto-char (diff-review--line-pos (plist-get hunk :line)))
        (dotimes (_ (plist-get hunk :count))
          (let ((overlay (make-overlay (point) (point))))
            (overlay-put overlay 'before-string
                         (propertize " " 'display
                                     `((margin left-margin)
                                       ,(propertize "+" 'face 'diff-indicator-added))))
            (push overlay diff-review--overlays))
          (forward-line 1))))
    (setq-local left-margin-width (max 1 (or left-margin-width 0)))
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (set-window-margins window (max 1 (or (car (window-margins window)) 0))
                          (cdr (window-margins window))))))

(advice-add 'diff-review--decorate :around #'treemacs-magit--review-decorate)
(add-hook 'post-command-hook #'treemacs-magit--review-follow)

(defun treemacs-magit--diff-review-git (&rest args)
  "Return Git output for ARGS, preserving trailing newlines."
  (with-temp-buffer
    (let ((code (apply #'process-file "git" nil t nil args)))
      (unless (zerop code)
        (error "Git failed: %s" (buffer-string)))
      (buffer-string))))

(defun treemacs-magit--review-head-buffer (original file)
  "Prefer FILE on disk when it exactly matches the reviewed version.
Transfer an existing file buffer from an older review rather than forcing a
snapshot merely because that review is still open.  ORIGINAL handles files
whose disk or unsaved contents differ, and reviews outside this adapter."
  (if (not (buffer-live-p (or treemacs-magit--opening-review-tree
                             treemacs-magit--review-tree)))
      (funcall original file)
    (let* ((default-directory diff-review--root)
           (path (expand-file-name (plist-get file :path) default-directory))
           (existing (find-buffer-visiting path))
           (contents (and (file-regular-p path) (not (file-symlink-p path))
                          (treemacs-magit--diff-review-git
                           "show" (concat diff-review--tip ":" (plist-get file :path)))))
           (matches (and contents
                         (equal contents (with-temp-buffer
                                           (insert-file-contents path)
                                           (buffer-string)))
                         (or (not existing)
                             (with-current-buffer existing
                               (save-restriction
                                 (widen)
                                 (equal contents (buffer-substring-no-properties
                                                  (point-min) (point-max)))))))))
      (if (not matches)
          (funcall original file)
        (let ((review (current-buffer))
              (buffer (diff-review--visit path)))
          (with-current-buffer buffer
            (when (and diff-review-file-mode
                       (not (eq diff-review--review review)))
              (diff-review-file-mode -1)))
          buffer)))))

(advice-add 'diff-review--head-buffer :around #'treemacs-magit--review-head-buffer)

;;;###autoload
(defun treemacs-magit-diff-review (data root file status)
  "Open DATA from ROOT at FILE with STATUS in a native review session."
  (unless (fboundp 'diff-review-open-file)
    (user-error "Install diff-review with the diff-review-open-file API"))
  (let* ((default-directory (treemacs-magit-node-repository data))
         (head (and (eq status 'committed) (treemacs-magit-node-revision root)))
         (range (and head (treemacs-magit-node-range root)))
         (base (if head
                   (if range
                       (if (string-match "\\`\\(.*?\\)\\(\\.\\.\\.?\\)\\(.*\\)\\'" range)
                           (let ((left (match-string 1 range))
                                 (dots (match-string 2 range)))
                             (if (equal dots "...")
                                 (magit-git-string "merge-base" left head)
                               left))
                         (user-error "Unsupported revision range: %s" range))
                     (magit-rev-verify (concat head "^")))
                 (and (magit-rev-verify "HEAD") "HEAD")))
         (comparison (pcase status
                       ('committed "range") ('staged "staged")
                       ('unstaged "unstaged") (_ "worktree")))
         (branch (or (magit-get-current-branch) (magit-rev-verify "HEAD") "unborn")))
    (unless base
      (setq base (string-trim
                  (with-temp-buffer
                    (unless (zerop (call-process-region (point-min) (point-max) "git" nil t nil
                                                       "hash-object" "-w" "-t" "tree" "--stdin"))
                      (error "Cannot create empty tree"))
                    (buffer-string)))))
    (let* ((identity (secure-hash 'sha256 (prin1-to-string
                                         (list default-directory branch comparison base head))))
           (review-file (expand-file-name
                         (concat "treeview-reviews/" identity ".json")
                         (expand-file-name (magit-git-string "rev-parse" "--git-common-dir")
                                           default-directory))))
      (treemacs-magit--review-close review-file)
      (let ((treemacs-magit--opening-review-tree (current-buffer)))
        (treemacs-magit--run-in-target
         #'diff-review-open-file review-file file default-directory base head comparison)))))

(defvar magit-difftastic-mode)
(defvar magit-difftastic-diff-buffers)
(defvar magit-difftastic-default-rendering)
(declare-function magit-difftastic-mode "magit-difftastic" (&optional arg))

(defun treemacs-magit--difftastic-file-setup ()
  "Select Difftastic rendering for this file's Magit diff buffer."
  (setq-local magit-difftastic-diff-buffers t
              magit-difftastic-default-rendering 'difftastic))

;;;###autoload
(defun treemacs-magit-difftastic-file ()
  "Show the current file's diff in a read-only Magit Difftastic buffer.
In a diff-review file buffer, use that review's exact base and head, even
for a branch, PR or historical snapshot.  Staged and unstaged reviews
use the current index comparison.  Otherwise
compare the file on disk against HEAD.  Unsaved edits are not saved.
The separate Magit buffer is locked to this comparison and file; `q'
returns using Magit's normal window handling.  Enable
`magit-difftastic-mode' if necessary."
  (interactive)
  (let* ((review (and (bound-and-true-p diff-review-file-mode)
                      (buffer-live-p diff-review--review) diff-review--review))
         (root (if review (buffer-local-value 'diff-review--root review)
                 (and buffer-file-name (magit-toplevel))))
         (file (if review diff-review--file-path
                 (and root (file-relative-name buffer-file-name root))))
         (comparison (and review
                          (gethash "comparison"
                                   (buffer-local-value 'diff-review--data review))))
         (range (cond
                 ((equal comparison "unstaged") nil)
                 ((equal comparison "staged")
                  (buffer-local-value 'diff-review--base review))
                 (review
                  (with-current-buffer review
                    (if diff-review--tip
                        (concat diff-review--base ".." diff-review--tip)
                      diff-review--base)))
                 (t "HEAD")))
         (typearg (and (equal comparison "staged") "--cached")))
    (unless (and root file)
      (user-error "Visit a Git file or a diff-review file first"))
    (unless (require 'magit-difftastic nil t)
      (user-error "Install magit-difftastic to use this command"))
    (unless (executable-find "difft")
      (user-error "Difftastic executable `difft' is not available"))
    (unless magit-difftastic-mode (magit-difftastic-mode 1))
    (let* ((default-directory root)
           (magit-diff-mode-hook (cons #'treemacs-magit--difftastic-file-setup
                                       magit-diff-mode-hook)))
      (let ((buffer (magit-diff-setup-buffer
                     range typearg nil (list file)
                     (cond (typearg 'staged)
                           ((null range) 'unstaged)
                           (t 'committed))
                     t)))
        (with-current-buffer buffer
          (dolist (section (oref magit-root-section children))
            (when (eq (oref section type) 'file)
              (magit-section-show section))))
        buffer))))

(provide 'treemacs-magit-diff-review)
;;; treemacs-magit-diff-review.el ends here
