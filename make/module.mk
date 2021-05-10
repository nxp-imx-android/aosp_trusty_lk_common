
# modules
#
# args:
# MODULE : module name (required)
# MODULE_SRCS : list of source files, local path (required)
# MODULE_DEPS : other modules that this one depends on
# MODULE_DEFINES : #defines local to this module
# MODULE_OPTFLAGS : OPTFLAGS local to this module
# MODULE_COMPILEFLAGS : COMPILEFLAGS local to this module
# MODULE_CFLAGS : CFLAGS local to this module
# MODULE_CPPFLAGS : CPPFLAGS local to this module
# MODULE_ASMFLAGS : ASMFLAGS local to this module
# MODULE_INCLUDES : include directories local to this module
# MODULE_SRCDEPS : extra dependencies that all of this module's files depend on
# MODULE_EXTRA_ARCHIVES : extra .a files that should be linked with the module
# MODULE_EXTRA_OBJS : extra .o files that should be linked with the module
# MODULE_DISABLE_LTO : disable LTO for this module
# MODULE_DISABLE_CFI : disable CFI for this module
# MODULE_DISABLE_STACK_PROTECTOR : disable stack protector for this module
# MODULE_DISABLE_SCS : disable shadow call stack for this module

# MODULE_ARM_OVERRIDE_SRCS : list of source files, local path that should be force compiled with ARM (if applicable)

# the minimum module rules.mk file is as follows:
#
# LOCAL_DIR := $(GET_LOCAL_DIR)
# MODULE := $(LOCAL_DIR)
#
# MODULE_SRCS := $(LOCAL_DIR)/at_least_one_source_file.c
#
# include make/module.mk

# test for old style rules.mk
ifneq ($(MODULE_OBJS),)
$(warning MODULE_OBJS = $(MODULE_OBJS))
$(error MODULE $(MODULE) is setting MODULE_OBJS, change to MODULE_SRCS)
endif
ifneq ($(OBJS),)
$(warning OBJS = $(OBJS))
$(error MODULE $(MODULE) is probably setting OBJS, change to MODULE_SRCS)
endif

MODULE_SRCDIR := $(MODULE)
MODULE_BUILDDIR := $(call TOBUILDDIR,$(MODULE_SRCDIR))

# add a local include dir to the global include path
GLOBAL_INCLUDES += $(MODULE_SRCDIR)/include

# add the listed module deps to the global list
MODULES += $(MODULE_DEPS)

#$(info module $(MODULE))
#$(info MODULE_SRCDIR $(MODULE_SRCDIR))
#$(info MODULE_BUILDDIR $(MODULE_BUILDDIR))
#$(info MODULE_DEPS $(MODULE_DEPS))
#$(info MODULE_SRCS $(MODULE_SRCS))

MODULE_DEFINES += MODULE_COMPILEFLAGS=\"$(subst $(SPACE),_,$(MODULE_COMPILEFLAGS))\"
MODULE_DEFINES += MODULE_CFLAGS=\"$(subst $(SPACE),_,$(MODULE_CFLAGS))\"
MODULE_DEFINES += MODULE_CPPFLAGS=\"$(subst $(SPACE),_,$(MODULE_CPPFLAGS))\"
MODULE_DEFINES += MODULE_ASMFLAGS=\"$(subst $(SPACE),_,$(MODULE_ASMFLAGS))\"
MODULE_DEFINES += MODULE_LDFLAGS=\"$(subst $(SPACE),_,$(MODULE_LDFLAGS))\"
MODULE_DEFINES += MODULE_OPTFLAGS=\"$(subst $(SPACE),_,$(MODULE_OPTFLAGS))\"
MODULE_DEFINES += MODULE_INCLUDES=\"$(subst $(SPACE),_,$(MODULE_INCLUDES))\"
MODULE_DEFINES += MODULE_SRCDEPS=\"$(subst $(SPACE),_,$(MODULE_SRCDEPS))\"
MODULE_DEFINES += MODULE_DEPS=\"$(subst $(SPACE),_,$(MODULE_DEPS))\"
MODULE_DEFINES += MODULE_SRCS=\"$(subst $(SPACE),_,$(MODULE_SRCS))\"

# LTO
MODULE_LTO_ENABLED := false
ifneq (true,$(call TOBOOL,$(MODULE_DISABLE_LTO)))
ifeq (true,$(call TOBOOL,$(USER_TASK_MODULE)))

ifeq (true,$(call TOBOOL,$(USER_LTO_ENABLED)))
MODULE_LTO_ENABLED := true
endif

else

ifeq (true,$(call TOBOOL,$(KERNEL_LTO_ENABLED)))
MODULE_LTO_ENABLED := true
endif

endif
endif

ifeq (true,$(call TOBOOL,$(MODULE_LTO_ENABLED)))
MODULE_COMPILEFLAGS += -fvisibility=hidden -flto=thin

# CFI
MODULE_CFI_ENABLED := false
ifneq (true,$(call TOBOOL,$(MODULE_DISABLE_CFI)))
ifeq (true,$(call TOBOOL,$(CFI_ENABLED)))
MODULE_CFI_ENABLED := true
endif

ifeq (true,$(call TOBOOL,$(USER_TASK_MODULE)))

ifdef $(USER_CFI_ENABLED)
MODULE_CFI_ENABLED := $(call TOBOOL,$(USER_CFI_ENABLED))
endif

else

ifdef $(KERNEL_CFI_ENABLED)
MODULE_CFI_ENABLED := $(call TOBOOL,$(KERNEL_CFI_ENABLED))
endif

endif
endif

