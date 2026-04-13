import { Capability, a, K8s, kind, Log } from "pepr";

const name = "namespace-automation";
const description =
  "Auto-configure new namespaces with default network policies, resource quotas, and labels";

// Standard labels applied to every new namespace
const DEFAULT_LABELS: Record<string, string> = {
  "platform.openplatform.io/managed-by": "pepr",
  "pod-security.kubernetes.io/enforce": "baseline",
  "pod-security.kubernetes.io/warn": "restricted",
};

// Default ResourceQuota for new namespaces
const DEFAULT_QUOTA = {
  hard: {
    "requests.cpu": "4",
    "requests.memory": "8Gi",
    "limits.cpu": "8",
    "limits.memory": "16Gi",
    pods: "50",
    services: "20",
    "persistentvolumeclaims": "10",
  },
};

// Default LimitRange for new namespaces
const DEFAULT_LIMIT_RANGE = {
  limits: [
    {
      type: "Container" as const,
      default: {
        cpu: "500m",
        memory: "256Mi",
      },
      defaultRequest: {
        cpu: "50m",
        memory: "64Mi",
      },
      max: {
        cpu: "4",
        memory: "8Gi",
      },
    },
  ],
};

// Namespaces that should not be auto-configured
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

export const NamespaceAutomation = new Capability({
  name,
  description,
  namespaces: [],
});

const { When } = NamespaceAutomation;

// ─── Mutate: Inject default labels on namespace creation ──────────
When(a.Namespace)
  .IsCreated()
  .Mutate((request) => {
    const ns = request.Raw.metadata?.name || "";
    if (EXEMPT_NAMESPACES.includes(ns)) return;

    for (const [key, value] of Object.entries(DEFAULT_LABELS)) {
      request.SetLabel(key, value);
    }

    Log.info(`[MUTATE] Namespace "${ns}": injected default labels`);
  });

// ─── Watch: Create ResourceQuota and LimitRange for new namespaces ─
When(a.Namespace)
  .IsCreated()
  .Watch(async (ns) => {
    const nsName = ns.metadata?.name || "";
    if (EXEMPT_NAMESPACES.includes(nsName)) return;

    Log.info(
      `[WATCH] Namespace "${nsName}" created — applying default quota and limits`
    );

    try {
      // Create default ResourceQuota
      await K8s(kind.ResourceQuota).Apply({
        metadata: {
          name: "default-quota",
          namespace: nsName,
          labels: {
            "platform.openplatform.io/managed-by": "pepr",
          },
        },
        spec: DEFAULT_QUOTA,
      });
      Log.info(`[WATCH] Created ResourceQuota "default-quota" in "${nsName}"`);

      // Create default LimitRange
      await K8s(kind.LimitRange).Apply({
        metadata: {
          name: "default-limits",
          namespace: nsName,
          labels: {
            "platform.openplatform.io/managed-by": "pepr",
          },
        },
        spec: DEFAULT_LIMIT_RANGE,
      });
      Log.info(`[WATCH] Created LimitRange "default-limits" in "${nsName}"`);
    } catch (err) {
      Log.error(
        `[WATCH] Failed to configure namespace "${nsName}": ${err}`
      );
    }
  });
