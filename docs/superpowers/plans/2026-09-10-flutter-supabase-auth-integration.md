# Flutter Supabase Auth Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the simulated authentication behavior in the existing Flutter auth screens with Supabase Auth and profile persistence, while preserving the current UI and adding the minimum session and password-recovery flow required for a usable integration.

**Architecture:** Keep the current feature-first Flutter structure. Add one Auth service boundary under `features/auth`, initialize `supabase_flutter` once from compile-time configuration, and let the current screens call the service through constructor injection for widget tests. Supabase Auth owns credentials and sessions; `public.profiles` stores `full_name` under the existing RLS policy. No custom backend, JWT, password hash, role claim, or database migration is introduced unless an implementation-time contract check proves the current schema insufficient.

**Tech Stack:** Flutter/Dart 3.11.3, `supabase_flutter` v2 with the current verified patch version, Supabase Auth, PostgREST/Data API, Flutter test, local Supabase CLI, Android deep links, and iOS URL schemes.

**Spec:** `CONTRIBUTING.md` sections 2–3, 5–7, 12–14; `be-tech-plan.md` sections 4, 8, 9, 12, and 13; `supabase/migrations/20260905225944_create_foundation_tables.sql`; `supabase/migrations/20260905225945_create_profile_triggers.sql`; `supabase/migrations/20260905225947_create_foundation_rls.sql`; current screens under `vango_app/lib/features/auth/screens`.

## Global Constraints

- Follow RED → GREEN → REFACTOR for every behavior change.
- Read the current Supabase changelog and official Dart references before changing package APIs or deep-link behavior.
- Use `Supabase.initialize(url: ..., publishableKey: ...)`; the legacy `anonKey` name is not the preferred new configuration.
- The Flutter client may contain only the public publishable/anon key; never add `service_role`, secret keys, or database passwords.
- Never use `user_metadata` or `app_metadata` for authorization decisions. `full_name` metadata is only a temporary profile-data input, not a role source.
- Preserve existing Portuguese user-facing copy and English identifiers, comments, tests, and technical documentation.
- Keep all UI and authentication calls out of `main.dart` except SDK initialization and application bootstrap.
- Do not add a repository, state-management package, generated API client, or generic network abstraction for this first Auth slice.
- Do not change existing migrations or add a migration for authentication unless the current `profiles` contract fails a verified integration test.
- Do not add a product dashboard, fleet, marketplace, trip, map, notification, or Realtime screen in this plan. The temporary authenticated screen exists only to verify the session boundary.
- Run the local Supabase stack before runtime tests; do not seed or reset a remote project.
- Do not commit or push without explicit authorization.

## Current Baseline

The Flutter feature commit is `921ba6b` (`feat(auth): initialize Flutter app with design system and auth screens`). The current app contains `WelcomeScreen`, `LoginScreen`, `RegisterScreen`, and `ForgotPasswordScreen`. Login, registration, and password reset currently use local validators, a 1.5-second delay, and success snackbars.

At the committed baseline, `vango_app/pubspec.yaml` had no `supabase_flutter` dependency, `main.dart` did not initialize Supabase, and no Auth service or session gate existed. If the current working tree already contains the dependency or generated plugin registrations, record and preserve those changes, then verify them instead of adding a duplicate or changing unrelated packages. `AppRoutes` has no authenticated destination and no password-update route. The backend already creates a minimal profile after `auth.users` insertion, permits the authenticated user to update `profiles.full_name`, and uses RLS to restrict profile reads and updates to the current user.

## File Map

