EMACS ?= emacs
STRAIGHT_BUILD ?= $(HOME)/.emacs.d/straight/build

.PHONY: test
test:
	$(EMACS) --batch -Q \
	  --eval '(let ((default-directory (expand-file-name "$(STRAIGHT_BUILD)/"))) (normal-top-level-add-subdirs-to-load-path))' \
	  -L . -L test \
	  -l treemacs-magit-mode.el \
	  -l treemacs-magit-mode-test.el \
	  -f ert-run-tests-batch-and-exit
