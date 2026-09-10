function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

import { createWorkerDispatcher, handle } from "./index.ts";

type FcmRequestBody = {
  message: {
    data: { notification_id: string };
    notification: { body: string };
  };
};

Deno.test("worker não é endpoint público de envio", async () => {
  let called = false;
  const response = await handle(
    new Request("http://localhost", { method: "POST" }),
    {
      workerSecret: "test-secret",
      dispatch: () => {
        called = true;
        return Promise.resolve({ claimed: 0 });
      },
    },
  );

  assert(response.status === 401 && !called, "envio não autorizado");
});

function request(
  body: string,
  method = "POST",
  secret = "test-secret",
): Request {
  const init: RequestInit = {
    method,
    headers: { "Content-Type": "application/json", "x-worker-secret": secret },
  };
  if (method !== "GET" && method !== "HEAD") init.body = body;
  return new Request(
    "http://localhost/functions/v1/notification-dispatch",
    init,
  );
}

Deno.test("worker aceita somente {} e devolve resumo sem campos extras", async () => {
  let calls = 0;
  const response = await handle(request("{}"), {
    workerSecret: "test-secret",
    dispatch: () => {
      calls += 1;
      return Promise.resolve({
        claimed: 2,
        sent: 1,
        retried: 1,
        failed: 0,
        secret: 123,
      });
    },
  });

  assert(
    response.status === 200 && calls === 1,
    "body vazio deve disparar uma execução",
  );
  const body = await response.json();
  assert(
    JSON.stringify(body) ===
      JSON.stringify({ claimed: 2, sent: 1, retried: 1, failed: 0 }),
    "resumo deve ter contrato estável",
  );
});

Deno.test("worker rejeita método e body inesperados antes do dispatch", async () => {
  let calls = 0;
  const deps = {
    workerSecret: "test-secret",
    dispatch: () => {
      calls += 1;
      return Promise.resolve({ claimed: 0, sent: 0, retried: 0, failed: 0 });
    },
  };
  const methodResponse = await handle(request("{}", "GET"), deps);
  const bodyResponse = await handle(request('{"recipients":[]}'), deps);

  assert(
    methodResponse.status === 405,
    "método diferente de POST deve ser rejeitado",
  );
  assert(
    bodyResponse.status === 400 && calls === 0,
    "body não vazio não pode escolher destinatários",
  );
});

Deno.test("falha do dispatch não expõe erro interno", async () => {
  const response = await handle(request("{}"), {
    workerSecret: "test-secret",
    dispatch: () =>
      Promise.reject(new Error("service role secret should not escape")),
  });
  assert(response.status === 500, "falha interna deve ser erro 500");
  const body = await response.text();
  assert(
    body === '{"error":"dispatch_failed"}',
    "resposta de erro deve ser sanitizada",
  );
});

