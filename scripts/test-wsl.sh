#!/usr/bin/env bash
# Tests du cœur (Core/) sous Linux ou Windows + WSL (Ubuntu).
#
# Prérequis, une fois (sans droits administrateur) :
#   - Swift 6.x de swift.org décompressé dans ~/swift
#     (https://www.swift.org/install/linux/ — archive « Ubuntu 26.04 » ou celle de votre distribution) ;
#   - si `swift --version` réclame libncurses.so.6, ou si l'en-tête sqlite3.h manque :
#       cd ~ && apt-get download libncurses6 libsqlite3-dev
#       for f in *.deb; do dpkg -x "$f" ~/swiftdeps; done
#       ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 ~/swiftdeps/usr/lib/x86_64-linux-gnu/libsqlite3.so
#
# Usage : scripts/test-wsl.sh [--filter NomDuTest]
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/swift/usr/bin:$PATH"
deps="$HOME/swiftdeps/usr"
flags=()
if [ -d "$deps" ]; then
  export LD_LIBRARY_PATH="$deps/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  flags+=(-Xcc "-I$deps/include" -Xlinker "-L$deps/lib/x86_64-linux-gnu")
fi
# Produits de compilation sur le disque Linux (bien plus rapide que /mnt/c).
# « native » : le système de construction par défaut perd LD_LIBRARY_PATH au moment de l'édition de liens.
swift test --package-path "$here/Core" --scratch-path "$HOME/.cache/phototheque-ios-build" \
  --build-system native "${flags[@]}" "$@"
