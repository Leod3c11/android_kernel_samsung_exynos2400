#!/usr/bin/env bash
set -Eeuo pipefail

# Exynos 2400 / s5e9945 make-based build helper.
# Focus: build kernel + split modules into Android-style buckets.
# Optional: build vendor_boot.img in a stock-like layout.
# No staging outside the source tree.
# Mirrors Kleaf extract_modules.bzl more closely.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

log() { printf '[exynos2400-make] %s\n' "$*"; }
warn() { printf '[exynos2400-make][warn] %s\n' "$*" >&2; }
die() { printf '[exynos2400-make][error] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

TARGET_SOC="${TARGET_SOC:-s5e9945}"
DEVICE_CODENAME="${DEVICE_CODENAME:-r12s}"
BUILD_VARIANT="${BUILD_VARIANT:-user}"
KERNEL_DIR="${KERNEL_DIR:-.}"
JOBS="${JOBS:-$(nproc --all 2>/dev/null || echo 8)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/${TARGET_SOC}_${BUILD_VARIANT}_make}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/out/${TARGET_SOC}_${BUILD_VARIANT}_dist}"
MAKE_GOALS="${MAKE_GOALS:-Image modules dtbs}"
KERNEL_BINARY="${KERNEL_BINARY:-Image}"
CLEAN_BUILD="${CLEAN_BUILD:-0}"
AUTO_MRPROPER="${AUTO_MRPROPER:-1}"
STRICT_MISSING_MODULES="${STRICT_MISSING_MODULES:-0}"
INSTALL_MOD_STRIP="${INSTALL_MOD_STRIP:-1}"
USE_MERGED_DEFCONFIG="${USE_MERGED_DEFCONFIG:-1}"
MERGED_DEFCONFIG="${MERGED_DEFCONFIG:-$ROOT_DIR/arch/arm64/configs/exynos2400_r12s_defconfig}"
DEFCONFIG_TARGET="${DEFCONFIG_TARGET:-${DEVICE_CODENAME}_defconfig}"
BUILD_CONFIG_FILE="${BUILD_CONFIG_FILE:-$ROOT_DIR/projects/s5e9945/build.config.s5e9945_user}"
PROJECT_DIR="${PROJECT_DIR:-$ROOT_DIR/projects/s5e9945}"
MODULES_BZL="${MODULES_BZL:-$PROJECT_DIR/s5e9945_modules.bzl}"
MODEL_VARIANT_BZL="${MODEL_VARIANT_BZL:-$PROJECT_DIR/s5e9945_${DEVICE_CODENAME}_modules.bzl}"
SYSTEM_MODULES_BZL="${SYSTEM_MODULES_BZL:-$ROOT_DIR/modules.bzl}"
LEGO_BZL="${LEGO_BZL:-$ROOT_DIR/lego.bzl}"
KUNIT_BZL="${KUNIT_BZL:-$ROOT_DIR/kunit.bzl}"
EXTRA_VENDOR_BOOT_LIST_FILES="${EXTRA_VENDOR_BOOT_LIST_FILES:-}"
EXTRA_VENDOR_DLKM_LIST_FILES="${EXTRA_VENDOR_DLKM_LIST_FILES:-}"
EXTRA_SYSTEM_DLKM_LIST_FILES="${EXTRA_SYSTEM_DLKM_LIST_FILES:-}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
CLANG_BIN="${CLANG_BIN:-$ROOT_DIR/../prebuilts/clang/host/linux-x86/clang-r487747c/bin}"
USE_REAL_KERNEL_RELEASE="${USE_REAL_KERNEL_RELEASE:-0}"
BUILD_VENDOR_BOOT_IMG="${BUILD_VENDOR_BOOT_IMG:-0}"
MKBOOTIMG="${MKBOOTIMG:-}"
VENDOR_RAMDISK_BASE_DIR="${VENDOR_RAMDISK_BASE_DIR:-}"
VENDOR_BOOT_IMAGE_OUT="${VENDOR_BOOT_IMAGE_OUT:-$DIST_DIR/vendor_boot.img}"
VENDOR_BOOTCONFIG_OUT="${VENDOR_BOOTCONFIG_OUT:-$DIST_DIR/vendor-bootconfig.txt}"
VENDOR_BOOTCONFIG_FILE="${VENDOR_BOOTCONFIG_FILE:-}"
VENDOR_BOOTCONFIG_TEXT="${VENDOR_BOOTCONFIG_TEXT:-buildtime_bootconfig=enable
androidboot.serialconsole=0}"
VENDOR_BOOT_HEADER_VERSION="${VENDOR_BOOT_HEADER_VERSION:-4}"
VENDOR_BOOT_PAGESIZE="${VENDOR_BOOT_PAGESIZE:-2048}"
VENDOR_BOOT_BOARD="${VENDOR_BOOT_BOARD:-SRPXD17A003}"
VENDOR_BOOT_BASE="${VENDOR_BOOT_BASE:-0x00000000}"
VENDOR_BOOT_KERNEL_OFFSET="${VENDOR_BOOT_KERNEL_OFFSET:-0x10008000}"
VENDOR_BOOT_RAMDISK_OFFSET="${VENDOR_BOOT_RAMDISK_OFFSET:-0x10000000}"
VENDOR_BOOT_TAGS_OFFSET="${VENDOR_BOOT_TAGS_OFFSET:-0x10000000}"
VENDOR_BOOT_DTB_OFFSET="${VENDOR_BOOT_DTB_OFFSET:-0x0000000011F00000}"
VENDOR_BOOT_CMDLINE="${VENDOR_BOOT_CMDLINE:-bootconfig loop.max_part=7}"
VENDOR_DTB_IMAGE="${VENDOR_DTB_IMAGE:-}"
VENDOR_FSTAB="${VENDOR_FSTAB:-}"
VENDOR_INIT_RECOVERY_RC="${VENDOR_INIT_RECOVERY_RC:-}"
VENDOR_INIT_USB_RC="${VENDOR_INIT_USB_RC:-}"
VENDOR_FIRMWARE_SGPU="${VENDOR_FIRMWARE_SGPU:-}"
VENDOR_PREBUILT_SYSTEM_FILES_TAR="${VENDOR_PREBUILT_SYSTEM_FILES_TAR:-}"
ALLOW_MINIMAL_VENDOR_RAMDISK="${ALLOW_MINIMAL_VENDOR_RAMDISK:-0}"

