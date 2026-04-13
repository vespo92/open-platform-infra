import { V1Container } from "@kubernetes/client-node";

const DEFAULT_RESOURCES = {
  requests: { cpu: "50m", memory: "64Mi" },
  limits: { cpu: "500m", memory: "256Mi" },
};

function validateResources(containers: V1Container[]): {
  approved: boolean;
  violations: string[];
} {
  const violations: string[] = [];

  for (const container of containers) {
    const resources = container.resources;
    const hasRequests = resources?.requests?.cpu && resources?.requests?.memory;
    const hasLimits = resources?.limits?.cpu && resources?.limits?.memory;

    if (!hasRequests || !hasLimits) {
      violations.push(
        `Container "${container.name}" is missing resource requests/limits`
      );
    }
  }

  return { approved: violations.length === 0, violations };
}

function injectDefaults(container: V1Container): V1Container {
  const result = JSON.parse(JSON.stringify(container));
  if (!result.resources) result.resources = {};
  if (!result.resources.requests) {
    result.resources.requests = { ...DEFAULT_RESOURCES.requests };
  }
  if (!result.resources.limits) {
    result.resources.limits = { ...DEFAULT_RESOURCES.limits };
  }
  return result;
}

describe("Phase 3: Resource Governance", () => {
  describe("Validation", () => {
    it("should approve containers with full resource definitions", () => {
      const result = validateResources([
        {
          name: "app",
          image: "nginx",
          resources: {
            requests: { cpu: "100m", memory: "128Mi" },
            limits: { cpu: "500m", memory: "256Mi" },
          },
        } as V1Container,
      ]);
      expect(result.approved).toBe(true);
    });

    it("should reject containers with no resources", () => {
      const result = validateResources([
        { name: "app", image: "nginx" } as V1Container,
      ]);
      expect(result.approved).toBe(false);
    });

    it("should reject containers with only requests", () => {
      const result = validateResources([
        {
          name: "app",
          image: "nginx",
          resources: { requests: { cpu: "100m", memory: "128Mi" } },
        } as V1Container,
      ]);
      expect(result.approved).toBe(false);
    });

    it("should reject containers with only limits", () => {
      const result = validateResources([
        {
          name: "app",
          image: "nginx",
          resources: { limits: { cpu: "500m", memory: "256Mi" } },
        } as V1Container,
      ]);
      expect(result.approved).toBe(false);
    });

    it("should reject if only one container out of many is missing resources", () => {
      const result = validateResources([
        {
          name: "app",
          image: "nginx",
          resources: {
            requests: { cpu: "100m", memory: "128Mi" },
            limits: { cpu: "500m", memory: "256Mi" },
          },
        } as V1Container,
        { name: "sidecar", image: "envoy" } as V1Container,
      ]);
      expect(result.approved).toBe(false);
      expect(result.violations).toHaveLength(1);
      expect(result.violations[0]).toContain("sidecar");
    });
  });

  describe("Mutation (default injection)", () => {
    it("should inject default requests when missing", () => {
      const container: V1Container = {
        name: "app",
        image: "nginx",
      } as V1Container;
      const result = injectDefaults(container);
      expect(result.resources!.requests!.cpu).toBe("50m");
      expect(result.resources!.requests!.memory).toBe("64Mi");
    });

    it("should inject default limits when missing", () => {
      const container: V1Container = {
        name: "app",
        image: "nginx",
      } as V1Container;
      const result = injectDefaults(container);
      expect(result.resources!.limits!.cpu).toBe("500m");
      expect(result.resources!.limits!.memory).toBe("256Mi");
    });

    it("should not override existing requests", () => {
      const container: V1Container = {
        name: "app",
        image: "nginx",
        resources: {
          requests: { cpu: "200m", memory: "512Mi" },
        },
      } as V1Container;
      const result = injectDefaults(container);
      expect(result.resources!.requests!.cpu).toBe("200m");
      expect(result.resources!.requests!.memory).toBe("512Mi");
    });

    it("should not override existing limits", () => {
      const container: V1Container = {
        name: "app",
        image: "nginx",
        resources: {
          limits: { cpu: "2", memory: "1Gi" },
        },
      } as V1Container;
      const result = injectDefaults(container);
      expect(result.resources!.limits!.cpu).toBe("2");
      expect(result.resources!.limits!.memory).toBe("1Gi");
    });
  });
});
