export type RoutePoint = {
  id: string;
  kind: "origin" | "home" | "school" | "destination";
  latitude: number;
  longitude: number;
  schoolOrder: number | null;
};

export type RouteInput = {
  tripId: string;
  revision: number;
  points: RoutePoint[];
  departureAt: string;
  schoolOrder: string[];
};

export type RouteLeg = {
  fromId: string;
  toId: string;
  durationSeconds: number;
  distanceMeters: number;
};

export type RouteResult = {
  revision: number;
  orderedPointIds: string[];
  distanceMeters: number;
  durationSeconds: number;
  calculatedAt: string;
  legs: RouteLeg[];
};

type JsonObject = Record<string, unknown>;

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function fail(code: string): never {
  throw new Error(code);
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && Number.isFinite(Date.parse(value));
}

function validateInput(input: RouteInput): {
  pointById: Map<string, RoutePoint>;
  schoolOrder: string[];
} {
  if (
    !input ||
    typeof input.tripId !== "string" ||
    input.tripId.trim() === "" ||
    !Number.isSafeInteger(input.revision) ||
    input.revision < 1 ||
    !Array.isArray(input.points) ||
    !isTimestamp(input.departureAt) ||
    !Array.isArray(input.schoolOrder)
  ) {
    fail("invalid_route_input");
  }

  const pointById = new Map<string, RoutePoint>();
  let originCount = 0;
  let destinationCount = 0;
  const schoolIds: string[] = [];

  for (const point of input.points) {
    if (
      !isObject(point) ||
      typeof point.id !== "string" ||
      point.id.trim() === "" ||
      pointById.has(point.id) ||
      !["origin", "home", "school", "destination"].includes(
        String(point.kind),
      ) ||
      !isFiniteNumber(point.latitude) ||
      point.latitude < -90 ||
      point.latitude > 90 ||
      !isFiniteNumber(point.longitude) ||
      point.longitude < -180 ||
      point.longitude > 180 ||
      (point.schoolOrder !== null && !Number.isInteger(point.schoolOrder))
    ) {
      fail("invalid_route_points");
    }

    if (point.kind === "origin") originCount += 1;
    if (point.kind === "destination") destinationCount += 1;
    if (point.kind === "school") {
      if (point.schoolOrder === null || point.schoolOrder < 0) {
        fail("invalid_route_points");
      }
      schoolIds.push(point.id);
    } else if (point.schoolOrder !== null) {
      fail("invalid_route_points");
    }
    pointById.set(point.id, point);
  }

  if (originCount !== 1 || destinationCount !== 1 || input.points.length < 2) {
    fail("invalid_route_points");
  }
  const schoolOrders = schoolIds.map((id) => pointById.get(id)?.schoolOrder);
  if (new Set(schoolOrders).size !== schoolOrders.length) {
    fail("invalid_route_input");
  }

  const requestedSchoolOrder: string[] = [];
  for (const id of input.schoolOrder) {
    if (
      typeof id !== "string" || id.trim() === "" ||
      requestedSchoolOrder.includes(id)
    ) {
      fail("invalid_route_input");
    }
    requestedSchoolOrder.push(id);
  }

  const sortedSchoolIds = [...schoolIds].sort((left, right) => {
    const leftOrder = pointById.get(left)?.schoolOrder ?? 0;
    const rightOrder = pointById.get(right)?.schoolOrder ?? 0;
    return leftOrder - rightOrder;
  });
  const schoolOrder = requestedSchoolOrder;

  if (
    schoolOrder.length !== schoolIds.length ||
    schoolOrder.some((id, index) => id !== sortedSchoolIds[index])
  ) {
    fail("invalid_route_input");
  }

  return { pointById, schoolOrder };
}

export function validateRouteResult(
  input: RouteInput,
  result: unknown,
): RouteResult {
  const { pointById, schoolOrder } = validateInput(input);
  if (!isObject(result)) fail("invalid_route_result");

  if (
    !Number.isSafeInteger(result.revision) || result.revision !== input.revision
  ) {
    fail("route_revision_mismatch");
  }
  if (!Array.isArray(result.orderedPointIds)) fail("invalid_route_points");

  const orderedPointIds = result.orderedPointIds;
  if (
    orderedPointIds.length !== pointById.size ||
    orderedPointIds.some((id) => typeof id !== "string") ||
    new Set(orderedPointIds).size !== orderedPointIds.length
  ) {
    fail("invalid_route_points");
  }
  if (orderedPointIds.some((id) => !pointById.has(id))) {
    fail("unknown_route_point");
  }

  const originId = input.points.find((point) => point.kind === "origin")?.id;
  const destinationId = input.points.find((point) =>
    point.kind === "destination"
  )?.id;
  if (
    orderedPointIds[0] !== originId || orderedPointIds.at(-1) !== destinationId
  ) {
    fail("invalid_route_points");
  }

  const resultSchoolOrder = orderedPointIds.filter((id) =>
    pointById.get(id)?.kind === "school"
  );
  if (resultSchoolOrder.some((id, index) => id !== schoolOrder[index])) {
    fail("school_order_changed");
  }

  if (
    !isFiniteNumber(result.distanceMeters) ||
    result.distanceMeters < 0 ||
    !isFiniteNumber(result.durationSeconds) ||
    result.durationSeconds < 0 ||
    !isTimestamp(result.calculatedAt) ||
    !Array.isArray(result.legs) ||
    result.legs.length !== orderedPointIds.length - 1
  ) {
    fail("invalid_route_result");
  }

  const legs: RouteLeg[] = [];
  for (let index = 0; index < result.legs.length; index += 1) {
    const leg = result.legs[index];
    if (
      !isObject(leg) ||
      leg.fromId !== orderedPointIds[index] ||
      leg.toId !== orderedPointIds[index + 1] ||
      !isFiniteNumber(leg.durationSeconds) ||
      leg.durationSeconds < 0 ||
      !isFiniteNumber(leg.distanceMeters) ||
      leg.distanceMeters < 0
    ) {
      fail("invalid_route_legs");
    }
    const fromId = orderedPointIds[index];
    const toId = orderedPointIds[index + 1];
    legs.push({
      fromId,
      toId,
      durationSeconds: leg.durationSeconds,
      distanceMeters: leg.distanceMeters,
    });
  }

  return {
    revision: result.revision,
    orderedPointIds: [...orderedPointIds],
    distanceMeters: result.distanceMeters,
    durationSeconds: result.durationSeconds,
    calculatedAt: result.calculatedAt,
    legs,
  };
}
