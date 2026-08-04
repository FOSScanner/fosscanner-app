FROM ghcr.io/cirruslabs/flutter:stable

# Set the working directory
WORKDIR /app

# Copy pubspec files first to leverage Docker cache
COPY pubspec.* ./

# Safe directory for git
RUN git config --global --add safe.directory /app
RUN git config --global --add safe.directory /sdks/flutter
