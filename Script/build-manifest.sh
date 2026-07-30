#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[*] malformed project structure"
    exit 1
fi

ARM64_ZIP=${1:-}
ARM64_URL=${2:-}
X86_64_ZIP=${3:-}
X86_64_URL=${4:-}

if [ -z "$ARM64_ZIP" ] || [ -z "$ARM64_URL" ] || [ -z "$X86_64_ZIP" ] || [ -z "$X86_64_URL" ]; then
    echo "Usage: $0 <arm64_zip> <arm64_url> <x86_64_zip> <x86_64_url>"
    echo
    echo "Two assets, one per arch — see the note at the top of"
    echo "Package.swift.template for why, and for the environment variable that"
    echo "picks between them at resolve time."
    exit 1
fi

for f in "$ARM64_ZIP" "$X86_64_ZIP"; do
    if [ ! -f "$f" ]; then
        echo "[!] $f not found"
        exit 1
    fi
done

ARM64_SUM=$(shasum -a 256 "$ARM64_ZIP" | awk '{print $1}')
X86_64_SUM=$(shasum -a 256 "$X86_64_ZIP" | awk '{print $1}')
echo "[*] arm64  SHA256: $ARM64_SUM"
echo "[*] x86_64 SHA256: $X86_64_SUM"

PACKAGE_MANIFEST=$(cat Package.swift.template)
PACKAGE_MANIFEST=${PACKAGE_MANIFEST/__DOWNLOAD_URL_ARM64__/$ARM64_URL}
PACKAGE_MANIFEST=${PACKAGE_MANIFEST/__CHECKSUM_ARM64__/$ARM64_SUM}
PACKAGE_MANIFEST=${PACKAGE_MANIFEST/__DOWNLOAD_URL_X86_64__/$X86_64_URL}
PACKAGE_MANIFEST=${PACKAGE_MANIFEST/__CHECKSUM_X86_64__/$X86_64_SUM}

echo "$PACKAGE_MANIFEST" >Package.swift
