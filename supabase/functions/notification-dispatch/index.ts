import { getGoogleAccessToken } from "./oauth.ts";
import { type FcmResult, sendFcmMessage } from "./fcm.ts";

const encoder = new TextEncoder();

const CLAIM_LIMIT = 10;
const MAX_PARALLEL_SENDS = 4;
const MAX_RUNTIME_MS = 45_000;
const RPC_TIMEOUT_MS = 10_000;

export type DispatchSummary = {
  claimed: number;
  sent: number;
  retried: number;
  failed: number;
};

export type WorkerHandleDeps = {
  workerSecret: string;
  dispatch: () => Promise<Record<string, number>>;
};

export type NotificationDelivery = {
  id: string;
  token: string;
  notification_id: string;
  expires_at: string;
  attempt: number;
  lease_id: string;
};

export type WorkerConfig = {
  supabaseUrl: string;
  supabaseServiceRoleKey: string;
  fcmProjectId: string;
  fcmClientEmail: string;
  fcmPrivateKey: string;
};

export type WorkerRuntime = {
  fetchImpl?: typeof fetch;
  now?: () => Date;
  maxParallel?: number;
  maxRuntimeMs?: number;
};

function constantTimeEqual(expected: string, actual: string): boolean {
  const expectedBytes = encoder.encode(expected);
  const actualBytes = encoder.encode(actual);
  let difference = expectedBytes.length ^ actualBytes.length;
  const length = Math.max(expectedBytes.length, actualBytes.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (expectedBytes[index] ?? 0) ^ (actualBytes[index] ?? 0);
  }
  return difference === 0 && expectedBytes.length > 0;
}

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function numberOrZero(value: unknown): number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0
    ? value
    : 0;
}

function publicSummary(value: Record<string, number>): DispatchSummary {
  return {
    claimed: numberOrZero(value.claimed),
    sent: numberOrZero(value.sent),
    retried: numberOrZero(value.retried),
    failed: numberOrZero(value.failed),
  };
}

function rpcEndpoint(config: WorkerConfig, functionName: string): string {
  return `${
    config.supabaseUrl.replace(/\/+$/u, "")
  }/rest/v1/rpc/${functionName}`;
}

