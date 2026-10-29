#include "ProducerAuthentication.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <errno.h>
#include <signal.h>

static const CFStringRef kPeelHostCodeRequirement = CFSTR(
    "anchor apple generic and "
    "identifier \"com.zephyrstudiosllc.Peel-Host\" and "
    "certificate leaf[subject.OU] = \"V729QMY3V6\""
);

bool peel_producer_authenticate_process(pid_t process_id) {
    if (process_id <= 0) {
        return false;
    }

    const int process_id_value = (int)process_id;
    CFNumberRef process_id_number = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberIntType,
        &process_id_value
    );
    if (process_id_number == NULL) {
        return false;
    }

    const void *keys[] = {kSecGuestAttributePid};
    const void *values[] = {process_id_number};
    CFDictionaryRef attributes = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFRelease(process_id_number);
    if (attributes == NULL) {
        return false;
    }

    SecCodeRef guest_code = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(
        NULL,
        attributes,
        kSecCSDefaultFlags,
        &guest_code
    );
    CFRelease(attributes);
    if (status != errSecSuccess || guest_code == NULL) {
        if (guest_code != NULL) {
            CFRelease(guest_code);
        }
        return false;
    }

    SecRequirementRef requirement = NULL;
    status = SecRequirementCreateWithString(
        kPeelHostCodeRequirement,
        kSecCSDefaultFlags,
        &requirement
    );
    bool is_valid = false;
    if (status == errSecSuccess && requirement != NULL) {
        is_valid =
            SecCodeCheckValidity(
                guest_code,
                kSecCSDefaultFlags,
                requirement
            ) == errSecSuccess;
    }

    if (requirement != NULL) {
        CFRelease(requirement);
    }
    CFRelease(guest_code);
    return is_valid;
}

bool peel_producer_process_has_exited(pid_t process_id) {
    if (process_id <= 0) {
        return false;
    }

    errno = 0;
    return kill(process_id, 0) == -1 && errno == ESRCH;
}
