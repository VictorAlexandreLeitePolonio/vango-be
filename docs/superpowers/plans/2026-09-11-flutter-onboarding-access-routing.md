# Flutter Onboarding and Access Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user choose an onboarding intent during registration and make the authenticated Flutter UI render from effective backend access instead of trusting registration metadata.

**Architecture:** Extend the existing Auth service boundary with two typed contracts: `OnboardingIntent` for registration guidance and `AccessContext` for authorization-aware UI. Supabase Auth metadata transports the intent during signup, while `public.get_my_access_context()` remains the only source used to choose authenticated content. Keep one authenticated shell that supports multiple roles and shows the correct setup state when the user has no effective role yet.

**Tech Stack:** Flutter/Dart 3.11.3, `supabase_flutter` 2.17.2, Supabase Auth, PostgREST RPC, Flutter widget/unit tests.

**Spec:** `supabase/migrations/20260911081018_add_onboarding_access_context.sql`; `supabase/tests/database/044_onboarding_access_context.test.sql`; `docs/superpowers/specs/2026-09-06-ciclo-2-marketplace-vinculos-design.md`; `CONTRIBUTING.md`.

## Global Constraints

- Follow RED -> GREEN -> REFACTOR for every behavior change.
- Preserve all current uncommitted visual changes in `vango_app`; do not overwrite or reformat unrelated UI work.
- Use `fleet_owner`, `driver`, `guardian`, and `adult_student` as the exact backend onboarding values.
- Treat onboarding intent as navigation guidance only; never use it to grant access or hide backend-returned roles.
- Use only `account_roles` and `fleet_access` returned by `get_my_access_context()` for role-protected UI.
- Support multiple effective roles for one account; do not collapse the user into one permanent type.
- A minor has no Auth account. The authenticated guardian creates the minor through the existing `create_minor_student` contract and becomes the primary guardian.
- Keep user-facing text in Portuguese (pt-BR) and all identifiers, comments, tests, and technical documentation in English.
- Add no package, state-management framework, repository abstraction, generated client, or speculative dashboard.
- Do not commit or push unless the user explicitly authorizes it.

---

## File Map

| File | Responsibility |
| --- | --- |
| `vango_app/lib/features/auth/models/onboarding_intent.dart` | Typed onboarding values and Portuguese labels. |
| `vango_app/lib/features/auth/models/access_context.dart` | Parse the exact `get_my_access_context()` response. |
| `vango_app/lib/features/auth/services/auth_service.dart` | Send signup intent and load effective access through the RPC. |
| `vango_app/lib/features/auth/screens/register_screen.dart` | Require one of the four onboarding choices without disturbing the current visual work. |
| `vango_app/lib/features/auth/widgets/auth_gate.dart` | Load, retry, and refresh access after authentication changes. |
| `vango_app/lib/features/auth/screens/authenticated_home_screen.dart` | Render role-aware content and allow switching when several roles are active. |
| `vango_app/test/support/fake_auth_client.dart` | Capture signup metadata and return deterministic RPC rows. |
| `vango_app/test/support/fake_auth_service.dart` | Expose deterministic `AccessContext` values to widget tests. |
| `vango_app/test/unit/features/auth/access_context_test.dart` | Verify backend response parsing and malformed-response failures. |
| `vango_app/test/unit/features/auth/auth_service_test.dart` | Verify signup and RPC contracts. |
| `vango_app/test/widget/features/auth/register_screen_test.dart` | Verify required intent selection and submitted value. |
| `vango_app/test/widget/features/auth/auth_gate_test.dart` | Verify loading, error, retry, and authenticated access states. |
| `vango_app/test/widget/features/auth/authenticated_home_screen_test.dart` | Verify effective-role rendering and multi-role switching. |
| `vango_app/README.md` | Document the backend values and the separation between intent and permission. |

## Approved Interfaces

```dart
enum OnboardingIntent {
  fleetOwner('fleet_owner', 'Sou dono de uma frota'),
  driver('driver', 'Sou motorista'),
  guardian('guardian', 'Sou responsável por um aluno'),
  adultStudent('adult_student', 'Sou aluno maior de idade');

  const OnboardingIntent(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

enum AccountRole { owner, driver, guardian, student }

class FleetAccess {
  const FleetAccess({required this.fleetId, required this.roles});

  final String fleetId;
  final Set<AccountRole> roles;
}

class AccessContext {
  const AccessContext({
    required this.onboardingIntent,
    required this.accountRoles,
    required this.dependentStudentIds,
    required this.adultStudentId,
    required this.fleetAccess,
  });

  final OnboardingIntent? onboardingIntent;
  final Set<AccountRole> accountRoles;
  final List<String> dependentStudentIds;
  final String? adultStudentId;
  final List<FleetAccess> fleetAccess;

  factory AccessContext.fromJson(Map<String, dynamic> json);
}
```

