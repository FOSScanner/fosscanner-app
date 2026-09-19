# Flutter 3.44.0; pin the multi-platform image index, not a mutable tag.
FROM ghcr.io/cirruslabs/flutter@sha256:217a3d81b124f3fab82b24633bf66b256cc74528b894e7f17103f70150232077

# Android native assets need CMake and Ninja. The base digest is pinned, while
# apt security package versions intentionally resolve from the archive at build time.
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    ninja-build \
    build-essential \
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
