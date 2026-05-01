#!/bin/bash

# Copyright (c) Joby Aviation 2022
# Original authors: Thulio Ferraz Assis (thulio@aspect.dev), Aspect.dev
#
# Copyright (c) Thulio Ferraz Assis 2024-2025
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

usage() {
    echo "Usage: $0 <gcc_version> <arch> <output_dir>"
    echo ""
    echo "  gcc_version  GCC version to build"
    echo "  arch         Target architecture (x86_64)"
    echo "  output_dir   Directory where the toolchain archive will be saved"
    echo ""
    echo "Examples:"
    echo "  $0 16.1.0 x86_64 ."
    echo ""
    echo "Output format: gcc-toolchain-{gcc_version}-{arch}.tar.xz"
}

set -o errexit -o nounset -o pipefail

readonly default_gcc_version="16.1.0"
readonly default_gcc_sha512="b3454958891ab47e1e5b6cb9396c0ad3b04f32fe2a7bf1153a143f21013fdb6b295ca94c98964698a688e4c1d7555ffd8ffbc20187507cce6b1c32cbcc09897a"
readonly default_binutils_version="2.46"
readonly default_binutils_sha512="20540d217cd57c53bc51151046b3e406ee75b80917c9b0b6c37aafaf61702ea4caec533b5554f4dea12e6e211452a6adbaa02004fec12c56e0ef31028acc427a"

# Handle help flag
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

readonly gcc_version="${1:-}"
readonly arch="${2:-}"
readonly output_dir="${3:-}"

if [ -z "${gcc_version}" ]; then
    >&2 echo "ERROR: the first argument of the script must be the GCC version."
    >&2 echo ""
    usage
    exit 1
fi

if [ -z "${arch}" ]; then
    >&2 echo "ERROR: the second argument of the script must be the architecture."
    >&2 echo ""
    usage
    exit 1
fi

if [ -z "${output_dir}" ]; then
    >&2 echo "ERROR: the third argument of the script must be the output directory."
    >&2 echo ""
    usage
    exit 1
fi

gcc_sha512="${GCC_SHA512:-}"
if [ -z "${gcc_sha512}" ]; then
    if [[ "${gcc_version}" != "${default_gcc_version}" ]]; then
        >&2 echo "ERROR: GCC_SHA512 must be set when building GCC ${gcc_version}."
        exit 1
    fi
    gcc_sha512="${default_gcc_sha512}"
fi

binutils_version="${BINUTILS_VERSION:-${default_binutils_version}}"
binutils_sha512="${BINUTILS_SHA512:-${default_binutils_sha512}}"

# Validate architecture
case "${arch}" in
    x86_64)
        ;;
    *)
        >&2 echo "ERROR: unsupported architecture '${arch}'. Supported architecture: x86_64"
        >&2 echo ""
        usage
        exit 1
        ;;
esac

echo "INFO: Building GCC ${gcc_version} toolchain for ${arch} architecture..."

output_filename="gcc-toolchain-${gcc_version}-${arch}.tar.xz"
container_source_dir="/var/builds/toolchain"

echo "INFO: building toolchain inside container..."

project_dir="$(git rev-parse --show-toplevel)"
build_dir="${project_dir}"
output=$(realpath "${output_dir}/${output_filename}")
image_tag="gcc-toolchain-${gcc_version}-${arch}"

(cd "${build_dir}"; \
    docker build \
        --build-arg ARCH="${arch}" \
        --build-arg GCC_VERSION="${gcc_version}" \
        --build-arg GCC_SHA512="${gcc_sha512}" \
        --build-arg BINUTILS_VERSION="${binutils_version}" \
        --build-arg BINUTILS_SHA512="${binutils_sha512}" \
        --tag "${image_tag}" \
        --target toolchain \
        .)

echo "INFO: exporting toolchain to '${output}'..."

tmpdir="${build_dir}/.tmpdir"
function remove_tmpdir {
    rm -rf "${tmpdir}"
}
trap remove_tmpdir EXIT
mkdir --parents "${tmpdir}"

container_id="$(docker create "${image_tag}")"
function remove_container {
    docker rm "${container_id}"
    remove_tmpdir
}
trap remove_container EXIT

docker cp "${container_id}:${container_source_dir}" "${tmpdir}"
readonly os_name="$(uname -s)"
if [[ "${os_name}" == "Linux" ]]; then
    readonly cpus="$(nproc --all)"
elif [[ "${os_name}" == "Darwin" ]]; then
    readonly cpus="$(sysctl -n hw.ncpu)"
fi

source_dir_name=$(basename "${container_source_dir}")

(cd "${tmpdir}/${source_dir_name}"; tar --create --file /dev/stdout . | XZ_DEFAULTS="--threads ${cpus}" xz -5 > "${output}")
shasum -a 256 "${output}"

echo "INFO: Successfully created ${output_filename}"
