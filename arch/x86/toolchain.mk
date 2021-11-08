# x86-32 toolchain
ifeq ($(SUBARCH),x86-32)
ifndef ARCH_x86_TOOLCHAIN_INCLUDED
ARCH_x86_TOOLCHAIN_INCLUDED := 1

ifndef ARCH_x86_TOOLCHAIN_PREFIX
$(error Please run envsetup.sh to set ARCH_x86_TOOLCHAIN_PREFIX)
endif

endif
endif

# x86-64 toolchain
ifeq ($(SUBARCH),x86-64)
ifndef ARCH_x86_64_TOOLCHAIN_INCLUDED
ARCH_x86_64_TOOLCHAIN_INCLUDED := 1

ifndef ARCH_x86_64_TOOLCHAIN_PREFIX
$(error Please run envsetup.sh to set ARCH_x86_64_TOOLCHAIN_PREFIX)
endif

CLANG_X86_64_TARGET_SYS ?= linux
CLANG_X86_64_TARGET_ABI ?= gnu

CLANG_X86_64_AS_DIR := $(shell dirname $(shell dirname $(ARCH_x86_64_TOOLCHAIN_PREFIX)))

AS_PATH := $(wildcard $(CLANG_X86_64_AS_DIR)/*/bin/as)
ifeq ($(AS_PATH),)
	$(error Could not find $(CLANG_X86_64_AS_DIR)/*/bin/as, did the directory structure change?)
endif

ARCH_x86_COMPILEFLAGS += -target x86_64-$(CLANG_X86_64_TARGET_SYS)-$(CLANG_X86_64_TARGET_ABI) \
				--gcc-toolchain=$(CLANG_X86_64_AS_DIR)/

endif
endif

