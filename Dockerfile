FROM ghcr.io/cirruslabs/flutter:stable

# cmake/ninja/build-essential: required to build opencv_dart's native
# (dartcv4) component via Dart's native-assets build hooks during Flutter
# builds.
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    ninja-build \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /app

# Copy pubspec files first to leverage Docker cache
COPY pubspec.* ./

# Safe directory for git
RUN git config --global --add safe.directory /app
RUN git config --global --add safe.directory /sdks/flutter
