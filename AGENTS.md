# Repository Guidelines

## Project Structure & Module Organization

This repository is currently empty apart from its Git history and this guide. No source, test, or asset directories have been established. When adding the first implementation, group related code together and introduce clearly named directories for tests and assets as needed. Document the resulting layout here.

## Build, Test, and Development Commands

No build system, package manager, or local run command is configured yet. When introducing tooling, document the exact setup, build, run, and test commands in this section. Prefer commands that work from the repository root and record required runtime versions and dependencies.

## Coding Style & Naming Conventions

No language-specific formatter or linter is configured. Follow the conventions of the language and any existing code when adding files. Use descriptive names for modules, functions, and variables; keep naming consistent within each language. If formatting or linting tools are added, configure them in the repository and document how to run them.

## Testing Guidelines

No test framework or coverage target is defined. Add tests alongside new behavior using the chosen framework, and document the test location, naming pattern, and command here. Cover meaningful behavior and edge cases, especially when fixing a defect.

## Commit & Pull Request Guidelines

The available Git history contains only `Initial commit`, so it does not establish a broader message convention. Use short, descriptive commit subjects that explain the change. For pull requests, describe the purpose and behavior, list the checks performed, and link related issues when available. Include screenshots or recordings for visible interface changes.

## Security & Configuration

Do not commit secrets, credentials, or machine-specific configuration. When configuration becomes necessary, provide an example file with placeholder values and document how contributors supply local settings.

## Current implementation

The Flutter plugin API is in `lib/`, Android code in `android/src/main/`, iOS code in `ios/Classes/`, tests in `test/`, and the example app in `example/`. Run `flutter pub get`, `flutter analyze`, and `flutter test` from the repository root with a Flutter SDK. Android and iOS builds additionally require their platform toolchains.
