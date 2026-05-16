set shell := ["bash", "-cu"]

# preview-kit dogfoods its own release flow.
import 'release.just'

default:
    @just --list

# Validate that preview.just parses and all recipes are listed
check:
    just --list --justfile preview.just

# Run check as a one-shot smoke test
test: check