| File | Responsibility |
| --- | --- |
| `vango_app/pubspec.yaml` | Add the verified `supabase_flutter` v2 dependency. |
| `vango_app/pubspec.lock` | Record the resolved package version. |
| `vango_app/lib/core/config/supabase_config.dart` | Read and validate `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` from `--dart-define`. |
| `vango_app/lib/main.dart` | Initialize Supabase before `runApp` and provide the production Auth service. |
| `vango_app/lib/features/auth/services/auth_service.dart` | Define the small Auth boundary used by screens and the Supabase implementation. |
| `vango_app/lib/features/auth/services/auth_error_mapper.dart` | Convert verified SDK/Auth error identifiers into Portuguese UI messages with a generic fallback. |
| `vango_app/lib/features/auth/models/auth_result.dart` | Represent whether Auth returned a user and an active session. |
| `vango_app/lib/features/auth/screens/login_screen.dart` | Call real password sign-in and preserve the current form/visual states. |
| `vango_app/lib/features/auth/screens/register_screen.dart` | Call real sign-up and persist `full_name` when an authenticated session exists. |
| `vango_app/lib/features/auth/screens/forgot_password_screen.dart` | Request a real reset email and show the existing sent state. |
| `vango_app/lib/features/auth/screens/reset_password_screen.dart` | Accept a new password after a Supabase recovery callback. |
| `vango_app/lib/features/auth/screens/authenticated_home_screen.dart` | Temporary authenticated destination showing the current account and sign-out action. |
| `vango_app/lib/features/auth/widgets/auth_gate.dart` | Restore the persisted session and switch between public, authenticated, and recovery states. |
| `vango_app/lib/core/routes/app_routes.dart` | Register reset and temporary authenticated routes if navigation requires them. |
| `vango_app/ios/Runner/Info.plist` | Register the VanGo mobile URL scheme. |
| `vango_app/android/app/src/main/AndroidManifest.xml` | Register the Android callback intent filter. |
| `supabase/config.toml` | Add the local development callback URLs only if the chosen scheme is used during local Auth tests. |
| `vango_app/test/unit/core/config/supabase_config_test.dart` | Test configuration validation. |
| `vango_app/test/unit/features/auth/auth_service_test.dart` | Test Auth service behavior through a small fake Auth client and profile update contract. |
| `vango_app/test/support/fake_auth_client.dart` | Test-only narrow client seam used by Auth service unit tests; not shipped as application architecture. |
| `vango_app/test/support/fake_auth_service.dart` | Shared widget-test fake and `buildTestApp` helper for deterministic Auth screen tests. |
| `vango_app/test/unit/features/auth/auth_error_mapper_test.dart` | Test stable Auth failure mappings and fallback behavior. |
| `vango_app/test/widget/features/auth/login_screen_test.dart` | Test sign-in submission, loading, success navigation, and failure copy. |
| `vango_app/test/widget/features/auth/register_screen_test.dart` | Test sign-up submission, session/no-session copy, and profile failure handling. |
| `vango_app/test/widget/features/auth/forgot_password_screen_test.dart` | Test reset-email submission and sent state. |
| `vango_app/test/widget/features/auth/auth_gate_test.dart` | Test public, authenticated, signed-out, and password-recovery states. |
| `vango_app/test/widget/features/auth/reset_password_screen_test.dart` | Test password update validation and success navigation. |
| `vango_app/test/widget/features/auth/authenticated_home_screen_test.dart` | Test account display and sign-out. |
| `vango_app/README.md` | Document the non-secret runtime configuration and local/remote run commands. |

## Approved Interfaces

Use the following small boundary so screens do not depend directly on `Supabase.instance.client`:

```dart
abstract interface class AuthService {
  Session? get currentSession;

  Stream<AuthState> get authStateChanges;

  Future<AuthResult> signIn({
    required String email,
    required String password,
  });

  Future<AuthResult> signUp({
    required String fullName,
    required String email,
    required String password,
  });

  Future<void> sendPasswordReset({required String email});

  Future<void> updatePassword({required String password});

  Future<void> signOut();
}
```

For unit-test injection only, define this narrow client seam in the same service file:

```dart
abstract interface class AuthClient {
  Session? get currentSession;

  Stream<AuthState> get authStateChanges;

  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  });

  Future<AuthResponse> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? data,
    String? emailRedirectTo,
  });

  Future<void> resetPasswordForEmail(String email, {String? redirectTo});

  Future<UserResponse> updateUser(UserAttributes attributes);

  Future<void> signOut();

  Future<void> updateOwnProfile({
    required String userId,
    required String fullName,
  });
}
```

