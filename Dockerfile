FROM ubuntu:24.04

# Leave empty to auto-resolve the latest actions/runner release at build time
ARG RUNNER_VERSION=""
ARG DOTNET_CHANNEL=10.0
ARG TARGETARCH=amd64

ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1

# Base packages & developer tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libssl-dev \
        libicu74 \
        ca-certificates \
        curl \
        wget \
        git \
        jq \
        zip \
        unzip \
        tar \
        xz-utils \
        gnupg \
        gosu \
        lsb-release \
        openssh-client \
        rsync \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Node.js (current LTS) + npm
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# .NET SDK
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- \
        --channel "${DOTNET_CHANNEL}" \
        --install-dir /usr/share/dotnet \
    && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet

# Docker CLI + buildx + compose (daemon is provided by mounting /var/run/docker.sock)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# NativeAOT win-x64 cross-compilation: lld provides lld-link (COFF cross-linker),
# xwin downloads the MSVC CRT + Windows SDK libs. Used with the PublishAotCrossXWin
# NuGet package. Wine (32+64-bit) runs the Inno Setup compiler for installers.
RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends lld wine wine32:i386 xvfb \
    && rm -rf /var/lib/apt/lists/*

RUN XWIN_VERSION=$(curl -fsSL https://api.github.com/repos/Jake-Shadle/xwin/releases/latest | jq -r '.tag_name') \
    && curl -fsSL "https://github.com/Jake-Shadle/xwin/releases/download/${XWIN_VERSION}/xwin-${XWIN_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        | tar xz -C /tmp \
    && mv "/tmp/xwin-${XWIN_VERSION}-x86_64-unknown-linux-musl/xwin" /usr/local/bin/xwin \
    && rm -rf /tmp/xwin-*

# AWS CLI v2
RUN case "${TARGETARCH}" in \
        amd64) AWSARCH=x86_64 ;; \
        arm64) AWSARCH=aarch64 ;; \
        *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSARCH}.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# Runner user (ubuntu:24.04 ships a default 'ubuntu' user at uid 1000 — replace it).
# Everything the agent may write lives under /mnt/agent so the AppArmor profile
# can deny writes to the rest of the filesystem, including /home and /root.
RUN userdel -r ubuntu \
    && mkdir -p /mnt/agent/workspace \
    && useradd -m -u 1000 -d /mnt/agent/home runner \
    && groupadd -f docker \
    && usermod -aG docker runner

# GitHub Actions runner
WORKDIR /mnt/agent/runner
RUN VERSION="${RUNNER_VERSION:-$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')}" \
    && case "${TARGETARCH}" in \
        amd64) ARCH=x64 ;; \
        arm64) ARCH=arm64 ;; \
        *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-linux-${ARCH}-${VERSION}.tar.gz" \
    && tar xzf runner.tar.gz \
    && rm runner.tar.gz \
    && ./bin/installdependencies.sh \
    && rm -rf /var/lib/apt/lists/* \
    && chown -R runner:runner /mnt/agent

# Inno Setup under Wine, installed into the runner user's prefix so runtime
# writes stay inside /mnt/agent (AppArmor) and the prefix is part of the
# pristine snapshot below. `iscc` wrapper puts it on PATH for jobs.
# Installers live in immutable GitHub releases since March 2026 (tag is-X_Y_Z);
# files.jrsoftware.org only hosts .issig signatures now.
ARG INNOSETUP_VERSION=6.7.3
ENV WINEPREFIX=/mnt/agent/home/.wine \
    WINEDEBUG=-all
# The whole install sequence must share one xvfb session: wineboot spawns
# wineserver/explorer, and if those start without a display, the installer's
# (hidden) windows fail with "Invalid window handle" even under /VERYSILENT.
RUN curl -fsSL -o /tmp/innosetup.exe \
        "https://github.com/jrsoftware/issrc/releases/download/is-$(echo "${INNOSETUP_VERSION}" | tr . _)/innosetup-${INNOSETUP_VERSION}.exe" \
    && gosu runner env HOME=/mnt/agent/home xvfb-run -a sh -c \
        'wineboot --init && wine /tmp/innosetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- && wineserver -w' \
    && rm /tmp/innosetup.exe

# iscc wrapper: resolve ISCC.exe inside the prefix at run time ("Program Files"
# vs "Program Files (x86)" depends on the prefix architecture)
RUN printf '%s\n' \
        '#!/bin/sh' \
        'set -- "$(ls -d "${WINEPREFIX:-$HOME/.wine}"/drive_c/Program\ Files*/Inno\ Setup\ 6/ISCC.exe 2>/dev/null | head -1)" "$@"' \
        'exec xvfb-run -a wine "$@"' \
        > /usr/local/bin/iscc \
    && chmod 755 /usr/local/bin/iscc \
    && test -x "$(ls -d /mnt/agent/home/.wine/drive_c/Program\ Files*/Inno\ Setup\ 6/ISCC.exe | head -1)"

# Pristine snapshot of the agent tree, restored on startup when RUNNER_CLEAN_FS
# is enabled (default for ephemeral runners)
RUN tar -C / -czf /opt/agent-skel.tar.gz mnt/agent

COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Starts as root: the entrypoint remaps the runner user to PUID/PGID and
# drops privileges via gosu before registering the runner.
ENTRYPOINT ["/entrypoint.sh"]
