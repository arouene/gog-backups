EMACS ?= emacs
ACURL_DIR ?= ../acurl
BATCH = $(EMACS) -Q --batch -L . -L $(ACURL_DIR) -L test

.PHONY: all compile checkdoc test clean

all: compile checkdoc test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile gog-backups.el test/gog-backups-test.el

checkdoc:
	$(BATCH) -l test/run-checkdoc.el gog-backups.el

test:
	$(BATCH) -l test/gog-backups-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
