# Engineering and Documentation Standards

This rule governs code commenting, documentation, and README maintenance across all workspaces and features in the VanGo project.

## 1. Code Comments and Self-Documenting Code
- **Public APIs and Classes:** Every newly introduced or modified class, enum, model, service, controller, and public method **must** have a descriptive docstring (`///` in Dart, JSDoc in TS/JS). Explain its purpose, parameters, return types, and side effects.
- **Complex Logic & Algorithms:** Any non-trivial calculations (such as geospatial formulas, azimuth/bearing calculations, Haversine distance, time-distance matrix manipulations, state machines, and concurrency/streams) **must** include explanatory inline comments (`//`) detailing *why* and *how* the computation works.
- **Language Consistency:**
  - Code, identifiers, comments (`//`, `///`), docstrings, and technical documentation must be written in **English**.
  - All user-facing text, error messages displayed to the user, dialogs, button labels, and snackbars must be in **Brazilian Portuguese (pt-BR)**.

## 2. Mandatory README & Documentation Synchronization
- **Continuous Documentation:** Whenever a feature, architectural pattern, screen, backend service, dependency, or environment variable is added or altered:
  - The relevant `README.md` (e.g., `vango_app/README.md` for mobile/client, and root `README.md` for backend/platform) **must be promptly updated** before marking the task as complete.
  - Document prerequisites, newly added configuration keys (e.g., in `.env`), permission requirements (e.g., Android `AndroidManifest.xml` / iOS `Info.plist`), and steps to run or test the feature.
- **Test Instructions:** Always provide exact commands and instructions on how to test new features both with automated test suites (`flutter test`) and manually on target devices (web, desktop, Android/iOS devices).
