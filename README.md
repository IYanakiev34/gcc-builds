# GCC Builds

This repository contains the definitions and scripts to build an optimized, hermetic GCC toolchain
for x86_64 Linux. The build process creates both GCC binaries and a glibc-based sysroot in a single
Docker pipeline.

The sysroot intentionally stays on glibc 2.26 for broad runtime compatibility. GCC prerequisites are
downloaded through GCC's `contrib/download_prerequisites` script, and binutils is built from the
`binutils-with-gold` release archive so the final toolchain includes the GNU linker set expected by
the Bazel toolchain package.

The build enables C, C++, Fortran, and LTO. Fortran is included because the Bazel `gcc_toolchain`
module declares `bin/gfortran` as part of the generated toolchain repository even for C and C++
compilation actions.

## Building the Toolchains

Use the `build.sh` script to build the sysroots and GCC binaries using Docker. The current
restriction is that the container must run on x86_64.

### Using the Build Script

#### Building the Toolchains

```shell
./build.sh 16.1.0 x86_64 .
```

#### Output

The build process generates an optimized toolchain archive:

- `gcc-toolchain-16.1.0-x86_64.tar.xz`

This archive contains the GCC binaries, binutils, runtime libraries, headers, and the corresponding
sysroot needed by the Bazel `gcc_toolchain` module extension.

## Publishing a GitHub Release

After building the archive, compute its SHA256 and publish it as a release asset:

```shell
sha256sum gcc-toolchain-16.1.0-x86_64.tar.xz
gh release create gcc-16.1.0-x86_64 \
  ./gcc-toolchain-16.1.0-x86_64.tar.xz \
  --repo IYanakiev34/gcc-builds \
  --target main \
  --title "GCC 16.1.0 x86_64 toolchain" \
  --notes "Hermetic GCC 16.1.0 x86_64 Linux toolchain. SHA256: <sha256>" \
  --latest
```

The release asset URL has this form:

```text
https://github.com/IYanakiev34/gcc-builds/releases/download/gcc-16.1.0-x86_64/gcc-toolchain-16.1.0-x86_64.tar.xz
```

Use that URL and the computed SHA256 in the consuming `MODULE.bazel`.

### Publishing with the GitHub API

The `gh release create` command is the simplest path, but the same release can be created through
the GitHub REST API when you need explicit control over the release object and asset upload.

```shell
tag="gcc-16.1.0-x86_64"
asset="gcc-toolchain-16.1.0-x86_64.tar.xz"
sha256="$(sha256sum "${asset}" | awk '{print $1}')"

upload_url="$(
  gh api repos/IYanakiev34/gcc-builds/releases \
    --method POST \
    --field tag_name="${tag}" \
    --field target_commitish=main \
    --field name="GCC 16.1.0 x86_64 toolchain" \
    --field body="Hermetic GCC 16.1.0 x86_64 Linux toolchain. SHA256: ${sha256}" \
    --raw-field make_latest=true \
    --jq .upload_url
)"

gh api "${upload_url%\{*}?name=${asset}" \
  --method POST \
  --header "Content-Type: application/x-xz" \
  --input "${asset}"
```
