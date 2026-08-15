# Contributing

Contributions are welcome. Here's how to get started.

## Setting up

```sh
git clone <repo-url>
cd build_system
swift build
swift test --package-path SemelCore
```

## Project layout

| Directory | Purpose |
|-----------|---------|
| `build_system/` | CLI executable and command plugins |
| `SemelCore/` | Core library — engine, node functions, graph, database |
| `SemelDatabaseModels/` | GRDB schema models shared by both packages |

## Making changes

- Keep changes focused — one concern per PR
- Add or update tests in `SemelCore/Tests/` for anything in the core library
- Run `swift test --package-path SemelCore` before opening a PR
- Follow the existing code style (no comments explaining *what* code does, only *why*)

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.yml). Include the output of `swift --version` and `sw_vers`, the commands that triggered the issue, and any error output from the `e` command.

## License

By contributing you agree that your contributions will be licensed under the [MIT License](../LICENSE).
