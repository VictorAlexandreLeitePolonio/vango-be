# AI Instructions and Engineering Guidelines (VanGo)

All AI agents and assistants working in this repository **MUST ALWAYS** read and strictly follow the project rules defined in:
- [`CONTRIBUTING.md`](./CONTRIBUTING.md)

## Core Non-Negotiable Rules Summary

1. **Test-Driven Development (TDD) Mandatory:**
   - Always follow the strict **Red -> Green -> Refactor** cycle.
   - Never implement code before writing and executing a failing test.
   - For Flutter, write unit tests (`test/unit/`) or widget tests (`test/widget/`) before implementing widgets or business logic.

2. **Strict English-Only Policy:**
   - All code, class names, function names, variable names, database schema identifiers, comments (`//`, `///`), docstrings, commit messages, and test descriptions must be written in **English**.
   - User-facing UI copy in Portuguese (pt-BR) must use English identifiers and string keys.

3. **Static Analysis & Linting (Zero Issues Allowed):**
   - After completing any implementation, run `flutter analyze` inside `vango_app`.
   - Must achieve **0 issues found** (zero errors, zero warnings).
   - Check code formatting with `dart format`.
   - For backend/Edge Functions, run `deno lint` and `deno check`.

4. **Test Coverage:**
   - Execute `flutter test --coverage` to generate `coverage/lcov.info`.
   - Enforce a minimum threshold of **80% coverage** on business and domain logic layers.
