# VanGo Flutter app

The VanGo mobile client. The application uses Supabase Auth for account
creation, sign-in, password recovery, session restoration, and sign-out.

## Configuration

Runtime configuration is provided through Dart defines:

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY`

Only the Supabase publishable key belongs in the client. Never use the service
role key in this application.

For local development, keep these two client values in `vango_app/.env`.
This file is ignored by Git. Do not pass the repository root `.env` to Flutter,
because it contains server-side SMTP credentials.

## Local development

Start the local Supabase stack from the repository root:

```bash
supabase start
supabase status -o env
```

Local Auth emails are captured by the Mailpit instance started by Supabase.

Then run the app from this directory with the local define file:

```bash
flutter pub get
flutter run --dart-define-from-file=.env
```

The Android and iOS clients register the same callback scheme used by
Supabase Auth: `com.vango.vangoapp://auth-callback/`.

## Onboarding and access

Registration sends `full_name` and `onboarding_intent` as Auth metadata. The
supported intent values are `fleet_owner`, `driver`, `guardian`, and
`adult_student`.

The onboarding intent guides account setup only and never grants
authorization. Authenticated navigation reads `public.get_my_access_context()`
and renders from its effective roles. One account may have multiple roles
across fleets.

Minor students do not own Auth accounts. Their primary guardian creates them
through the existing backend contract.

## Checks

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test --coverage
```

## Flutter resources

- [Flutter documentation](https://docs.flutter.dev/)
- [Supabase Flutter documentation](https://supabase.com/docs/reference/dart/introduction)
