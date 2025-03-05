# syntax=docker/dockerfile:1.7.0-labs
ARG TAG=24.04
FROM ubuntu:${TAG} AS build

### Build stage

ARG GHC=9.6.3
ARG CABAL=3.12.1.0

# Install curl, git and and simplexmq dependencies
RUN apt-get update && apt-get install -y curl git sqlite3 libsqlite3-dev build-essential libgmp3-dev zlib1g-dev llvm llvm-dev libnuma-dev libssl-dev

# Specify bootstrap Haskell versions
ENV BOOTSTRAP_HASKELL_GHC_VERSION=${GHC}
ENV BOOTSTRAP_HASKELL_CABAL_VERSION=${CABAL}

# Do not install Stack
ENV BOOTSTRAP_HASKELL_INSTALL_NO_STACK=true
ENV BOOTSTRAP_HASKELL_INSTALL_NO_STACK_HOOK=true

# Install ghcup
RUN curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | BOOTSTRAP_HASKELL_NONINTERACTIVE=1 sh

# Adjust PATH
ENV PATH="/root/.cabal/bin:/root/.ghcup/bin:$PATH"

# Set both as default
RUN ghcup set ghc "${GHC}" && \
    ghcup set cabal "${CABAL}"

# Copy only the source code
COPY apps /project/apps/
COPY cbits /project/cbits/
COPY src /project/src/
COPY tests /project/tests/

COPY cabal.project Setup.hs simplexmq.cabal LICENSE /project

WORKDIR /project

# Compile app
RUN cabal update
RUN cabal build --enable-tests

# Test
RUN cabal test --test-show-details=direct

# Move binaries
WORKDIR /out
RUN for i in smp-server xftp-server ntf-server xftp; do \
        bin=$(find /project/dist-newstyle -name "$i" -type f -executable); \
        strip "$bin"; \
        chmod +x "$bin"; \
        mv "$bin" .; \
    done

FROM scratch
COPY --from=build /out /
