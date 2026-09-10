// Actual local Realtime sockets, including channels opened before revocation.
// Run: deno run --allow-run --allow-read --allow-env --allow-net tracking.ts
const root = new URL("../../../", import.meta.url);
const psql = Deno.env.get("VANGO_PSQL") ?? "/opt/homebrew/opt/libpq/bin/psql";
const sqlEnv = {
  PGHOST: "127.0.0.1",
  PGPORT: "54322",
  PGUSER: "postgres",
  PGDATABASE: "postgres",
  PGPASSWORD: "postgres",
  PGOPTIONS: "-c statement_timeout=20000 -c lock_timeout=15000",
};
for (const key of ["PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE"]) {
  if (Deno.env.get(key)) {
    throw new Error(`${key} must be unset for local-only tracking tests`);
  }
}
function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
async function command(
  program: string,
  args: string[],
  input?: string,
): Promise<string> {
  const child = new Deno.Command(program, {
    args,
    cwd: root,
    env: sqlEnv,
    stdin: input === undefined ? "null" : "piped",
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  if (input !== undefined) {
    const writer = child.stdin.getWriter();
    await writer.write(new TextEncoder().encode(input));
    await writer.close();
  }
  const result = await child.output();
  assert(
    result.success,
    program === psql
      ? `Local fixture SQL failed: ${new TextDecoder().decode(result.stderr)}`
      : `${program} failed; credentials and private output suppressed`,
  );
  return new TextDecoder().decode(result.stdout);
}
function sql(text: string): Promise<string> {
  return command(psql, ["-X", "-qAt", "-v", "ON_ERROR_STOP=1"], text);
}
const status = JSON.parse(await command("supabase", ["status", "-o", "json"]));
const api = new URL(status.API_URL);
assert(
  ["127.0.0.1", "localhost", "[::1]"].includes(api.hostname) &&
    api.port === "54321",
  "Refusing non-local API",
);
const fixtureFleet = "41000000-0000-0000-0000-000000000001";
assert(
  (await sql(
    `select count(*) from auth.users where id::text like '40000000-%' or id::text like '60000000-%';`,
  )).trim() === "0",
  "Dedicated fixtures already exist; refusing to overwrite",
);
const encoder = new TextEncoder();
const base64 = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_")
    .replaceAll("=", "");
async function token(user: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const data = `${
    base64(encoder.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })))
  }.${
    base64(
      encoder.encode(
        JSON.stringify({
          sub: user,
          role: "authenticated",
          aud: "authenticated",
          iat: now,
          exp: now + 3600,
        }),
      ),
    )
  }`;
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(status.JWT_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return `${data}.${
    base64(
      new Uint8Array(
        await crypto.subtle.sign("HMAC", key, encoder.encode(data)),
      ),
    )
  }`;
}
const sockets: WebSocket[] = [];
type Channel = { socket: WebSocket; messages: Record<string, unknown>[] };
async function join(
  topic: string,
  jwt: string,
  allowed = true,
  privateChannel = true,
): Promise<Channel> {
  const url = new URL("/realtime/v1/websocket", api);
  url.protocol = "ws:";
  url.searchParams.set("apikey", status.ANON_KEY);
  url.searchParams.set("vsn", "1.0.0");
  const socket = new WebSocket(url);
  sockets.push(socket);
  const messages: Record<string, unknown>[] = [];
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("Realtime join timed out")),
      8000,
    );
    socket.onopen = () =>
      socket.send(JSON.stringify({
        topic: `realtime:${topic}`,
        event: "phx_join",
        payload: {
          config: {
            broadcast: { ack: true, self: false },
            presence: { enabled: false },
            postgres_changes: [],
            private: privateChannel,
          },
          access_token: jwt,
        },
        ref: "1",
        join_ref: "1",
      }));
    socket.onerror = () => {
      clearTimeout(timer);
      reject(new Error("Realtime socket failed"));
    };
    socket.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (
        message.event === "broadcast" && message.payload?.event === "location"
      ) messages.push(message.payload.payload);
      if (message.event === "phx_reply" && message.ref === "1") {
        clearTimeout(timer);
        if ((message.payload.status === "ok") !== allowed) {
          reject(
            new Error(
              allowed
                ? `Authorized private join denied: ${
                  JSON.stringify(message.payload.response)
                }`
                : "Revoked private join accepted",
            ),
          );
        } else resolve();
      }
    };
  });
  return { socket, messages };
}
const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
let ownsFixture = false;
try {
  const setup = await command(psql, [
    "-X",
    "-qAt",
    "-v",
    "ON_ERROR_STOP=1",
    "-f",
    new URL("supabase/tests/concurrency/tracking_setup.psql", root).pathname,
  ]);
  ownsFixture = true;
  const line = setup.split("\n").find((line) =>
    line.startsWith("VANGO_TRACKING=")
  );
  assert(line, "Fixture IDs missing");
  const ids: Record<string, string> = JSON.parse(
    line.slice("VANGO_TRACKING=".length),
  );
  assert(
    Object.values(ids).every((id) => /^[0-9a-f-]{36}$/.test(id)),
    "Invalid fixture identifier",
  );
  const owner1 = await token("40000000-0000-0000-0000-000000000001");
  const owner2 = await token("40000000-0000-0000-0000-000000000002");
  const guardian = await token("60000000-0000-0000-0000-000000000001");
  const driver = await token(ids.driver);
  const topic = () =>
    sql(
      `select 'trip:'||id||':v'||broadcast_epoch from public.trips where id='${ids.trip}';`,
    ).then((s) => s.trim());
  const original = await topic();
  const oldOwner = await join(original, owner2);
  const oldGuardian = await join(original, guardian);
  const oldDriver = await join(original, driver);
  const publicChannel = await join(original, status.ANON_KEY, true, false);
  oldOwner.socket.send(
    JSON.stringify({
      topic: `realtime:${original}`,
      event: "broadcast",
      payload: {
        type: "broadcast",
        event: "location",
        payload: { sequence: 777 },
      },
      ref: "fake",
      join_ref: "1",
    }),
  );
  await join(
    original,
    await token("40000000-0000-0000-0000-000000000005"),
    false,
  );
  let sequence = 0;
  const publish = async (
    jwt: string,
    assignment: string,
    positive: Channel,
    negatives: Channel[] = [],
  ): Promise<void> => {
    await delay(1100);
    sequence++;
    const response = await fetch(
      new URL("/rest/v1/rpc/ingest_trip_locations", api),
      {
        method: "POST",
        signal: AbortSignal.timeout(8000),
        headers: {
          apikey: status.ANON_KEY,
          Authorization: `Bearer ${jwt}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          p_trip_id: ids.trip,
          p_assignment_id: assignment,
          p_points: [{
            sequence,
            captured_at: new Date().toISOString(),
            latitude: -23.55,
            longitude: -46.63,
            accuracy: 5,
          }],
          p_live: true,
        }),
      },
    );
    assert(response.ok, `GPS RPC failed (${response.status})`);
    const deadline = Date.now() + 5000;
    while (
      !positive.messages.some((message) => message.sequence === sequence) &&
      Date.now() < deadline
    ) await delay(25);
    assert(
      positive.messages.some((message) => message.sequence === sequence),
      "Authorized current topic did not receive GPS",
    );
    await delay(300);
    assert(
      negatives.every((channel) =>
        !channel.messages.some((message) => message.sequence === sequence)
      ),
      "An old opened topic received post-revocation GPS",
    );
  };
  await publish(driver, ids.assignment, oldOwner, [publicChannel]);
  assert(
    !oldGuardian.messages.some((message) => message.sequence === 777),
    "Client published an unauthorized location",
  );
  assert(
    oldGuardian.messages.length > 0 && oldDriver.messages.length > 0,
    "Initial authorized participants did not receive GPS",
  );
  await sql(
    `begin; select set_config('request.jwt.claims','{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}',true); select public.set_fleet_membership_status('42000000-0000-0000-0000-000000000002','suspended'); commit;`,
  );
  const afterOwner = await topic();
  assert(afterOwner !== original, "Owner membership loss did not rotate epoch");
  const currentOwner = await join(afterOwner, owner1);
  await join(afterOwner, owner2, false);
  await publish(driver, ids.assignment, currentOwner, [
    oldOwner,
    oldGuardian,
    oldDriver,
  ]);
  await sql(
    `update public.trip_passengers set operation_status='absent' where trip_id='${ids.trip}' and student_id='${ids.student}';`,
  );
  const afterAbsent = await topic();
  const remainingDependent = await join(afterAbsent, guardian);
  await publish(driver, ids.assignment, remainingDependent, [
    oldGuardian,
    currentOwner,
  ]);
  await sql(
    `update public.student_guardians set status='removed',removed_at=clock_timestamp() where student_id='${
      ids["second-dependent"]
    }' and guardian_user_id='60000000-0000-0000-0000-000000000001';`,
  );
  const afterUnlink = await topic();
  await join(afterUnlink, guardian, false);
  const afterPassenger = await join(afterUnlink, owner1);
  await publish(driver, ids.assignment, afterPassenger, [
    remainingDependent,
    oldGuardian,
  ]);
  // Substitute the current assignment; the old driver remains a fleet driver.
  await sql(
    `begin; insert into public.fleet_membership_roles(membership_id,role) select id,'driver' from public.fleet_memberships where fleet_id='${fixtureFleet}' and user_id='40000000-0000-0000-0000-000000000001' on conflict do nothing; update public.trip_assignments set valid_until=clock_timestamp() where id='${ids.assignment}'; update public.trips set driver_user_id='40000000-0000-0000-0000-000000000001' where id='${ids.trip}'; insert into public.trip_assignments(fleet_id,trip_id,van_id,driver_user_id) select fleet_id,id,van_id,driver_user_id from public.trips where id='${ids.trip}'; commit;`,
  );
  const newAssignment = (await sql(
    `select id from public.trip_assignments where trip_id='${ids.trip}' and valid_until is null;`,
  )).trim();
  const afterSwap = await topic();
  await join(afterSwap, driver, false);
  const newDriver = await join(afterSwap, owner1);
  await publish(owner1, newAssignment, newDriver, [oldDriver, afterPassenger]);
  const adultToken = await token("60000000-0000-0000-0000-000000000003");
  const adultChannel = await join(await topic(), adultToken);
  await sql(
    `delete from public.fleet_membership_roles where role='student' and membership_id in (select id from public.fleet_memberships where fleet_id='${fixtureFleet}' and user_id='60000000-0000-0000-0000-000000000003');`,
  );
  const afterAdult = await topic();
  await join(afterAdult, adultToken, false);
  const ownerAfterAdult = await join(afterAdult, owner1);
  await publish(owner1, newAssignment, ownerAfterAdult, [
    adultChannel,
    newDriver,
  ]);
  await sql(
    `update public.fleet_memberships set status='active',suspended_at=null where fleet_id='${fixtureFleet}' and user_id='40000000-0000-0000-0000-000000000002';`,
  );
  const ownerBeforeRoleLoss = await join(await topic(), owner2);
  await sql(
    `delete from public.fleet_membership_roles where role='owner' and membership_id='42000000-0000-0000-0000-000000000002';`,
  );
  await join(await topic(), owner2, false);
  const finalOwner = await join(await topic(), owner1);
  await publish(owner1, newAssignment, finalOwner, [
    ownerBeforeRoleLoss,
    ownerAfterAdult,
  ]);
  console.log(
    "Realtime WebSocket PASS: private delivery, foreign/public/client-write denial, owner suspension/role removal, remaining dependent, guardian unlink, adult role removal and driver substitution; old opened topics stayed silent.",
  );
} catch (error) {
  console.error(
    error instanceof Error ? error.message : "Tracking test failed",
  );
  throw error;
} finally {
  for (const socket of sockets) socket.close();
  if (ownsFixture) {
    const cleanup = await Deno.readTextFile(
      new URL("supabase/tests/concurrency/operations_cleanup.psql", root),
    );
    await sql(cleanup);
    assert(
      (await sql(
        `select count(*) from public.fleets where id='${fixtureFleet}';`,
      )).trim() === "0",
      "Tracking fixture cleanup failed",
    );
    console.log("Realtime fixture cleanup PASS");
  }
}
