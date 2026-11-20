# Repository Guidelines

## Project Structure & Module Organization

This repository currently has no source code, tests, assets, or build configuration. When adding the first component, keep its source and tests in clearly named directories (for example, `src/` and `tests/`), and document the resulting layout in `README.md`. Keep generated files out of source directories.

## Build, Test, and Development Commands

No build, test, or run commands are configured yet. Add the commands needed for the chosen stack to `README.md` alongside the first implementation. Prefer one reproducible command for each common task, such as building, running locally, and running the full test suite. Do not assume a toolchain is installed merely because an example command appears in this guide.

## Coding Style & Naming Conventions

Follow the formatter and linter adopted with the first language or framework. Commit their configuration so contributors use the same rules. Use descriptive names, keep formatting changes separate from behavior changes when practical, and use consistent directory and file naming within each component.

## Testing Guidelines

No test framework or coverage threshold has been established. Add focused tests with new behavior, place them in the test location chosen for that component, and document how to run them. Name tests for the behavior they verify, including the expected result and relevant edge case.

## Commit & Pull Request Guidelines

There is no Git history here from which to infer an existing commit convention. Until one is established, use short, imperative commit subjects that describe the change. Pull requests should explain the purpose, summarize the implementation, list verification performed, and link related issues when available. Include screenshots for visible interface changes.

## Configuration & Secrets

Document required environment variables in the project README or a checked-in example configuration file. Never commit credentials, private keys, or local environment files containing secrets.
