#!/bin/sh
# ilk kurulum: Swift köprü dosyalarını üret, sonra Xcode projesini oluştur
set -eu
cd "$(dirname "$0")/.."
./scripts/build-rust.sh
cd apps/macos && xcodegen generate
