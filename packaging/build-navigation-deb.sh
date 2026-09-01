#!/usr/bin/env bash
#
# Build the `navigation` Debian package from THIS repository's nav2 packages
# plus the companions pinned in packaging/navigation.repos.
#
# This is the native arm64 port of the vdp-navigation recipe in
# swsoc-elxr-config (boards/arm64/simaai/packages/vdp-navigation/vdp-navigation.yaml),
# which cross-compiled from x86 against an arm64 sysroot under qemu. Most of
# that recipe was scaffolding for the cross-build and is gone:
#
#   dropped   -DCMAKE_SYSROOT, CMAKE_FIND_ROOT_PATH*, QEMU_LD_PREFIX
#   dropped   -DCMAKE_C_COMPILER=/usr/bin/aarch64-linux-gnu-gcc and friends --
#             the native cc IS the aarch64 compiler here
#   dropped   -DX11_*_LIB, -DOPENGL_*_LIBRARY, -DFREETYPE_LIBRARY, -DBLAS_/
#             -DLAPACK_LIBRARIES and the openblas/liblapack.so symlinks, which
#             existed only because CMake cannot probe a sysroot for them
#   dropped   -Wl,--allow-shlib-undefined on all three linker flag variables:
#             it hid genuinely unresolved symbols so a cross-link could finish,
#             and hiding them is the last thing a package build wants
#   dropped   --parallel-workers 2 / MAKEFLAGS=-j8, concessions to qemu
#   kept      --merge-install, --packages-up-to nav2_bringup nav2_route,
#             -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
#   kept      -Wno-error=null-dereference. nav2_common's nav2_package() adds
#             -Werror -Wnull-dereference to every nav2 target, and GCC 12 fires
#             it inside xtensor from nav2_mppi_controller. Without this the
#             build stops there.
#   kept      the pass that strips the staging prefix out of generated files,
#             widened to select files by content rather than by extension
#
# NOT carried over: navigation2_rtabmap.patch. See the note where the sources
# are assembled.
#
# Run inside the container built from packaging/Dockerfile.build, with this
# repository mounted at /workspace.
#
# Environment:
#   WORKDIR         scratch root                   (default /workspace/.build/navigation)
#   DISTDIR         where the .deb is written      (default /workspace/dist)
#   PKG_VERSION     overrides the derived version
#   SKIP_COLCON     reuse an already-staged tree instead of rebuilding
#   COLCON_WORKERS  parallel colcon packages       (default from available RAM)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=packaging/deb-version.sh
source "${REPO_ROOT}/packaging/deb-version.sh"

WORKDIR="${WORKDIR:-/workspace/.build/navigation}"
DISTDIR="${DISTDIR:-/workspace/dist}"

SRC="${WORKDIR}/src"
BUILD="${WORKDIR}/build"
STAGE="${WORKDIR}/stage"
SHLIBDEPS_DIR="${WORKDIR}/shlibdeps"
INSTALL_PREFIX="/usr/local/rosbot_navigation"
ROS2_PREFIX="/usr/local/ros2"

log() { printf '\n=== %s ===\n' "$*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
#
# Checked up front so a missing piece names itself, rather than surfacing forty
# minutes in as a CMake message nobody can trace back.

for tool in vcs colcon dpkg-architecture dpkg-deb dpkg-shlibdeps readelf cc c++ make cmake git; do
    command -v "${tool}" >/dev/null || die "Missing required tool: ${tool}"
done

MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
DEB_ARCH="$(dpkg-architecture -qDEB_HOST_ARCH)"

[[ "${DEB_ARCH}" == arm64 ]] \
    || die "This package is built natively for arm64; host is ${DEB_ARCH}. Building it anywhere else would emulate the whole tree."

[[ -f "${ROS2_PREFIX}/local_setup.bash" ]] \
    || die "${ROS2_PREFIX}/local_setup.bash is missing. Install the ros2 package first."

# The mirror image of the Dockerfile's guard: a prebuilt nav2 on
# AMENT_PREFIX_PATH would satisfy colcon's resolution and packages would build
# against it instead of against each other.
[[ ! -e "${INSTALL_PREFIX}" ]] \
    || die "${INSTALL_PREFIX} already exists; colcon would resolve against it rather than the tree being built."

# ------------------------------------------------------- branch sanity check --
#
# `main` in this fork is upstream's Rolling line (nav2 1.5.0); `jazzy` is the
# Jazzy release line (1.3.12). The ros2 package this links against is Jazzy, so
# building main would either fail or produce something subtly incompatible.
# The version is read from package.xml a few lines down, so assert on that
# rather than on the branch name -- a branch name is not what determines what
# gets compiled, and CI checks out a detached ref anyway.

BASE_VERSION="$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "${REPO_ROOT}/nav2_bringup/package.xml" | head -1)"
[[ -n "${BASE_VERSION}" ]] || die "Could not read <version> from ${REPO_ROOT}/nav2_bringup/package.xml."

case "${BASE_VERSION}" in
    1.3.*) : ;;
    *) die "nav2_bringup is ${BASE_VERSION}. The Jazzy line is 1.3.x; 1.5.x is \`main\`, which is upstream's Rolling development branch and does not match the Jazzy ros2 package this links against. Build from \`jazzy\`." ;;