function encodePem(value: ArrayBuffer): string {
  const bytes = new Uint8Array(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const encoded = btoa(binary);
  const lines = encoded.match(/.{1,64}/gu)?.join("\n") ?? encoded;
  return `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----`;
}

async function workerConfig(email: string): Promise<{
  supabaseUrl: string;
  supabaseServiceRoleKey: string;
  fcmProjectId: string;
  fcmClientEmail: string;
  fcmPrivateKey: string;
}> {
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
  return {
    supabaseUrl: "https://supabase.test/",
    supabaseServiceRoleKey: "server-key",
    fcmProjectId: "project",
    fcmClientEmail: email,
    fcmPrivateKey: encodePem(
      await crypto.subtle.exportKey("pkcs8", keys.privateKey),
    ),
  };
}

function rpcName(input: RequestInfo | URL): string | null {
  const path = new URL(input.toString()).pathname;
  return path.startsWith("/rest/v1/rpc/")
    ? path.slice("/rest/v1/rpc/".length)
    : null;
}

function requestJson(
  init: RequestInit | undefined,
): Record<string, unknown> {
  return JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>;
}

Deno.test("worker consulta concessão, envia payload discreto e conclui entrega", async () => {
  const config = await workerConfig("orchestration@example.test");
  const calls: string[] = [];
  const bodies: Record<string, unknown>[] = [];
  const fake: typeof fetch = async (input, init) => {
    const url = input.toString();
    const rpc = rpcName(input);
    if (url === "https://oauth2.googleapis.com/token") {
      calls.push("oauth");
      return Response.json({
        access_token: "google-access",
        expires_in: 3_600,
      });
    }
    if (rpc === "claim_notification_deliveries") {
      calls.push("claim");
      bodies.push(await requestJson(init));
      return Response.json([{
        id: "delivery-1",
        token: "device-token",
        notification_id: "notification-1",
        expires_at: "2026-09-15T01:00:00Z",
        attempt: 1,
        lease_id: "lease-1",
      }]);
    }
    if (rpc === "notification_delivery_ready") {
      calls.push("ready");
      bodies.push(await requestJson(init));
      return Response.json(true);
    }
    if (url.startsWith("https://fcm.googleapis.com/")) {
      calls.push("fcm");
      const body = JSON.parse(String(init?.body ?? "{}")) as FcmRequestBody;
      assert(
        body.message.data.notification_id === "notification-1",
        "FCM deve usar id estável",
      );
      assert(
        body.message.notification.body ===
          "Você tem uma atualização no aplicativo.",
        "FCM não deve receber corpo privado",
      );
      return Response.json({ name: "projects/project/messages/provider-1" });
    }
    if (rpc === "finish_notification_delivery") {
      calls.push("finish");
      bodies.push(await requestJson(init));
      return Response.json("sent");
    }
    throw new Error(`unexpected URL ${url}`);
  };
  const now = () => new Date("2026-09-15T00:00:00Z");
  const dispatch = createWorkerDispatcher(config, { fetchImpl: fake, now });

  const summary = await dispatch();
  assert(
    JSON.stringify(summary) ===
      JSON.stringify({ claimed: 1, sent: 1, retried: 0, failed: 0 }),
    "resumo deve refletir conclusão",
  );
  assert(
    JSON.stringify(calls) ===
      JSON.stringify(["oauth", "claim", "ready", "fcm", "finish"]),
    "ordem deve autenticar antes de reivindicar e verificar concessão",
  );
  assert(bodies[0].p_limit === 10, "claim deve limitar lote a dez");
  assert(
    bodies[2].p_outcome === "sent" &&
      bodies[2].p_provider_id === "projects/project/messages/provider-1",
    "finish deve receber resultado sanitizado",
  );
});

Deno.test("worker não chama FCM quando concessão perdeu utilidade", async () => {
  const config = await workerConfig("suppression@example.test");
  let fcmCalls = 0;
  let finishBody: Record<string, unknown> | null = null;
  const fake: typeof fetch = async (input, init) => {
    const url = input.toString();
    const rpc = rpcName(input);
    if (url === "https://oauth2.googleapis.com/token") {
      return Response.json({ access_token: "access", expires_in: 3_600 });
    }
    if (rpc === "claim_notification_deliveries") {
      return Response.json([{
        id: "delivery-2",
        token: "device-token",
        notification_id: "notification-2",
        expires_at: "2026-09-15T01:00:00Z",
        attempt: 1,
        lease_id: "lease-2",
      }]);
    }
    if (rpc === "notification_delivery_ready") return Response.json(false);
    if (url.startsWith("https://fcm.googleapis.com/")) {
      fcmCalls += 1;
      return Response.json({ name: "must-not-send" });
    }
    if (rpc === "finish_notification_delivery") {
      finishBody = await requestJson(init);
      return Response.json("suppressed");
    }
    throw new Error(`unexpected URL ${url}`);
  };
  const dispatch = createWorkerDispatcher(config, {
    fetchImpl: fake,
    now: () => new Date("2026-09-15T00:00:00Z"),
  });

  const summary = await dispatch();
  assert(fcmCalls === 0, "concessão perdida deve impedir envio externo");
  assert(
    summary.failed === 1,
    "entrega obsoleta deve ser contabilizada como falha final",
  );
  const capturedFinish = finishBody as Record<string, unknown> | null;
  assert(
    capturedFinish !== null &&
      capturedFinish.p_outcome === "permanent_failure" &&
      capturedFinish.p_error_code === "not_actionable",
    "entrega obsoleta deve ser suprimida com código estável",
  );
});

Deno.test("worker aceita invalid_token suprimido após rotação", async () => {
  const config = await workerConfig("rotated-token@example.test");
  let finishCalls = 0;
  const fake: typeof fetch = (input) => {
    const url = input.toString();
    const rpc = rpcName(input);
    if (url === "https://oauth2.googleapis.com/token") {
      return Promise.resolve(
        Response.json({ access_token: "access", expires_in: 3_600 }),
      );
    }
    if (rpc === "claim_notification_deliveries") {
      return Promise.resolve(Response.json([{
        id: "delivery-rotated",
        token: "old-device-token",
        notification_id: "notification-rotated",
        expires_at: "2026-09-15T01:00:00Z",
        attempt: 1,
        lease_id: "lease-rotated",
      }]));
    }
    if (rpc === "notification_delivery_ready") {
      return Promise.resolve(Response.json(true));
    }
    if (url.startsWith("https://fcm.googleapis.com/")) {
      return Promise.resolve(Response.json({
        error: {
          code: 404,
          details: [{
            "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
            errorCode: "UNREGISTERED",
          }],
        },
      }, { status: 404 }));
    }
    if (rpc === "finish_notification_delivery") {
      finishCalls += 1;
      return Promise.resolve(Response.json("suppressed"));
    }
    return Promise.reject(new Error("unexpected request"));
  };
  const dispatch = createWorkerDispatcher(config, {
    fetchImpl: fake,
    now: () => new Date("2026-09-15T00:00:00Z"),
  });

  const summary = await dispatch();
  assert(
    finishCalls === 1 && summary.failed === 1,
    "finish suprimido deve ser aceito após rotação do token",
  );
});

Deno.test("worker conta falha CAS sem afirmar sucesso", async () => {
  const config = await workerConfig("cas@example.test");
  let finishCalls = 0;
  const fake: typeof fetch = (input) => {
    const url = input.toString();
    const rpc = rpcName(input);
    if (url === "https://oauth2.googleapis.com/token") {
      return Promise.resolve(
        Response.json({ access_token: "access", expires_in: 3_600 }),
      );
    }
    if (rpc === "claim_notification_deliveries") {
      return Promise.resolve(Response.json([{
        id: "delivery-3",
        token: "device-token",
        notification_id: "notification-3",
        expires_at: "2026-09-15T01:00:00Z",
        attempt: 1,
        lease_id: "lease-3",
      }]));
    }
    if (rpc === "notification_delivery_ready") {
      return Promise.resolve(Response.json(true));
    }
    if (url.startsWith("https://fcm.googleapis.com/")) {
      return Promise.resolve(Response.json({ name: "accepted-before-cas" }));
    }
    if (rpc === "finish_notification_delivery") {
      finishCalls += 1;
      return Promise.resolve(new Response("lease lost", { status: 409 }));
    }
    throw new Error(`unexpected URL ${url}`);
  };
  const dispatch = createWorkerDispatcher(config, {
    fetchImpl: fake,
    now: () => new Date("2026-09-15T00:00:00Z"),
  });

  const summary = await dispatch();
  assert(finishCalls === 1, "worker deve tentar concluir uma vez");
  assert(
    summary.sent === 0 && summary.failed === 1,
    "CAS rejeitado não deve afirmar sent",
  );
});

Deno.test("worker rejeita resposta RPC de claim fora do contrato", async () => {
  const config = await workerConfig("invalid-claim@example.test");
  let downstreamCalls = 0;
  const fake: typeof fetch = (input) => {
    const url = input.toString();
    if (url === "https://oauth2.googleapis.com/token") {
      return Promise.resolve(
        Response.json({ access_token: "access", expires_in: 3_600 }),
      );
    }
    if (rpcName(input) === "claim_notification_deliveries") {
      return Promise.resolve(Response.json({ items: [] }));
    }
    downstreamCalls += 1;
    return Promise.resolve(Response.json(true));
  };
  const dispatch = createWorkerDispatcher(config, {
    fetchImpl: fake,
    now: () => new Date("2026-09-15T00:00:00Z"),
  });

  try {
    await dispatch();
    throw new Error("claim inválido deveria falhar");
  } catch (error) {
    assert(
      error instanceof Error && error.message === "invalid_claim_response",
      "claim inválido deve ser rejeitado",
    );
  }
  assert(downstreamCalls === 0, "resposta inválida não deve iniciar envios");
});

Deno.test("worker não conta conclusão RPC sem estado textual", async () => {
  const config = await workerConfig("invalid-finish@example.test");
  const fake: typeof fetch = (input) => {
    const url = input.toString();
    const rpc = rpcName(input);
    if (url === "https://oauth2.googleapis.com/token") {
      return Promise.resolve(
        Response.json({ access_token: "access", expires_in: 3_600 }),
      );
    }
    if (rpc === "claim_notification_deliveries") {
      return Promise.resolve(Response.json([{
        id: "delivery-4",
        token: "device-token",
        notification_id: "notification-4",
        expires_at: "2026-09-15T01:00:00Z",
        attempt: 1,
        lease_id: "lease-4",
      }]));
    }
    if (rpc === "notification_delivery_ready") {
      return Promise.resolve(Response.json(true));
    }
    if (url.startsWith("https://fcm.googleapis.com/")) {
      return Promise.resolve(Response.json({ name: "accepted" }));
    }
    if (rpc === "finish_notification_delivery") {
      return Promise.resolve(Response.json({ state: "sent" }));
    }
    throw new Error(`unexpected URL ${url}`);
  };
  const dispatch = createWorkerDispatcher(config, {
    fetchImpl: fake,
    now: () => new Date("2026-09-15T00:00:00Z"),
  });

  const summary = await dispatch();
  assert(
    summary.sent === 0 && summary.failed === 1,
    "estado CAS não textual não pode afirmar sucesso",
  );
});

Deno.test("worker não inicia item sem tempo para concessão, envio e conclusão", async () => {
  const config = await workerConfig("deadline@example.test");
  let clockCalls = 0;
  let sideEffectCalls = 0;
  const base = new Date("2026-09-15T00:00:00Z").getTime();
  const now = () => {
    clockCalls += 1;
    return new Date(base + (clockCalls > 3 ? 30_000 : 0));
  };
  const fake: typeof fetch = (input) => {
    const url = input.toString();
    const rpc = rpcName(input);
    if (url === "https://oauth2.googleapis.com/token") {
      return Promise.resolve(
        Response.json({ access_token: "access", expires_in: 3_600 }),
      );
    }
    if (rpc === "claim_notification_deliveries") {
      return Promise.resolve(Response.json([{
        id: "delivery-5",
        token: "device-token",
        notification_id: "notification-5",
        expires_at: "2026-09-15T01:00:00Z",
        attempt: 1,
        lease_id: "lease-5",
      }]));
    }
    sideEffectCalls += 1;
    return Promise.resolve(Response.json(true));
  };
  const dispatch = createWorkerDispatcher(config, { fetchImpl: fake, now });

  const summary = await dispatch();
  assert(
    summary.claimed === 1 && summary.sent === 0 && summary.failed === 0,
    "item sem janela deve permanecer recuperável",
  );
  assert(
    sideEffectCalls === 0,
    "item sem janela não deve consultar nem enviar",
  );
});

Deno.test("worker envia no máximo quatro entregas simultâneas", async () => {
  const config = await workerConfig("parallel@example.test");
  let active = 0;
  let maxActive = 0;
  const fake: typeof fetch = async (input) => {
    const url = input.toString();
    const rpc = rpcName(input);
    if (url === "https://oauth2.googleapis.com/token") {
      return Response.json({ access_token: "access", expires_in: 3_600 });
    }
    if (rpc === "claim_notification_deliveries") {
      return Response.json(Array.from({ length: 5 }, (_, index) => ({
        id: `delivery-parallel-${index}`,
        token: `device-token-${index}`,
        notification_id: `notification-parallel-${index}`,
        expires_at: "2026-09-15T01:00:00Z",
        attempt: 1,
        lease_id: `lease-parallel-${index}`,
      })));
    }
    if (rpc === "notification_delivery_ready") return Response.json(true);
    if (url.startsWith("https://fcm.googleapis.com/")) {
      active += 1;
      maxActive = Math.max(maxActive, active);
      await new Promise((resolve) => setTimeout(resolve, 5));
      active -= 1;
      return Response.json({ name: "accepted" });
    }
    if (rpc === "finish_notification_delivery") return Response.json("sent");
    throw new Error(`unexpected URL ${url}`);
  };
  const dispatch = createWorkerDispatcher(config, {
    fetchImpl: fake,
    now: () => new Date("2026-09-15T00:00:00Z"),
  });

  const summary = await dispatch();
  assert(maxActive === 4, "worker deve limitar o lote concorrente a quatro");
  assert(
    summary.claimed === 5 && summary.sent === 5,
    "todas as entregas válidas devem concluir",
  );
});
