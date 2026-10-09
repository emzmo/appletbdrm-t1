# Apple Touch Bar T1 Driver Suite
# Builds: appletbdrm.ko (kernel) + ibridge-switcher (userspace)

obj-m := appletbdrm.o

KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# Kernel module build flags
EXTRA_CFLAGS := -msoft-float -msse -msse2 -msse3 -msse4

.PHONY: all modules userspace clean install uninstall

all: modules userspace

modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

userspace: ibridge-switcher

ibridge-switcher: ibridge_switcher.c
	$(CC) -o $@ $< -lusb-1.0

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f ibridge-switcher

install:
	@echo "Use ./install.sh for full installation"

uninstall:
	@echo "Use ./install.sh uninstall for removal"