SRC_DIR="$(cd "$ROOT_DIR/$KERNEL_DIR" && pwd)"

normalize_list_file() {
  local file="$1"
  [[ -f "$file" ]] || { : > "$file"; return 0; }
  awk 'NF && $0 !~ /^[[:space:]]*#/' "$file" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | awk '!seen[$0]++' > "${file}.tmp"
  mv -f "${file}.tmp" "$file"
}

parse_bzl_list_to_file() {
  local src="$1"
  local var_name="$2"
  local out="$3"
  [[ -f "$src" ]] || { : > "$out"; return 0; }
  python3 - "$src" "$var_name" "$out" <<'PY'
import re, sys
src, var_name, out = sys.argv[1:4]
text = open(src, 'r', encoding='utf-8').read()
lines = []
for line in text.splitlines():
    if re.match(r'^\s*#', line):
        continue
    lines.append(line)
text = '\n'.join(lines)
pat = re.compile(r'\b%s\s*=\s*\[(.*?)\]' % re.escape(var_name), re.S)
m = pat.search(text)
items = []
if m:
    items = re.findall(r'"([^"]+\.ko)"', m.group(1))
with open(out, 'w', encoding='utf-8') as f:
    for item in items:
        f.write(item + '\n')
PY
}

append_list_var() {
  local src="$1"
  local var_name="$2"
  local out="$3"
  [[ -f "$src" ]] || return 0
  python3 - "$src" "$var_name" "$out" <<'PY'
import re, sys
src, var_name, out = sys.argv[1:4]
text = open(src, 'r', encoding='utf-8').read()
pat = re.compile(r'\b%s\s*=\s*\[(.*?)\]' % re.escape(var_name), re.S)
m = pat.search(text)
items = []
if m:
    items = re.findall(r'"([^"]+\.ko)"', m.group(1))
with open(out, 'a', encoding='utf-8') as f:
    for item in items:
        f.write(item + '\n')
PY
}

find_clang_bin() {
  if [[ -n "$CLANG_BIN" && -x "$CLANG_BIN/clang" ]]; then
    printf '%s\n' "$CLANG_BIN"
    return 0
  fi
  local d
  for d in \
    "$ROOT_DIR/../prebuilts/clang/host/linux-x86" \
    "$ROOT_DIR/prebuilts/clang/host/linux-x86" \
    "$ROOT_DIR/prebuilts-master/clang/host/linux-x86" \
    "$ROOT_DIR/toolchain"; do
    [[ -d "$d" ]] || continue
    local found
    found="$(find "$d" -type f -name clang 2>/dev/null | sort | tail -n1 | xargs -r dirname || true)"
    if [[ -n "$found" && -x "$found/clang" ]]; then
      printf '%s\n' "$found"
      return 0
    fi
  done
  if command -v clang >/dev/null 2>&1; then
    dirname "$(command -v clang)"
    return 0
  fi
  return 1
}