`SupabaseAuthService` implements `AuthService` and accepts `AuthClient`; production construction wraps `Supabase.instance.client`, while tests inject `FakeAuthClient`. `AuthResult` contains `String? userId` and `bool hasSession`. A sign-up response with `hasSession == false` means the configured project requires email confirmation; the UI must show the verification message and must not pretend that the user is already signed in.

The profile update is an authenticated Data API operation with this exact contract:

```dart
await client
    .from('profiles')
    .update({'full_name': fullName.trim()})
    .eq('id', userId);
```

The client must not insert into `profiles`, set `id` from form state, or use a service key. The database trigger creates the row, and the existing `profiles_select_own` plus `profiles_update_own` policies protect the operation.

## Implementation Tasks

### Task 1: Verify the SDK contract and add the dependency

**Files:**
- Modify: `vango_app/pubspec.yaml`
- Modify: `vango_app/pubspec.lock`
- No production Dart behavior yet

- [x] **Step 1: Record the clean baseline**

Run:

```bash
git status --short
git log --oneline --decorate -5 -- vango_app
```

Expected: pre-existing changes are recorded and preserved; only files listed for the Auth slice are added to the implementation diff, and the latest Flutter feature commit remains `921ba6b`.

- [x] **Step 2: Verify current official Supabase references**

Read the current versions of these references before coding:

- `https://supabase.com/docs/reference/dart/initializing`
- `https://supabase.com/docs/reference/dart/auth-signinwithpassword`
- `https://supabase.com/docs/reference/dart/auth-signup`
- `https://supabase.com/docs/reference/dart/auth-resetpasswordforemail`
- `https://supabase.com/docs/reference/dart/auth-updateuser`
- `https://supabase.com/docs/reference/dart/auth-onauthstatechange`
- `https://supabase.com/docs/guides/auth/native-mobile-deep-linking`

Confirm that the resolved SDK uses `publishableKey`, `currentSession`, the v2 Auth methods, the current `AuthException` fields, and the current recovery event name. Do not copy old v1 examples into the app.

- [x] **Step 3: Verify or add the current v2 client package**

From `vango_app`, run:

```bash
flutter pub get
```

If `supabase_flutter` is absent, run `flutter pub add supabase_flutter`; if it is already present, keep the existing compatible constraint and only verify the resolved version. Review any generated platform registration changes, preserve pre-existing ones, and do not add another HTTP, environment, state-management, or mocking package for this slice.

- [x] **Step 4: Confirm the package setup without claiming feature completion**

Run:

```bash
flutter pub get
flutter analyze
```

Expected: dependency resolution succeeds. Any pre-existing analyzer issue is recorded before the first behavior task; no Auth behavior is expected yet.

### Task 2: Add validated runtime configuration and SDK initialization

**Files:**
- Create: `vango_app/lib/core/config/supabase_config.dart`
- Test: `vango_app/test/unit/core/config/supabase_config_test.dart`
- Modify: `vango_app/lib/main.dart`

**Interfaces:**
- Produces `SupabaseConfig.fromEnvironment()` with `url` and `publishableKey`.
- `validate()` throws `ArgumentError` when either value is empty or the URL is not an absolute HTTP(S) URL.

- [x] **Step 1: Write the failing configuration tests**

```dart
void main() {
  test('accepts an absolute Supabase URL and a publishable key', () {
    const config = SupabaseConfig(
      url: 'https://example.supabase.co',
      publishableKey: 'public-key',
    );

    expect(config.validate, returnsNormally);
  });

  test('rejects an empty publishable key', () {
    const config = SupabaseConfig(
      url: 'https://example.supabase.co',
      publishableKey: '',
    );

    expect(config.validate, throwsArgumentError);
  });

  test('rejects a non-HTTP Supabase URL', () {
    const config = SupabaseConfig(
      url: 'supabase.local',
      publishableKey: 'public-key',
    );

    expect(config.validate, throwsArgumentError);
  });
}
```

- [x] **Step 2: Run the focused test and verify RED**

Run:

```bash
flutter test test/unit/core/config/supabase_config_test.dart
```

