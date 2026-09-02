#!/usr/bin/env bash
#
# Installed by `sima-cli neat install navigation@jazzy`. sima-cli downloads the
# package resources into a directory and runs this from inside it.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

shopt -s nullglob
debs=(navigation_*_arm64.deb)
shopt -u nullglob

if (( ${#debs[@]} != 1 )); then
    echo "Expected exactly one navigation package here, found ${#debs[@]}." >&2
    exit 1
fi

sudo=""
if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null || { echo "Need root or sudo to install." >&2; exit 1; }
    sudo=sudo
fi

# apt rather than dpkg so the package's declared dependencies -- ros2 and some
# forty Debian libraries -- are resolved from the configured repositories, and
# so the vdp-navigation this Conflicts with is removed rather than leaving the
# install half-configured.
${sudo} apt-get update
${sudo} apt-get install -y "./${debs[0]}"

echo "Installed ${debs[0]} under /usr/local/navigation."
echo "Run: source /usr/local/navigation/local_setup.bash"
