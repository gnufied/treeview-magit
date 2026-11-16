EMACS ?= emacs
STRAIGHT_BUILD ?= $(HOME)/.emacs.d/straight/build

.PHONY: test
test:
	$(EMACS) --batch -Q \
	  --eval '(let ((default-directory (expand-file-name "$(STRAIGHT_BUILD)/"))) (normal-top-level-add-subdirs-to-load-path))' \
	  -L . -L test \
	  -l treemacs-magit-mode.el \
	  -l treemacs-magit-mode-test.el \
	  -l treemacs-magit-review-test.el \
	  -f ert-run-tests-batch-and-exit

DIFF_REVIEW_DIR ?= $(HOME)/checkout/diff-review
.PHONY: test-diff-review
test-diff-review:
	GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false \
	$(EMACS) --batch -Q \
	  --eval '(let ((default-directory (expand-file-name "$(STRAIGHT_BUILD)/"))) (normal-top-level-add-subdirs-to-load-path))' \
	  -L $(DIFF_REVIEW_DIR) -L . \
	  -l test/treemacs-magit-diff-review-test.el \
	  -f ert-run-tests-batch-and-exit
