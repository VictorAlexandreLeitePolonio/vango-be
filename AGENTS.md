# AI Instructions and Engineering Guidelines (VanGo)

All AI agents and assistants working in this repository **MUST ALWAYS** read and strictly follow the project rules defined in:
- [`CONTRIBUTING.md`](./CONTRIBUTING.md)

## Core Non-Negotiable Rules Summary

1. **Test-Driven Development (TDD) Mandatory:**
   - Always follow the strict **Red -> Green -> Refactor** cycle.
   - Never implement code before writing and executing a failing test.
   - For Flutter, write unit tests (`test/unit/`) or widget tests (`test/widget/`) before implementing widgets or business logic.

2. **Language Policy (Portuguese UI / English Code & Docs):**
   - All source code, class names, function names, variable names, database schema identifiers, inline comments (`//`, `///`), docstrings, technical documentation, commit messages, and test descriptions must be written in **English**.
   - User-facing UI copy in the app (labels, placeholders, buttons, titles, validator error messages, snackbars, dialog texts) MUST be in **Portuguese (pt-BR)** using English identifiers and string keys.

3. **Static Analysis & Linting (Zero Issues Allowed):**
   - After completing any implementation, run `flutter analyze` inside `vango_app`.
   - Must achieve **0 issues found** (zero errors, zero warnings).
   - Check code formatting with `dart format`.
   - For backend/Edge Functions, run `deno lint` and `deno check`.

4. **Test Coverage:**
   - Execute `flutter test --coverage` to generate `coverage/lcov.info`.
   - Enforce a minimum threshold of **80% coverage** on business and domain logic layers.

5. **Code Documentation & Comments Standard:**
   - Write clear docstrings (`///` in Dart, JSDoc in TS) for every newly created or updated class, service, model, and public method explaining its purpose, parameters, and return types.
   - Add inline comments (`//`) on non-trivial logic, mathematical computations (e.g., azimuth, bearing, Haversine distance), state management transitions, and UX choices to maintain high code comprehensibility for the team.
   - All code comments and identifiers must remain in **English** (UI copy in **pt-BR**).

6. **Continuous README & Documentation Synchronization:**
   - Whenever new features, architectural components, dependencies, routes, or environment variables are added or modified, update the relevant `README.md` (e.g., `vango_app/README.md` and repository `README.md`) immediately.
   - Document any new `.env` keys, permissions, prerequisites, and instructions on how to test and run the new capabilities.

