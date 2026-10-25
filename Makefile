.PHONY: test doctor chmod

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

chmod:
	chmod 755 $(ROOT)bin/hearthost $(ROOT)tests/run.sh

test: chmod
	$(ROOT)tests/run.sh

doctor: chmod
	$(ROOT)bin/hearthost doctor
