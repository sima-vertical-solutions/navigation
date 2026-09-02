#!/usr/bin/env bash
#
# Smoke-test the built navigation package in a clean Debian bookworm container.
#
#   docker run --rm \
#     --volume "${PWD}/dist:/dist:ro" \
#     --volume "${PWD}/packaging:/packaging:ro" \
#     debian:bookworm /packaging/smoke-test.sh
#
# This lives in a file rather than inline in the workflow because inline it
# needs three levels of quoting -- the YAML block, `bash -c` for docker run,
# and the inner loop -- and the innermost quotes terminate the outermost
# string. That broke the ros2 pipeline's run twice before its equivalent file
# existed.

set -euo pipefail

ROS2_PREFIX=/usr/local/ros2
PREFIX=/usr/local/navigation

ROS2_VERSION="${ROS2_VERSION:-2.1.3}"

echo "=== installing ROS 2 ${ROS2_VERSION} from the production Vulcan store ==="
# navigation declares Depends: ros2, and this container has no apt source that
# carries it -- by design. Installing it first, from the same store and the
# same pinned version the build container took it from, is what lets this
# container keep NO third-party apt source. sima-cli installs the deb through
# apt, so ros2 is dpkg-registered and satisfies the dependency below.
#
# That makes the remaining assertion stronger, not weaker: every OTHER
# dependency this deb declares -- some forty of them -- must now resolve from
# stock Debian alone, with no eLxr and no repo.sima.ai to fall back on.
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    ca-certificates curl python3 python3-venv >/dev/null
curl -fsSL https://artifacts.neat.sima.ai/sima-cli/linux-mac.sh | bash >/dev/null
# A non-login, non-interactive shell sees neither the PATH line the installer
# writes to .bash_profile nor its alias, so call the binary by path.
SIMA_CLI_CHECK_FOR_UPDATE=0 /root/.sima-cli/.venv/bin/sima-cli \
    neat install --prod "ros2@v${ROS2_VERSION}" >/dev/null
installed="$(dpkg-query -W -f='${Version}' ros2)"
[[ "${installed}" == "${ROS2_VERSION}" ]] \
    || { echo "ros2 ${installed} installed, expected ${ROS2_VERSION}" >&2; exit 1; }
echo "ros2 ${installed}"

echo
echo "=== installing the navigation package ==="
apt-get update -qq
apt-get install -y -qq /dist/navigation_*.deb

echo
echo "=== sourcing the ROS 2 and navigation environments ==="
set +u
# shellcheck disable=SC1091
source "${ROS2_PREFIX}/local_setup.bash"
# shellcheck disable=SC1091
source "${PREFIX}/local_setup.bash"
set -u

echo
echo "=== unresolved system libraries ==="
# Most of what this tree links against it either ships or gets from the ros2
# package, and those resolve through LD_LIBRARY_PATH rather than a system path.
# Hence sourcing the environments first, and discounting anything either prefix
# provides -- without both, the scan reports hundreds of false positives.
find "${PREFIX}" "${ROS2_PREFIX}" /usr/local/lib -name '*.so*' -printf '%f\n' 2>/dev/null | sort -u > /tmp/shipped

# ldd exits non-zero on anything that is not a dynamic executable, and
# -perm -u+x matches every shell script in the tree, so each call has to be
# allowed to fail. Piping the lot through xargs instead returns 123 and kills
# the step under `set -e`.
find "${PREFIX}" -type f \( -name '*.so*' -o -perm -u+x \) -print0 \
    | while IFS= read -r -d '' f; do ldd "${f}" 2>/dev/null || true; done \
    | sed -n 's/^[[:space:]]*\([^[:space:]]*\) => not found.*/\1/p' \
    | sort -u > /tmp/unresolved

comm -23 /tmp/unresolved /tmp/shipped > /tmp/missing
if [[ -s /tmp/missing ]]; then
    cat /tmp/missing
    echo "^^ undeclared runtime dependencies -- add them to packaging/runtime-depends.txt" >&2
    exit 1
fi
echo "none"

echo
echo "=== smoke test ==="
ros2 --help > /dev/null
for pkg in nav2_bringup nav2_route nav2_bt_navigator nav2_controller nav2_planner \
           nav2_costmap_2d nav2_lifecycle_manager nav2_smac_planner \
           nav2_regulated_pure_pursuit_controller nav2_mppi_controller; do
    printf '%-42s %s\n' "${pkg}" "$(ros2 pkg prefix "${pkg}")"
done

# Every nav2 plugin is loaded by pluginlib from a .so named in an XML manifest.
# A missing SONAME shows up as a lifecycle node that fails to configure on the
# board and nowhere earlier, so open each plugin library here.
echo
echo "=== plugin libraries load ==="
python3 - <<'PY'
import ctypes, glob, os, sys, xml.etree.ElementTree as ET

prefix = "/usr/local/navigation"
libs, failed = set(), []
for xml in glob.glob(os.path.join(prefix, "share", "*", "*.xml")):
    try:
        root = ET.parse(xml).getroot()
    except ET.ParseError:
        continue
    for node in root.iter("library"):
        path = node.get("path")
        if path:
            libs.add(os.path.basename(path))

for name in sorted(libs):
    for cand in (name, f"lib{name}.so", f"{name}.so"):
        so = os.path.join(prefix, "lib", cand)
        if os.path.exists(so):
            break
    else:
        continue
    try:
        ctypes.CDLL(so)
    except OSError as exc:
        failed.append(f"{so}: {exc}")

print(f"{len(libs)} plugin libraries declared, {len(failed)} failed to load")
for line in failed:
    print(line, file=sys.stderr)
sys.exit(1 if failed else 0)
PY

# The launch file and params the rover actually sources.
test -f "${PREFIX}/share/nav2_bringup/launch/navigation_launch.py"
test -f "${PREFIX}/share/nav2_bringup/params/nav2_params.yaml"
echo "navigation installs and resolves."
