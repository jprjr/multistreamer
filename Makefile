.PHONY: all upload

MULTISTREAMER_VERSION = $(shell lua -e 'print(require"lib/multistreamer/version".STRING)')
ROCKSPEC = rockspecs/multistreamer-$(MULTISTREAMER_VERSION)-0.rockspec

all: rockspec

upload: $(ROCKSPEC)
	luarocks upload $<
	rm -f multistreamer-$(MULTISTREAMER_VERSION).src.roc

rockspec: $(ROCKSPEC)

$(ROCKSPEC): rockspecs/multistreamer-template.rockspec
	sed "s/@@VERSION@@/$(MULTISTREAMER_VERSION)/" $< > $@