esac

# ------------------------------------------------------------------ version --
#
#   on a v* tag        -> 2.0.1
#   anywhere else      -> 1.3.12+20260901.g<sha>
#
# See packaging/deb-version.sh for why the base is package.xml and not
# `git describe`.
TAG_PREFIX="${TAG_PREFIX:-v}"

if [[ -z "${PKG_VERSION:-}" ]]; then
    if _tag="$(git -C "${REPO_ROOT}" describe --tags --exact-match --match "${TAG_PREFIX}*" 2>/dev/null)"; then
        PKG_VERSION="${_tag#"${TAG_PREFIX}"}"
    else
        PKG_VERSION="$(deb_version_for "${BASE_VERSION}" "${REPO_ROOT}")"
    fi
fi

dpkg --validate-version "${PKG_VERSION}" 2>/dev/null \
    || die "Computed version is not a valid Debian version: ${PKG_VERSION}"

# ------------------------------------------------------------- parallelism --
#
# The limit is memory, not cores. nav2_mppi_controller is the outlier: xtensor
# expression templates at -O3 want well over 2 GB per translation unit, and an
# OOM here looks like a linker signal 9, not like an out-of-memory message.

if [[ -z "${COLCON_WORKERS:-}" ]]; then
    _mem_gb="$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)"
    _by_mem=$(( _mem_gb / 3 ))
    _by_cpu="$(nproc)"
    COLCON_WORKERS=$(( _by_mem < _by_cpu ? _by_mem : _by_cpu ))
    (( COLCON_WORKERS < 1 )) && COLCON_WORKERS=1
fi

log "navigation ${PKG_VERSION} (nav2 ${BASE_VERSION}, ${DEB_ARCH}), ${COLCON_WORKERS} workers, $(nproc) cpus"

# ----------------------------------------------------------------- sources --

if [[ -n "${SKIP_COLCON:-}" && -d "${STAGE}${INSTALL_PREFIX}" ]]; then
    log "Reusing the staged tree; skipping fetch and colcon"
    mkdir -p "${DISTDIR}"
else

log "Assembling the workspace"

rm -rf "${WORKDIR}"
mkdir -p "${SRC}/navigation2" "${BUILD}" "${STAGE}${INSTALL_PREFIX}" "${DISTDIR}"

# Copied rather than built in place so CI cannot leave the checkout dirty.
# `nav2_*` picks up every ROS package in this repository -- including
# nav2_docking, which holds opennav_docking{,_bt,_core} -- and `navigation2` is
# the metapackage nav2_bringup build_depends on.
find "${REPO_ROOT}" -maxdepth 1 -mindepth 1 -type d \
     \( -name 'nav2_*' -o -name 'navigation2' \) \
     -exec cp -a {} "${SRC}/navigation2/" \;
ls "${SRC}/navigation2"

[[ -d "${SRC}/navigation2/nav2_bringup" ]] || die "nav2_bringup did not get copied into the workspace."
[[ -d "${SRC}/navigation2/nav2_route" ]]   || die "nav2_route did not get copied into the workspace."

