#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libusb-1.0/libusb.h>

#define IBRIDGE_VENDOR_ID              0x05ac
#define IBRIDGE_PRODUCT_ID             0x8600

#define IBRIDGE_LINUX_DFU_CONFIG_VALUE 1
#define IBRIDGE_MACOS_CONFIG_VALUE     2

void print_libusb_error(int error_code, const char *action) {
    fprintf(stderr, "Error %s: %s (%d)\n", action, libusb_error_name(error_code), error_code);
}

void print_usage(const char *prog_name) {
    printf("Usage: %s [option]\n", prog_name);
    printf("Switches the Apple iBridge device to a specified configuration.\n");
    printf("Requires root/sudo privileges.\n\n");
    printf("Options:\n");
    printf("  -1, --config1   Switch to Configuration #1 (usually for DFU mode).\n");
    printf("  (no option)     Switch to Configuration #2 (default macOS operational mode).\n");
    printf("  -h, --help      Display this help message and exit.\n");
}

int main(int argc, char *argv[]) {
    libusb_device_handle *handle = NULL;
    struct libusb_config_descriptor *config;
    int r;
    int initial_config_value = -1;
    int target_config_value = IBRIDGE_MACOS_CONFIG_VALUE;

    if (argc > 1) {
        if (strcmp(argv[1], "-1") == 0 || strcmp(argv[1], "--config1") == 0) {
            target_config_value = IBRIDGE_LINUX_DFU_CONFIG_VALUE;
            printf("Target configuration set to #1.\n");
        } else if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
            print_usage(argv[0]);

            return 0;
        } else {
            fprintf(stderr, "Unknown option: %s\n\n", argv[1]);
            print_usage(argv[0]);
            return 1;
        }
    }

    r = libusb_init(NULL);
    if (r < 0) {
        print_libusb_error(r, "initializing libusb");
        return 1;
    }

    libusb_set_option(NULL, LIBUSB_OPTION_LOG_LEVEL, LIBUSB_LOG_LEVEL_INFO);

    printf("Opening Apple iBridge device (05ac:8600)...\n");
    handle = libusb_open_device_with_vid_pid(NULL, IBRIDGE_VENDOR_ID, IBRIDGE_PRODUCT_ID);
    if (handle == NULL) {
        fprintf(stderr, "Could not find or open the iBridge device. Run with sudo.\n");
        libusb_exit(NULL);

        return 1;
    }
    printf("Device opened successfully.\n");

    r = libusb_get_configuration(handle, &initial_config_value);
    if (r < 0) {
        print_libusb_error(r, "getting current configuration");
        libusb_close(handle);
        libusb_exit(NULL);
        return 1;
    }
    printf("Device is currently in Configuration #%d.\n", initial_config_value);

    if (initial_config_value == target_config_value) {
        printf("Device is already in the desired configuration (#%d). Exiting.\n", target_config_value);
        libusb_close(handle);
        libusb_exit(NULL);
        return 0;
    }

    struct libusb_device* dev = libusb_get_device(handle);
    r = libusb_get_config_descriptor_by_value(dev, initial_config_value, &config);
    if (r < 0) {
        print_libusb_error(r, "getting config descriptor");
        libusb_close(handle);
        libusb_exit(NULL);
        return 1;
    }

    printf("Detaching kernel drivers from %d interfaces...\n", config->bNumInterfaces);
    for (int i = 0; i < config->bNumInterfaces; i++) {
        if (libusb_kernel_driver_active(handle, i)) {
            printf("  - Detaching driver from interface %d\n", i);
            r = libusb_detach_kernel_driver(handle, i);
            if (r < 0 && r != LIBUSB_ERROR_NOT_FOUND) {
                print_libusb_error(r, "detaching kernel driver");
            }
        }
    }
    // free the descriptor now that we're done with it
    libusb_free_config_descriptor(config);
    printf("Attempting to set configuration to #%d...\n", target_config_value);
    r = libusb_set_configuration(handle, target_config_value);
    if (r < 0) {
        print_libusb_error(r, "setting configuration");
        libusb_close(handle);
        libusb_exit(NULL);
        return 1;
    }
    printf("\nSUCCESS! iBridge device successfully switched to Configuration #%d.\n", target_config_value);
    printf("The OS will now re-enumerate the device with its new interfaces.\n");
    printf("Check `dmesg` to see the new devices appearing.\n");
    libusb_close(handle);
    libusb_exit(NULL);

    return 0;
}
