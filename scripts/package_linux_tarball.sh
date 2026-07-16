#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' pubspec.yaml)"
if [[ -z "$version" ]]; then
  echo "Unable to read the release version from pubspec.yaml." >&2
  exit 1
fi

flutter pub get
flutter build linux --release

bundle_dir="build/linux/x64/release/bundle"
archive_dir="build/release"
archive_path="$archive_dir/AudioBridge-${version}-linux-x64.tar.gz"
if [[ ! -d "$bundle_dir" ]]; then
  echo "Linux release bundle not found at $bundle_dir." >&2
  exit 1
fi

mkdir -p "$archive_dir"
rm -f "$archive_path"
tar -C "$(dirname "$bundle_dir")" -czf "$archive_path" "$(basename "$bundle_dir")"
printf '%s\n' "$archive_path"