setup_toolchain() {
  local clang_dir
  clang_dir="$(find_clang_bin)" || die "clang not found"
  export PATH="$clang_dir:$PATH"
  export ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE
  export CC="$clang_dir/clang"
  export HOSTCC="$clang_dir/clang"
  export HOSTCXX="$clang_dir/clang++"
  export LD="$clang_dir/ld.lld"
  export AR="$clang_dir/llvm-ar"
  export NM="$clang_dir/llvm-nm"
  export STRIP="$clang_dir/llvm-strip"
  export OBJCOPY="$clang_dir/llvm-objcopy"
  export OBJDUMP="$clang_dir/llvm-objdump"
  export READELF="$clang_dir/llvm-readelf"
  export DTC_FLAGS='-@'
  log "Using clang: $clang_dir"
  "$CC" --version | head -n1 || true
}

list_source_tree_dirty_markers() {
  local markers=(
    ".config" ".config.old" "Module.symvers" "modules.order" ".version" ".old_version"
    ".tmp_versions" "include/config" "include/generated" "arch/arm64/include/generated"
  )
  local marker
  for marker in "${markers[@]}"; do
    [[ -e "$SRC_DIR/$marker" ]] && printf '%s\n' "$marker"
  done
}

ensure_clean_source_tree_for_o_build() {
  local probe_out probe_rc
  set +e
  probe_out="$(make -C "$SRC_DIR" O="$OUT_DIR" kernelversion 2>&1)"
  probe_rc=$?
  set -e
  if [[ $probe_rc -eq 0 ]]; then
    return 0
  fi
  if grep -q "The source tree is not clean" <<<"$probe_out"; then
    if [[ "$AUTO_MRPROPER" != "1" ]]; then
      die "source tree is not clean for O= build. Re-run with AUTO_MRPROPER=1 or clean manually with 'make mrproper'."
    fi
    warn "source tree is not clean for O= build; running 'make mrproper' automatically in the source root"
    local markers
    markers="$(list_source_tree_dirty_markers || true)"
    if [[ -n "$markers" ]]; then
      warn "generated source-tree artifacts detected:"
      while IFS= read -r line; do
        [[ -n "$line" ]] && warn "  - $line"
      done <<<"$markers"
    fi
    make -C "$SRC_DIR" mrproper
    return 0
  fi
  die "kernel O= preflight probe failed:\n$probe_out"
}

prepare_dirs() {
  [[ "$CLEAN_BUILD" == "1" ]] && rm -rf "$OUT_DIR" "$DIST_DIR"
  mkdir -p "$OUT_DIR" "$DIST_DIR"
  mkdir -p \
    "$OUT_DIR/listfiles" \
    "$OUT_DIR/install" \
    "$OUT_DIR/staging/vendor_boot" \
    "$OUT_DIR/staging/vendor_dlkm" \
    "$OUT_DIR/staging/system_dlkm" \
    "$DIST_DIR/sections/vendor_boot/lib/modules" \
    "$DIST_DIR/sections/vendor_dlkm/lib/modules" \
    "$DIST_DIR/sections/system_dlkm/lib/modules"
}

apply_config() {
  local make_cmd=(make -C "$SRC_DIR" O="$OUT_DIR")
  if [[ "$USE_MERGED_DEFCONFIG" == "1" ]]; then
    [[ -f "$MERGED_DEFCONFIG" ]] || die "merged defconfig not found: $MERGED_DEFCONFIG"
    log "Applying merged config: $MERGED_DEFCONFIG"
    cp -f "$MERGED_DEFCONFIG" "$OUT_DIR/.config"
    "${make_cmd[@]}" olddefconfig
  else
    log "Applying defconfig target: $DEFCONFIG_TARGET"
    "${make_cmd[@]}" "$DEFCONFIG_TARGET"
    "${make_cmd[@]}" olddefconfig
  fi
}

build_kernel() {
  log "Building kernel with goals: $MAKE_GOALS"
  make -C "$SRC_DIR" O="$OUT_DIR" -j"$JOBS" $MAKE_GOALS
}

install_modules_tree() {
  log "Running modules_install into source-root staging"
  rm -rf "$OUT_DIR/install"
  mkdir -p "$OUT_DIR/install"
  make -C "$SRC_DIR" O="$OUT_DIR" -j"$JOBS" \
    INSTALL_MOD_PATH="$OUT_DIR/install" \
    INSTALL_MOD_STRIP="$INSTALL_MOD_STRIP" \
    modules_install
}