Extend the existing service without introducing a second data layer:

```dart
abstract interface class AuthService {
  // Keep existing members.

  Future<AuthResult> signUp({
    required String fullName,
    required String email,
    required String password,
    required OnboardingIntent onboardingIntent,
  });

  Future<AccessContext> getMyAccessContext();
}
```

The production RPC call is exactly:

```dart
final rows = await _client.rpc('get_my_access_context');
```

Require exactly one returned row. An empty, duplicated, or malformed response throws `FormatException`; it must not silently become an account with no access.

## Task 1: Add typed signup intent and access-context parsing

**Files:**
- Create: `vango_app/lib/features/auth/models/onboarding_intent.dart`
- Create: `vango_app/lib/features/auth/models/access_context.dart`
- Modify: `vango_app/lib/features/auth/services/auth_service.dart`
- Modify: `vango_app/test/support/fake_auth_client.dart`
- Modify: `vango_app/test/support/fake_auth_service.dart`
- Create: `vango_app/test/unit/features/auth/access_context_test.dart`
- Modify: `vango_app/test/unit/features/auth/auth_service_test.dart`

**Interfaces:**
- Produces: `OnboardingIntent`, `AccountRole`, `FleetAccess`, `AccessContext.fromJson`, and `AuthService.getMyAccessContext()`.
- Consumes: the current `AuthService`, `AuthClient`, and backend RPC row.

- [ ] **Step 1: Write failing parsing tests**

Add literal fixtures covering the full response and nullable setup state:

```dart
test('parses roles, dependents, adult student, and fleet access', () {
  final context = AccessContext.fromJson({
    'onboarding_intent': 'guardian',
    'account_roles': ['driver', 'guardian'],
    'dependent_student_ids': ['student-1'],
    'adult_student_id': null,
    'fleet_access': [
      {'fleet_id': 'fleet-1', 'roles': ['driver']},
    ],
  });

  expect(context.onboardingIntent, OnboardingIntent.guardian);
  expect(context.accountRoles, {AccountRole.driver, AccountRole.guardian});
  expect(context.dependentStudentIds, ['student-1']);
  expect(context.fleetAccess.single.roles, {AccountRole.driver});
});

test('rejects an unknown effective role', () {
  expect(
    () => AccessContext.fromJson({
      'onboarding_intent': 'guardian',
      'account_roles': ['admin'],
      'dependent_student_ids': <String>[],
      'adult_student_id': null,
      'fleet_access': <Map<String, dynamic>>[],
    }),
    throwsFormatException,
  );
});
```

- [ ] **Step 2: Run the parser tests and verify RED**

Run from `vango_app`:

```bash
flutter test test/unit/features/auth/access_context_test.dart
```

Expected: FAIL because the models do not exist.

- [ ] **Step 3: Implement strict enum and response parsing**

Implement the approved interfaces. Parse lists with explicit type checks and enum lookup. Do not use `any`, unchecked casts, fallback roles, or authorization values from `currentSession.user.userMetadata`.

- [ ] **Step 4: Write failing service-contract tests**

Extend the existing signup test:

```dart
await service.signUp(
  fullName: ' Maria Silva ',
  email: 'maria@example.com',
  password: 'secret123',
  onboardingIntent: OnboardingIntent.guardian,
);

expect(client.lastSignUpData, {
  'full_name': 'Maria Silva',
  'onboarding_intent': 'guardian',
});
```

Add an RPC test whose fake returns one literal row and assert the parsed `AccessContext`. Add separate tests asserting `FormatException` for zero or two rows.

- [ ] **Step 5: Run the service tests and verify RED**

```bash
flutter test test/unit/features/auth/auth_service_test.dart
```

Expected: FAIL because signup lacks the intent argument and the client lacks the RPC boundary.

- [ ] **Step 6: Implement the minimum service changes**

Send both fields through the existing signup metadata:

