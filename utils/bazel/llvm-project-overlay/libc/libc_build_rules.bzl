# This file is licensed under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

"""LLVM libc starlark rules for building individual functions."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:selects.bzl", "selects")
load(":libc_configure_options.bzl", "LIBC_CONFIGURE_OPTIONS")
load(":libc_namespace.bzl", "LIBC_NAMESPACE")
load(":platforms.bzl", "PLATFORM_CPU_X86_64")

def libc_internal_target(name):
    return name + ".__internal__"

def libc_common_copts():
    root_label = Label(":libc")
    libc_include_path = paths.join(root_label.workspace_root, root_label.package)
    return [
        "-I" + libc_include_path,
        "-I" + paths.join(libc_include_path, "include"),
        "-DLIBC_NAMESPACE=" + LIBC_NAMESPACE,
    ]

def _libc_library(name, hidden, copts = [], deps = [], local_defines = [], **kwargs):
    """Internal macro to serve as a base for all other libc library rules.

    Args:
      name: Target name.
      copts: The special compiler options for the target.
      deps: The list of target dependencies if any.
      local_defines: The list of target local_defines if any.
      hidden: Whether the symbols should be explicitly hidden or not.
      **kwargs: All other attributes relevant for the cc_library rule.
    """

    # We want all libc sources to be compiled with "hidden" visibility.
    # The public symbols will be given "default" visibility explicitly.
    # See src/__support/common.h for more information.
    if hidden:
        copts = copts + ["-fvisibility=hidden"]
    native.cc_library(
        name = name,
        copts = copts + libc_common_copts(),
        local_defines = local_defines + LIBC_CONFIGURE_OPTIONS,
        deps = deps,
        linkstatic = 1,
        **kwargs
    )

# A convenience function which should be used to list all libc support libraries.
# Any library which does not define a public function should be listed with
# libc_support_library.
def libc_support_library(name, **kwargs):
    _libc_library(name = name, hidden = False, **kwargs)

def libc_function(
        name,
        srcs,
        weak = False,
        copts = None,
        local_defines = [],
        **kwargs):
    """Add target for a libc function.

    The libc function is eventually available as a cc_library target by name
    "name". LLVM libc implementations of libc functions are in C++. So, this
    rule internally generates a C wrapper for the C++ implementation and adds
    it to the source list of the cc_library. This way, the C++ implementation
    and the C wrapper are both available in the cc_library.

    Args:
      name: Target name. It is normally the name of the function this target is
            for.
      srcs: The .cpp files which contain the function implementation.
      weak: Make the symbol corresponding to the libc function "weak".
      copts: The list of options to add to the C++ compilation command.
      local_defines: The preprocessor defines which will be prepended with -D
                     and passed to the compile command of this target but not
                     its deps.
      **kwargs: Other attributes relevant for a cc_library. For example, deps.
    """

    # We use the explicit equals pattern here because append and += mutate the
    # original list, where this creates a new list and stores it in deps.
    copts = copts or []
    copts = copts + [
        "-O3",
        "-fno-builtin",
        "-fno-lax-vector-conversions",
        "-ftrivial-auto-var-init=pattern",
        "-fno-omit-frame-pointer",
        "-fstack-protector-strong",
    ]

    # x86 targets have -mno-omit-leaf-frame-pointer.
    platform_copts = selects.with_or({
        PLATFORM_CPU_X86_64: ["-mno-omit-leaf-frame-pointer"],
        "//conditions:default": [],
    })
    copts = copts + platform_copts

    # We compile the code twice, the first target is suffixed with ".__internal__" and contains the
    # C++ functions in the "LIBC_NAMESPACE" namespace. This allows us to test the function in the
    # presence of another libc.
    libc_support_library(
        name = libc_internal_target(name),
        srcs = srcs,
        copts = copts,
        local_defines = local_defines,
        **kwargs
    )

    # This second target is the llvm libc C function with either a default or hidden visibility.
    # All other functions are hidden.
    func_attrs = [
        "LLVM_LIBC_FUNCTION_ATTR_" + name + "='LLVM_LIBC_EMPTY, [[gnu::weak]]'",
    ] if weak else []

    local_defines = (local_defines +
                     ["LIBC_COPT_PUBLIC_PACKAGING"] +
                     ["LLVM_LIBC_FUNCTION_ATTR='[[gnu::visibility(\"default\")]]'"] +
                     func_attrs)
    _libc_library(
        name = name,
        hidden = True,
        srcs = srcs,
        copts = copts,
        local_defines = local_defines,
        **kwargs
    )

def libc_math_function(
        name,
        additional_deps = None):
    """Add a target for a math function.

    Args:
      name: The name of the function.
      additional_deps: Other deps like helper cc_library targes used by the
                       math function.
    """
    additional_deps = additional_deps or []

    #TODO(michaelrj): Fix the floating point dependencies
    OLD_FPUTIL_DEPS = [
        ":__support_fputil_basic_operations",
        ":__support_fputil_division_and_remainder_operations",
        ":__support_fputil_fenv_impl",
        ":__support_fputil_fp_bits",
        ":__support_fputil_hypot",
        ":__support_fputil_manipulation_functions",
        ":__support_fputil_nearest_integer_operations",
        ":__support_fputil_normal_float",
        ":__support_math_extras",
        ":__support_fputil_except_value_utils",
    ]
    libc_function(
        name = name,
        srcs = ["src/math/generic/" + name + ".cpp"],
        hdrs = ["src/math/" + name + ".h"],
        deps = [":__support_common"] + OLD_FPUTIL_DEPS + additional_deps,
    )
