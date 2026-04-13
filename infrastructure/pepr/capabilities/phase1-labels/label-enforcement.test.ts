import { makeValidateRequest, makeNamespace, makeDeployment } from "../helpers.test-utils";

// Test the validation logic directly — we extract the rules and test them
// rather than going through Pepr's When() registration (which needs a running controller)

const REQUIRED_WORKLOAD_LABELS = [
  "app.kubernetes.io/name",
  "app.kubernetes.io/part-of",
  "app.kubernetes.io/managed-by",
];

const REQUIRED_NAMESPACE_LABELS = [
  "platform.openplatform.io/owner",
  "platform.openplatform.io/environment",
];

const EXEMPT_NAMESPACES = [
  "kube-system",
  "kube-public",
  "kube-node-lease",
  "default",
  "pepr-system",
  "flux-system",
];

function validateNamespaceLabels(name: string, labels: Record<string, string>) {
  if (EXEMPT_NAMESPACES.includes(name)) return { approved: true, missing: [] };
  const missing = REQUIRED_NAMESPACE_LABELS.filter((l) => !labels[l]);
  return { approved: missing.length === 0, missing };
}

function validateWorkloadLabels(labels: Record<string, string>) {
  const missing = REQUIRED_WORKLOAD_LABELS.filter((l) => !labels[l]);
  return { approved: missing.length === 0, missing };
}

describe("Phase 1: Label Enforcement", () => {
  describe("Namespace validation", () => {
    it("should approve namespaces with all required labels", () => {
      const result = validateNamespaceLabels("my-app", {
        "platform.openplatform.io/owner": "team-a",
        "platform.openplatform.io/environment": "production",
      });
      expect(result.approved).toBe(true);
      expect(result.missing).toHaveLength(0);
    });

    it("should reject namespaces missing owner label", () => {
      const result = validateNamespaceLabels("my-app", {
        "platform.openplatform.io/environment": "production",
      });
      expect(result.approved).toBe(false);
      expect(result.missing).toContain("platform.openplatform.io/owner");
    });

    it("should reject namespaces missing environment label", () => {
      const result = validateNamespaceLabels("my-app", {
        "platform.openplatform.io/owner": "team-a",
      });
      expect(result.approved).toBe(false);
      expect(result.missing).toContain("platform.openplatform.io/environment");
    });

    it("should reject namespaces with no labels", () => {
      const result = validateNamespaceLabels("my-app", {});
      expect(result.approved).toBe(false);
      expect(result.missing).toHaveLength(2);
    });

    it.each(EXEMPT_NAMESPACES)(
      "should always approve exempt namespace: %s",
      (ns) => {
        const result = validateNamespaceLabels(ns, {});
        expect(result.approved).toBe(true);
      }
    );
  });

  describe("Workload validation", () => {
    it("should approve workloads with all required labels", () => {
      const result = validateWorkloadLabels({
        "app.kubernetes.io/name": "my-app",
        "app.kubernetes.io/part-of": "platform",
        "app.kubernetes.io/managed-by": "flux",
      });
      expect(result.approved).toBe(true);
    });

    it("should reject workloads missing name label", () => {
      const result = validateWorkloadLabels({
        "app.kubernetes.io/part-of": "platform",
        "app.kubernetes.io/managed-by": "flux",
      });
      expect(result.approved).toBe(false);
      expect(result.missing).toContain("app.kubernetes.io/name");
    });

    it("should reject workloads with no labels", () => {
      const result = validateWorkloadLabels({});
      expect(result.approved).toBe(false);
      expect(result.missing).toHaveLength(3);
    });

    it("should ignore extra labels and still approve", () => {
      const result = validateWorkloadLabels({
        "app.kubernetes.io/name": "my-app",
        "app.kubernetes.io/part-of": "platform",
        "app.kubernetes.io/managed-by": "flux",
        "custom-label": "value",
      });
      expect(result.approved).toBe(true);
    });
  });
});