ifeq (true,$(call TOBOOL,$(MODULE_CFI_ENABLED)))
MODULE_COMPILEFLAGS += -fsanitize=cfi -DCFI_ENABLED
MODULES += trusty/kernel/lib/ubsan

ifeq (true,$(call TOBOOL,$(CFI_DIAGNOSTICS)))
MODULE_COMPILEFLAGS += -fno-sanitize-trap=cfi
endif
endif

endif

# Stack protector
ifneq (true,$(call TOBOOL,$(MODULE_DISABLE_STACK_PROTECTOR)))
ifeq (true,$(call TOBOOL,$(USER_TASK_MODULE)))
ifeq (true,$(call TOBOOL,$(USER_STACK_PROTECTOR)))
MODULE_COMPILEFLAGS += -fstack-protector-strong
endif
endif
else
MODULE_COMPILEFLAGS += -fno-stack-protector
endif

# Shadow call stack
ifeq (true,$(call TOBOOL,$(SCS_ENABLED)))
# set in arch/$(ARCH)/toolchain.mk iff shadow call stack is supported
ifeq (false,$(call TOBOOL,$(ARCH_$(ARCH)_SUPPORTS_SCS)))
$(error Error: Shadow call stack is not supported for $(ARCH))
endif

ifeq (false,$(call TOBOOL,$(MODULE_DISABLE_SCS)))
# architectures that support SCS should set the flag that reserves
# a register for the shadow call stack in their toolchain.mk file
MODULE_COMPILEFLAGS += \
	-fsanitize=shadow-call-stack \

endif
endif

# Code coverage
ifeq (true,$(call TOBOOL,$(USER_COVERAGE_ENABLED)))
ifeq (true,$(call TOBOOL,$(USER_TASK_MODULE)))
ifeq (false,$(call TOBOOL, $(APP_DISABLE_COVERAGE)))
MODULES += trusty/user/base/lib/sancov

# -fno-optimize-sibling-calls is necessary to get correct caller information in
# the sancov instrumentation.
MODULE_COMPILEFLAGS += \
	-fsanitize-coverage-blocklist=trusty/user/base/lib/sancov/exemptlist \
	-fsanitize-coverage=trace-pc-guard \
	-fno-optimize-sibling-calls

endif
endif
endif

# HWASan
ifeq (true,$(call TOBOOL,$(USER_HWASAN_ENABLED)))
MODULE_DEFINES += \
	HWASAN_ENABLED=1 \
	HWASAN_SHADOW_SCALE=4 \

ifeq (true,$(call TOBOOL,$(USER_TASK_MODULE)))
MODULES += trusty/user/base/lib/hwasan
MODULE_COMPILEFLAGS += \
	-fsanitize-blacklist=trusty/user/base/lib/hwasan/exemptlist \
	-fsanitize=hwaddress \
	-mllvm -hwasan-with-tls=0 \
	-mllvm -hwasan-globals=0 \
	-mllvm -hwasan-use-short-granules=0 \

endif
endif

# generate a per-module config.h file
MODULE_CONFIG := $(MODULE_BUILDDIR)/module_config.h

$(MODULE_CONFIG): MODULE_DEFINES:=$(MODULE_DEFINES)
$(MODULE_CONFIG): configheader
	@$(call MAKECONFIGHEADER,$@,MODULE_DEFINES)

GENERATED += $(MODULE_CONFIG)

MODULE_COMPILEFLAGS += --include $(MODULE_CONFIG)

MODULE_SRCDEPS += $(MODULE_CONFIG)

MODULE_INCLUDES := $(addprefix -I,$(MODULE_INCLUDES))

# include the rules to compile the module's object files
include make/compile.mk

# MODULE_OBJS is passed back from compile.mk
#$(info MODULE_OBJS = $(MODULE_OBJS))

# Archive the module's object files into a static library.
MODULE_OBJECT := $(call TOBUILDDIR,$(MODULE_SRCDIR).mod.a)
$(MODULE_OBJECT): $(MODULE_OBJS) $(MODULE_EXTRA_OBJS)
	@$(MKDIR)
	@echo creating $@
	$(NOECHO)rm -f $@
	$(NOECHO)$(AR) rcs $@ $^

# track the module object for make clean
GENERATED += $(MODULE_OBJECT)

# make the rest of the build depend on our output
ALLMODULE_OBJS := $(MODULE_INIT_OBJS) $(ALLMODULE_OBJS) $(MODULE_OBJECT) $(MODULE_EXTRA_ARCHIVES)

# track all of the source files compiled
ALLSRCS += $(MODULE_SRCS_FIRST) $(MODULE_SRCS)

# track all the objects built
ALLOBJS += $(MODULE_INIT_OBJS) $(MODULE_OBJS)

# empty out any vars set here
MODULE :=
MODULE_SRCDIR :=
MODULE_BUILDDIR :=
MODULE_DEPS :=
MODULE_SRCS :=
MODULE_OBJS :=
MODULE_DEFINES :=
MODULE_OPTFLAGS :=
MODULE_COMPILEFLAGS :=
MODULE_CFLAGS :=
MODULE_CPPFLAGS :=
MODULE_ASMFLAGS :=
MODULE_SRCDEPS :=
MODULE_INCLUDES :=
MODULE_EXTRA_ARCHIVES :=
MODULE_EXTRA_OBJS :=
MODULE_CONFIG :=
MODULE_OBJECT :=
MODULE_ARM_OVERRIDE_SRCS :=
MODULE_SRCS_FIRST :=
MODULE_INIT_OBJS :=
MODULE_DISABLE_LTO :=
MODULE_LTO_ENABLED :=
MODULE_DISABLE_CFI :=
MODULE_DISABLE_STACK_PROTECTOR :=
MODULE_DISABLE_SCS :=
