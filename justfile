set shell := ["bash", "-uc"]

# `release` / `version` / changelog recipes come from release.just (shared).

import 'release.just'

default:
    @just --list

# preview-kit dogfoods its own release flow.

# Validate that preview.just parses and all recipes are listed
check:
    just --list --justfile preview.just

# Run check as a one-shot smoke test
test: check