```dart
data: {
  'full_name': fullName.trim(),
  'onboarding_intent': onboardingIntent.apiValue,
},
```

Add one `AuthClient.getMyAccessContext()` method that wraps the exact RPC. Keep `updateOwnProfile` unchanged for an immediate-session signup; the database trigger already handles the no-session path.

- [ ] **Step 7: Run focused tests and format**

```bash
dart format lib/features/auth/models/onboarding_intent.dart lib/features/auth/models/access_context.dart lib/features/auth/services/auth_service.dart test/support/fake_auth_client.dart test/support/fake_auth_service.dart test/unit/features/auth/access_context_test.dart test/unit/features/auth/auth_service_test.dart
flutter test test/unit/features/auth/access_context_test.dart test/unit/features/auth/auth_service_test.dart
```

Expected: PASS.

## Task 2: Require onboarding intent during registration

**Files:**
- Modify: `vango_app/lib/features/auth/screens/register_screen.dart`
- Modify: `vango_app/test/widget/features/auth/register_screen_test.dart`

**Interfaces:**
- Consumes: `OnboardingIntent.values` and the extended `AuthService.signUp()`.
- Produces: one required onboarding choice submitted with the existing registration fields.

- [ ] **Step 1: Write failing widget tests**

Add one test that submits the otherwise-valid form without choosing an intent and expects `Escolha como você usará o VanGo` with `signUpCalls == 0`. Update the successful registration test to tap `Sou responsável por um aluno` and assert:

```dart
expect(service.lastOnboardingIntent, OnboardingIntent.guardian);
```

- [ ] **Step 2: Run the registration tests and verify RED**

```bash
flutter test test/widget/features/auth/register_screen_test.dart
```

Expected: FAIL because the choice is absent and the fake does not capture it.

- [ ] **Step 3: Add the smallest accessible selector**

Inside the existing form, add a Portuguese prompt and four radio choices generated from `OnboardingIntent.values`. Store `OnboardingIntent? _onboardingIntent`, display the validation message after submit, and pass the non-null value to `signUp`. Preserve the current constrained width, animation duration, fields, spacing tokens, and visual changes already present in the working tree.

- [ ] **Step 4: Verify registration behavior and layout**

```bash
dart format lib/features/auth/screens/register_screen.dart test/widget/features/auth/register_screen_test.dart
flutter test test/widget/features/auth/register_screen_test.dart test/widget/features/auth/auth_visual_layout_test.dart
```

Expected: PASS with no overflow at the existing compact viewport sizes.

## Task 3: Route authenticated UI from effective access

**Files:**
- Modify: `vango_app/lib/features/auth/widgets/auth_gate.dart`
- Modify: `vango_app/lib/features/auth/screens/authenticated_home_screen.dart`
- Modify: `vango_app/test/support/fake_auth_service.dart`
- Modify: `vango_app/test/widget/features/auth/auth_gate_test.dart`
- Modify: `vango_app/test/widget/features/auth/authenticated_home_screen_test.dart`

**Interfaces:**
- Consumes: `AuthService.getMyAccessContext()` and `AccessContext`.
- Produces: loading/error/retry states and a role-aware authenticated shell.

- [ ] **Step 1: Write failing AuthGate tests**

Cover these observable states:

```text
session + pending RPC       -> CircularProgressIndicator
session + RPC failure       -> "Não foi possível carregar seu acesso" and "Tentar novamente"
retry + successful RPC      -> authenticated home
signedOut during pending RPC -> public welcome, never stale authenticated content
```

The fake service must complete access requests explicitly so the pending and stale-result behaviors are deterministic.

- [ ] **Step 2: Run AuthGate tests and verify RED**

```bash
flutter test test/widget/features/auth/auth_gate_test.dart
```

Expected: FAIL because `AuthGate` currently renders the authenticated screen immediately.

- [ ] **Step 3: Implement access loading with stale-result protection**

On initial authenticated session and `signedIn`/`userUpdated` events, await `getMyAccessContext()`. Before applying the result, verify the widget is mounted and the session user ID still matches the request's user ID. Keep password recovery higher priority than access loading. Retry invokes only the access request; it must not sign in again.

- [ ] **Step 4: Write failing role-rendering tests**

Use literal contexts to verify:

