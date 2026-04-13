const DEFAULT_LABELS: Record<string, string> = {
  "platform.openplatform.io/managed-by": "pepr",
  "pod-security.kubernetes.io/enforce": "baseline",
  "pod-security.kubernetes.io/warn": "restricted",
};

const DEFAULT_QUOTA = {
  hard: {
    "requests.cpu": "4",
    "requests.memory": "8Gi",
    "limits.cpu": "8",
    "limits.memory": "16Gi",
    pods: "50",
    services: "20",
    persistentvolumeclaims: "10",
  },
};

const EXEMPT_NAMESPACES = [
  "kube-system",
  "kube-public",
  "kube-node-lease",
  "default",
  "pepr-system",
  "flux-system",
  "cilium",
  "cert-manager",
  "monitoring",
];

function shouldConfigureNamespace(name: string): boolean {
  return !EXEMPT_NAMESPACES.includes(name);
}

function applyDefaultLabels(
  existing: Record<string, string>
): Record<string, string> {
  return { ...existing, ...DEFAULT_LABELS };
}

describe("Phase 4: Namespace Automation", () => {
  describe("Exemption logic", () => {
    it.each(EXEMPT_NAMESPACES)(
      "should NOT configure exempt namespace: %s",
      (ns) => {
        expect(shouldConfigureNamespace(ns)).toBe(false);
      }
    );

    it("should configure non-exempt namespaces", () => {
      expect(shouldConfigureNamespace("my-app")).toBe(true);
      expect(shouldConfigureNamespace("staging")).toBe(true);
      expect(shouldConfigureNamespace("team-a")).toBe(true);
    });
  });

  describe("Label injection", () => {
    it("should add all default labels", () => {
      const result = applyDefaultLabels({});
      expect(result["platform.openplatform.io/managed-by"]).toBe("pepr");
      expect(result["pod-security.kubernetes.io/enforce"]).toBe("baseline");
      expect(result["pod-security.kubernetes.io/warn"]).toBe("restricted");
    });

    it("should preserve existing labels", () => {
      const result = applyDefaultLabels({
        "custom-label": "value",
        "another-label": "test",
      });
      expect(result["custom-label"]).toBe("value");
      expect(result["another-label"]).toBe("test");
      expect(result["platform.openplatform.io/managed-by"]).toBe("pepr");
    });

    it("should override conflicting labels with defaults", () => {
      const result = applyDefaultLabels({
        "platform.openplatform.io/managed-by": "helm",
      });
      expect(result["platform.openplatform.io/managed-by"]).toBe("pepr");
    });
  });

  describe("Default quota", () => {
    it("should have reasonable CPU limits", () => {
      expect(parseInt(DEFAULT_QUOTA.hard["requests.cpu"])).toBeLessThanOrEqual(
        parseInt(DEFAULT_QUOTA.hard["limits.cpu"])
      );
    });

    it("should have a pod limit", () => {
      expect(parseInt(DEFAULT_QUOTA.hard.pods)).toBeGreaterThan(0);
    });

    it("should have a PVC limit", () => {
      expect(
        parseInt(DEFAULT_QUOTA.hard.persistentvolumeclaims)
      ).toBeGreaterThan(0);
    });
  });
});
