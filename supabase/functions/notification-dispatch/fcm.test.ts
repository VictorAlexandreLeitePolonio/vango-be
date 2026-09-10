function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

import { sendFcmMessage } from "./fcm.ts";

Deno.test("token inexistente é desativável", async () => {
  const fake: typeof fetch = () =>
    Promise.resolve(
      new Response(
        JSON.stringify({
          error: {
            code: 404,
            details: [{
              "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
              errorCode: "UNREGISTERED",
            }],
          },
        }),
        { status: 404 },
      ),
    );

  const result = await sendFcmMessage({
    projectId: "test",
    accessToken: "fake",
    deviceToken: "fake-device",
    notificationId: "notice-1",
    expiresAt: "2026-09-15T00:00:00Z",
    now: new Date("2026-09-14T00:00:00Z"),
    fetchImpl: fake,
  });

  assert(result.kind === "invalid_token", "token deve ser invalidado");
});

Deno.test("sucesso exige name e não envia conteúdo privado", async () => {
  let request: Request | null = null;
  const fake: typeof fetch = (input, init) => {
    request = new Request(input, init);
    return Promise.resolve(
      Response.json({ name: "projects/test/messages/abc" }),
    );
  };

  const result = await sendFcmMessage({
    projectId: "test project",
    accessToken: "access",
    deviceToken: "device",
    notificationId: "notice-1",
    expiresAt: "2026-09-15T00:00:30Z",
    now: new Date("2026-09-15T00:00:00Z"),
    fetchImpl: fake,
  });

  assert(result.kind === "sent", "resposta com name deve ser sucesso");
  assert(
    result.providerId === "projects/test/messages/abc",
    "provider id deve ser preservado",
  );
  const captured = request as Request | null;
  assert(captured !== null, "FCM deve receber uma requisição");
  assert(
    captured.url.endsWith("/projects/test%20project/messages:send"),
    "project id deve ser codificado",
  );
  const body = await captured.json();
  assert(
    body.message.data.notification_id === "notice-1",
    "payload deve carregar apenas o id",
  );
  assert(
    body.message.notification.body ===
      "Você tem uma atualização no aplicativo.",
    "push deve ser discreto",
  );
  assert(
    body.message.android.ttl === "30s",
    "TTL Android deve respeitar a validade",
  );
  assert(
    body.message.apns.headers["apns-expiration"] === "1789430430",
    "APNs deve receber a expiração",
  );
  assert(
    !JSON.stringify(body).includes("conteúdo privado"),
    "payload não pode copiar conteúdo privado",
  );
});

Deno.test("aviso expirado não chama o provedor", async () => {
  let calls = 0;
  const result = await sendFcmMessage({
    projectId: "test",
    accessToken: "access",
    deviceToken: "device",
    notificationId: "notice-1",
    expiresAt: "2026-09-15T00:00:00Z",
    now: new Date("2026-09-15T00:00:00Z"),
    fetchImpl: () => {
      calls += 1;
      return Promise.resolve(Response.json({ name: "should-not-send" }));
    },
  });

  assert(
    result.kind === "permanent_failure" && result.code === "expired",
    "aviso vencido deve ser suprimido",
  );
  assert(calls === 0, "aviso vencido não deve fazer chamada externa");
});

Deno.test("resposta 2xx sem name não é sucesso", async () => {
  const result = await sendFcmMessage({
    projectId: "test",
    accessToken: "access",
    deviceToken: "device",
    notificationId: "notice-1",
    expiresAt: "2026-09-15T01:00:00Z",
    now: new Date("2026-09-15T00:00:00Z"),
    fetchImpl: () => Promise.resolve(new Response("not-json", { status: 200 })),
  });

  assert(
    result.kind === "permanent_failure" && result.code === "invalid_response",
    "resposta inválida não deve virar sent",
  );
});

Deno.test("429 respeita Retry-After", async () => {
  const result = await sendFcmMessage({
    projectId: "test",
    accessToken: "access",
    deviceToken: "device",
    notificationId: "notice-1",
    expiresAt: "2026-09-15T01:00:00Z",
    now: new Date("2026-09-15T00:00:00Z"),
    fetchImpl: () =>
      Promise.resolve(
        new Response(
          JSON.stringify({ error: { status: "RESOURCE_EXHAUSTED" } }),
          {
            status: 429,
            headers: { "Retry-After": "17" },
          },
        ),
      ),
  });

  assert(result.kind === "retry", "429 deve ser repetido");
  assert(
    result.code === "rate_limited" && result.retryAfterSeconds === 17,
    "Retry-After deve ser sanitizado",
  );
});

