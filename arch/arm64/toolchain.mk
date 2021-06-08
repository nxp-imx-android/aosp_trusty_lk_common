ifndef ARCH_arm64_TOOLCHAIN_PREFIX
$(error Please run envsetup.sh to set ARCH_arm64_TOOLCHAIN_PREFIX)
endif

ifeq (false,$(call TOBOOL,$(ALLOW_FP_USE)))
ARCH_arm64_COMPILEFLAGS := -mgeneral-regs-only -DWITH_NO_FP=1
else
ARCH_arm64_COMPILEFLAGS :=
endif

ARCH_arm64_SUPPORTS_SCS := true
ARCH_arm64_DEFAULT_USER_SHADOW_STACK_SIZE ?= $(ARCH_DEFAULT_SHADOW_STACK_SIZE)
ifeq (true,$(call TOBOOL,$(SCS_ENABLED)))
# architecture-specific flag required for shadow call stack
ARCH_arm64_COMPILEFLAGS += -ffixed-x18
endif

ifeq ($(call TOBOOL,$(CLANGBUILD)),true)

CLANG_ARM64_TARGET_SYS ?= linux
CLANG_ARM64_TARGET_ABI ?= gnu

CLANG_ARM64_AS_DIR ?= $(shell dirname $(shell dirname $(ARCH_arm64_TOOLCHAIN_PREFIX)))

ARM64_AS_PATH ?= $(wildcard $(CLANG_ARM64_AS_DIR)/*/bin/as)
ifeq ($(ARM64_AS_PATH),)
$(error Could not find $(CLANG_ARM64_AS_DIR)/*/bin/as, did the directory structure change?)
endif

ARCH_arm64_COMPILEFLAGS += -target aarch64-$(CLANG_ARM64_TARGET_SYS)-$(CLANG_ARM64_TARGET_ABI) \
			   --gcc-toolchain=$(CLANG_ARM64_AS_DIR)/

endif
