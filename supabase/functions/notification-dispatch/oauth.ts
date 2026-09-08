export type GoogleServiceAccountCredentials = {
  client_email: string;
  private_key: string;
};

export type GoogleAccessToken = {
  token: string;
  expiresAt: number;
};

const TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
const TOKEN_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const TOKEN_AUDIENCE = TOKEN_ENDPOINT;
const ASSERTION_LIFETIME_SECONDS = 3_600;
const CACHE_REFRESH_WINDOW_SECONDS = 60;
const OAUTH_TIMEOUT_MS = 10_000;

const encoder = new TextEncoder();
const tokenCache = new Map<string, GoogleAccessToken>();

function base64Url(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(
    /=+$/u,
    "",
  );
}

function jsonBase64Url(value: unknown): string {
  return base64Url(encoder.encode(JSON.stringify(value)));
}

function privateKeyDer(privateKey: string): Uint8Array {
  const normalized = privateKey.replaceAll("\\n", "\n").trim();
  const match = normalized.match(
    /-----BEGIN PRIVATE KEY-----([\s\S]+?)-----END PRIVATE KEY-----/u,
  );
  if (!match) throw new Error("invalid_credentials");

  const encoded = match[1].replaceAll(/\s/gu, "");
  try {
    const binary = atob(encoded);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    throw new Error("invalid_credentials");
  }
}

async function serviceAccountAssertion(
  credentials: GoogleServiceAccountCredentials,
  now: Date,
): Promise<string> {
  const der = privateKeyDer(credentials.private_key);
  const iat = Math.floor(now.getTime() / 1_000);
  const header = jsonBase64Url({ alg: "RS256", typ: "JWT" });
  const claims = jsonBase64Url({
    iss: credentials.client_email,
    scope: TOKEN_SCOPE,
    aud: TOKEN_AUDIENCE,
    iat,
    exp: iat + ASSERTION_LIFETIME_SECONDS,
  });
  const unsigned = `${header}.${claims}`;

  try {
    const key = await crypto.subtle.importKey(
      "pkcs8",
      der.buffer as ArrayBuffer,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const signature = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      encoder.encode(unsigned),
    );
    return `${unsigned}.${base64Url(new Uint8Array(signature))}`;
  } catch {
    throw new Error("invalid_credentials");
  }
}

function cacheKey(credentials: GoogleServiceAccountCredentials): string {
  return `${credentials.client_email}\u0000${credentials.private_key}`;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function getGoogleAccessToken(
  credentials: GoogleServiceAccountCredentials,
  fetchImpl: typeof fetch,
  now: Date,
): Promise<GoogleAccessToken> {
  if (
    typeof credentials.client_email !== "string" ||
    credentials.client_email.trim() === "" ||
    typeof credentials.private_key !== "string" ||
    credentials.private_key.trim() === "" ||
    !Number.isFinite(now.getTime())
  ) {
    throw new Error("invalid_credentials");
  }

  const nowSeconds = Math.floor(now.getTime() / 1_000);
  const key = cacheKey(credentials);
  const cached = tokenCache.get(key);
  if (cached && cached.expiresAt - CACHE_REFRESH_WINDOW_SECONDS > nowSeconds) {
    return cached;
  }

  const assertion = await serviceAccountAssertion(credentials, now);
  const form = new URLSearchParams({
    grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion,
  });

  let response: Response;
  try {
    response = await fetchImpl(TOKEN_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
      signal: AbortSignal.timeout(OAUTH_TIMEOUT_MS),
    });
  } catch {
    throw new Error("oauth_unavailable");
  }
  if (!response.ok) throw new Error("oauth_token_error");

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    throw new Error("oauth_token_error");
  }
  if (
    !isObject(payload) ||
    typeof payload.access_token !== "string" ||
    payload.access_token.trim() === ""
  ) {
    throw new Error("oauth_token_error");
  }
  const expiresIn = typeof payload.expires_in === "number"
    ? payload.expires_in
    : Number(payload.expires_in);
  if (!Number.isFinite(expiresIn) || expiresIn <= 0) {
    throw new Error("oauth_token_error");
  }

  const result = {
    token: payload.access_token.trim(),
    expiresAt: nowSeconds + Math.floor(expiresIn),
  };
  tokenCache.set(key, result);
  return result;
}