get_kernel_release() {
  if [[ "$USE_REAL_KERNEL_RELEASE" == "1" ]]; then
    local rel
    rel="$(make -s -C "$SRC_DIR" O="$OUT_DIR" kernelrelease 2>/dev/null || true)"
    [[ -n "$rel" ]] && { printf '%s\n' "$rel"; return 0; }
  fi
  printf '0.0\n'
}

copy_core_outputs() {
  local candidates=(
    "$OUT_DIR/arch/arm64/boot/$KERNEL_BINARY"
    "$OUT_DIR/System.map"
    "$OUT_DIR/vmlinux"
    "$OUT_DIR/modules.builtin"
    "$OUT_DIR/modules.builtin.modinfo"
    "$OUT_DIR/modules.order"
    "$OUT_DIR/Module.symvers"
    "$OUT_DIR/.config"
    "$OUT_DIR/arch/arm64/boot/dts/exynos/${TARGET_SOC}.dtb"
  )
  local f
  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] && cp -f "$f" "$DIST_DIR/"
  done
}

build_module_lists() {
  local L="$OUT_DIR/listfiles"

  parse_bzl_list_to_file "$MODULES_BZL" VENDOR_EARLY_MODULE_LIST "$L/vendor_early.list"
  parse_bzl_list_to_file "$MODULES_BZL" VENDOR_MODULE_LIST "$L/vendor_main.list"
  parse_bzl_list_to_file "$MODULES_BZL" VENDOR_DLKM_MODULE_LIST "$L/vendor_dlkm.list"
  parse_bzl_list_to_file "$MODULES_BZL" VENDOR_DEV_MODULE_LIST "$L/vendor_dev.list"
  parse_bzl_list_to_file "$MODEL_VARIANT_BZL" MODEL_VARIANT_MODULE_LIST "$L/model_variant.list"

  : > "$L/vendor_boot_extra.list"
  : > "$L/system_dlkm_explicit.list"

  append_list_var "$LEGO_BZL" lego_module_list "$L/vendor_boot_extra.list"
  append_list_var "$KUNIT_BZL" kunit_module_list "$L/vendor_boot_extra.list"
  append_list_var "$SYSTEM_MODULES_BZL" _COMMON_GKI_MODULES_LIST "$L/system_dlkm_explicit.list"
  append_list_var "$SYSTEM_MODULES_BZL" _ARM64_GKI_MODULES_LIST "$L/system_dlkm_explicit.list"

  if [[ -n "$EXTRA_VENDOR_BOOT_LIST_FILES" ]]; then
    IFS=':' read -r -a extra_files <<< "$EXTRA_VENDOR_BOOT_LIST_FILES"
    local f
    for f in "${extra_files[@]}"; do
      [[ -n "$f" ]] && append_list_var "$f" lego_module_list "$L/vendor_boot_extra.list"
    done
  fi

  if [[ -n "$EXTRA_SYSTEM_DLKM_LIST_FILES" ]]; then
    IFS=':' read -r -a extra_files <<< "$EXTRA_SYSTEM_DLKM_LIST_FILES"
    local f
    for f in "${extra_files[@]}"; do
      [[ -n "$f" ]] && append_list_var "$f" _COMMON_GKI_MODULES_LIST "$L/system_dlkm_explicit.list"
    done
  fi

  : > "$L/vendor_boot.list"
  cat "$L/vendor_main.list" "$L/vendor_boot_extra.list" "$L/model_variant.list" >> "$L/vendor_boot.list"
  if [[ "$BUILD_VARIANT" == "eng" || "$BUILD_VARIANT" == *debug* ]]; then
    cat "$L/vendor_dev.list" >> "$L/vendor_boot.list"
  fi

  normalize_list_file "$L/vendor_early.list"
  normalize_list_file "$L/vendor_main.list"
  normalize_list_file "$L/vendor_dlkm.list"
  normalize_list_file "$L/vendor_dev.list"
  normalize_list_file "$L/model_variant.list"
  normalize_list_file "$L/vendor_boot_extra.list"
  normalize_list_file "$L/vendor_boot.list"
  normalize_list_file "$L/system_dlkm_explicit.list"

  cp -f "$L/system_dlkm_explicit.list" "$L/system_dlkm.list"
  normalize_list_file "$L/system_dlkm.list"

  cp -f "$L/vendor_dlkm.list" "$DIST_DIR/init.insmod.vendor_dlkm.cfg"
  cp -f "$L/vendor_early.list" "$DIST_DIR/vendor_boot.early.list"
  cp -f "$L/vendor_boot.list" "$DIST_DIR/vendor_boot.main.list"
  cp -f "$L/system_dlkm.list" "$DIST_DIR/system_dlkm.list"

  # debug exports
  cp -f "$L/vendor_dlkm.list" "$DIST_DIR/vendor_dlkm.list"
  cp -f "$L/vendor_main.list" "$DIST_DIR/vendor_main.raw.list"
  cp -f "$L/vendor_boot_extra.list" "$DIST_DIR/vendor_boot.extra.list"

  log "List sizes:"
  wc -l \
    "$L/vendor_early.list" \
    "$L/vendor_boot.list" \
    "$L/vendor_dlkm.list" \
    "$L/system_dlkm.list" | sed 's/^/[exynos2400-make]   /'
}

