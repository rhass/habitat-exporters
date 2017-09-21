#!/bin/bash
#
# # Usage
#
# ```
# $ hab-pkg-rpm [PKG ...]
# ```
#
# # Synopsis
#
# Create an RPM package from a set of Habitat packages.
#
# # License and Copyright
#
# ```
# Copyright: Copyright (c) 2017 Chef Software, Inc.
# License: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ```

# Default variables
pkg=
post=
postun=
pre=
preun=
debname=
safe_name=
safe_version=
group=
gpg_path="${HOME}/.gnupg"


# defaults for the application
: ${pkg:="unknown"}

# Fail if there are any unset variables and whenever a command returns a
# non-zero exit code.
set -eu

# If the variable `$DEBUG` is set, then print the shell commands as we execute.
if [ -n "${DEBUG:-}" ]; then
  set -x
  export DEBUG
fi

# ## Help

# **Internal** Prints help
print_help() {
  printf -- "%s %s
%s
Habitat Package RPM - Create a RPM package from a set of Habitat packages
USAGE:
  %s [FLAGS] <PKG_IDENT>
FLAGS:
    --help           Prints help information
OPTIONS:
    --archive=FILE        Filename of exported RPM package. Should end in .rpm
    --compression=TYPE    Compression type for RPM; gzip (default), bzip2, or xz
    --conflicts=PKG       Comma-separated list of packages with which the exported RPM conflicts
    --dist_tag=DIST_TAG   Distribution name for use in RPM filename
    --gnupg_path=PATH     Full path to .gnupg directory
    --gnupg_keyname=NAME  Name associated with GPG key to use in signing RPM files.
    --group=RPMGROUP      Group to be assigned to the RPM package
    --obsoletes=PKG       Comma-separated list of packages made obsolete by the exported RPM
    --postinst=FILE       File name of script called after installation
    --postrm=FILE         File name of script called after removal
    --preinst=FILE        File name of script called before installation
    --prerm=FILE          File name of script called before removal
    --provides=PKG        Comma-separated list of facilities provided by the exported RPM
    --requires=PKG        Comma-separated list of packages required by the exported RPM
    --testname=TESTNAME   Test name used to create a staging directory for examination
ARGS:
    <PKG_IDENT>      Habitat package identifier (ex: acme/redis)
" "$program" "$author" "$program"
}

# internal** Exit the program with an error message and a status code.
#
# ```sh
# exit_with "Something bad went down" 55
# ```
exit_with() {
  if [[ "${HAB_NOCOLORING:-}" = "true" ]]; then
    printf -- "ERROR: %s\n" "$1"
  else
    case "${TERM:-}" in
      *term | xterm-* | rxvt | screen | screen-*)
        printf -- "\033[1;31mERROR: \033[1;37m%s\033[0m\n" "$1"
        ;;
      *)
        printf -- "ERROR: %s\n" "$1"
        ;;
    esac
  fi
  exit "$2"
}

# **Internal** Print a warning line on stderr. Takes the rest of the line as its
# only argument.
#
# ```sh
# warn "Checksum failed"
# ```
warn() {
  case "${TERM:-}" in
    *term | xterm-* | rxvt | screen | screen-*)
      printf -- "\033[1;33mWARN: \033[1;37m%s\033[0m\n" "$1" >&2
      ;;
    *)
      printf -- "WARN: %s\n" "$1" >&2
      ;;
  esac
}

get_script_dir () {
  SOURCE="${BASH_SOURCE[0]}"
  while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$( dirname "$SOURCE" )" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
  done
  (cd -P "$(dirname "$SOURCE")" && pwd)
}

find_system_commands() {
  wtf=$(mktemp --version)
  if mktemp --version 2>&1 | grep -q 'GNU coreutils'; then
    _mktemp_cmd=$(command -v mktemp)
  else
    if /bin/mktemp --version 2>&1 | grep -q 'GNU coreutils'; then
      _mktemp_cmd=/bin/mktemp
    else
      exit_with "We require GNU mktemp to build applications archives; aborting" 1
    fi
  fi
}