Expected: FAIL because `SupabaseConfig` does not exist.

- [x] **Step 3: Implement the minimum configuration object**

Implement a `const` value object that reads:

```dart
const SupabaseConfig.fromEnvironment()
    : url = const String.fromEnvironment('SUPABASE_URL'),
      publishableKey = const String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      );
```

Validate the URL with `Uri.tryParse`, require `hasScheme`, `hasAuthority`, and an `http` or `https` scheme, and reject blank keys. Do not add a fallback URL or key.

- [x] **Step 4: Initialize Supabase before the app starts**

Change `main()` to:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = SupabaseConfig.fromEnvironment()..validate();
  await Supabase.initialize(
    url: config.url,
    publishableKey: config.publishableKey,
  );

  runApp(const VanGoApp());
}
```

Preserve the existing system UI overlay setup and move it after initialization only if the Dart analyzer requires a specific ordering. Do not put credentials in source code.

- [x] **Step 5: Run the focused test and verify GREEN**

Run:

```bash
flutter test test/unit/core/config/supabase_config_test.dart
```

Expected: PASS.

### Task 3: Create the Auth service and stable error boundary

**Files:**
- Create: `vango_app/lib/features/auth/models/auth_result.dart`
- Create: `vango_app/lib/features/auth/services/auth_service.dart`
- Create: `vango_app/lib/features/auth/services/auth_error_mapper.dart`
- Test: `vango_app/test/unit/features/auth/auth_service_test.dart`
- Test: `vango_app/test/unit/features/auth/auth_error_mapper_test.dart`

**Interfaces:**
- `AuthService` exposes the approved methods in this plan.
- `SupabaseAuthService` delegates credentials/session work to the current Supabase SDK.
- `AuthErrorMapper.message(Object error)` returns a Portuguese message and never returns a raw stack trace.

- [x] **Step 1: Write failing service tests against a fake Auth client**

To keep these tests deterministic without adding a mocking package, define a narrow `AuthClient` seam in `auth_service.dart` and a matching `FakeAuthClient` in `test/support/fake_auth_client.dart`. The seam contains only `currentSession`, `authStateChanges`, `signInWithPassword`, `signUp`, `resetPasswordForEmail`, `updateUser`, `signOut`, and `updateOwnProfile`. The production adapter delegates those calls to `Supabase.instance.client`; the fake records the email, profile payload, and call counts used below. This is a test seam, not a generic HTTP or repository layer.

Cover these behaviors:

```dart
test('signIn trims the email and returns the authenticated user', () async {
  final client = FakeAuthClient.signedIn(userId: 'user-1');
  final service = SupabaseAuthService(client: client);

  final result = await service.signIn(
    email: ' user@example.com ',
    password: 'secret123',
  );

  expect(client.lastEmail, 'user@example.com');
  expect(result.userId, 'user-1');
  expect(result.hasSession, isTrue);
});

test('signUp updates the own profile when a session is returned', () async {
  final client = FakeAuthClient.signedIn(userId: 'user-1');
  final service = SupabaseAuthService(client: client);

  await service.signUp(
    fullName: ' Maria Silva ',
    email: 'maria@example.com',
    password: 'secret123',
  );

  expect(client.updatedProfile, {
    'id': 'user-1',
    'full_name': 'Maria Silva',
  });
});

test('signUp preserves the no-session result when email confirmation is required', () async {
  final client = FakeAuthClient.emailConfirmationRequired();
  final service = SupabaseAuthService(client: client);

  final result = await service.signUp(
    fullName: 'Maria Silva',
    email: 'maria@example.com',
    password: 'secret123',
  );

  expect(result.hasSession, isFalse);
  expect(client.updatedProfile, isNull);
});
```

The fake may be private to the test file or live in `test/support`; it must implement only the methods required by the service boundary. It must not become a production abstraction beyond the `AuthService` interface.

- [x] **Step 2: Run the focused tests and verify RED**

Run:

```bash
flutter test test/unit/features/auth/auth_service_test.dart test/unit/features/auth/auth_error_mapper_test.dart
```

Expected: FAIL because the Auth service, result, mapper, and test fake do not exist.

- [x] **Step 3: Implement the Supabase Auth calls**

Use the current SDK equivalents of:

```dart
client.auth.signInWithPassword(
  email: email.trim(),
  password: password,
);