resolve_built_module_path() {
  local module_rel="$1"
  local kernel_release="$2"

  if [[ -n "$kernel_release" && -f "$OUT_DIR/install/lib/modules/$kernel_release/${module_rel#./}" ]]; then
    printf '%s\n' "$OUT_DIR/install/lib/modules/$kernel_release/${module_rel#./}"
    return 0
  fi

  local base
  base="$(basename "$module_rel")"

  local found
  found="$(find "$OUT_DIR/install" -type f -name "$base" 2>/dev/null | head -n1 || true)"
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
    return 0
  fi

  if [[ -f "$OUT_DIR/$module_rel" ]]; then
    printf '%s\n' "$OUT_DIR/$module_rel"
    return 0
  fi

  found="$(find "$OUT_DIR" -type f -name "$base" 2>/dev/null | head -n1 || true)"
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
    return 0
  fi
  return 1
}

copy_selected_modules() {
  local order_list="$1"
  local stage_root="$2"
  local missing_log="$3"
  local kernel_release="$4"
  mkdir -p "$stage_root/lib/modules"
  : > "$missing_log"
  local module_rel src
  while IFS= read -r module_rel; do
    [[ -n "$module_rel" ]] || continue
    if src="$(resolve_built_module_path "$module_rel" "$kernel_release")"; then
      cp -fL "$src" "$stage_root/lib/modules/"
    else
      printf '%s\n' "$module_rel" >> "$missing_log"
    fi
  done < "$order_list"
  if [[ -s "$missing_log" ]]; then
    warn "Some modules were not found for $(basename "$stage_root")"
    [[ "$STRICT_MISSING_MODULES" == "1" ]] && die "STRICT_MISSING_MODULES=1 and missing modules exist"
  fi
}

create_order_file() {
  local early_list="$1"
  local main_list="$2"
  local out_order="$3"
  : > "$out_order"
  if [[ -s "$early_list" ]]; then
    awk 'NF {print $0}' "$early_list" >> "$out_order"
  fi
  if [[ -s "$main_list" ]]; then
    grep -w -f "$main_list" "$OUT_DIR/modules.order" >> "$out_order" || true
  fi
  awk 'NF && !seen[$0]++' "$out_order" > "${out_order}.tmp"
  mv -f "${out_order}.tmp" "$out_order"
}

create_stage_metadata() {
  local order_list="$1"
  local stage_dir="$2"
  local mount_prefix="$3"
  local kernel_release="$4"
  local depmod_root="$stage_dir/.depmod_root"
  local depmod_moddir="$depmod_root/lib/modules/$kernel_release"
  local final_dir="$stage_dir/lib/modules"

  rm -rf "$depmod_root"
  mkdir -p "$depmod_moddir" "$final_dir"

  awk 'NF {print $0}' "$order_list" | xargs -r -n1 basename > "$depmod_moddir/modules.order"
  cp -f "$depmod_moddir/modules.order" "$depmod_moddir/modules.load"
  cp -f "$OUT_DIR/modules.builtin" "$depmod_moddir/"
  cp -f "$OUT_DIR/modules.builtin.modinfo" "$depmod_moddir/"
  find "$final_dir" -maxdepth 1 -type f -name '*.ko' -exec cp -fL '{}' "$depmod_moddir/" ';'
  depmod --errsyms --filesyms="$OUT_DIR/System.map" --basedir="$depmod_root" "$kernel_release"
  sed -i 's#\(^\|[ :\t]\)lib/#\1/lib/#g' "$depmod_moddir/modules.dep" || true
  if [[ -n "$mount_prefix" ]]; then
    sed -i "s#/lib/#/${mount_prefix}/lib/#g" "$depmod_moddir/modules.dep" || true
  fi
  cp -f "$depmod_moddir/modules.alias" "$final_dir/"
  cp -f "$depmod_moddir/modules.dep" "$final_dir/"
  cp -f "$depmod_moddir/modules.softdep" "$final_dir/"
  cp -f "$depmod_moddir/modules.order" "$final_dir/"
  cp -f "$depmod_moddir/modules.load" "$final_dir/"
}

