function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

import { getGoogleAccessToken } from "./oauth.ts";

Deno.test("credencial ausente falha antes de chamar OAuth", async () => {
  let calls = 0;
  try {
    await getGoogleAccessToken(
      { client_email: "", private_key: "" },
      () => {
        calls += 1;
        return Promise.resolve(Response.json({ access_token: "unexpected" }));
      },
      new Date("2026-09-15T00:00:00Z"),
    );
    throw new Error("credencial ausente deveria falhar");
  } catch (error) {
    assert(
      error instanceof Error && error.message === "invalid_credentials",
      "erro deve ser sanitizado",
    );
  }
  assert(calls === 0, "não deve chamar endpoint sem credencial");
});

function base64(value: ArrayBuffer): string {
  const bytes = new Uint8Array(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function pem(value: ArrayBuffer): string {
  const encoded = base64(value);
  const lines = encoded.match(/.{1,64}/gu)?.join("\n") ?? encoded;
  return `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----`;
}

function decodeJson(part: string): Record<string, unknown> {
  const encoded = part.replaceAll("-", "+").replaceAll("_", "/");
  const padded = encoded + "=".repeat((4 - encoded.length % 4) % 4);
  const binary = atob(padded);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes));
}

Deno.test("assertion RS256 contém claims OAuth e troca por access token", async () => {
  const keys = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2_048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const privateKey = pem(
    await crypto.subtle.exportKey("pkcs8", keys.privateKey),
  );
  let request: Request | null = null;
  const fake: typeof fetch = (input, init) => {
    request = new Request(input, init);
    return Promise.resolve(
      Response.json({ access_token: "google-access", expires_in: 3_600 }),
    );
  };
  const now = new Date("2026-09-15T00:00:00Z");

  const result = await getGoogleAccessToken(
    {
      client_email: "worker@example.iam.gserviceaccount.com",
      private_key: privateKey,
    },
    fake,
    now,
  );

  assert(
    result.token === "google-access",
    "access token deve vir do endpoint OAuth",
  );
  assert(
    result.expiresAt === Math.floor(now.getTime() / 1_000) + 3_600,
    "expiração deve usar expires_in",
  );
  const captured = request as Request | null;
  assert(captured !== null, "endpoint OAuth deve receber requisição");
  assert(
    captured.url === "https://oauth2.googleapis.com/token",
    "endpoint deve ser o OAuth do Google",
  );
  const form = new URLSearchParams(await captured.text());
  assert(
    form.get("grant_type") === "urn:ietf:params:oauth:grant-type:jwt-bearer",
    "grant type deve ser JWT bearer",
  );
  const assertion = form.get("assertion");
  assert(typeof assertion === "string", "assertion deve ser enviada");
  const parts = assertion.split(".");
  assert(parts.length === 3, "assertion deve ter três segmentos");
  const header = decodeJson(parts[0]);
  const claims = decodeJson(parts[1]);
  assert(
    header.alg === "RS256" && header.typ === "JWT",
    "header deve declarar RS256",
  );
  assert(
    claims.iss === "worker@example.iam.gserviceaccount.com",
    "iss deve ser o service account",
  );
  assert(
    claims.scope === "https://www.googleapis.com/auth/firebase.messaging",
    "scope deve limitar a FCM",
  );
  assert(
    claims.aud === "https://oauth2.googleapis.com/token",
    "audience deve ser o endpoint OAuth",
  );
  assert(
    claims.iat === Math.floor(now.getTime() / 1_000),
    "iat deve usar o relógio fornecido",
  );
  assert(
    claims.exp === Math.floor(now.getTime() / 1_000) + 3_600,
    "exp deve ser uma hora após iat",
  );
  const signature = parts[2].replaceAll("-", "+").replaceAll("_", "/");
  const padded = signature + "=".repeat((4 - signature.length % 4) % 4);
  const signatureBytes = Uint8Array.from(
    atob(padded),
    (character) => character.charCodeAt(0),
  );
  const valid = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    keys.publicKey,
    signatureBytes,
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  assert(valid, "assertion deve ser assinada pela chave privada");
});