client.auth.signUp(
  email: email.trim(),
  password: password,
  data: {'full_name': fullName.trim()},
  emailRedirectTo: 'com.vango.vango_app://auth-callback/',
);

client
    .from('profiles')
    .update({'full_name': fullName.trim()})
    .eq('id', response.user!.id);

client.auth.resetPasswordForEmail(
  email.trim(),
  redirectTo: 'com.vango.vango_app://auth-callback/',
);

client.auth.updateUser(UserAttributes(password: password));
```

The `data` entry helps retain the name through a confirmation flow, but it is not an authorization source. Only update `profiles` when `response.session` and `response.user` are both present. If the profile update fails after a successful account creation, propagate the error so the screen reports a partial failure instead of claiming complete success.

- [x] **Step 4: Implement error mapping from verified SDK fields**

Map the current SDK's stable Auth error identifier/status values for invalid credentials, already-registered email, weak password, rate limiting, and network failure. Return these Portuguese messages:

```text
E-mail ou senha incorretos.
Este e-mail já está cadastrado.
A senha não atende aos requisitos mínimos.
Muitas tentativas. Aguarde um momento e tente novamente.
Não foi possível conectar ao servidor. Verifique sua internet.
Não foi possível concluir a operação. Tente novamente.
```

Do not branch on the complete server error message. Preserve the original exception for logs/debugging outside user-visible copy, without logging credentials or tokens.

- [x] **Step 5: Run the focused tests and verify GREEN**

Run:

```bash
flutter test test/unit/features/auth/auth_service_test.dart test/unit/features/auth/auth_error_mapper_test.dart
```

Expected: PASS.

### Task 4: Wire Login and Registration to the service

**Files:**
- Modify: `vango_app/lib/features/auth/screens/login_screen.dart`
- Modify: `vango_app/lib/features/auth/screens/register_screen.dart`
- Test: `vango_app/test/widget/features/auth/login_screen_test.dart`
- Test: `vango_app/test/widget/features/auth/register_screen_test.dart`

**Interfaces:**
- Both screens accept an optional `AuthService` constructor parameter for tests and use `SupabaseAuthService` in production.
- A successful call shows the existing Portuguese success state; navigation is finalized in Task 5 after the authenticated destination exists.
- Unconfirmed sign-up remains on the register flow and displays the email-verification message.

- [x] **Step 1: Write failing widget tests**

Cover the current UI contract plus the new calls:

```dart
testWidgets('login calls AuthService and shows success after sign-in', (tester) async {
  final service = FakeAuthService.signedIn(userId: 'user-1');

  await tester.pumpWidget(buildTestApp(LoginScreen(authService: service)));
  await tester.enterText(find.bySemanticsLabel('E-mail'), 'user@example.com');
  await tester.enterText(find.bySemanticsLabel('Senha'), 'secret123');
  await tester.tap(find.text('Entrar'));
  await tester.pumpAndSettle();

  expect(service.signInCalls, 1);
  expect(find.text('Login realizado com sucesso!'), findsOneWidget);
});

testWidgets('register sends the full name after an immediate session', (tester) async {
  final service = FakeAuthService.signedIn(userId: 'user-1');

  await tester.pumpWidget(buildTestApp(RegisterScreen(authService: service)));
  await tester.enterText(find.bySemanticsLabel('Nome completo'), 'Maria Silva');
  await tester.enterText(find.bySemanticsLabel('E-mail'), 'maria@example.com');
  await tester.enterText(find.bySemanticsLabel('Senha'), 'secret123');
  await tester.enterText(find.bySemanticsLabel('Confirmar senha'), 'secret123');
  await tester.tap(find.text('Criar Conta'));
  await tester.pumpAndSettle();

  expect(service.signUpCalls, 1);
  expect(service.lastFullName, 'Maria Silva');
  expect(find.text('Conta criada com sucesso!'), findsOneWidget);
});

