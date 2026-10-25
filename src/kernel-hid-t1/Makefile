KDIR ?= /lib/modules/$(shell uname -r)/build

# Minimum kernel version: 6.11 (requires on_hid_hw_open/close HID callbacks)
KERNELVER_CHECK := $(shell \
	ver=$$(uname -r); \
	major=$$(echo $$ver | sed 's/\([0-9]*\)\..*/\1/'); \
	minor=$$(echo $$ver | sed 's/[0-9]*\.\([0-9]*\).*/\1/'); \
	if [ $$major -gt 6 ] || { [ $$major -eq 6 ] && [ $$minor -ge 11 ]; }; then \
		echo "ok"; \
	else \
		echo "fail"; \
	fi)

ifneq ($(KERNELVER_CHECK),ok)
$(error kernel-hid-t1 requires kernel >= 6.11 (got $(shell uname -r)). \
	See pre_build.sh for details.)
endif

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src clean

install:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src modules_install

.PHONY: all clean install