#
# The type of compression to use for the .rpm.
#
compression_type() {
  if [[ -z "${compression+x}" ]]; then
    echo xz
  else
    echo "$compression"
  fi
}

#
# Parse comma-separated list of conflicting packages
#
conflicts_list() {
  if [[ ! -z "${conflicts+x}" ]]; then
    if [[ "$conflicts" == *,* ]] ; then
      echo "$conflicts" | sed -n 1'p' | tr ',' '\n' | sed -e 's/^/Conflicts: /'
    else
      echo "Conflicts: $conflicts"
    fi
  fi
}

# The package group.
#
# See https://docs.fedoraproject.org/en-US/Fedora_Draft_Documentation/0.1/html/Packagers_Guide/chap-Packagers_Guide-Spec_File_Reference-Preamble.html
#
group() {
  if [[ ! -z "$group" ]]; then
    echo "$group"
  else
    echo default
  fi
}

# The size of the package when installed.
#
# Per http://www.debian.org/doc/debian-policy/ch-controlfields.html, the
# disk space is given as the integer value of the estimated installed
# size in bytes, divided by 1024 and rounded up.
installed_size() {
  du "$rpm_context" --apparent-size --block-size=1024 --summarize | cut -f1
}

#
# Parse comma-separated list of conflicting packages
#
obsoletes_list() {
  if [[ ! -z "${obsoletes+x}" ]]; then
    if [[ "$obsoletes" == *,* ]] ; then
      echo "$obsoletes" | sed -n 1'p' | tr ',' '\n' | sed -e 's/^/Obsoletes: /'
    else
      echo "Obsoletes: $obsoletes"
    fi
  fi
}

#
# Parse comma-separated list of provided facilities
#
provides_list() {
  if [[ ! -z "${provides+x}" ]]; then
    if [[ "$provides" == *,* ]] ; then
      echo "$provides" | sed -n 1'p' | tr ',' '\n' | sed -e 's/^/Provides: /'
    else
      echo "Provides: $provides"
    fi
  fi
}

#
# Parse comma-separated list of required dependencies
#
requires_list() {
  if [[ ! -z "${requires+x}" ]]; then
    if [[ "$requires" == *,* ]] ; then
      echo "$requires" | sed -n 1'p' | tr ',' '\n' | sed -e 's/^/Requires: /'
    else
      echo "Requires: $requires"
    fi
  fi
}

# parse the CLI flags and options
parse_options() {
  opts="$(getopt \
    --longoptions help,archive:,compression:,conflicts:,dist_tag:,gnupg_keyname:,gnupg_path:,group:,obsoletes:,post:,postun:,pre:,preun:,provides:,requires:,testname: \
    --name "$program" --options h -- "$@" \
  )"
  eval set -- "$opts"

  while :; do
    case "$1" in
      -h | --help)
        print_help
        exit
        ;;
      --archive)
        archive=$2
        shift 2
        ;;
      --compression)
        compression=$2
        shift 2
        ;;
      --conflicts)
        conflicts=$2
        shift 2
        ;;
      --dist_tag)
        dist_tag=$2
        shift 2
        ;;
      --gnupg_keyname)
        gpg_keyname=$2
        shift 2
        ;;
      --gnupg_path)
        gpg_path=$2
        shift 2
        ;;
      --group)
        group=$2
        shift 2
        ;;
      --obsoletes)
        obsoletes=$2
        shift 2
        ;;
      --post)
        post=$2
        shift 2
        ;;
      --postun)
        postun=$2
        shift 2
        ;;
      --pre)
        pre=$2
        shift 2
        ;;
      --preun)
        preun=$2;
        shift 2
        ;;
      --provides)
        provides=$2
        shift 2
        ;;
      --requires)
        requires=$2
        shift 2
        ;;
      --testname)
        testname=$2
        shift 2
        ;;
      --)
        shift
        pkg=$*
        break
        ;;
      *)
        exit_with "Unknown error" 1
        ;;
    esac
  done

  if [[ -z "$pkg" ]] || [[ "$pkg" = "--" ]]; then
    print_help
    exit_with "You must specify a Habitat package." 1
  fi

  install_dir=$(hab pkg path "$pkg")

  #
  # If *inst or *rm scripts are included with the package, use them.
  # The `bin` directory is specified because that is where automate currently drops its install scripts.
  #
  if [[ -z "$pre" ]] && [[ -e "$install_dir/bin/pre" ]]; then
    pre="$install_dir/bin/pre"
  fi

  if [[ -z "$post" ]] && [[ -e "$install_dir/bin/post" ]]; then
    post="$install_dir/bin/post"
  fi

  if [[ -z "$preun" ]] && [[ -e "$install_dir/bin/preun" ]]; then
    preun="$install_dir/bin/preun"
  fi

  if [[ -z "$postun" ]] && [[ -e "$install_dir/bin/postun" ]]; then
    postun="$install_dir/bin/postun"
  fi
}

