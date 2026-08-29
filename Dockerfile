# Flutter 3.44.0; pin the multi-platform image index, not a mutable tag.
FROM ghcr.io/cirruslabs/flutter@sha256:46691e311715845de03a3ba4753a475476936805b29431b1f00f1816981033f8

# Native assets need CMake/Ninja; Linux desktop builds additionally need
# Clang and GTK development headers. The base digest is pinned, while apt
# security package versions intentionally resolve from the archive at build time.
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    ninja-build \
    build-essential \
    clang \
    libgtk-3-dev \
    && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /app

# Cache package downloads before copying the rest of the project.
COPY pubspec.* ./
RUN flutter pub get

COPY . .

# Safe directory for git
RUN git config --global --add safe.directory /app
RUN git config --global --add safe.directory /sdks/flutter
