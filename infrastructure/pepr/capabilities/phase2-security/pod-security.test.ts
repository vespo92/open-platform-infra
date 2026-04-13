import { V1Container, V1PodSpec } from "@kubernetes/client-node";

// Test the security validation and mutation logic directly

interface SecurityCheckResult {
  approved: boolean;
  violations: string[];
}

function checkPodSecurity(
  podName: string,
  ns: string,
  spec: Partial<V1PodSpec>
): SecurityCheckResult {
  const violations: string[] = [];
  const allContainers: V1Container[] = [
    ...(spec.containers || []),
    ...(spec.initContainers || []),
  ];

  for (const container of allContainers) {
    const sc = container.securityContext;

    if (sc?.privileged === true) {
      violations.push(
        `Container "${container.name}" runs as privileged`
      );
    }

    if (sc?.runAsUser === 0) {
      violations.push(
        `Container "${container.name}" runs as root (UID 0)`
      );
    }
  }

  if (spec.hostNetwork) violations.push("Uses host network");
  if (spec.hostPID) violations.push("Uses host PID");
  if (spec.hostIPC) violations.push("Uses host IPC");

  return { approved: violations.length === 0, violations };
}

function hardenContainer(container: V1Container): V1Container {
  const result = JSON.parse(JSON.stringify(container));
  if (!result.securityContext) result.securityContext = {};
  const sc = result.securityContext;

  if (!sc.capabilities) {
    sc.capabilities = { drop: ["ALL"], add: [] };
  } else if (!sc.capabilities.drop?.includes("ALL")) {
    sc.capabilities.drop = ["ALL"];
  }

  if (sc.readOnlyRootFilesystem === undefined) {
    sc.readOnlyRootFilesystem = true;
  }

  if (sc.allowPrivilegeEscalation === undefined) {
    sc.allowPrivilegeEscalation = false;
  }

  return result;
}

describe("Phase 2: Pod Security Baseline", () => {
  describe("Validation", () => {
    it("should approve a pod with no security concerns", () => {
      const result = checkPodSecurity("test", "default", {
        containers: [
          { name: "app", image: "nginx", securityContext: {} } as V1Container,
        ],
      });
      expect(result.approved).toBe(true);
    });

    it("should reject a privileged container", () => {
      const result = checkPodSecurity("test", "default", {
        containers: [
          {
            name: "bad",
            image: "nginx",
            securityContext: { privileged: true },
          } as V1Container,
        ],
      });
      expect(result.approved).toBe(false);
      expect(result.violations).toContain(
        'Container "bad" runs as privileged'
      );
    });

    it("should reject a root UID container", () => {
      const result = checkPodSecurity("test", "default", {
        containers: [
          {
            name: "root-user",
            image: "nginx",
            securityContext: { runAsUser: 0 },
          } as V1Container,
        ],
      });
      expect(result.approved).toBe(false);
      expect(result.violations).toContain(
        'Container "root-user" runs as root (UID 0)'
      );
    });

    it("should reject host networking", () => {
      const result = checkPodSecurity("test", "default", {
        hostNetwork: true,
        containers: [
          { name: "app", image: "nginx" } as V1Container,
        ],
      });
      expect(result.approved).toBe(false);
      expect(result.violations).toContain("Uses host network");
    });

    it("should reject host PID", () => {
      const result = checkPodSecurity("test", "default", {
        hostPID: true,
        containers: [
          { name: "app", image: "nginx" } as V1Container,
        ],
      });
      expect(result.approved).toBe(false);
    });

    it("should catch violations in init containers too", () => {
      const result = checkPodSecurity("test", "default", {
        containers: [
          { name: "app", image: "nginx" } as V1Container,
        ],
        initContainers: [
          {
            name: "init-bad",
            image: "busybox",
            securityContext: { privileged: true },
          } as V1Container,
        ],
      });
      expect(result.approved).toBe(false);
      expect(result.violations).toContain(
        'Container "init-bad" runs as privileged'
      );
    });

    it("should report multiple violations", () => {
      const result = checkPodSecurity("test", "default", {
        hostNetwork: true,
        hostPID: true,
        containers: [
          {
            name: "bad",
            image: "nginx",
            securityContext: { privileged: true, runAsUser: 0 },
          } as V1Container,
        ],
      });
      expect(result.violations.length).toBeGreaterThanOrEqual(3);
    });
  });

  describe("Mutation (hardening)", () => {
    it("should add drop ALL capabilities when none set", () => {
      const container: V1Container = {
        name: "app",
        image: "nginx",
      } as V1Container;
      const result = hardenContainer(container);
      expect(result.securityContext!.capabilities!.drop).toContain("ALL");
    });

    it("should set readOnlyRootFilesystem when undefined", () => {
      const container: V1Container = {
        name: "app",
        image: "nginx",
      } as V1Container;
      const result = hardenContainer(container);
      expect(result.securityContext!.readOnlyRootFilesystem).toBe(true);
    });

    it("should set allowPrivilegeEscalation=false when undefined", () => {
      const container: V1Container = {
        name: "app",
        image: "nginx",
      } as V1Container;
      const result = hardenContainer(container);
      expect(result.securityContext!.allowPrivilegeEscalation).toBe(false);
    });

    it("should not override explicit readOnlyRootFilesystem=false", () => {
      const container: V1Container = {
        name: "app",
        image: "nginx",
        securityContext: { readOnlyRootFilesystem: false },
      } as V1Container;
      const result = hardenContainer(container);
      expect(result.securityContext!.readOnlyRootFilesystem).toBe(false);
    });

    it("should force drop ALL even if other caps are set", () => {
      const container: V1Container = {
        name: "app",
        image: "nginx",
        securityContext: {
          capabilities: { add: ["NET_ADMIN"], drop: ["CHOWN"] },
        },
      } as V1Container;
      const result = hardenContainer(container);
      expect(result.securityContext!.capabilities!.drop).toContain("ALL");
    });
  });
});