Deno.test("access token fica em cache e renova 60 segundos antes de expirar", async () => {
  const keys = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2_048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const privateKey = pem(
    await crypto.subtle.exportKey("pkcs8", keys.privateKey),
  );
  const credentials = {
    client_email: "cache-worker@example.iam.gserviceaccount.com",
    private_key: privateKey,
  };
  let calls = 0;
  const fake: typeof fetch = () => {
    calls += 1;
    return Promise.resolve(
      Response.json({ access_token: `token-${calls}`, expires_in: 120 }),
    );
  };
  const first = await getGoogleAccessToken(
    credentials,
    fake,
    new Date("2026-09-15T00:00:00Z"),
  );
  const cached = await getGoogleAccessToken(
    credentials,
    fake,
    new Date("2026-09-15T00:00:30Z"),
  );
  assert(
    calls === 1 && cached.token === first.token,
    "token válido deve ser reutilizado",
  );

  const renewed = await getGoogleAccessToken(
    credentials,
    fake,
    new Date("2026-09-15T00:01:00Z"),
  );
  assert(
    Number(calls) === 2 && renewed.token === "token-2",
    "cache deve renovar antes da expiração",
  );
});

Deno.test("resposta OAuth sem access token é rejeitada sem expor corpo", async () => {
  const keys = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2_048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const privateKey = pem(
    await crypto.subtle.exportKey("pkcs8", keys.privateKey),
  );
  let calls = 0;
  try {
    await getGoogleAccessToken(
      { client_email: "bad-response@example.test", private_key: privateKey },
      () => {
        calls += 1;
        return Promise.resolve(
          Response.json({ error: "private provider detail" }),
        );
      },
      new Date("2026-09-15T00:00:00Z"),
    );
    throw new Error("resposta inválida deveria falhar");
  } catch (error) {
    assert(
      error instanceof Error && error.message === "oauth_token_error",
      "resposta inválida deve ser sanitizada",
    );
    assert(
      !error.message.includes("private provider detail"),
      "erro não pode carregar corpo do provedor",
    );
  }
  assert(calls === 1, "endpoint deve ser chamado com chave válida");
});

Deno.test("access token vazio é rejeitado após resposta OAuth", async () => {
  const keys = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2_048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const privateKey = pem(
    await crypto.subtle.exportKey("pkcs8", keys.privateKey),
  );
  let calls = 0;
  try {
    await getGoogleAccessToken(
      { client_email: "empty-token@example.test", private_key: privateKey },
      () => {
        calls += 1;
        return Promise.resolve(
          Response.json({ access_token: "", expires_in: 3_600 }),
        );
      },
      new Date("2026-09-15T00:00:00Z"),
    );
    throw new Error("token vazio deveria falhar");
  } catch (error) {
    assert(
      error instanceof Error && error.message === "oauth_token_error",
      "token vazio deve ser sanitizado",
    );
  }
  assert(calls === 1, "resposta do endpoint deve ser validada");
});

Deno.test("timeout do endpoint OAuth não expõe erro externo", async () => {
  const keys = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2_048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const privateKey = pem(
    await crypto.subtle.exportKey("pkcs8", keys.privateKey),
  );
  try {
    await getGoogleAccessToken(
      { client_email: "oauth-timeout@example.test", private_key: privateKey },
      () => Promise.reject(new DOMException("provider secret", "TimeoutError")),
      new Date("2026-09-15T00:00:00Z"),
    );
    throw new Error("timeout deveria falhar");
  } catch (error) {
    assert(
      error instanceof Error && error.message === "oauth_unavailable",
      "timeout deve ser sanitizado",
    );
    assert(
      !error.message.includes("provider secret"),
      "erro não pode carregar mensagem externa",
    );
  }
});
