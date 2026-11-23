#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <dlfcn.h>

static void *decode_adrp_ldr(uint32_t *pc) {
    uint32_t ins1 = pc[0];
    uint32_t ins2 = pc[1];
    int32_t immlo = (ins1 >> 29) & 3;
    int32_t immhi = (ins1 >> 5) & 0x7FFFF;
    int64_t imm = ((int64_t)((immhi << 2) | immlo) << 43) >> 43;
    uint64_t base = ((uint64_t)pc & ~0xFFFULL) + (imm << 12);
    uint32_t imm12 = ((ins2 >> 10) & 0xFFF) << 3;
    return (void *)(base + imm12);
}

static void *decode_adrp_add(uint32_t *pc) {
    uint32_t ins1 = pc[0];
    uint32_t ins2 = pc[1];
    int32_t immlo = (ins1 >> 29) & 3;
    int32_t immhi = (ins1 >> 5) & 0x7FFFF;
    int64_t imm = ((int64_t)((immhi << 2) | immlo) << 43) >> 43;
    uint64_t base = ((uint64_t)pc & ~0xFFFULL) + (imm << 12);
    uint32_t imm12 = (ins2 >> 10) & 0xFFF;
    return (void *)(base + imm12);
}

__attribute__((constructor))
static void FixExtensionBootstrap(void) {
    os_log_error(OS_LOG_DEFAULT, "[BatteryExtensionHook] FixExtensionBootstrap running...");

    // 1. Swizzle LSBundleRecord bundleRecordForCurrentProcess
    Class bundleRecordCls = NSClassFromString(@"LSBundleRecord");
    if (bundleRecordCls) {
        SEL curProcSel = NSSelectorFromString(@"bundleRecordForCurrentProcess");
        Method curProcMethod = class_getClassMethod(bundleRecordCls, curProcSel);
        SEL getRecordSel = NSSelectorFromString(@"bundleRecordWithBundleIdentifier:allowPlaceholder:error:");
        Method getRecordMethod = class_getClassMethod(bundleRecordCls, getRecordSel);
        
        if (curProcMethod && getRecordMethod) {
            id (*origCurProc)(id, SEL) = (id (*)(id, SEL))method_getImplementation(curProcMethod);
            id (*getRecFunc)(id, SEL, NSString *, BOOL, NSError **) = (id (*)(id, SEL, NSString *, BOOL, NSError **))method_getImplementation(getRecordMethod);
            
            id (^swizzledBlock)(id) = ^id(id self) {
                id record = origCurProc(self, curProcSel);
                if (record) return record;
                NSError *err = nil;
                id fallback = getRecFunc(self, getRecordSel, @"com.local.MacBatteryTray.BatteryControlExtension", NO, &err);
                return fallback;
            };
            method_setImplementation(curProcMethod, imp_implementationWithBlock([swizzledBlock copy]));
            os_log_error(OS_LOG_DEFAULT, "[BatteryExtensionHook] LSBundleRecord swizzled!");
        }
    }

    // 2. Pre-initialize _EXRunningExtension._shared
    void *ef = dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
    if (!ef) {
        os_log_error(OS_LOG_DEFAULT, "[BatteryExtensionHook] Failed to load ExtensionFoundation");
        return;
    }

    uint32_t *boot = (uint32_t *)dlsym(ef, "$sSo12_EXExtensionC19ExtensionFoundationE9bootstrap4withyAB_tFZ");
    if (!boot) {
        os_log_error(OS_LOG_DEFAULT, "[BatteryExtensionHook] bootstrap symbol not found");
        return;
    }

    uint32_t *sharedInst = NULL;
    for (int i = 0; i < 30; i++) {
        uint32_t ins = boot[i];
        if ((ins & 0xFC000000) == 0x94000000) {
            int32_t imm26 = ins & 0x03FFFFFF;
            if (imm26 & 0x02000000) imm26 |= 0xFC000000;
            void *tgt = (void *)((intptr_t)(boot + i) + (imm26 * 4));
            Dl_info info;
            if (dladdr(tgt, &info) && info.dli_sname && strstr(info.dli_sname, "sharedInstance")) {
                sharedInst = (uint32_t *)tgt;
                break;
            }
        }
    }

    if (!sharedInst) {
        os_log_error(OS_LOG_DEFAULT, "[BatteryExtensionHook] sharedInstance not found");
        return;
    }

    void **shared_var = (void **)decode_adrp_ldr(&sharedInst[8]);
    intptr_t *token = (intptr_t *)decode_adrp_add(&sharedInst[22]);
    if (!shared_var || !token) {
        os_log_error(OS_LOG_DEFAULT, "[BatteryExtensionHook] Failed to decode shared_var or token");
        return;
    }

    // Lookup Extension Record
    id extRecord = nil;
    if (bundleRecordCls) {
        SEL getRecordSel = NSSelectorFromString(@"bundleRecordWithBundleIdentifier:allowPlaceholder:error:");
        Method getRecordMethod = class_getClassMethod(bundleRecordCls, getRecordSel);
        if (getRecordMethod) {
            id (*getRecFunc)(id, SEL, NSString *, BOOL, NSError **) = (id (*)(id, SEL, NSString *, BOOL, NSError **))method_getImplementation(getRecordMethod);
            extRecord = getRecFunc(bundleRecordCls, getRecordSel, @"com.local.MacBatteryTray.BatteryControlExtension", NO, nil);
        }
    }

    // Create _EXExtensionIdentity
    id ident = nil;
    Class idCls = NSClassFromString(@"_EXExtensionIdentity");
    if (idCls && extRecord) {
        SEL initRecSel = NSSelectorFromString(@"initWithApplicationExtensionRecord:");
        Method initM = class_getInstanceMethod(idCls, initRecSel);
        if (initM) {
            id (*initRecFunc)(id, SEL, id) = (id (*)(id, SEL, id))method_getImplementation(initM);
            ident = initRecFunc([idCls alloc], initRecSel, extRecord);
        }
    }

    // Create ExtensionFoundation._EXRunningExtension
    Class extCls = NSClassFromString(@"ExtensionFoundation._EXRunningExtension");
    if (extCls) {
        id runningExt = [[extCls alloc] init];
        if (ident) {
            void **extWords = (void **)runningExt;
            extWords[4] = (void *)ident; // offset 32 (_extensionIdentity)
            [ident retain];
        }
        [runningExt retain];
        *shared_var = (void *)runningExt;
        *token = -1;
        os_log_error(OS_LOG_DEFAULT, "[BatteryExtensionHook] Pre-initialized _EXRunningExtension._shared successfully: %p", runningExt);
    }
}
