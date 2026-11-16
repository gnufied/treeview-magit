;;; treemacs-magit-diff-review.el --- Inline review display -*- lexical-binding: t -*-

;;; Commentary:
;; Optional diff-review renderer for treeview-magit.

;;; Code:
(require 'treemacs-magit-mode)
(require 'diff-review)

(declare-function diff-review-open-file "diff-review"
                  (review-file path root base &optional head comparison))

(defun treemacs-magit--review-git (&rest args)
  "Return Git output for ARGS, preserving trailing newlines."
  (with-temp-buffer
    (let ((code (apply #'process-file "git" nil t nil args)))
      (unless (zerop code)
        (error "Git failed: %s" (buffer-string)))
      (buffer-string))))

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
      (treemacs-magit--run-in-target
       #'diff-review-open-file review-file file default-directory base head comparison))))

(provide 'treemacs-magit-diff-review)
;;; treemacs-magit-diff-review.el ends here
