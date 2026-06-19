# Makefile for typespec

EMACS ?= emacs
LOAD_PATH ?= -L .

# .el sources to byte-compile (dependency order; excludes *-test.el)
EL_SOURCES = typespec-core.el typespec.el typespec-builtins.el \
	typespec-eval-core.el typespec-eval-types.el typespec-eval-var.el \
	typespec-eval-simplify.el typespec-eval-struct.el typespec-eval-numeric.el \
	typespec-eval-op.el typespec-eval.el

.PHONY: test check test-core test-eval clean compile

# clean → test (source) → compile → test (.elc)
test check: clean
	$(MAKE) test-core && $(MAKE) test-eval
	$(MAKE) compile
	$(MAKE) test-core && $(MAKE) test-eval

test-core:
	$(EMACS) -Q --batch $(LOAD_PATH) \
		-l ert -l typespec-core-test \
		-f ert-run-tests-batch-and-exit

test-eval:
	$(EMACS) -Q --batch $(LOAD_PATH) \
		-l ert -l typespec-eval-test \
		-f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc

compile:
	$(EMACS) -Q --batch $(LOAD_PATH) -f batch-byte-compile $(EL_SOURCES)
