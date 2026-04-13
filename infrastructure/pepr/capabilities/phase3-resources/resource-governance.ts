import { Capability, a, Log } from "pepr";
import { V1Container } from "@kubernetes/client-node";

const name = "resource-governance";
const description =
  "Ensure all containers have resource requests and limits defined";

const AUDIT_MODE = () => process.env.PEPR_MODE === "audit";

// Default resource injection for containers that have none
const DEFAULT_RESOURCES = {
  requests: {
    cpu: "50m",
    memory: "64Mi",
  },
  limits: {
    cpu: "500m",
    memory: "256Mi",
  },
};

export const ResourceGovernance = new Capability({
  name,
  description,
  namespaces: [],
});

const { When } = ResourceGovernance;

// ─── Validate: Reject pods without resource definitions ───────────
When(a.Pod)
  .IsCreated()
  .Validate((request) => {
    const podName = request.Raw.metadata?.name || "unknown";
    const ns = request.Raw.metadata?.namespace || "";
    const containers = request.Raw.spec?.containers || [];

    for (const container of containers) {
      const resources = container.resources;

      const hasRequests =
        resources?.requests?.cpu && resources?.requests?.memory;
      const hasLimits = resources?.limits?.cpu && resources?.limits?.memory;

      if (!hasRequests || !hasLimits) {
        const msg = `Pod "${ns}/${podName}" container "${container.name}" is missing resource requests/limits`;
        if (AUDIT_MODE()) {
          Log.warn(`[AUDIT] ${msg}`);
          continue;
        }
        return request.Deny(msg);
      }
    }

    return request.Approve();
  });

// ─── Mutate: Inject default resources when missing ────────────────
When(a.Pod)
  .IsCreated()
  .Mutate((request) => {
    const podName = request.Raw.metadata?.name || "unknown";
    const containers = request.Raw.spec?.containers || [];

    for (const container of containers) {
      if (!container.resources) {
        container.resources = {};
      }

      if (!container.resources.requests) {
        container.resources.requests = { ...DEFAULT_RESOURCES.requests };
        Log.info(
          `[MUTATE] Pod "${podName}" container "${container.name}": injected default resource requests`
        );
      }

      if (!container.resources.limits) {
        container.resources.limits = { ...DEFAULT_RESOURCES.limits };
        Log.info(
          `[MUTATE] Pod "${podName}" container "${container.name}": injected default resource limits`
        );
      }
    }
  });