testWidgets('register explains email confirmation when no session is returned', (tester) async {
  final service = FakeAuthService.emailConfirmationRequired();

  await tester.pumpWidget(buildTestApp(RegisterScreen(authService: service)));
  await tester.enterText(find.bySemanticsLabel('Nome completo'), 'Maria Silva');
  await tester.enterText(find.bySemanticsLabel('E-mail'), 'maria@example.com');
  await tester.enterText(find.bySemanticsLabel('Senha'), 'secret123');
  await tester.enterText(find.bySemanticsLabel('Confirmar senha'), 'secret123');
  await tester.tap(find.text('Criar Conta'));
  await tester.pumpAndSettle();

  expect(find.textContaining('Verifique seu e-mail'), findsOneWidget);
});
```

The test helper must enter valid values explicitly; keep validator tests separate from service tests.

- [x] **Step 2: Run the focused widget tests and verify RED**

Run:

```bash
flutter test test/widget/features/auth/login_screen_test.dart test/widget/features/auth/register_screen_test.dart
```

Expected: FAIL because the screens still use the simulated delay and no authenticated destination exists.

- [x] **Step 3: Inject the service and replace only the simulated handlers**

Preserve the existing validators, animations, layout, and Portuguese copy. Replace the `Future.delayed` blocks with service calls. Keep `_isLoading`, guard `mounted` after every await, and show the mapped error in the existing snackbar pattern.

For Login, call `signIn` with trimmed email and show `Login realizado com sucesso!`. For Register, call `signUp` with the trimmed full name; show `Conta criada com sucesso!` only when `hasSession` is true, otherwise show a confirmation message and keep the account unclaimed in the UI. Do not add navigation until Task 5.

- [x] **Step 4: Run the focused widget tests and verify GREEN**

Run:

```bash
flutter test test/widget/features/auth/login_screen_test.dart test/widget/features/auth/register_screen_test.dart
```

Expected: PASS.

### Task 5: Add the minimum authenticated destination and session restoration

**Files:**
- Create: `vango_app/lib/features/auth/widgets/auth_gate.dart`
- Create: `vango_app/lib/features/auth/screens/authenticated_home_screen.dart`
- Modify: `vango_app/lib/main.dart`
- Modify: `vango_app/lib/core/routes/app_routes.dart`
- Modify: `vango_app/lib/features/auth/screens/login_screen.dart`
- Modify: `vango_app/lib/features/auth/screens/register_screen.dart`
- Test: `vango_app/test/widget/features/auth/auth_gate_test.dart`
- Test: `vango_app/test/widget/features/auth/authenticated_home_screen_test.dart`

**Interfaces:**
- `AuthGate` receives an `AuthService` and renders `WelcomeScreen` when `currentSession == null` and `AuthenticatedHomeScreen` when a session exists. Password recovery is added to the gate in Task 6.
- `AuthenticatedHomeScreen` receives the current session identity only for display and exposes a sign-out action.

- [x] **Step 1: Write failing gate and home tests**

```dart
testWidgets('shows public entry when there is no session', (tester) async {
  final service = FakeAuthService.signedOut();

  await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));

  expect(find.text('Transporte escolar\nseguro e organizado'), findsOneWidget);
});

testWidgets('shows the authenticated destination for an existing session', (tester) async {
  final service = FakeAuthService.signedIn(userId: 'user-1');

  await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));

  expect(find.text('VanGo autenticado'), findsOneWidget);
  expect(find.text('Sair'), findsOneWidget);
});