# navigation2_rtabmap.patch is NOT applied here.
#
# The eLxr recipe applies it, and it does exist -- in the Bitbucket
# vdp-simaai-ros2 tree at rover/navigation/rtabmap_navigation/, not at the
# $S/navigation2_rtabmap.patch the recipe names, so the recipe as written has
# been failing to find it too. Two reasons it stays out:
#
#   1. It no longer applies. Against jazzy at 1.3.12 two of its four file
#      hunksets are rejected (nav2_params.yaml and nav2_mppi_controller's
#      CMakeLists have both moved on). Rewriting it here would mean inventing a
#      patch nobody reviewed.
#
#   2. What it changes is deployment configuration, not the build: it remaps
#      /map to /rtabmap/map, swaps cmd_vel_nav for cmd_vel_smoothed, comments
#      out the docking server, and replaces nav2_params.yaml wholesale with the
#      rover's tuning. That belongs with the rover's launch configuration --
#      which is where stigabtree and the bringup packages already keep their
#      nav2 params -- not baked into a generic nav2 deb where no one can see it.
#
# Its only build-relevant hunks are two warning suppressions, and the one that
# matters (-Wno-null-dereference for nav2_mppi_controller) is covered by the
# -Wno-error=null-dereference the recipe already passes on the colcon command
# line below. The other, -Wno-array-bounds, is on a unit test, and
# BUILD_TESTING is OFF.

vcs import --input "${REPO_ROOT}/packaging/navigation.repos" "${SRC}"

# ------------------------------------------------------------------- build --

log "Building with colcon"

set +u
# shellcheck disable=SC1091
source "${ROS2_PREFIX}/local_setup.bash"
set -u

# local_setup.bash, not setup.bash: setup.bash chains to the prefixes recorded
# when the ros2 package was itself built, which do not exist in this container.
# It reads unset variables, hence the set +u around it.
[[ -n "${AMENT_PREFIX_PATH:-}" ]] \
    || die "AMENT_PREFIX_PATH is empty after sourcing ${ROS2_PREFIX}/local_setup.bash; colcon would find no ROS 2 at all."

# ------------------------------------------- ROS 2 config-chain preflight --
#
# ROS 2's exported CMake config files pull in system packages that appear in no
# manifest anywhere: find_package(rclcpp) chains through
# get_default_rmw_implementation to rmw_fastrtps_cpp, whose fastrtps-config.cmake
# does find_package(OpenSSL REQUIRED), and libyaml_vendor exports
# find_package(yaml). Nothing in nav2's package.xml files or in the eLxr bdeps
# list mentions either -- the eLxr sysroot simply happened to contain them.
#
# The first build here died on exactly that, 6.6 seconds into colcon, on
# diagnostic_updater. It costs the same hour of cold build to discover the
# second missing one as the first, so resolve the whole chain up front against
# a throwaway project. Ten seconds, and the failure names the package instead
# of naming whichever unlucky ROS package colcon happened to reach first.
#
# The list is the union of what nav2's packages find_package, transitively:
# every C++ node needs rclcpp; nav2_rviz_plugins is the widest, dragging in the
# whole rviz and resource_retriever chain.

log "Probing the ROS 2 CMake config chain"

PROBE="${WORKDIR}/probe"
rm -rf "${PROBE}"
mkdir -p "${PROBE}/src" "${PROBE}/build"

cat > "${PROBE}/src/CMakeLists.txt" <<'PROBE_EOF'
cmake_minimum_required(VERSION 3.16)
project(ros2_config_probe LANGUAGES CXX)
foreach(pkg
    ament_cmake ament_cmake_ros
    rclcpp rclcpp_action rclcpp_lifecycle rclcpp_components
    rcl_interfaces builtin_interfaces
    tf2 tf2_ros tf2_geometry_msgs tf2_eigen
    laser_geometry message_filters pluginlib class_loader
    resource_retriever urdf
    rviz_common rviz_default_plugins rviz_rendering rviz_ogre_vendor)
  find_package(${pkg} REQUIRED)
  message(STATUS "probe ok: ${pkg}")
endforeach()
PROBE_EOF

if ! cmake -S "${PROBE}/src" -B "${PROBE}/build" > "${PROBE}/cmake.log" 2>&1; then
    echo "--- ROS 2 CMake config chain is not satisfiable in this container ---" >&2
    tail -40 "${PROBE}/cmake.log" >&2
    echo "---" >&2
    die "A system -dev package that ROS 2's exported CMake configs require is missing. Add it to packaging/build-depends.txt; see the transitive-deps section there."
