#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' pubspec.yaml)"
if [[ -z "$version" ]]; then
  echo "Unable to read the release version from pubspec.yaml." >&2
  exit 1
fi

if ! command -v rpmbuild >/dev/null; then
  echo "rpmbuild is required. Install the rpm-build package and try again." >&2
  exit 1
fi

flutter pub get
flutter build linux --release

bundle_dir="$project_root/build/linux/x64/release/bundle"
desktop_file="$project_root/packaging/rpm/audiobridge.desktop"
spec_file="$project_root/packaging/rpm/audiobridge.spec"
archive_dir="$project_root/build/release"

if [[ ! -x "$bundle_dir/audiobridge" ]]; then
  echo "Linux release bundle not found at $bundle_dir." >&2
  exit 1
fi

build_root="$(mktemp -d "${TMPDIR:-/tmp}/audiobridge-rpm.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
mkdir -p "$archive_dir"

rpmbuild \
  --define "_topdir $build_root" \
  --define "_app_version $version" \
  --define "_bundle_dir $bundle_dir" \
  --define "_desktop_file $desktop_file" \
  -bb "$spec_file"

rpm_path="$build_root/RPMS/x86_64/audiobridge-${version}-1.x86_64.rpm"
if [[ ! -f "$rpm_path" ]]; then
  echo "RPM build completed without producing the expected package." >&2
  exit 1
fi

archive_path="$archive_dir/AudioBridge-${version}-1.x86_64.rpm"
cp "$rpm_path" "$archive_path"
printf '%s\n' "$archive_path"