```text
no roles + fleet_owner intent  -> "Configure sua frota"
no roles + driver intent       -> "Aguarde ou aceite um convite da frota"
no roles + guardian intent     -> "Cadastre o aluno sob sua responsabilidade"
no roles + adult_student intent -> "Complete seus dados de aluno"
owner role                     -> "Painel da frota"
driver role                    -> "Minhas viagens"
guardian role                  -> "Meus alunos"
student role                   -> "Meu transporte"
owner + driver                 -> both role choices are available and switch content
```

Assert roles from `onboardingIntent` alone never render a protected destination.

- [ ] **Step 5: Run home tests and verify RED**

```bash
flutter test test/widget/features/auth/authenticated_home_screen_test.dart
```

Expected: FAIL because the current screen only shows `VanGo autenticado`.

- [ ] **Step 6: Implement one role-aware authenticated shell**

Pass `AccessContext` into `AuthenticatedHomeScreen`. When roles are empty, render only the setup message selected by onboarding intent. When roles exist, render the matching content title; if more than one role exists, show an accessible role selector and retain the user's selection for the current widget lifetime. Do not build fleet, trip, student, map, or billing features in this task.

- [ ] **Step 7: Run focused widget tests**

```bash
dart format lib/features/auth/widgets/auth_gate.dart lib/features/auth/screens/authenticated_home_screen.dart test/support/fake_auth_service.dart test/widget/features/auth/auth_gate_test.dart test/widget/features/auth/authenticated_home_screen_test.dart
flutter test test/widget/features/auth/auth_gate_test.dart test/widget/features/auth/authenticated_home_screen_test.dart
```

Expected: PASS.

## Task 4: Document and validate the complete frontend slice

**Files:**
- Modify: `vango_app/README.md`
- Verify: every file changed in Tasks 1-3

**Interfaces:**
- Consumes: the final registration and access-context behavior.
- Produces: documented frontend/backend contract and validation evidence.

- [ ] **Step 1: Document the exact contract**

Add a short section containing:

```text
Registration sends full_name and onboarding_intent as Auth metadata.
onboarding_intent guides setup only and never grants authorization.
Authenticated navigation reads public.get_my_access_context().
Minor students do not own Auth accounts; their primary guardian creates them.
```

List the four exact intent values and note that one user may have multiple effective roles across fleets.

- [ ] **Step 2: Run all Flutter tests with coverage**

From `vango_app`:

```bash
flutter test --coverage
```

Expected: all tests PASS and `coverage/lcov.info` is generated. Measure the business/domain files added by this plan and confirm at least 80% coverage.

- [ ] **Step 3: Run analyzer and formatting checks**

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
```

Expected: format check exits 0 and analyzer reports `No issues found!`.

- [ ] **Step 4: Run the mandatory quality gate**

Use `software-quality-gate`. Inspect the complete diff, verify no metadata value grants access, reason about mutations removing the active-membership filter and stale-session guard, and rerun any affected tests after fixes.

- [ ] **Step 5: Verify repository integrity**

```bash
git diff --check
git status --short
git diff --name-only
```

Expected: only authorized frontend files plus the already-created backend migration/test and pre-existing visual changes are present. No dependency, lockfile, generated platform file, or unrelated source file changes.

- [ ] **Step 6: Commit only with explicit authorization**

If and only if the user explicitly authorizes a commit:

```bash
git add \
  vango_app/lib/features/auth/models/onboarding_intent.dart \
  vango_app/lib/features/auth/models/access_context.dart \
  vango_app/lib/features/auth/services/auth_service.dart \
  vango_app/lib/features/auth/screens/register_screen.dart \
  vango_app/lib/features/auth/widgets/auth_gate.dart \
  vango_app/lib/features/auth/screens/authenticated_home_screen.dart \
  vango_app/test/support/fake_auth_client.dart \
  vango_app/test/support/fake_auth_service.dart \
  vango_app/test/unit/features/auth/access_context_test.dart \
  vango_app/test/unit/features/auth/auth_service_test.dart \
  vango_app/test/widget/features/auth/register_screen_test.dart \
  vango_app/test/widget/features/auth/auth_gate_test.dart \
  vango_app/test/widget/features/auth/authenticated_home_screen_test.dart \
  vango_app/README.md \
  docs/superpowers/plans/2026-09-11-flutter-onboarding-access-routing.md
git commit -m "feat(auth): route onboarding by effective access"
```

Otherwise leave the reviewed diff uncommitted.