testWidgets('sign out returns to the public entry', (tester) async {
  final service = FakeAuthService.signedIn(userId: 'user-1');

  await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));
  await tester.tap(find.text('Sair'));
  await tester.pump();

  expect(service.signOutCalls, 1);
  expect(find.text('Transporte escolar\nseguro e organizado'), findsOneWidget);
});
```

- [x] **Step 2: Run the focused tests and verify RED**

Run:

```bash
flutter test test/widget/features/auth/auth_gate_test.dart test/widget/features/auth/authenticated_home_screen_test.dart
```

Expected: FAIL because the gate, home screen, route, and sign-out flow do not exist.

- [x] **Step 3: Implement the session gate**

Use `auth.currentSession` for the initial state and subscribe to `authStateChanges` with an explicit `onError` handler. React to `signedIn`, `signedOut`, `initialSession`, and `tokenRefreshed`. Password recovery is wired in Task 6. Cancel the subscription in `dispose`.

Keep the temporary home intentionally small: show the authenticated email or user id, a Portuguese sign-out button, and no fleet/domain data. The screen is a testable handoff point for the next product feature.

- [x] **Step 4: Make `VanGoApp` start at `AuthGate`**

Keep named routes for the public screens, add `AppRoutes.authenticatedHome`, and pass the production `SupabaseAuthService` from the initialized app. Update the successful Login and Register branches from Task 4 to navigate to that route only after the service returns success. Do not duplicate session checks inside every screen.

- [x] **Step 5: Run the focused tests and verify GREEN**

Run:

```bash
flutter test test/widget/features/auth/auth_gate_test.dart test/widget/features/auth/authenticated_home_screen_test.dart
flutter test test/widget/features/auth/login_screen_test.dart test/widget/features/auth/register_screen_test.dart
```

Expected: PASS.

### Task 6: Complete password recovery and mobile deep links

**Files:**
- Modify: `vango_app/lib/features/auth/screens/forgot_password_screen.dart`
- Create: `vango_app/lib/features/auth/screens/reset_password_screen.dart`
- Modify: `vango_app/lib/features/auth/widgets/auth_gate.dart`
- Modify: `vango_app/lib/core/routes/app_routes.dart`
- Modify: `vango_app/ios/Runner/Info.plist`
- Modify: `vango_app/android/app/src/main/AndroidManifest.xml`
- Modify: `supabase/config.toml`
- Test: `vango_app/test/widget/features/auth/forgot_password_screen_test.dart`
- Test: `vango_app/test/widget/features/auth/reset_password_screen_test.dart`
- Modify: `vango_app/test/widget/features/auth/auth_gate_test.dart`

**Interfaces:**
- Forgot password calls `AuthService.sendPasswordReset` and retains the existing sent state.
- The shared mobile recovery callback is `com.vango.vango_app://auth-callback/`.
- Reset screen calls `AuthService.updatePassword` and returns to the authenticated gate on success.

- [x] **Step 1: Write failing reset-flow tests**

```dart
testWidgets('forgot password requests a reset email', (tester) async {
  final service = FakeAuthService.signedOut();

  await tester.pumpWidget(buildTestApp(
    ForgotPasswordScreen(authService: service),
  ));
  await tester.enterText(find.bySemanticsLabel('E-mail'), 'user@example.com');
  await tester.tap(find.text('Enviar link'));
  await tester.pumpAndSettle();

  expect(service.passwordResetCalls, 1);
  expect(find.text('E-mail enviado!'), findsOneWidget);
});

testWidgets('reset screen validates and updates the password', (tester) async {
  final service = FakeAuthService.signedIn(userId: 'user-1');

  await tester.pumpWidget(buildTestApp(
    ResetPasswordScreen(authService: service),
  ));
  await tester.enterText(find.bySemanticsLabel('Nova senha'), 'secret123');
  await tester.enterText(find.bySemanticsLabel('Confirmar senha'), 'secret123');
  await tester.tap(find.text('Atualizar senha'));
  await tester.pumpAndSettle();

  expect(service.updatePasswordCalls, 1);
});
```

- [x] **Step 2: Run the focused tests and verify RED**

Run:

```bash
flutter test test/widget/features/auth/forgot_password_screen_test.dart test/widget/features/auth/reset_password_screen_test.dart
```

Expected: FAIL because the screens still use the simulated delay and the reset screen does not exist.

- [x] **Step 3: Replace the simulated password-reset request**

Call `sendPasswordReset` with the trimmed email and keep the current success state. Use the same loading/error treatment as Login and Register.

- [x] **Step 4: Implement the password-update screen**

