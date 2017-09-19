pkg_name=hab-pkg-rpm
pkg_origin=chef
pkg_version="0.1.0"
pkg_maintainer="The Habitat Maintainers <humans@habitat.sh>"
pkg_license=('Apache-2.0')
pkg_deps=(
  core/bash
  core/coreutils
  core/diffutils
  core/findutils
  core/gawk
  core/gnupg
  core/grep
  core/hab
  core/hab-studio
  core/handlebars-cmd
  core/rpm
  core/sed
  core/util-linux
  core/xz
)
pkg_build_deps=(
  chef/inspec
  core/busybox
  core/netcat
)
pkg_bin_dirs=(bin)
pkg_description="Exports an RPM package from a Habitat package."
pkg_upstream_url="https://github.com/chef/habitat-exporters"

update_src_path=false

do_build() {
  return 0
}

do_check() {
  inspec exec "$SRC_PATH/tests/inspec"
}

do_install() {
  install -d "$pkg_prefix/bin"
  install -v -D "./bin/$pkg_name.sh" "$pkg_prefix/bin/$pkg_name"
  install -d "$pkg_prefix/export/rpm"
  install -v -D -m 0644 "./export/rpm/spec" "$pkg_prefix/export/rpm"
  install -d "$pkg_prefix/var/lib/"
  install -m 0444 "./sorted_filesystem_list" "$pkg_prefix/var/lib/"

  # Make sure we do not use the system bash and instead force the use of
  # the one installed as a runtime dependency.
  fix_interpreter "$pkg_prefix/bin/hab-pkg-rpm" "core/bash" "bin/bash"
}

# Execute our unit tests.
# This sources the test script within a bash subshell to ensure we do not
# unintentionally mutate functions or variables owned by plan-build and
# friends. Using the script in this fashion allows us to ensure the PATH is
# set correctly and we can leverage plan-build helper functions.
do_after() {
  (source "${SRC_PATH}/tests/setup.sh") || exit_with "Test execution failed." $?
}
