FROM ghcr.io/cirruslabs/flutter:stable

# cmake/build-essential: required to build opencv_dart's native (dartcv4)
# component via Dart's native-assets build hooks at `pub get` time.
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /app

# Copy pubspec files first to leverage Docker cache
COPY pubspec.* ./

# Safe directory for git
RUN git config --global --add safe.directory /app
RUN git config --global --add safe.directory /sdks/flutter
