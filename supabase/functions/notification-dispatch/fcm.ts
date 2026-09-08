export type FcmResult =
  | { kind: "sent"; providerId: string }
  | { kind: "retry"; code: string; retryAfterSeconds: number | null }
  | { kind: "invalid_token" | "permanent_failure"; code: string };

export type SendFcmMessageInput = {
  projectId: string;
  accessToken: string;
  deviceToken: string;
  notificationId: string;
  expiresAt: string;
  now: Date;
  fetchImpl: typeof fetch;
};

const FCM_URL = "https://fcm.googleapis.com/v1/projects";
const FCM_TIMEOUT_MS = 10_000;
const MAX_TTL_SECONDS = 2_419_200;

type JsonObject = Record<string, unknown>;

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function safeCode(value: unknown, fallback: string): string {
  if (typeof value !== "string") return fallback;
  const code = value.trim().replace(/[^A-Za-z0-9_.-]/g, "_");
  return code.length > 0 && code.length <= 80 ? code : fallback;
}

function retryAfterSeconds(response: Response, now: Date): number | null {
  const value = response.headers.get("retry-after");
  if (!value) return null;

  const seconds = Number(value.trim());
  if (Number.isFinite(seconds) && seconds >= 0) return Math.ceil(seconds);

  const date = Date.parse(value);
  if (!Number.isFinite(date)) return null;
  return Math.max(0, Math.ceil((date - now.getTime()) / 1000));
}

async function readJson(
  response: Response,
): Promise<{ value: unknown; errorName: string | null }> {
  try {
    return { value: await response.json(), errorName: null };
  } catch (error) {
    return {
      value: null,
      errorName: error instanceof Error ? error.name : "UnknownError",
    };
  }
}

function fcmErrorCode(payload: unknown): string | null {
  if (!isObject(payload) || !isObject(payload.error)) return null;
  const details = payload.error.details;
  if (!Array.isArray(details)) return null;

  for (const detail of details) {
    if (!isObject(detail)) continue;
    const type = detail["@type"];
    if (
      typeof type === "string" &&
      type === "type.googleapis.com/google.firebase.fcm.v1.FcmError" &&
      typeof detail.errorCode === "string"
    ) {
      return detail.errorCode;
    }
  }
  return null;
}

function hasInvalidRegistrationDetail(payload: unknown): boolean {
  if (!isObject(payload) || !isObject(payload.error)) return false;
  const message = typeof payload.error.message === "string"
    ? payload.error.message.toLowerCase()
    : "";
  if (!message.includes("registration token")) return false;

  const details = payload.error.details;
  return Array.isArray(details) && details.some((detail) => {
    if (!isObject(detail)) return false;
    return detail["@type"] ===
        "type.googleapis.com/google.firebase.fcm.v1.FcmError" &&
      detail.errorCode === "INVALID_ARGUMENT";
  });
}

function buildBody(
  input: SendFcmMessageInput,
  expiresAtMs: number,
): JsonObject {
  const ttlSeconds = Math.min(
    MAX_TTL_SECONDS,
    Math.max(0, Math.floor((expiresAtMs - input.now.getTime()) / 1000)),
  );
  return {
    message: {
      token: input.deviceToken,
      notification: {
        title: "VanGo",
        body: "Você tem uma atualização no aplicativo.",
      },
      data: { notification_id: input.notificationId },
      android: { ttl: `${ttlSeconds}s` },
      apns: {
        headers: { "apns-expiration": String(Math.floor(expiresAtMs / 1000)) },
      },
    },
  };
}

export async function sendFcmMessage(
  input: SendFcmMessageInput,
): Promise<FcmResult> {
  const expiresAtMs = Date.parse(input.expiresAt);
  if (
    !input.projectId.trim() || !input.accessToken.trim() ||
    !input.deviceToken.trim() ||
    !input.notificationId.trim() || !Number.isFinite(expiresAtMs) ||
    !Number.isFinite(input.now.getTime())
  ) {
    return { kind: "permanent_failure", code: "invalid_input" };
  }
  if (input.now.getTime() >= expiresAtMs) {
    return { kind: "permanent_failure", code: "expired" };
  }

  const url = `${FCM_URL}/${encodeURIComponent(input.projectId)}/messages:send`;
  let response: Response;
  try {
    response = await input.fetchImpl(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${input.accessToken}`,
        "Content-Type": "application/json",
      },
      signal: AbortSignal.timeout(FCM_TIMEOUT_MS),
      body: JSON.stringify(buildBody(input, expiresAtMs)),
    });
  } catch (error) {
    const name = error instanceof Error ? error.name : "";
    return {
      kind: "retry",
      code: name === "AbortError" || name === "TimeoutError"
        ? "timeout"
        : "network_error",
      retryAfterSeconds: null,
    };
  }

  const parsed = await readJson(response);
  if (
    parsed.errorName === "AbortError" || parsed.errorName === "TimeoutError"
  ) {
    return { kind: "retry", code: "response_timeout", retryAfterSeconds: null };
  }
  const payload = parsed.value;
  if (response.ok) {
    if (isObject(payload) && typeof payload.name === "string" && payload.name) {
      return { kind: "sent", providerId: payload.name };
    }
    return { kind: "permanent_failure", code: "invalid_response" };
  }

  const providerCode = fcmErrorCode(payload);
  if (providerCode === "UNREGISTERED") {
    return { kind: "invalid_token", code: "UNREGISTERED" };
  }
  if (
    providerCode === "INVALID_ARGUMENT" && hasInvalidRegistrationDetail(payload)
  ) {
    return { kind: "invalid_token", code: "INVALID_ARGUMENT" };
  }

  if (response.status === 429) {
    return {
      kind: "retry",
      code: "rate_limited",
      retryAfterSeconds: retryAfterSeconds(response, input.now),
    };
  }
  if (response.status >= 500 && response.status <= 599) {
    return {
      kind: "retry",
      code: "provider_unavailable",
      retryAfterSeconds: retryAfterSeconds(response, input.now),
    };
  }

  const status = isObject(payload) && isObject(payload.error)
    ? payload.error.status
    : null;
  return {
    kind: "permanent_failure",
    code: safeCode(providerCode ?? status, `http_${response.status}`),
  };
}