# The name converted to all lowercase to be compatible with Debian naming
# conventions
convert_name() {
  if [[ ! -z "$debname" ]]; then
    safe_name="${debname,,}"
  else
    safe_name="${pkg_origin,,}-${pkg_name,,}"
  fi
}

# Return the Debian-ready version, replacing all dashes (-) with tildes
# (~) and converting any invalid characters to underscores (_).
convert_version() {
  if [[ $pkg_version == *"-"* ]]; then
    safe_version="${pkg_version//-/\~}"
    warn "Dashes hold special significance in the Debian package versions. "
    warn "Versions that contain a dash and should be considered an earlier "
    warn "version (e.g. pre-releases) may actually be ordered as later "
    warn "(e.g. 12.0.0-rc.6 > 12.0.0). We'll work around this by replacing "
    warn "dashes (-) with tildes (~). Converting '$pkg_version' "
    warn "to '$safe_version'."
	else
    safe_version="$pkg_version"
	fi
}

# The filename to be used for the exported Debian package.
rpmfile() {
  if [[ -z "${archive+x}" ]]; then
    if [[ -z "${dist_tag+x}" ]]; then
      echo "${safe_name}-$safe_version-${pkg_release}.$(architecture).rpm"
    else
      echo "${safe_name}-$safe_version-${pkg_release}.${dist_tag}.$(architecture).rpm"
    fi
  else
    echo "$archive"
  fi
}

description() {
  pkg_description="$(head -2 <<< "$manifest" | tail -1)"

  # TODO: Handle multi-line descriptions.
  # See https://www.debian.org/doc/debian-policy/ch-controlfields.html#s-f-Description
  # Handle empty pkg_description
  if [[ -z "$pkg_description" ]]; then
    if [[ ! -z "$debname" ]]; then
      echo "$debname"
    else
      echo "$pkg_name"
    fi
  else
    echo "$pkg_description"
  fi
}

