# Version scheme for the deb this repository builds. Sourced, not executed.
#
#   <nav2 version>+<YYYYMMDD>.g<12-char sha>
#
# e.g.  navigation_1.3.12+20260901.gbc1f43a7c0de_arm64.deb
#
# WHY NOT A FIXED VERSION
#   The eLxr vdp-navigation recipe versions the package with the Palette
#   release number (${include:simaai-palette/version}, 2.1.3 today), which says
#   nothing about which nav2 is inside and does not change when the nav2 source
#   does. Two different builds then sit in the store under one name, and the
#   only way to tell them apart is to unpack them. The sha needs nobody to
#   remember a bump, and it answers "which commit built this deb" from the
#   filename.
#
# WHICH BASE
#   <version> from nav2_bringup/package.xml -- 1.3.12 on the jazzy branch.
#   NOT `git describe`: this is a fork of ros-navigation/navigation2 and
#   carries every one of its tags, so git describe lands on whichever upstream
#   tag is nearest and would happily version a Jazzy package after a Rolling
#   release. package.xml is also the number that has to agree with the ROS 2
#   distro this links against, so it is the one that means something.
#
#   Note that this deliberately sorts BELOW the 2.1.3 the eLxr vdp-navigation
#   package carries. That is why this package is named `navigation` and
#   declares Conflicts/Replaces/Provides on vdp-navigation rather than reusing
#   its name: apt replaces the old package outright instead of being asked to
#   treat 1.3.12 as an upgrade of 2.1.3, which it correctly would not.
#
# ORDERING
#   '+' sorts above a bare version and above a Debian revision, so successive
#   builds of the same nav2 release order by date and a later nav2 (1.3.13)
#   still wins. Two builds on the same UTC day fall back to comparing shas,
#   which is arbitrary -- tolerable because the date moves, and it is the
#   scheme the ros2 and rtabmap_ros pipelines already ship.

# Prints the short sha of the commit being built, or "nogit" outside a checkout.
# In CI the container runs as root over a runner-owned mount, so the caller must
# have set safe.directory -- see the docker run in .github/workflows/github-ci.yml.
deb_version_sha() {
    local repo_root="$1" sha
    if sha="$(git -C "${repo_root}" rev-parse --short=12 HEAD 2>/dev/null)"; then
        printf '%s' "${sha}"
        return 0
    fi
    # Not fatal here, because a source-tarball build has no git and should
    # still produce something installable. It IS fatal in CI: every build would
    # otherwise mint the same "gnogit" version and collide silently, so
    # github-ci.yml rejects it. Say so loudly either way.
    echo "[WARN] No git metadata in ${repo_root}; deb versions will not identify a commit." >&2
    printf 'nogit'
}

# Prints "<base>+<YYYYMMDD>.g<sha>".
deb_version_for() {
    local base="$1" repo_root="$2"
    printf '%s+%s.g%s' "${base}" "$(date -u +%Y%m%d)" "$(deb_version_sha "${repo_root}")"
}
