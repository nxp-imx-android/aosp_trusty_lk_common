LOCAL_DIR := $(GET_LOCAL_DIR)

MODULE := $(LOCAL_DIR)

GLOBAL_DEFINES += \
	ARM64_CPU_$(ARM_CPU)=1 \
	ARM_ISA_ARMV8=1 \
	IS_64BIT=1

MODULE_SRCS += \
	$(LOCAL_DIR)/arch.c \
	$(LOCAL_DIR)/asm.S \
	$(LOCAL_DIR)/exceptions.S \
	$(LOCAL_DIR)/exceptions_c.c \
	$(LOCAL_DIR)/fpu.c \
	$(LOCAL_DIR)/thread.c \
	$(LOCAL_DIR)/spinlock.S \
	$(LOCAL_DIR)/start.S \
	$(LOCAL_DIR)/cache-ops.S \
	$(LOCAL_DIR)/usercopy.S \
	$(LOCAL_DIR)/safecopy.S \

#	$(LOCAL_DIR)/arm/start.S \
	$(LOCAL_DIR)/arm/cache.c \
	$(LOCAL_DIR)/arm/ops.S \
	$(LOCAL_DIR)/arm/faults.c \
	$(LOCAL_DIR)/arm/dcc.S

MODULE_DEPS += \
	trusty/kernel/lib/trusty \

GLOBAL_DEFINES += \
	ARCH_DEFAULT_STACK_SIZE=4096

ARCH_DEFAULT_SHADOW_STACK_SIZE := 4096
ifeq (true,$(call TOBOOL,$(KERNEL_SCS_ENABLED)))
GLOBAL_DEFINES += \
	ARCH_DEFAULT_SHADOW_STACK_SIZE=$(ARCH_DEFAULT_SHADOW_STACK_SIZE)
endif

# if its requested we build with SMP, arm generically supports 4 cpus
ifeq ($(WITH_SMP),1)
SMP_MAX_CPUS ?= 4
SMP_CPU_CLUSTER_SHIFT ?= 8
SMP_CPU_ID_BITS ?= 24 # Ignore aff3 bits for now since they are not next to aff2

GLOBAL_DEFINES += \
    WITH_SMP=1 \
    SMP_MAX_CPUS=$(SMP_MAX_CPUS) \
    SMP_CPU_CLUSTER_SHIFT=$(SMP_CPU_CLUSTER_SHIFT) \
    SMP_CPU_ID_BITS=$(SMP_CPU_ID_BITS)

MODULE_SRCS += \
    $(LOCAL_DIR)/mp.c
else
GLOBAL_DEFINES += \
    SMP_MAX_CPUS=1
endif

ifeq (false,$(call TOBOOL,$(ARM_WITHOUT_VFP_NEON)))
# Enable optional instructions unless platform already disabled them
USE_ARM_V7_NEON ?= true
USE_ARM_V8_AES ?= true
USE_ARM_V8_PMULL ?= true
USE_ARM_V8_SHA1 ?= true
USE_ARM_V8_SHA2 ?= true
endif

ARCH_OPTFLAGS := -O2

# Set ARM_MERGE_FIQ_IRQ to remove separation between IRQs and FIQs. This is
# for GICv3 or GICv4 when running in trustzone as the non-secure interrupts
# will be delivered as FIQs instead of IRQs.
ARM_MERGE_FIQ_IRQ ?= false

ifeq (true,$(call TOBOOL,$(ARM_MERGE_FIQ_IRQ)))
GLOBAL_DEFINES += ARM_MERGE_FIQ_IRQ=1
endif

# we have a mmu and want the vmm/pmm
WITH_KERNEL_VM ?= 1

ifeq ($(WITH_KERNEL_VM),1)

MODULE_SRCS += \
	$(LOCAL_DIR)/mmu.c

KERNEL_ASPACE_BASE ?= 0xffff000000000000
KERNEL_ASPACE_SIZE ?= 0x0001000000000000
USER_ASPACE_BASE   ?= 0x0000000001000000
USER_ASPACE_SIZE   ?= 0x0000fffffe000000

GLOBAL_DEFINES += \
    KERNEL_ASPACE_BASE=$(KERNEL_ASPACE_BASE) \
    KERNEL_ASPACE_SIZE=$(KERNEL_ASPACE_SIZE) \
    USER_ASPACE_BASE=$(USER_ASPACE_BASE) \
    USER_ASPACE_SIZE=$(USER_ASPACE_SIZE)

KERNEL_BASE ?= $(KERNEL_ASPACE_BASE)
KERNEL_LOAD_OFFSET ?= 0

GLOBAL_DEFINES += \
    KERNEL_BASE=$(KERNEL_BASE) \
    KERNEL_LOAD_OFFSET=$(KERNEL_LOAD_OFFSET)

else

KERNEL_BASE ?= $(MEMBASE)
KERNEL_LOAD_OFFSET ?= 0

endif

GLOBAL_DEFINES += \
	MEMBASE=$(MEMBASE) \
	MEMSIZE=$(MEMSIZE)

# try to find the toolchain
include $(LOCAL_DIR)/toolchain.mk
TOOLCHAIN_PREFIX := $(ARCH_$(ARCH)_TOOLCHAIN_PREFIX)
$(info TOOLCHAIN_PREFIX = $(TOOLCHAIN_PREFIX))

ARCH_COMPILEFLAGS += $(ARCH_$(ARCH)_COMPILEFLAGS)

GLOBAL_LDFLAGS += -z max-page-size=4096


# make sure some bits were set up
MEMVARS_SET := 0
ifneq ($(MEMBASE),)
MEMVARS_SET := 1
endif
ifneq ($(MEMSIZE),)
MEMVARS_SET := 1
endif
ifeq ($(MEMVARS_SET),0)
$(error missing MEMBASE or MEMSIZE variable, please set in target rules.mk)
endif

# potentially generated files that should be cleaned out with clean make rule
GENERATED += \
	$(BUILDDIR)/system-onesegment.ld

# rules for generating the linker script
$(BUILDDIR)/system-onesegment.ld: $(LOCAL_DIR)/system-onesegment.ld $(wildcard arch/*.ld) linkerscript.phony
	@echo generating $@
	@$(MKDIR)
	$(NOECHO)sed "s/%MEMBASE%/$(MEMBASE)/;s/%MEMSIZE%/$(MEMSIZE)/;s/%KERNEL_BASE%/$(KERNEL_BASE)/;s/%KERNEL_LOAD_OFFSET%/$(KERNEL_LOAD_OFFSET)/" < $< > $@.tmp
	@$(call TESTANDREPLACEFILE,$@.tmp,$@)

linkerscript.phony:
.PHONY: linkerscript.phony

include make/module.mk