fi
grep -c 'probe ok:' "${PROBE}/cmake.log" | xargs printf '%s ROS 2 config packages resolved\n'

colcon build \
    --base-paths "${SRC}" \
    --build-base "${BUILD}" \
    --install-base "${STAGE}${INSTALL_PREFIX}" \
    --merge-install \
    --packages-up-to nav2_bringup nav2_route \
    --parallel-workers "${COLCON_WORKERS}" \
    --event-handlers console_direct+ \
    --cmake-args \
        --no-warn-unused-cli \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF \
        -DCMAKE_CXX_FLAGS=-Wno-error=null-dereference

fi   # end SKIP_COLCON

# ------------------------------------------------------- staging path fixup --
#
# colcon writes its own absolute paths into the generated setup scripts, CMake
# config files and ament index entries. They point at the staging directory, so
# strip it and they resolve once the package is installed at ${INSTALL_PREFIX}.
#
# The eLxr recipe matched a fixed extension list (*.sh, *.bash, *.zsh, *.py,
# *.ps1, *.cmake). That misses
# share/ament_index/resource_index/parent_prefix_path/<pkg>, which has no
# extension and holds the prefix path ament_index resolves against at runtime --
# so the vdp-navigation deb on repo.sima.ai almost certainly carries a
# build-machine path in every one of those files. Selecting by content means
# the rewrite and the check below operate on the same set and cannot disagree.
# grep -I skips binaries, which must not be sed-ed.

log "Rewriting staging paths in generated files"