async function callRpc(
  config: WorkerConfig,
  functionName: string,
  body: Record<string, unknown>,
  fetchImpl: typeof fetch,
): Promise<unknown> {
  let response: Response;
  try {
    response = await fetchImpl(rpcEndpoint(config, functionName), {
      method: "POST",
      headers: {
        apikey: config.supabaseServiceRoleKey,
        Authorization: `Bearer ${config.supabaseServiceRoleKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
    });
  } catch {
    throw new Error("rpc_unavailable");
  }
  if (!response.ok) throw new Error("rpc_failed");
  const raw = await response.text();
  if (raw.trim() === "") throw new Error("rpc_invalid_response");
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error("rpc_invalid_response");
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function deliveryRows(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  throw new Error("invalid_claim_response");
}

function readString(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

function readInteger(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) && value >= 1
    ? value
    : null;
}

function parseDelivery(value: unknown): NotificationDelivery {
  if (!isObject(value)) throw new Error("invalid_claim_response");
  const id = readString(value.id);
  const token = readString(value.token);
  const notificationId = readString(value.notification_id);
  const expiresAt = readString(value.expires_at);
  const attempt = readInteger(value.attempt);
  const leaseId = readString(value.lease_id);
  if (!id || !token || !notificationId || !expiresAt || !attempt || !leaseId) {
    throw new Error("invalid_claim_response");
  }
  return {
    id,
    token,
    notification_id: notificationId,
    expires_at: expiresAt,
    attempt,
    lease_id: leaseId,
  };
}

function readReady(value: unknown): boolean {
  if (typeof value !== "boolean") throw new Error("invalid_ready_response");
  return value;
}

async function isDeliveryReady(
  config: WorkerConfig,
  delivery: NotificationDelivery,
  fetchImpl: typeof fetch,
): Promise<boolean> {
  const result = await callRpc(config, "notification_delivery_ready", {
    p_delivery_id: delivery.id,
    p_lease_id: delivery.lease_id,
  }, fetchImpl);
  return readReady(result);
}

function finishArguments(
  delivery: NotificationDelivery,
  result: FcmResult | { kind: "permanent_failure"; code: string },
): Record<string, unknown> {
  if (result.kind === "sent") {
    return {
      p_delivery_id: delivery.id,
      p_lease_id: delivery.lease_id,
      p_outcome: "sent",
      p_provider_id: result.providerId,
      p_error_code: null,
      p_retry_after_seconds: null,
    };
  }
  if (result.kind === "retry") {
    return {
      p_delivery_id: delivery.id,
      p_lease_id: delivery.lease_id,
      p_outcome: "retry",
      p_provider_id: null,
      p_error_code: result.code,
      p_retry_after_seconds: result.retryAfterSeconds,
    };
  }
  return {
    p_delivery_id: delivery.id,
    p_lease_id: delivery.lease_id,
    p_outcome: result.kind === "invalid_token"
      ? "invalid_token"
      : "permanent_failure",
    p_provider_id: null,
    p_error_code: result.code,
    p_retry_after_seconds: null,
  };
}

type ProcessResult = "sent" | "retried" | "failed" | "skipped";

function hasBudget(
  startedAt: number,
  maxRuntimeMs: number,
  now: () => Date,
  requiredMs: number,
): boolean {
  return now().getTime() - startedAt + requiredMs <= maxRuntimeMs;
}

function finishAccepted(result: unknown, outcome: FcmResult["kind"]): boolean {
  if (typeof result !== "string") return false;
  if (outcome === "sent") return result === "sent";
  if (outcome === "retry") {
    return result === "retry" || result === "pending" || result === "expired";
  }
  if (outcome === "invalid_token") {
    return result === "invalid_token" || result === "failed" ||
      result === "suppressed" || result === "expired";
  }
  return result === "permanent_failure" || result === "failed" ||
    result === "suppressed" || result === "expired";
}

async function processDelivery(
  config: WorkerConfig,
  delivery: NotificationDelivery,
  accessToken: string,
  fetchImpl: typeof fetch,
  now: () => Date,
  startedAt: number,
  maxRuntimeMs: number,
): Promise<ProcessResult> {
  try {
    if (!hasBudget(startedAt, maxRuntimeMs, now, RPC_TIMEOUT_MS * 3)) {
      return "skipped";
    }
    if (!await isDeliveryReady(config, delivery, fetchImpl)) {
      const suppressed = {
        kind: "permanent_failure" as const,
        code: "not_actionable",
      };
      if (!hasBudget(startedAt, maxRuntimeMs, now, RPC_TIMEOUT_MS)) {
        return "skipped";
      }
      const finishResult = await callRpc(
        config,
        "finish_notification_delivery",
        finishArguments(delivery, suppressed),
        fetchImpl,
      );
      if (!finishAccepted(finishResult, suppressed.kind)) return "failed";
      return "failed";
    }

    if (!hasBudget(startedAt, maxRuntimeMs, now, RPC_TIMEOUT_MS * 2)) {
      return "skipped";
    }
    const result = await sendFcmMessage({
      projectId: config.fcmProjectId,
      accessToken,
      deviceToken: delivery.token,
      notificationId: delivery.notification_id,
      expiresAt: delivery.expires_at,
      now: now(),
      fetchImpl,
    });
    if (!hasBudget(startedAt, maxRuntimeMs, now, RPC_TIMEOUT_MS)) {
      return "skipped";
    }
    const finishResult = await callRpc(
      config,
      "finish_notification_delivery",
      finishArguments(delivery, result),
      fetchImpl,
    );
    if (!finishAccepted(finishResult, result.kind)) return "failed";
    if (result.kind === "sent") return "sent";
    if (result.kind === "retry") {
      return finishResult === "expired" ? "failed" : "retried";
    }
    return "failed";
  } catch {
    return "failed";
  }
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value || value.trim() === "") throw new Error(`missing_${name}`);
  return value;
}

export function createWorkerDispatcher(
  config: WorkerConfig,
  runtime: WorkerRuntime = {},
): () => Promise<DispatchSummary> {
  const fetchImpl = runtime.fetchImpl ?? globalThis.fetch;
  const now = runtime.now ?? (() => new Date());
  const maxParallel = Math.max(
    1,
    Math.min(MAX_PARALLEL_SENDS, runtime.maxParallel ?? MAX_PARALLEL_SENDS),
  );
  const maxRuntimeMs = Math.max(1, runtime.maxRuntimeMs ?? MAX_RUNTIME_MS);

  return async () => {
    if (
      !config.supabaseUrl || !config.supabaseServiceRoleKey ||
      !config.fcmProjectId || !config.fcmClientEmail || !config.fcmPrivateKey
    ) {
      throw new Error("worker_configuration");
    }

    const startedAt = now().getTime();
    const accessToken = await getGoogleAccessToken(
      {
        client_email: config.fcmClientEmail,
        private_key: config.fcmPrivateKey,
      },
      fetchImpl,
      now(),
    );
    const leaseId = crypto.randomUUID();
    const claimedResponse = await callRpc(
      config,
      "claim_notification_deliveries",
      {
        p_limit: CLAIM_LIMIT,
        p_lease_id: leaseId,
      },
      fetchImpl,
    );
    const deliveries = deliveryRows(claimedResponse).map((value) =>
      parseDelivery(value)
    );
    const summary: DispatchSummary = {
      claimed: deliveries.length,
      sent: 0,
      retried: 0,
      failed: 0,
    };

    for (let offset = 0; offset < deliveries.length; offset += maxParallel) {
      if (now().getTime() - startedAt >= maxRuntimeMs) break;
      const batch = deliveries.slice(offset, offset + maxParallel);
      const results = await Promise.all(
        batch.map((delivery) =>
          processDelivery(
            config,
            delivery,
            accessToken.token,
            fetchImpl,
            now,
            startedAt,
            maxRuntimeMs,
          )
        ),
      );
      for (const result of results) {
        if (result === "sent") summary.sent += 1;
        else if (result === "retried") summary.retried += 1;
        else if (result === "failed") summary.failed += 1;
      }
    }
    return summary;
  };
}

export async function handle(
  request: Request,
  deps: WorkerHandleDeps,
): Promise<Response> {
  const providedSecret = request.headers.get("x-worker-secret") ?? "";
  if (!constantTimeEqual(deps.workerSecret, providedSecret)) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  if (request.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  let body: unknown;
  try {
    body = JSON.parse(await request.text());
  } catch {
    return jsonResponse({ error: "invalid_body" }, 400);
  }
  if (
    typeof body !== "object" || body === null || Array.isArray(body) ||
    Object.keys(body).length !== 0
  ) {
    return jsonResponse({ error: "invalid_body" }, 400);
  }

  try {
    return jsonResponse(publicSummary(await deps.dispatch()));
  } catch {
    return jsonResponse({ error: "dispatch_failed" }, 500);
  }
}

if (import.meta.main) {
  const workerSecret = requiredEnv("NOTIFICATION_WORKER_SECRET");
  const supabaseServiceRoleKey =
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim()
      ? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
      : requiredEnv("SUPABASE_SECRET_KEY");
  const config: WorkerConfig = {
    supabaseUrl: requiredEnv("SUPABASE_URL"),
    supabaseServiceRoleKey,
    fcmProjectId: requiredEnv("FCM_PROJECT_ID"),
    fcmClientEmail: requiredEnv("FCM_CLIENT_EMAIL"),
    fcmPrivateKey: requiredEnv("FCM_PRIVATE_KEY"),
  };
  const dispatch = createWorkerDispatcher(config);
  Deno.serve((request) => handle(request, { workerSecret, dispatch }));
}
