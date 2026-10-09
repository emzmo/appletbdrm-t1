KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m += hid-multitouch.o

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

install:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules_install

.PHONY: all clean install