generate_filelist() {
  # Get a list of all the files in the staging directory.
  find "$staging/BUILD" | sed -e s#"$staging\/BUILD"## | sed '/^$/d' | sort > "$staging/tmp/hab_filepaths"

  # find directories
  find "$staging/BUILD" -type d | sed -e s#"$staging\/BUILD"## | sort > "$staging/tmp/hab_dirlist"

  # TODO: how to handle symlinks
  # find symlinks
  # find /tmp/test-hab-pkg-rpm-pkg_provides_configs/BUILD -type l > links
  # sed -e 's/\/tmp\/test-hab-pkg-rpm-pkg_provides_configs\/BUILD//' links > linklist

  # printf "Generating list of filesystem directories to mark\n"
  comm -12 "$(dirname "$0")/../var/lib/sorted_filesystem_list" "$staging/tmp/hab_dirlist" > "$staging/tmp/filesystem_directories_to_mark"

  # This will hang on OS X because the syntax is different.
  # for dirname in `cat "$staging/tmp/filesystem_directories_to_mark"`; do
    # printf "Marking directory owned by filesystem package: %s\n" "$dirname"
  #  sed -i 's#'"^$dirname$"'#%dir %attr(0755,root,root) '"$dirname"'#' "$staging/tmp/hab_filepaths"
  # done

  while read -r dirname
  do
    sed -i 's#'"^$dirname$"'#%dir %attr(0755,root,root) '"$dirname"'#' "$staging/tmp/hab_filepaths"
  done < "$staging/tmp/filesystem_directories_to_mark"

  # printf "Generating list of non-filesystem directories to mark\n"
  comm -23 "$staging/tmp/hab_dirlist" "$staging/tmp/filesystem_directories_to_mark" > "$staging/tmp/normal_directories_to_mark"

  # printf "Generating sed script to mark directories not owned by the filesystem package\n"
  sed -re 's/^(.*)$/s#\^\1\$#%dir \1#/' "$staging/tmp/normal_directories_to_mark" > "$staging/tmp/sed.script"
  sed -f "$staging/tmp/sed.script" "$staging/tmp/hab_filepaths" > "$staging/tmp/filelist"

  # This clears config files because we've already declared them.
  # for filename in `cat /src/tests/inputs/export/rpm/configs`; do
  #  sed -i '\#'"^$filename$"'#d' "$staging/tmp/filelist"
  # done
  while read -r filename
  do
    sed -i '\#'"^$filename$"'#d' "$staging/tmp/filelist"
  done < /src/hab-pkg-rpm/tests/inputs/export/rpm/configs
}

maintainer() {
  pkg_maintainer="$(grep __Maintainer__: <<< "$manifest" | cut -d ":" -f2 | sed 's/^ *//g')"

  if [[ -z "$pkg_maintainer" ]]; then
    echo "$pkg_origin"
  else
    echo "$pkg_maintainer"
  fi
}

release() {
 # Release: <%= iteration %><%= dist_tag ? dist_tag : '' %>
  if [[ -z "${dist_tag+x}" ]]; then
    echo "$pkg_release"
  else
    echo "${pkg_release}.${dist_tag}"
  fi
}

# Output the contents of the "control" file
render_spec_file() {
  spec_template="$(get_script_dir)/../export/rpm/spec"
  if [[ -f "$install_dir/export/rpm/spec" ]]; then
    spec_template="$install_dir/export/rpm/spec"
  fi

  hab pkg exec core/handlebars-cmd handlebars \
    --compression "$(compression_type)" \
    --name "$safe_name" \
    --version "$safe_version" \
    --release "$(release)" \
    --summary "${pkg_name,,}" \
    --description "$(description)" \
    --group "$(group)" \
    --license "$pkg_license" \
    --vendor "$pkg_origin" \
    --url "$pkg_upstream_url" \
    --packager "$(maintainer)" \
    --architecture "$(architecture)" \
    --installed_size "$(installed_size)" \
    --pkg_upstream_url "$pkg_upstream_url" \
    --conflicts "$(conflicts_list)" \
    --requires "$(requires_list)" \
    --provides "$(provides_list)" \
    --obsoletes "$(obsoletes_list)" \
    --scripts "$(script_contents)" \
    --configs "$(configs)" \
    --package_user "$(package_user)" \
    --package_group "$(package_group)" \
    < "$spec_template" \
    > "$staging/SPECS/$safe_name.spec"

  # Append the filelist separately to avoid overflowing the allowable command line length.
  cat "$staging/tmp/filelist" >> "$staging/SPECS/$safe_name.spec"
}

configs() {
  if [[ -f "$install_dir/export/rpm/configs" ]]; then
    sed -e 's/^/%config(noreplace) /' "$install_dir/export/rpm/configs"
  fi
}

package_group() {
  echo root
}

package_user() {
  echo root
}

script_contents() {
  scripts=
  for script_name in post postun pre preun; do
    eval "file_name=\$$script_name"
    if [[ -n $file_name ]]; then
      if [[ -f $file_name ]]; then
        scripts+=$(printf "%%%s\n%s\n", "$script_name" "$(<"$file_name")")
      else
        exit_with "$script_name script '$file_name' not found" 1
      fi
      echo "$scripts"
    fi
  done
}

