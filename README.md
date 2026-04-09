# How do I submit patches to Android Common Kernels

1. **BEST:** Make all of your changes to upstream Linux. If appropriate, backport to the stable releases.
   These patches will be merged automatically in the corresponding common kernels. If the patch is already
   in upstream Linux, post a backport of the patch that conforms to the patch requirements below.
   - Do not send patches upstream that contain only symbol exports. To be considered for upstream Linux,
     additions of `EXPORT_SYMBOL_GPL()` require an in-tree modular driver that uses the symbol — so include
     the new driver or changes to an existing driver in the same patchset as the export.
   - When sending patches upstream, the commit message must contain a clear case for why the patch
     is needed and beneficial to the community. Enabling out-of-tree drivers or functionality is not
     a persuasive case.

2. **LESS GOOD:** Develop your patches out-of-tree (from an upstream Linux point of view). Unless these are
   fixing an Android-specific bug, these are very unlikely to be accepted unless they have been
   coordinated with `kernel-team@android.com`. If you want to proceed, post a patch that conforms to the
   patch requirements below.

# Common Kernel patch requirements

- All patches must conform to the Linux kernel coding standards and pass `scripts/checkpatch.pl`
- Patches shall not break `gki_defconfig` or `allmodconfig` builds for `arm`, `arm64`, `x86`, `x86_64` architectures
  (see <https://source.android.com/setup/build/building-kernels>)
- If the patch is not merged from an upstream branch, the subject must be tagged with the type of patch:
  `UPSTREAM:`, `BACKPORT:`, `FROMGIT:`, `FROMLIST:`, or `ANDROID:`.
- All patches must have a `Change-Id:` tag
  (see <https://gerrit-review.googlesource.com/Documentation/user-changeid.html>)
- If an Android bug has been assigned, there must be a `Bug:` tag.
- All patches must have a `Signed-off-by:` tag by the author and the submitter.

Additional requirements are listed below based on patch type.

## Requirements for backports from mainline Linux: `UPSTREAM:`, `BACKPORT:`

- If the patch is a cherry-pick from Linux mainline with no changes at all:
  - tag the patch subject with `UPSTREAM:`
  - add upstream commit information with a `(cherry picked from commit ...)` line

Example:

```text
UPSTREAM: important patch from upstream

This is the detailed description of the important patch

Signed-off-by: Fred Jones <fred.jones@foo.org>

Bug: 135791357
Change-Id: I4caaaa566ea080fa148c5e768bb1a0b6f7201c01
(cherry picked from commit c31e73121f4c1ec41143423ac6ce3ce6dafdcec1)
Signed-off-by: Joe Smith <joe.smith@foo.org>
```

- If the patch requires any changes from the upstream version, tag the patch with `BACKPORT:`
  instead of `UPSTREAM:`
  - use the same tags as `UPSTREAM:`
  - add comments about the changes under the `(cherry picked from commit ...)` line

Example:

```text
BACKPORT: important patch from upstream

This is the detailed description of the important patch

Signed-off-by: Fred Jones <fred.jones@foo.org>

Bug: 135791357
Change-Id: I4caaaa566ea080fa148c5e768bb1a0b6f7201c01
(cherry picked from commit c31e73121f4c1ec41143423ac6ce3ce6dafdcec1)
[joe: Resolved minor conflict in drivers/foo/bar.c ]
Signed-off-by: Joe Smith <joe.smith@foo.org>
```

## Requirements for other backports: `FROMGIT:`, `FROMLIST:`

- If the patch has been merged into an upstream maintainer tree, but has not yet
  been merged into Linux mainline:
  - tag the patch subject with `FROMGIT:`
  - add info on where the patch came from as
    `(cherry picked from commit <sha1> <repo> <branch>)`
  - if changes were required, use `BACKPORT: FROMGIT:`

Example:

```text
FROMGIT: important patch from upstream

This is the detailed description of the important patch

Signed-off-by: Fred Jones <fred.jones@foo.org>

Bug: 135791357
(cherry picked from commit 878a2fd9de10b03d11d2f622250285c7e63deace
 https://git.kernel.org/pub/scm/linux/kernel/git/foo/bar.git test-branch)
Change-Id: I4caaaa566ea080fa148c5e768bb1a0b6f7201c01
Signed-off-by: Joe Smith <joe.smith@foo.org>
```

- If the patch has been submitted to LKML, but not accepted into any maintainer tree:
  - tag the patch subject with `FROMLIST:`
  - add a `Link:` tag with a link to the submission on `lore.kernel.org`
  - add a `Bug:` tag with the Android bug
  - if changes were required, use `BACKPORT: FROMLIST:`

Example:

```text
FROMLIST: important patch from upstream

This is the detailed description of the important patch

Signed-off-by: Fred Jones <fred.jones@foo.org>

Bug: 135791357
Link: https://lore.kernel.org/lkml/20190619171517.GA17557@someone.com/
Change-Id: I4caaaa566ea080fa148c5e768bb1a0b6f7201c01
Signed-off-by: Joe Smith <joe.smith@foo.org>
```

## Requirements for Android-specific patches: `ANDROID:`

- If the patch is fixing a bug in Android-specific code:
  - tag the patch subject with `ANDROID:`
  - add a `Fixes:` tag that cites the patch with the bug

Example:

```text
ANDROID: fix android-specific bug in foobar.c

This is the detailed description of the important fix

Fixes: 1234abcd2468 ("foobar: add cool feature")
Change-Id: I4caaaa566ea080fa148c5e768bb1a0b6f7201c01
Signed-off-by: Joe Smith <joe.smith@foo.org>
```

- If the patch is a new feature:
  - tag the patch subject with `ANDROID:`
  - add a `Bug:` tag with the Android bug

## How to compile this project

This project is built with a custom `make`-based build script instead of relying on the original Bazel/Kleaf build flow.

### Why this script exists

The official build method for this kernel tree uses Bazel/Kleaf. That method is useful for generating standard outputs, but for this project it is too restrictive because direct control is needed over:

- the merged kernel configuration used for compilation;
- the raw kernel build with `make`;
- the separation of kernel modules into `vendor_boot`, `vendor_dlkm`, and `system_dlkm`;
- the generation of module metadata such as `modules.dep`, `modules.load`, `modules.alias`, and `modules.softdep`;
- the optional reconstruction of `vendor_boot.img` using a stock base ramdisk plus modules rebuilt from source.

In other words, this script does **not** simply invoke the official Bazel target.  
It replaces the Bazel/Kleaf flow with a controlled `make`-based build process tailored for this project.

### What the script does

The build script performs the following steps:

1. configures the kernel build using the merged defconfig extracted from the Bazel/Kleaf flow;
2. builds the kernel with `make` using Clang/LLVM;
3. builds and installs kernel modules inside the source tree output directories;
4. splits the modules into logical sections:
   - `vendor_boot`
   - `vendor_dlkm`
   - `system_dlkm`
5. generates module dependency and load metadata for each section;
6. optionally creates a `vendor_boot.img` using:
   - a stock base ramdisk (fragment 0),
   - a rebuilt `dlkm` ramdisk fragment generated from the newly compiled modules.

### Requirements

Before running the script, make sure that:

- the kernel source tree is located at the expected path;
- the Clang toolchain exists and matches the path passed in `CLANG_BIN`;
- the merged defconfig exists at `arch/arm64/configs/exynos2400_r12s_defconfig`;
- the stock `vendor_boot` base ramdisk has already been extracted and placed in a directory such as
  `build/vendor_boot_base/r12s`;
- the stock base ramdisk directory does **not** contain stock kernel modules, because the script injects rebuilt modules separately into the `dlkm` ramdisk fragment.

### Example build command

```bash
BUILD_CONFIG_FILE=$PWD/projects/s5e9945/build.config.s5e9945_user \
MERGED_DEFCONFIG=$PWD/arch/arm64/configs/exynos2400_r12s_defconfig \
CLANG_BIN=$PWD/../prebuilts/clang/host/linux-x86/clang-r487747c/bin \
USE_MERGED_DEFCONFIG=1 \
TARGET_SOC=s5e9945 \
DEVICE_CODENAME=r12s \
BUILD_VARIANT=user \
AUTO_MRPROPER=0 \
BUILD_VENDOR_BOOT_IMG=1 \
VENDOR_RAMDISK_BASE_DIR=$PWD/build/vendor_boot_base/r12s \
./build_exynos2400.sh
```

### Variable description

- `BUILD_CONFIG_FILE`  
  Points to the Samsung project build config used by this device tree.

- `MERGED_DEFCONFIG`  
  Points to the merged defconfig extracted from the Bazel/Kleaf configuration flow.

- `CLANG_BIN`  
  Path to the Clang/LLVM toolchain binaries. In this project layout, the toolchain is stored outside the kernel source root.

- `USE_MERGED_DEFCONFIG=1`  
  Tells the script to use the merged defconfig directly instead of a regular in-tree defconfig target.

- `TARGET_SOC=s5e9945`  
  Selects the SoC/platform identifier used by the build logic.

- `DEVICE_CODENAME=r12s`  
  Selects the device-specific module grouping and output naming.

- `BUILD_VARIANT=user`  
  Defines the build variant.

- `AUTO_MRPROPER=0`  
  Prevents automatic source tree cleanup. Set this to `1` if you want the script to automatically run `make mrproper` when required.

- `BUILD_VENDOR_BOOT_IMG=1`  
  Enables `vendor_boot.img` generation.

- `VENDOR_RAMDISK_BASE_DIR`  
  Path to the extracted stock vendor boot base ramdisk (fragment 0). This directory must contain only the base ramdisk files, not the stock kernel modules.

### Important note

This script is designed for this project and this kernel tree layout.  
You may need to adjust paths such as:

- `CLANG_BIN`
- `BUILD_CONFIG_FILE`
- `MERGED_DEFCONFIG`
- `VENDOR_RAMDISK_BASE_DIR`

if your local environment is different.

This is **not** a generic Android kernel build wrapper.  
It is a project-specific build flow created to provide manual control over the Exynos 2400 kernel, module packaging, and vendor boot construction.