make_section() {
  local name="$1"
  local early_list="$2"
  local main_list="$3"
  local mount_prefix="$4"
  local kernel_release="$5"
  local stage_dir="$OUT_DIR/staging/$name"
  local final_dir="$DIST_DIR/sections/$name"
  local order_file="$OUT_DIR/listfiles/${name}.order"
  local missing_log="$OUT_DIR/listfiles/${name}.missing"

  rm -rf "$stage_dir" "$final_dir"
  mkdir -p "$stage_dir/lib/modules" "$final_dir/lib/modules"

  create_order_file "$early_list" "$main_list" "$order_file"
  copy_selected_modules "$order_file" "$stage_dir" "$missing_log" "$kernel_release"
  if [[ -x "${STRIP:-}" ]]; then
    find "$stage_dir/lib/modules" -maxdepth 1 -type f -name '*.ko' -exec "${STRIP}" --strip-debug '{}' ';' || true
  fi
  create_stage_metadata "$order_file" "$stage_dir" "$mount_prefix" "$kernel_release"

  cp -a "$stage_dir/lib/modules/." "$final_dir/lib/modules/"
  cp -f "$order_file" "$DIST_DIR/${name}.modules.order"
  [[ -s "$missing_log" ]] && cp -f "$missing_log" "$DIST_DIR/${name}.missing"

  local count
  count="$(find "$final_dir/lib/modules" -maxdepth 1 -type f -name '*.ko' | wc -l)"
  log "Section ${name}: ${count} modules"
}