mapfile -t rewrite < <(grep -rIl "${STAGE}" "${STAGE}${INSTALL_PREFIX}" || true)
if (( ${#rewrite[@]} > 0 )); then
    printf '%s\0' "${rewrite[@]}" | xargs -0 sed -i "s|${STAGE}||g"
    echo "rewrote ${#rewrite[@]} files"
fi

leftovers="$(grep -rIl "${STAGE}" "${STAGE}${INSTALL_PREFIX}" || true)"
if [[ -n "${leftovers}" ]]; then
    echo "Staging path still present in installed files after rewrite:" >&2
    printf '%s\n' "${leftovers}" | head -20 >&2
    exit 1
fi

# A staging path baked into an RPATH would be just as broken, and sed cannot
# fix it. Report rather than fail: this has never been checked before.
while IFS= read -r so; do
    if readelf -d "${so}" 2>/dev/null | grep -q "${STAGE}"; then
        echo "WARNING: staging path in RPATH: ${so}" >&2
    fi
done < <(find "${STAGE}${INSTALL_PREFIX}" -name '*.so*' -type f)

# ------------------------------------------------------------ dependencies --

log "Resolving shared-library dependencies"

# dpkg-shlibdeps insists on a debian/control next to it, so give it a
# throwaway one.
mkdir -p "${SHLIBDEPS_DIR}/debian"
cat > "${SHLIBDEPS_DIR}/debian/control" <<EOF
Source: navigation
Section: libs
Priority: optional
Maintainer: SiMa.ai Technologies <noreply@sima.ai>

Package: navigation
Architecture: any
Description: placeholder for dpkg-shlibdeps
EOF

# readelf is the ELF test rather than `file`: ldd exits non-zero on anything
# that is not a dynamic executable, and -perm -111 matches every shell script
# in the tree, so feeding the lot to a tool that exits on its first non-ELF
# input kills the step under `set -e` -- via xargs it comes back as 123.
mapfile -t elf_files < <(
    find "${STAGE}${INSTALL_PREFIX}" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -111 \) 2>/dev/null \
      | while IFS= read -r f; do readelf -h "${f}" >/dev/null 2>&1 && printf '%s\n' "${f}"; done
)
(( ${#elf_files[@]} > 0 )) || die "No ELF files under ${STAGE}${INSTALL_PREFIX} -- the build produced nothing."
echo "${#elf_files[@]} ELF files"

# --ignore-missing-info because ROS 2 installs into /usr/local without a dpkg
# shlibs entry, so shlibdeps cannot attribute its SONAMEs to a package. `ros2`
# is declared by hand in runtime-depends.txt instead.
raw="$(cd "${SHLIBDEPS_DIR}" && dpkg-shlibdeps -O --ignore-missing-info \
        -l"${STAGE}${INSTALL_PREFIX}/lib" \
        -l/usr/local/lib \
        -l"${ROS2_PREFIX}/lib" \
        "${elf_files[@]}" 2>/dev/null || true)"

SHLIB_DEPENDS="$(sed -n 's/^shlibs:Depends=//p' <<< "${raw}" | head -1)"
echo "shlibdeps: ${SHLIB_DEPENDS:-<none>}"

# paste -d takes a LIST of delimiters and cycles through them, so -d ', '
# alternates comma and space and yields "ros2,lttng-tools python3-numpy".
# Join on a single comma, then space it out.
MANUAL_DEPENDS="$(grep -vE '^\s*(#|$)' "${REPO_ROOT}/packaging/runtime-depends.txt" \
    | paste -sd , - | sed 's/,/, /g')"

DEPENDS="${MANUAL_DEPENDS}"
[[ -n "${SHLIB_DEPENDS}" ]] && DEPENDS="${DEPENDS}, ${SHLIB_DEPENDS}"

# ---------------------------------------------------------------- package --

log "Assembling the Debian package"

INSTALLED_KB="$(du -sk "${STAGE}" | cut -f1)"

mkdir -p "${STAGE}/DEBIAN"

# Substituted with bash parameter expansion rather than sed. A Debian Depends
# field may hold an alternative, and dpkg-shlibdeps emits them:
#
#   libqt5gui5 (>= 5.0.2) | libqt5gui5-gles (>= 5.0.2)
#
# The pipe closes an s|...|...| expression and sed dies with "unknown option to
# `s'". Changing the delimiter to # or , only moves the bug: both are legal in
# a dependency field too. ${var//pat/repl} has no delimiter at all, and its
# replacement is literal -- & and \1 are not special there.
control="$(grep -v '^#' "${REPO_ROOT}/packaging/control.in")"
control="${control//@VERSION@/${PKG_VERSION}}"
control="${control//@ARCH@/${DEB_ARCH}}"
control="${control//@INSTALLED_SIZE@/${INSTALLED_KB}}"
control="${control//@DEPENDS@/${DEPENDS}}"
printf '%s\n' "${control}" > "${STAGE}/DEBIAN/control"

if grep -q '@[A-Z_]*@' "${STAGE}/DEBIAN/control"; then
    echo "Unsubstituted placeholder left in the control file:" >&2
    grep -n '@[A-Z_]*@' "${STAGE}/DEBIAN/control" >&2
    exit 1
fi

echo "--- DEBIAN/control ---"
cat "${STAGE}/DEBIAN/control"
echo "----------------------"

DEB="${DISTDIR}/navigation_${PKG_VERSION}_${DEB_ARCH}.deb"
rm -f "${DEB}"
dpkg-deb --root-owner-group --build "${STAGE}" "${DEB}"

# ----------------------------------------------------------------- verify --

log "Verifying the package"
dpkg-deb --info "${DEB}"

# The packages the rover's launch files actually load. A colcon build that
# skipped one of these still "succeeds" -- --packages-up-to only fails on what
# it was asked for -- so name them.
for pkg in nav2_bringup nav2_route nav2_bt_navigator nav2_controller nav2_planner \
           nav2_costmap_2d nav2_behaviors nav2_smoother nav2_velocity_smoother \
           nav2_collision_monitor nav2_lifecycle_manager nav2_map_server \
           nav2_waypoint_follower nav2_smac_planner nav2_amcl \
           nav2_regulated_pure_pursuit_controller nav2_mppi_controller; do
    [[ -d "${STAGE}${INSTALL_PREFIX}/share/${pkg}" ]] || die "${pkg} is missing from the staged tree."
done

# The two launch entry points the rover sources by name.
for f in launch/navigation_launch.py params/nav2_params.yaml; do
    [[ -f "${STAGE}${INSTALL_PREFIX}/share/nav2_bringup/${f}" ]] \
        || die "nav2_bringup/${f} is missing from the staged tree."
done

log "Built $(basename "${DEB}") ($(du -h "${DEB}" | cut -f1))"