render_md5sums() {
  pushd "$rpm_context" > /dev/null
    find . -type f ! -regex '.*?DEBIAN.*' -exec md5sum {} +
  popd > /dev/null
}

# The platform architecture.
architecture() {
  # Memoize architecture value.
  RPM_ARCH="${RPM_ARCH:=$(rpm --eval "%{_arch}")}"
  echo "${RPM_ARCH}"
}

copy_artifacts() {
  local results_path
  results_path="./results"

  cp "$staging/RPMS/$(architecture)/"*.rpm "${results_path}"
}

build_rpm() {
  rpm_context="$($_mktemp_cmd -t -d "${program}-XXXX")"
  pushd "$rpm_context" > /dev/null

  env PKGS="$pkg" NO_MOUNT=1 hab studio -r "$rpm_context" -t bare new
  echo "$pkg" > "$rpm_context"/.hab_pkg
  popd > /dev/null

  # Stage the files to be included in the exported .deb package.
  if [[ ! -z "${testname+x}" ]]; then
    staging="/tmp/test-${program}-${testname}"
    mkdir -p "$staging"
  else
    staging="$($_mktemp_cmd -t -d "${program}-staging-XXXX")"
  fi

  # Magic RPM directories
  mkdir -p "$staging/BUILD"
  mkdir -p "$staging/RPMS"
  mkdir -p "$staging/SRPMS"
  mkdir -p "$staging/SOURCES"
  mkdir -p "$staging/SPECS"
  mkdir -p "$staging/BUILD/hab"
  mkdir -p "$staging/tmp"

  manifest="$install_dir/MANIFEST"

  # Set the pkg variables
  pkg_origin="$(echo "${install_dir}" | cut -f4 -d/)"
  pkg_name="$(echo "${install_dir}" | cut -f5 -d/)"
  pkg_version="$(echo "${install_dir}" | cut -f6 -d/)"
  pkg_release="$(echo "${install_dir}" | cut -f7 -d/)"
  # Parsing from the manifest is the safest way to fetch these values since
  # the right-hand assignment of variables can contain other shell variables.
  pkg_license="$(awk -F '[()]' '/__Upstream URL__/ && !/not defined$/ {print $(NF-1)}' "${manifest}")"
  # Parse URL from manifest. Intentionally set the value to an empty string
  # when the value is undefined in the plan.
  pkg_upstream_url="$(awk -F '[()]' '/__Upstream URL__/ && !/not defined$/ {print $(NF-1)}' "${manifest}")"

  convert_name
  convert_version

  # Copy needed files into staging directory
  cp -pr "$rpm_context/hab/pkgs" "$staging/BUILD/hab"
  cp -pr "$rpm_context/hab/bin" "$staging/BUILD/hab"

  generate_filelist

  # Write the spec file
  render_spec_file

  # For most testing, it is enough to generate the spec file and RPM name without building the full package.
  if [[ -z "${testname+x}" ]]; then
    install_options=(--target "$(architecture)" -bb --buildroot "$staging/BUILD" --define "_topdir $staging" "$staging/SPECS/$safe_name.spec")
    if [[ -n "${DEBUG+x}" ]]; then
      install_options+=('--verbose')
    fi

    if [[ -n "${gpg_keyname}" ]]; then
      install_options+=('--sign')

      cat >"${HOME}/.rpmmacros" <<EOF
%_signature gpg
%_gpg_path ${gpg_path}
%_gpg_name "${gpg_keyname}"
EOF
    fi
    rpmbuild "${install_options[@]}"
    copy_artifacts
  else
    printf "%s" "$(rpmfile)" > "$staging/rpm_name"
  fi
}

# The author of this program
author='The Habitat Maintainers <humans@habitat.sh>'

# The short version of the program name which is used in logging output
program=$(basename "$0")

find_system_commands

parse_options "$@"
build_rpm

rm -rf "$rpm_context"
# if [[ -z "${testname+x}" ]]; then
#  rm -rf "$staging"
# fi