find_mkbootimg() {
  if [[ -n "$MKBOOTIMG" && -f "$MKBOOTIMG" ]]; then
    printf '%s\n' "$MKBOOTIMG"
    return 0
  fi
  local cand
  for cand in \
    "$SRC_DIR/toolchain/mkbootimg/mkbootimg.py" \
    "$SRC_DIR/tools/mkbootimg/mkbootimg.py" \
    "$ROOT_DIR/toolchain/mkbootimg/mkbootimg.py" \
    "$ROOT_DIR/tools/mkbootimg/mkbootimg.py"; do
    [[ -f "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
  done
  local found
  found="$(find "$SRC_DIR" "$ROOT_DIR" -type f -name mkbootimg.py 2>/dev/null | head -n1 || true)"
  [[ -n "$found" ]] && { printf '%s\n' "$found"; return 0; }
  return 1
}

find_vendor_dtb_image() {
  if [[ -n "$VENDOR_DTB_IMAGE" && -f "$VENDOR_DTB_IMAGE" ]]; then
    printf '%s\n' "$VENDOR_DTB_IMAGE"
    return 0
  fi
  local cand
  for cand in \
    "$DIST_DIR/${TARGET_SOC}.dtb" \
    "$OUT_DIR/${TARGET_SOC}.dtb" \
    "$OUT_DIR/arch/arm64/boot/dts/exynos/${TARGET_SOC}.dtb"; do
    [[ -f "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
  done
  local found
  found="$(find "$OUT_DIR/arch/arm64/boot/dts" -type f -name '*.dtb' 2>/dev/null | sort | head -n1 || true)"
  [[ -n "$found" ]] && { printf '%s\n' "$found"; return 0; }
  return 1
}

populate_vendor_ramdisk_base() {
  local base_dir="$1"
  rm -rf "$base_dir"
  mkdir -p "$base_dir"

  if [[ -n "$VENDOR_RAMDISK_BASE_DIR" && -d "$VENDOR_RAMDISK_BASE_DIR" ]]; then
    log "Using prebuilt vendor ramdisk base dir: $VENDOR_RAMDISK_BASE_DIR"
    cp -a "$VENDOR_RAMDISK_BASE_DIR/." "$base_dir/"
    return 0
  fi

  local have_inputs=0
  [[ -n "$VENDOR_FSTAB" && -f "$VENDOR_FSTAB" ]] && have_inputs=1
  [[ -n "$VENDOR_INIT_RECOVERY_RC" && -f "$VENDOR_INIT_RECOVERY_RC" ]] && have_inputs=1
  [[ -n "$VENDOR_INIT_USB_RC" && -f "$VENDOR_INIT_USB_RC" ]] && have_inputs=1
  [[ -n "$VENDOR_FIRMWARE_SGPU" && -f "$VENDOR_FIRMWARE_SGPU" ]] && have_inputs=1
  [[ -n "$VENDOR_PREBUILT_SYSTEM_FILES_TAR" && -f "$VENDOR_PREBUILT_SYSTEM_FILES_TAR" ]] && have_inputs=1

  if [[ "$have_inputs" == "1" ]]; then
    log "Assembling vendor ramdisk base from explicit input files"
    mkdir -p "$base_dir/first_stage_ramdisk" "$base_dir/etc/init"
    if [[ -n "$VENDOR_FSTAB" && -f "$VENDOR_FSTAB" ]]; then
      cp -f "$VENDOR_FSTAB" "$base_dir/first_stage_ramdisk/fstab.${TARGET_SOC}"
      cp -f "$VENDOR_FSTAB" "$base_dir/fstab.${TARGET_SOC}"
      mkdir -p "$base_dir/etc"
      cp -f "$VENDOR_FSTAB" "$base_dir/etc/recovery.fstab"
    fi
    if [[ -n "$VENDOR_INIT_RECOVERY_RC" && -f "$VENDOR_INIT_RECOVERY_RC" ]]; then
      cp -f "$VENDOR_INIT_RECOVERY_RC" "$base_dir/init.recovery.${TARGET_SOC}.rc"
    fi
    if [[ -n "$VENDOR_INIT_USB_RC" && -f "$VENDOR_INIT_USB_RC" ]]; then
      mkdir -p "$base_dir/etc/init"
      cp -f "$VENDOR_INIT_USB_RC" "$base_dir/etc/init/init.${TARGET_SOC}.usb.rc"
    fi
    if [[ -n "$VENDOR_FIRMWARE_SGPU" && -f "$VENDOR_FIRMWARE_SGPU" ]]; then
      mkdir -p "$base_dir/lib/firmware/sgpu"
      cp -f "$VENDOR_FIRMWARE_SGPU" "$base_dir/lib/firmware/sgpu/"
    fi
    if [[ -n "$VENDOR_PREBUILT_SYSTEM_FILES_TAR" && -f "$VENDOR_PREBUILT_SYSTEM_FILES_TAR" ]]; then
      mkdir -p "$base_dir/system"
      tar xzf "$VENDOR_PREBUILT_SYSTEM_FILES_TAR" -C "$base_dir/system"
    fi
    return 0
  fi

  if [[ "$ALLOW_MINIMAL_VENDOR_RAMDISK" == "1" ]]; then
    warn "Building vendor_boot.img with a minimal base ramdisk; this may bootloop."
    mkdir -p "$base_dir/first_stage_ramdisk" "$base_dir/etc/init"
    return 0
  fi

  die "No vendor ramdisk base source found. Set VENDOR_RAMDISK_BASE_DIR to an extracted stock fragment0 dir, or provide VENDOR_FSTAB/VENDOR_INIT_* inputs. To force an unsafe minimal base, set ALLOW_MINIMAL_VENDOR_RAMDISK=1."
}

write_vendor_bootconfig() {
  local out="$1"
  if [[ -n "$VENDOR_BOOTCONFIG_FILE" && -f "$VENDOR_BOOTCONFIG_FILE" ]]; then
    cp -f "$VENDOR_BOOTCONFIG_FILE" "$out"
  else
    printf '%s\n' "$VENDOR_BOOTCONFIG_TEXT" > "$out"
  fi
}

pack_lz4_legacy_cpio() {
  local src_dir="$1"
  local out_file="$2"
  rm -f "$out_file"
  (
    cd "$src_dir"
    find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root 2>/dev/null | lz4 -l > "$out_file"
  )
}

build_vendor_boot_image() {
  [[ "$BUILD_VENDOR_BOOT_IMG" == "1" ]] || return 0
  need_cmd cpio
  need_cmd lz4

  local mkbootimg
  mkbootimg="$(find_mkbootimg)" || die "mkbootimg.py not found; set MKBOOTIMG=/path/to/mkbootimg.py"
  local dtb_image
  dtb_image="$(find_vendor_dtb_image)" || die "Could not locate DTB image; set VENDOR_DTB_IMAGE=/path/to/${TARGET_SOC}.dtb"

  local img_root="$OUT_DIR/vendor_bootimg"
  local base_stage="$img_root/vendor_ramdisk_base"
  local dlkm_stage="$img_root/vendor_ramdisk_dlkm"
  local vendor_ramdisk="$img_root/vendor_ramdisk.lz4"
  local dlkm_ramdisk="$img_root/vendor_dlkm_ramdisk.lz4"
  local bootconfig_txt="$img_root/vendor-bootconfig.txt"

  rm -rf "$img_root"
  mkdir -p "$base_stage" "$dlkm_stage/lib/modules"

  populate_vendor_ramdisk_base "$base_stage"
  cp -a "$DIST_DIR/sections/vendor_boot/lib/modules/." "$dlkm_stage/lib/modules/"
  write_vendor_bootconfig "$bootconfig_txt"

  pack_lz4_legacy_cpio "$base_stage" "$vendor_ramdisk"
  pack_lz4_legacy_cpio "$dlkm_stage" "$dlkm_ramdisk"

  log "Building vendor_boot.img"
  python3 "$mkbootimg" \
    --header_version "$VENDOR_BOOT_HEADER_VERSION" \
    --pagesize "$VENDOR_BOOT_PAGESIZE" \
    --base "$VENDOR_BOOT_BASE" \
    --kernel_offset "$VENDOR_BOOT_KERNEL_OFFSET" \
    --ramdisk_offset "$VENDOR_BOOT_RAMDISK_OFFSET" \
    --tags_offset "$VENDOR_BOOT_TAGS_OFFSET" \
    --dtb_offset "$VENDOR_BOOT_DTB_OFFSET" \
    --vendor_cmdline "$VENDOR_BOOT_CMDLINE" \
    --board "$VENDOR_BOOT_BOARD" \
    --dtb "$dtb_image" \
    --vendor_bootconfig "$bootconfig_txt" \
    --ramdisk_type 1 \
    --ramdisk_name "" \
    --vendor_ramdisk_fragment "$vendor_ramdisk" \
    --ramdisk_type 3 \
    --ramdisk_name dlkm \
    --vendor_ramdisk_fragment "$dlkm_ramdisk" \
    --vendor_boot "$VENDOR_BOOT_IMAGE_OUT"

  cp -f "$bootconfig_txt" "$VENDOR_BOOTCONFIG_OUT"
  log "Created vendor_boot.img: $VENDOR_BOOT_IMAGE_OUT"
}

summarize() {
  log "Done. Key outputs:"
  [[ -f "$DIST_DIR/$KERNEL_BINARY" ]] && printf '  - %s\n' "$DIST_DIR/$KERNEL_BINARY"
  [[ -f "$DIST_DIR/vmlinux" ]] && printf '  - %s\n' "$DIST_DIR/vmlinux"
  [[ -d "$DIST_DIR/sections/vendor_boot/lib/modules" ]] && printf '  - sections/vendor_boot/lib/modules\n'
  [[ -d "$DIST_DIR/sections/vendor_dlkm/lib/modules" ]] && printf '  - sections/vendor_dlkm/lib/modules\n'
  [[ -d "$DIST_DIR/sections/system_dlkm/lib/modules" ]] && printf '  - sections/system_dlkm/lib/modules\n'
}

main() {
  need_cmd bash
  need_cmd make
  need_cmd python3
  need_cmd grep
  need_cmd awk
  need_cmd sed
  need_cmd find
  need_cmd xargs
  need_cmd depmod

  [[ -d "$SRC_DIR" ]] || die "kernel dir not found: $ROOT_DIR/$KERNEL_DIR"
  [[ -f "$MODULES_BZL" ]] || die "modules list file not found: $MODULES_BZL"
  [[ -f "$MODEL_VARIANT_BZL" ]] || die "model-variant list file not found: $MODEL_VARIANT_BZL"
  [[ -f "$SYSTEM_MODULES_BZL" ]] || die "system modules list file not found: $SYSTEM_MODULES_BZL"
  [[ -f "$LEGO_BZL" ]] || die "lego modules list file not found: $LEGO_BZL"
  [[ -f "$KUNIT_BZL" ]] || die "kunit modules list file not found: $KUNIT_BZL"

  prepare_dirs
  setup_toolchain
  ensure_clean_source_tree_for_o_build
  apply_config
  build_kernel
  install_modules_tree
  copy_core_outputs
  build_module_lists

  local kernel_release
  kernel_release="$(get_kernel_release)"
  log "Using staging kernel release: $kernel_release"

  make_section vendor_boot "$OUT_DIR/listfiles/vendor_early.list" "$OUT_DIR/listfiles/vendor_boot.list" "" "$kernel_release"
  make_section vendor_dlkm /dev/null "$OUT_DIR/listfiles/vendor_dlkm.list" "vendor" "$kernel_release"
  make_section system_dlkm /dev/null "$OUT_DIR/listfiles/system_dlkm.list" "system" "$kernel_release"
  build_vendor_boot_image

  summarize
}

main "$@"
