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

FROM ubuntu:22.04 AS base_image

WORKDIR /bin
SHELL ["/bin/bash", "-c"]

ARG GCC_VERSION
ARG GCC_SHA512=b3454958891ab47e1e5b6cb9396c0ad3b04f32fe2a7bf1153a143f21013fdb6b295ca94c98964698a688e4c1d7555ffd8ffbc20187507cce6b1c32cbcc09897a
ARG BINUTILS_VERSION=2.46
ARG BINUTILS_SHA512=20540d217cd57c53bc51151046b3e406ee75b80917c9b0b6c37aafaf61702ea4caec533b5554f4dea12e6e211452a6adbaa02004fec12c56e0ef31028acc427a

WORKDIR /
RUN apt-get update \
        && DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get install --yes \
                bzip2 \
                curl \
                dpkg-dev \
                file \
                gawk \
                gettext \
                less \
                libz-dev \
                m4 \
                make \
                pkg-config \
                python3 \
                rsync \
                texinfo \
                xsltproc \
                xz-utils \
        && apt-get clean \
        && rm -rf /var/lib/apt/lists/*

####################################################################################################
# Download steps
####################################################################################################

FROM base_image AS kernel_download
WORKDIR /downloads/kernel
RUN curl --fail-early --location https://github.com/torvalds/linux/archive/refs/tags/v4.9.tar.gz \
        | tar --gzip --extract --strip-components=1 --file -

FROM base_image AS glibc_download
WORKDIR /downloads/glibc
RUN curl --fail-early --location https://ftp.gnu.org/gnu/glibc/glibc-2.26.tar.xz \
        | tar --xz --extract --strip-components=1 --file -

FROM base_image AS gcc_download
ARG GCC_VERSION
ARG GCC_SHA512=b3454958891ab47e1e5b6cb9396c0ad3b04f32fe2a7bf1153a143f21013fdb6b295ca94c98964698a688e4c1d7555ffd8ffbc20187507cce6b1c32cbcc09897a
WORKDIR /downloads/gcc
RUN if [ -z "${GCC_VERSION}" ]; then >&2 echo "Missing GCC_VERSION argument"; exit 1; fi \
        && curl --fail-early --location --output gcc.tar.xz \
            "https://sourceware.org/pub/gcc/releases/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz" \
        && echo "${GCC_SHA512}  gcc.tar.xz" | sha512sum --check - \
        && tar --xz --extract --strip-components=1 --file gcc.tar.xz \
        && rm gcc.tar.xz
RUN ./contrib/download_prerequisites

FROM base_image AS binutils_download
ARG BINUTILS_VERSION=2.46
ARG BINUTILS_SHA512=20540d217cd57c53bc51151046b3e406ee75b80917c9b0b6c37aafaf61702ea4caec533b5554f4dea12e6e211452a6adbaa02004fec12c56e0ef31028acc427a
WORKDIR /downloads/binutils
RUN curl --fail-early --location --output binutils.tar.xz \
            "https://sourceware.org/pub/binutils/releases/binutils-with-gold-${BINUTILS_VERSION}.tar.xz" \
        && echo "${BINUTILS_SHA512}  binutils.tar.xz" | sha512sum --check - \
        && tar --xz --extract --strip-components=1 --file binutils.tar.xz \
        && rm binutils.tar.xz
FROM base_image AS patchelf_download
WORKDIR /downloads/patchelf
RUN curl --fail-early --location https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-x86_64.tar.gz \
        | tar --gz --extract --strip-components=1 --file -

FROM base_image AS build_image

WORKDIR /opt/gcc/x86_64
RUN curl --fail-early --location https://toolchains.bootlin.com/downloads/releases/toolchains/x86-64-core-i7/tarballs/x86-64-core-i7--glibc--stable-2018.11-1.tar.bz2 \
        | tar --bzip --extract --strip-components=1 --file -
WORKDIR /opt/gcc/x86_64/bin
RUN rm pkg-config
RUN --mount=source=create_symlinks.sh,target=/usr/bin/create_symlinks.sh create_symlinks.sh x86_64-linux-
WORKDIR /

####################################################################################################
# Setup steps
####################################################################################################

ARG ARCH
ENV ARCH="${ARCH}"
RUN if [ -z "${ARCH}" ]; then >&2 echo "Missing ARCH argument"; exit 1; fi
RUN if [[ "${ARCH}" != "x86_64" ]]; then >&2 echo "Only x86_64 is supported"; exit 1; fi
RUN rm --force /lib/cpp && ln --symbolic "/opt/gcc/${ARCH}/bin/${ARCH}-linux-cpp.br_real" /lib/cpp

ENV PATH="/opt/gcc/x86_64/bin:${PATH}"

####################################################################################################
# Build steps
####################################################################################################

FROM build_image AS kernel
COPY --from=kernel_download /downloads/kernel /build/kernel
WORKDIR /build/kernel
RUN --mount=source=build_kernel.sh,target=/usr/bin/build_kernel.sh build_kernel.sh

FROM build_image AS glibc
COPY --from=kernel /var/install/kernel /var/install/kernel
COPY --from=glibc_download /downloads/glibc /build/glibc
WORKDIR /build/glibc/build
RUN --mount=source=configure.sh,target=/usr/bin/configure.sh configure.sh \
        --enable-kernel=4.9 \
        --disable-werror \
        --prefix=/usr \
        --with-headers=/var/install/kernel/usr/include \
        --with-tls \
        libc_cv_slibdir=/lib \
        || (cat config.log && exit 1)
RUN make all --jobs $(nproc)
RUN make DESTDIR=/var/install/glibc install

FROM build_image AS gcc
COPY --from=gcc_download /downloads/gcc /build/gcc
WORKDIR /build/gcc/build
COPY --from=kernel /var/install/kernel /var/install/gcc/sysroot
COPY --from=glibc /var/install/glibc /var/install/gcc/sysroot
RUN --mount=source=configure.sh,target=/usr/bin/configure.sh IS_GCC_BUILD=1 configure.sh \
        --disable-bootstrap \
        --enable-default-pie \
        --enable-languages=c,c++,lto \
        --disable-multilib \
        --prefix=/var/install/gcc \
        --enable-libstdcxx-threads \
        --with-linker-hash-style=gnu \
        --with-build-sysroot=/var/install/gcc/sysroot \
        --with-sysroot=/RELOCATABLE_SYSROOT \
        || (cat config.log && exit 1)
RUN grep -rl '/RELOCATABLE_SYSROOT' . | xargs sed -i 's|/RELOCATABLE_SYSROOT|$(exec_prefix)/sysroot|g'
RUN make --jobs $(nproc) all-gcc
RUN make install-gcc
ENV PATH="/var/install/gcc/bin:${PATH}"
RUN make --jobs $(nproc)
RUN make install

FROM build_image AS binutils
COPY --from=binutils_download /downloads/binutils /build/binutils
WORKDIR /build/binutils/build
COPY --from=kernel /var/install/kernel /var/install/gcc/sysroot
COPY --from=glibc /var/install/glibc /var/install/gcc/sysroot
RUN --mount=source=configure.sh,target=/usr/bin/configure.sh IS_GCC_BUILD=1 configure.sh \
        --enable-64-bit-bfd \
        --enable-default-pie \
        --enable-gold \
        --enable-plugins \
        --disable-shared \
        --enable-static \
        --with-static-standard-libraries \
        --enable-threads \
        --prefix=/var/install/binutils \
        --with-build-sysroot=/var/install/gcc/sysroot \
        --with-lib-path=/var/install/glibc/usr/lib \
        || (cat config.log && exit 1)
RUN make --jobs $(nproc)
RUN make install

####################################################################################################
# Assemble final toolchain
####################################################################################################

FROM build_image AS toolchain

COPY --from=gcc /var/install/gcc /var/install/gcc
COPY --from=binutils /var/install/binutils /var/install/binutils
RUN mkdir --parents /var/builds/toolchain \
        && rsync --archive /var/install/gcc/ /var/builds/toolchain/ \
        && rsync --archive /var/install/binutils/* /var/builds/toolchain/
RUN --mount=source=dedup,target=/usr/bin/dedup dedup /var/builds/toolchain

# We patch the shared libraries to set the rpath to $ORIGIN, so that during runtime the
# libraries are found in the same directory as the executable.
COPY --from=patchelf_download /downloads/patchelf /var/install/patchelf
RUN find /var/builds/toolchain \
        -name '*.so*' \
        -exec /var/install/patchelf/bin/patchelf --set-rpath '$ORIGIN/' {} \;

RUN find /var/builds/toolchain/bin -type f \
        -exec strip \
            --strip-all \
            --remove-section=.comment \
            --remove-section=.note \
            --remove-section=.eh_frame \
            --remove-section=.eh_frame_hdr \
            {} \;
