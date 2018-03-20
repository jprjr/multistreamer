.PHONY: all

MULTISTREAMER_VERSION = $(shell lua -e 'print(require"lib/multistreamer/version".STRING)')

all: rockspec

rockspec: rockspecs/multistreamer-$(MULTISTREAMER_VERSION)-0.rockspec

rockspecs/multistreamer-$(MULTISTREAMER_VERSION)-0.rockspec: rockspecs/multistreamer-template.rockspec
	sed "s/@@VERSION@@/$(MULTISTREAMER_VERSION)/" $< > $@
