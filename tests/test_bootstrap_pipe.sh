#!/usr/bin/env bash
# Real pipe + pseudoterminal smoke test using a fake archive, no network.
# Intended only for ephemeral GitHub-hosted Ubuntu CI runners.
set -euo pipefail
BASE_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
temp="$(mktemp -d)"
target=/opt/srv-settings
if [[ -e "$target" ]]; then
  echo "Refusing to overwrite an existing $target during smoke test" >&2
  exit 1
fi
cleanup() {
  sudo rm -rf -- "$target"
  rm -rf -- "$temp"
}
trap cleanup EXIT
mkdir -p "$temp/fixture/srv-settings-main" "$temp/mock"
cat > "$temp/fixture/srv-settings-main/setup.sh" <<'SETUP'
#!/usr/bin/env bash
set -euo pipefail
IFS= read -r -p "Interactive token: " value
[[ "$value" == "tty-ok" ]]
printf 'tty-ok\n' > "$TEST_RECEIPT"
SETUP
tar -czf "$temp/fixture.tar.gz" -C "$temp/fixture" srv-settings-main
cat > "$temp/mock/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output=''
url=''
while (( $# > 0 )); do
  case "$1" in
    -o) output="$2"; shift 2;;
    http*) url="$1"; shift;;
    *) shift;;
  esac
done
[[ -n "$output" ]]
case "$url" in
  *api.github.com/repos/medneem/srv-settings/commits/main*)
    printf '{"sha":"%s"}\n' "$TEST_FAKE_SHA" > "$output"
    ;;
  "https://codeload.github.com/medneem/srv-settings/tar.gz/$TEST_FAKE_SHA")
    cp -- "$TEST_ARCHIVE" "$output"
    ;;
  *) printf 'Unexpected curl URL: %s\n' "$url" >&2; exit 1;;
esac
MOCK
chmod +x "$temp/mock/curl"
fake_sha=0123456789abcdef0123456789abcdef01234567
receipt="$temp/receipt.txt"
# Legacy curl | sudo bash installation: do not launch an interactive menu. sudo
# may not relay terminal input to a piped command when use_pty is configured.
# 'script' supplies a pseudoterminal on otherwise non-interactive CI runners.
timeout 12s script -q -e -c "cat '$BASE_DIR/bootstrap.sh' | sudo env PATH='$temp/mock:$PATH' TEST_ARCHIVE='$temp/fixture.tar.gz' TEST_FAKE_SHA='$fake_sha' TEST_RECEIPT='$receipt' bash" /dev/null \
  > "$temp/legacy.log" 2>&1 || { cat "$temp/legacy.log" >&2; exit 1; }
if [[ -e "$receipt" ]]; then
  cat "$temp/legacy.log" >&2
  echo "Legacy pipe unexpectedly started the interactive menu" >&2
  exit 1
fi
grep -Fq 'sudo bash /opt/srv-settings/setup.sh' "$temp/legacy.log" || {
  cat "$temp/legacy.log" >&2
  echo 'Legacy pipe did not explain how to launch menu' >&2
  exit 1
}
[[ "$(cat "$target/.installed-commit")" == "$fake_sha" ]]

# In the recommended form sudo is the outer command and owns tty stdin, so
# bootstrap may safely enter interactive setup after reading its script pipe.
{ sleep 1; printf 'tty-ok\n'; sleep 1; } |
  timeout 12s script -q -e -c "sudo env PATH='$temp/mock:$PATH' TEST_ARCHIVE='$temp/fixture.tar.gz' TEST_FAKE_SHA='$fake_sha' TEST_RECEIPT='$receipt' bash -c \"cat '$BASE_DIR/bootstrap.sh' | bash\"" /dev/null \
  > "$temp/interactive.log" 2>&1 || { cat "$temp/interactive.log" >&2; exit 1; }
if [[ "$(cat "$receipt" 2>/dev/null)" != tty-ok ]]; then
  cat "$temp/interactive.log" >&2
  echo "Menu did not read from tty in the recommended form" >&2
  exit 1
fi
grep -Fq "$fake_sha" "$temp/interactive.log"
printf 'bootstrap pipe/sudo terminal regression smoke test: OK\n'
