# try to find the toolchain
ifndef ARCH_arm_TOOLCHAIN_PREFIX

FOUNDTOOL=

$(info $(TOOLCHAIN_PREFIX))
# if TOOLCHAIN_PREFIX is not empty and ARCH_arm64_TOOLCHAIN_PREFIX is empty,
# try to use TOOLCHAIN_PREFIX first
ifneq ($(TOOLCHAIN_PREFIX),)
ifeq ($(ARCH_arm64_TOOLCHAIN_PREFIX),)
ARCH_arm_TOOLCHAIN_PREFIX := $(TOOLCHAIN_PREFIX)
FOUNDTOOL=$(shell which $(ARCH_arm_TOOLCHAIN_PREFIX)gcc)
endif
endif

# try a series of common arm toolchain prefixes in the path
ifeq ($(FOUNDTOOL),)
ARCH_arm_TOOLCHAIN_PREFIX := arm-eabi-
FOUNDTOOL=$(shell which $(ARCH_arm_TOOLCHAIN_PREFIX)gcc)
endif
ifeq ($(FOUNDTOOL),)
ARCH_arm_TOOLCHAIN_PREFIX := arm-elf-
FOUNDTOOL=$(shell which $(ARCH_arm_TOOLCHAIN_PREFIX)gcc)
endif
ifeq ($(FOUNDTOOL),)
ARCH_arm_TOOLCHAIN_PREFIX := arm-none-eabi-
FOUNDTOOL=$(shell which $(ARCH_arm_TOOLCHAIN_PREFIX)gcc)
endif
ifeq ($(FOUNDTOOL),)
ARCH_arm_TOOLCHAIN_PREFIX := arm-linux-gnueabi-
FOUNDTOOL=$(shell which $(ARCH_arm_TOOLCHAIN_PREFIX)gcc)
endif # arm-linux-gnueabi-

else
FOUNDTOOL=$(shell which $(ARCH_arm_TOOLCHAIN_PREFIX)gcc)
endif # ARCH_arm_TOOLCHAIN_PREFIX

ifeq ($(FOUNDTOOL),)
$(error cannot find toolchain, please set ARCH_arm_TOOLCHAIN_PREFIX or add it to your path)
endif

ARCH_arm_COMPILEFLAGS :=

ifeq ($(ARM_CPU),cortex-a7)
ARCH_arm_COMPILEFLAGS += -mcpu=$(ARM_CPU)
ARCH_arm_COMPILEFLAGS += -mfpu=vfpv3 -mfloat-abi=softfp
endif
ifeq ($(ARM_CPU),cortex-a15)
ARCH_arm_COMPILEFLAGS += -mcpu=$(ARM_CPU)
ifneq ($(ARM_WITHOUT_VFP_NEON),true)
ARCH_arm_COMPILEFLAGS += -mfpu=vfpv3 -mfloat-abi=softfp
else
ARCH_arm_COMPILEFLAGS += -mfloat-abi=soft
endif
endif
ifeq ($(ARM_CPU),armv8-a)
ARCH_arm_COMPILEFLAGS += -march=$(ARM_CPU)
ifneq ($(ARM_WITHOUT_VFP_NEON),true)
ARCH_arm_COMPILEFLAGS += -mfpu=vfpv3 -mfloat-abi=softfp
else
ARCH_arm_COMPILEFLAGS += -mfloat-abi=soft
endif
endif

ifeq ($(call TOBOOL,$(CLANGBUILD)),true)

CLANG_ARM_TARGET_SYS ?= linux
CLANG_ARM_TARGET_ABI ?= gnu

CLANG_ARM_AS_DIR ?= $(shell dirname $(shell dirname $(ARCH_arm_TOOLCHAIN_PREFIX)))

ARM_AS_PATH ?= $(wildcard $(CLANG_ARM_AS_DIR)/*/bin/as)
ifeq ($(ARM_AS_PATH),)
$(error Could not find $(CLANG_ARM_AS_DIR)/*/bin/as, did the directory structure change?)
endif

ARCH_arm_THUMBCFLAGS :=
ifeq ($(ENABLE_THUMB),true)
ARCH_arm_THUMBCFLAGS := -mthumb -D__thumb__
endif

ARCH_arm_COMPILEFLAGS += -target arm-$(CLANG_ARM_TARGET_SYS)-$(CLANG_ARM_TARGET_ABI) \
			   --gcc-toolchain=$(CLANG_ARM_AS_DIR)/

endif
