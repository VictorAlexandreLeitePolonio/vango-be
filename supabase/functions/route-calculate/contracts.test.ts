import {
  type RouteInput,
  type RouteResult,
  validateRouteResult,
} from "./contracts.ts";

function assertThrows(action: () => unknown, expected: string): void {
  try {
    action();
  } catch (error) {
    if (error instanceof Error && error.message === expected) return;
    throw new Error(
      `erro inesperado: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
  }
  throw new Error("esperava erro");
}

const input: RouteInput = {
  tripId: "trip-1",
  revision: 3,
  points: [
    {
      id: "origin",
      kind: "origin",
      latitude: 0,
      longitude: 0,
      schoolOrder: null,
    },
    {
      id: "school-1",
      kind: "school",
      latitude: 0.01,
      longitude: 0.01,
      schoolOrder: 1,
    },
    {
      id: "home-1",
      kind: "home",
      latitude: 0.015,
      longitude: 0.015,
      schoolOrder: null,
    },
    {
      id: "school-2",
      kind: "school",
      latitude: 0.02,
      longitude: 0.02,
      schoolOrder: 2,
    },
    {
      id: "destination",
      kind: "destination",
      latitude: 0.03,
      longitude: 0.03,
      schoolOrder: null,
    },
  ],
  departureAt: "2026-09-14T11:00:00Z",
  schoolOrder: ["school-1", "school-2"],
};

Deno.test("resultado mantém escolas e legs encadeados em uma ordem válida", () => {
  const result = validateRouteResult(input, {
    revision: 3,
    orderedPointIds: [
      "origin",
      "school-1",
      "home-1",
      "school-2",
      "destination",
    ],
    distanceMeters: 140,
    durationSeconds: 80,
    calculatedAt: "2026-09-14T10:00:00Z",
    legs: [
      {
        fromId: "origin",
        toId: "school-1",
        durationSeconds: 20,
        distanceMeters: 40,
      },
      {
        fromId: "school-1",
        toId: "home-1",
        durationSeconds: 20,
        distanceMeters: 30,
      },
      {
        fromId: "home-1",
        toId: "school-2",
        durationSeconds: 20,
        distanceMeters: 30,
      },
      {
        fromId: "school-2",
        toId: "destination",
        durationSeconds: 20,
        distanceMeters: 40,
      },
    ],
  });

  if (
    result.orderedPointIds.join(",") !==
      "origin,school-1,home-1,school-2,destination"
  ) {
    throw new Error("ordem válida foi alterada");
  }
});

Deno.test("resultado não pode reordenar as escolas definidas pelo dono", () => {
  assertThrows(
    () =>
      validateRouteResult(input, {
        revision: 3,
        orderedPointIds: [
          "origin",
          "school-2",
          "home-1",
          "school-1",
          "destination",
        ],
        distanceMeters: 100,
        durationSeconds: 60,
        calculatedAt: "2026-09-14T10:00:00Z",
        legs: [
          {
            fromId: "origin",
            toId: "school-2",
            durationSeconds: 20,
            distanceMeters: 40,
          },
          {
            fromId: "school-2",
            toId: "home-1",
            durationSeconds: 20,
            distanceMeters: 30,
          },
          {
            fromId: "home-1",
            toId: "school-1",
            durationSeconds: 20,
            distanceMeters: 30,
          },
          {
            fromId: "school-1",
            toId: "destination",
            durationSeconds: 20,
            distanceMeters: 30,
          },
        ],
      }),
    "school_order_changed",
  );
});

Deno.test("resultado rejeita ponto desconhecido e IDs repetidos", () => {
  assertThrows(
    () =>
      validateRouteResult(input, {
        revision: 3,
        orderedPointIds: [
          "origin",
          "school-1",
          "home-1",
          "school-2",
          "school-2",
        ],
        distanceMeters: 1,
        durationSeconds: 1,
        calculatedAt: "2026-09-14T10:00:00Z",
        legs: [],
      }),
    "invalid_route_points",
  );
  assertThrows(
    () =>
      validateRouteResult(input, {
        revision: 3,
        orderedPointIds: [
          "origin",
          "school-1",
          "home-1",
          "missing",
          "destination",
        ],
        distanceMeters: 1,
        durationSeconds: 1,
        calculatedAt: "2026-09-14T10:00:00Z",
        legs: [],
      }),
    "unknown_route_point",
  );
});

Deno.test("resultado exige origem na primeira posição e destino na última", () => {
  assertThrows(
    () =>
      validateRouteResult(input, {
        revision: 3,
        orderedPointIds: [
          "school-1",
          "origin",
          "home-1",
          "school-2",
          "destination",
        ],
        distanceMeters: 1,
        durationSeconds: 1,
        calculatedAt: "2026-09-14T10:00:00Z",
        legs: [],
      }),
    "invalid_route_points",
  );
});

Deno.test("resultado exige legs encadeados", () => {
  assertThrows(
    () =>
      validateRouteResult(input, {
        revision: 3,
        orderedPointIds: [
          "origin",
          "school-1",
          "home-1",
          "school-2",
          "destination",
        ],
        distanceMeters: 1,
        durationSeconds: 1,
        calculatedAt: "2026-09-14T10:00:00Z",
        legs: [
          {
            fromId: "origin",
            toId: "school-1",
            durationSeconds: 1,
            distanceMeters: 1,
          },
          {
            fromId: "school-1",
            toId: "school-2",
            durationSeconds: 1,
            distanceMeters: 1,
          },
          {
            fromId: "home-1",
            toId: "school-2",
            durationSeconds: 1,
            distanceMeters: 1,
          },
          {
            fromId: "school-2",
            toId: "destination",
            durationSeconds: 1,
            distanceMeters: 1,
          },
        ],
      }),
    "invalid_route_legs",
  );
});

Deno.test("resultado rejeita revisão, números e timestamps inválidos", () => {
  const validOrder = [
    "origin",
    "school-1",
    "home-1",
    "school-2",
    "destination",
  ];
  const validLegs = [
    {
      fromId: "origin",
      toId: "school-1",
      durationSeconds: 1,
      distanceMeters: 1,
    },
    {
      fromId: "school-1",
      toId: "home-1",
      durationSeconds: 1,
      distanceMeters: 1,
    },
    {
      fromId: "home-1",
      toId: "school-2",
      durationSeconds: 1,
      distanceMeters: 1,
    },
    {
      fromId: "school-2",
      toId: "destination",
      durationSeconds: 1,
      distanceMeters: 1,
    },
  ];
  assertThrows(
    () =>
      validateRouteResult(input, {
        revision: 4,
        orderedPointIds: validOrder,
        distanceMeters: 1,
        durationSeconds: 1,
        calculatedAt: "2026-09-14T10:00:00Z",
        legs: validLegs,
      }),
    "route_revision_mismatch",
  );
  assertThrows(
    () =>
      validateRouteResult(input, {
        revision: 3,
        orderedPointIds: validOrder,
        distanceMeters: -1,
        durationSeconds: Number.NaN,
        calculatedAt: "not-a-date",
        legs: validLegs,
      }),
    "invalid_route_result",
  );
});

Deno.test("pontos de escola não podem compartilhar schoolOrder", () => {
  const ambiguous = structuredClone(input) as RouteInput;
  ambiguous.points[3] = { ...ambiguous.points[3], schoolOrder: 1 };
  assertThrows(
    () =>
      validateRouteResult(ambiguous, {
        revision: 3,
        orderedPointIds: [
          "origin",
          "school-1",
          "home-1",
          "school-2",
          "destination",
        ],
        distanceMeters: 1,
        durationSeconds: 1,
        calculatedAt: "2026-09-14T10:00:00Z",
        legs: [],
      }),
    "invalid_route_input",
  );
});

Deno.test("ordem explícita vazia não é substituída silenciosamente", () => {
  const orderedPointIds = input.points.map((point) => point.id);
  const result = {
    revision: input.revision,
    orderedPointIds,
    distanceMeters: 4,
    durationSeconds: 4,
    calculatedAt: "2026-09-14T10:00:00Z",
    legs: orderedPointIds.slice(1).map((toId, index) => ({
      fromId: orderedPointIds[index],
      toId,
      distanceMeters: 1,
      durationSeconds: 1,
    })),
  };
  assertThrows(
    () => validateRouteResult({ ...input, schoolOrder: [] }, result),
    "invalid_route_input",
  );
});

function validResult(): RouteResult {
  const orderedPointIds = input.points.map((point) => point.id);
  return {
    revision: input.revision,
    orderedPointIds,
    distanceMeters: 4,
    durationSeconds: 4,
    calculatedAt: "2026-09-14T10:00:00Z",
    legs: orderedPointIds.slice(1).map((toId, index) => ({
      fromId: orderedPointIds[index],
      toId,
      distanceMeters: 1,
      durationSeconds: 1,
    })),
  };
}

for (
  const [label, patch] of [
    ["distância negativa", { distanceMeters: -1 }],
    ["distância infinita", { distanceMeters: Infinity }],
    ["distância NaN", { distanceMeters: NaN }],
    ["duração negativa", { durationSeconds: -1 }],
    ["duração infinita", { durationSeconds: Infinity }],
    ["duração NaN", { durationSeconds: NaN }],
    ["timestamp inválido", { calculatedAt: "invalid" }],
  ] satisfies [string, Partial<RouteResult>][]
) {
  Deno.test(`validação independente: ${label}`, () => {
    assertThrows(
      () => validateRouteResult(input, { ...validResult(), ...patch }),
      "invalid_route_result",
    );
  });
}

Deno.test("cada métrica de trecho é validada sem outro campo inválido", () => {
  for (const metric of ["distanceMeters", "durationSeconds"] as const) {
    for (const value of [-1, NaN, Infinity]) {
      const result = validResult();
      result.legs[0][metric] = value;
      assertThrows(
        () => validateRouteResult(input, result),
        "invalid_route_legs",
      );
    }
  }
});

Deno.test("revisão não pode perder precisão de inteiro no JavaScript", () => {
  const revision = Number.MAX_SAFE_INTEGER + 1;
  assertThrows(
    () =>
      validateRouteResult({ ...input, revision }, {
        ...validResult(),
        revision,
      }),
    "invalid_route_input",
  );
});
