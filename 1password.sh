#!/usr/bin/env bash
set -euo pipefail

curl -sS https://downloads.1password.com/linux/keys/1password.asc | gpg --import
aur sync 1password