Add two password fields using the existing `VanGoTextField`, retain the six-character local validation, call `updatePassword`, show a Portuguese success message, and let `AuthGate` render the authenticated destination after the `passwordRecovery` event is completed.

- [x] **Step 5: Connect recovery state and register the mobile callback**

Handle `passwordRecovery` in `AuthGate` and render `ResetPasswordScreen` until the password update succeeds. Add the exact scheme `com.vango.vango_app` to iOS `CFBundleURLTypes`. Add an Android `VIEW` intent filter with `DEFAULT`, `BROWSABLE`, scheme `com.vango.vango_app`, and host `auth-callback`. Add the exact callback URL to local `auth.additional_redirect_urls`; configure the hosted project's Auth redirect allow-list separately without committing credentials.

- [x] **Step 6: Run the focused tests and verify GREEN**

Run:

```bash
flutter test test/widget/features/auth/forgot_password_screen_test.dart test/widget/features/auth/reset_password_screen_test.dart
```

Expected: PASS.

### Task 7: Validate against local Supabase and the real device targets

**Files:**
- Modify: `vango_app/README.md`
- No new production feature files

- [x] **Step 1: Start and inspect the local stack**

Use the current CLI help before execution, then run the local stack from the repository root:

```bash
supabase start
supabase status
```

Expected: all required local services are healthy and the local API URL/key can be supplied through environment variables. Do not use `supabase db reset` against a hosted project.

- [x] **Step 2: Run the database smoke query**

After a local sign-up, verify through a local authenticated client/query that:

1. `auth.users` contains the new user;
2. the trigger created exactly one `public.profiles` row;
3. `profiles.full_name` equals the submitted trimmed name when a session was returned;
4. an authenticated user cannot read another user's profile.

Use the existing database test harness or a local SQL query; do not add a migration solely for the client integration.

- [x] **Step 3: Run the Flutter quality commands**

From `vango_app`, run:

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter test --coverage
git diff --check
```

Expected: zero analyzer issues, all tests passing, coverage generated at `vango_app/coverage/lcov.info`, and no whitespace errors.

- [ ] **Step 4: Manually validate the Auth matrix**

Run the app on an Android emulator and an iOS simulator with local configuration, then verify:

- valid seeded login reaches the temporary authenticated screen;
- invalid credentials show Portuguese error copy and stop loading;
- sign-out clears the session and returns to Welcome;
- a unique registration creates Auth plus the profile row;
- a confirmation-required registration does not claim an active session;
- app restart restores an existing session;
- reset email appears in the local SMTP inbox;
- opening the reset callback reaches the password-update screen;
- a successful password update returns to the authenticated destination;
- no service key, access token, password, or full exception is shown in the UI/logs.

The Android/iOS manual matrix remains pending because this host has no mobile
simulator or device connected and Xcode is not installed. The available web
target was compiled successfully with the local Supabase defines.

- [x] **Step 5: Run the repository quality gate**

Run the `software-quality-gate` skill after implementation and inspect `git status --short` before and after it. Quality tooling must stay outside the repository and must not install dependencies, modify manifests/lockfiles, create tests, or leave generated files tracked.

- [x] **Step 6: Update the app README with only verified setup**

Document the commands and configuration names actually used:

```bash
flutter pub get
flutter run --dart-define-from-file=.env
```

The local `vango_app/.env` file contains only the client URL and publishable key
and is ignored by Git. Do not pass the repository root `.env`, which contains
server-side SMTP credentials. Explain the Android emulator host address versus
iOS simulator host address for local Supabase only after verifying the actual
device setup. Do not include real keys.

## Explicitly Out of Scope

- Fleet creation and `create_fleet` RPC integration.
- Marketplace search and school catalog screens.
- Student, guardian, invitation, enrollment, van, route, trip, notification, GPS, Realtime, and map screens.
- FCM credentials, Edge Function deployment, map provider selection, and production device release.
- Custom Node.js API, custom JWT/session storage, or client-side role authorization.

The next plan after Auth should consume the existing RPC/projection contracts one feature at a time, beginning with the authenticated profile/account surface and only then the marketplace or fleet flow.