Deno.test("INVALID_ARGUMENT de payload não desativa token", async () => {
  const result = await sendFcmMessage({
    projectId: "test",
    accessToken: "access",
    deviceToken: "device",
    notificationId: "notice-1",
    expiresAt: "2026-09-15T01:00:00Z",
    now: new Date("2026-09-15T00:00:00Z"),
    fetchImpl: () =>
      Promise.resolve(
        new Response(
          JSON.stringify({
            error: {
              status: "INVALID_ARGUMENT",
              message: "Invalid value at 'message.data'",
              details: [{
                "@type": "type.googleapis.com/google.rpc.BadRequest",
                fieldViolations: [{ field: "message.data" }],
              }],
            },
          }),
          { status: 400 },
        ),
      ),
  });

  assert(
    result.kind === "permanent_failure" && result.code === "INVALID_ARGUMENT",
    "erro de payload é permanente",
  );
});

Deno.test("INVALID_ARGUMENT com detalhe de token desativa token", async () => {
  const result = await sendFcmMessage({
    projectId: "test",
    accessToken: "access",
    deviceToken: "device",
    notificationId: "notice-1",
    expiresAt: "2026-09-15T01:00:00Z",
    now: new Date("2026-09-15T00:00:00Z"),
    fetchImpl: () =>
      Promise.resolve(
        new Response(
          JSON.stringify({
            error: {
              status: "INVALID_ARGUMENT",
              message:
                "The registration token is not a valid FCM registration token",
              details: [{
                "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
                errorCode: "INVALID_ARGUMENT",
              }],
            },
          }),
          { status: 400 },
        ),
      ),
  });

  assert(
    result.kind === "invalid_token",
    "detalhe específico de token deve desativá-lo",
  );
});

Deno.test("timeout ao ler resposta FCM é repetível", async () => {
  const response = {
    ok: true,
    status: 200,
    headers: new Headers(),
    json: () =>
      Promise.reject(new DOMException("provider timeout", "TimeoutError")),
  } as unknown as Response;
  const result = await sendFcmMessage({
    projectId: "test",
    accessToken: "access",
    deviceToken: "device",
    notificationId: "notice-1",
    expiresAt: "2026-09-15T01:00:00Z",
    now: new Date("2026-09-15T00:00:00Z"),
    fetchImpl: () => Promise.resolve(response),
  });

  assert(
    result.kind === "retry" && result.code === "response_timeout",
    "timeout de resposta deve voltar para a fila",
  );
});

Deno.test("entrada vazia não chama FCM", async () => {
  let calls = 0;
  const result = await sendFcmMessage({
    projectId: " ",
    accessToken: "access",
    deviceToken: "device",
    notificationId: "notice-1",
    expiresAt: "2026-09-15T01:00:00Z",
    now: new Date("2026-09-15T00:00:00Z"),
    fetchImpl: () => {
      calls += 1;
      return Promise.resolve(Response.json({ name: "unexpected" }));
    },
  });

  assert(
    result.kind === "permanent_failure" && result.code === "invalid_input",
    "entrada vazia deve ser inválida",
  );
  assert(calls === 0, "entrada inválida não deve chamar provedor");
});

Deno.test("5xx e timeout de rede são repetíveis", async () => {
  const common = {
    projectId: "test",
    accessToken: "access",
    deviceToken: "device",
    notificationId: "notice-1",
    expiresAt: "2026-09-15T01:00:00Z",
    now: new Date("2026-09-15T00:00:00Z"),
  };
  const unavailable = await sendFcmMessage({
    ...common,
    fetchImpl: () =>
      Promise.resolve(new Response("provider unavailable", { status: 503 })),
  });
  const timeout = await sendFcmMessage({
    ...common,
    fetchImpl: () =>
      Promise.reject(new DOMException("provider timeout", "TimeoutError")),
  });

  assert(
    unavailable.kind === "retry" && unavailable.code === "provider_unavailable",
    "5xx deve voltar para a fila",
  );
  assert(
    timeout.kind === "retry" && timeout.code === "timeout",
    "timeout de rede deve voltar para a fila",
  );
});
