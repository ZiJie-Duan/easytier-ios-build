FROM rust:1.95-bookworm
RUN apt-get update -qq && apt-get install -y -qq protobuf-compiler mold clang python3 iproute2 iptables curl procps >/dev/null && rm -rf /var/lib/apt/lists/*
