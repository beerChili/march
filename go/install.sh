#!/usr/bin/env bash
set -euo pipefail

sudo pacman -S go gopls
go env -w GOPATH=$HOME/Projects/.go

