import { Capability, a, Log } from "pepr";
import { V1Container } from "@kubernetes/client-node";

const name = "pod-security-baseline";
const description =
  "Enforce pod security standards: no privileged, drop ALL caps, read-only rootfs";

const AUDIT_MODE = () => process.env.PEPR_MODE === "audit";

export const PodSecurityBaseline = new Capability({
  name,
  description,
  namespaces: [],
});

const { When } = PodSecurityBaseline;

// ─── Validate: Block privileged containers ────────────────────────
When(a.Pod)
  .IsCreated()
  .Validate((request) => {
    const podName = request.Raw.metadata?.name || "unknown";
    const ns = request.Raw.metadata?.namespace || "";

    const allContainers: V1Container[] = [
      ...(request.Raw.spec?.containers || []),
      ...(request.Raw.spec?.initContainers || []),
    ];

    for (const container of allContainers) {
      const sc = container.securityContext;

      // Block privileged containers
      if (sc?.privileged === true) {
        const msg = `Pod "${ns}/${podName}" container "${container.name}" runs as privileged`;
        if (AUDIT_MODE()) {
          Log.warn(`[AUDIT] ${msg}`);
          continue;
        }
        return request.Deny(msg);
      }

      // Block host namespace sharing
      if (request.Raw.spec?.hostNetwork || request.Raw.spec?.hostPID || request.Raw.spec?.hostIPC) {
        const msg = `Pod "${ns}/${podName}" uses host namespaces (network/PID/IPC)`;
        if (AUDIT_MODE()) {
          Log.warn(`[AUDIT] ${msg}`);
          continue;
        }
        return request.Deny(msg);
      }

      // Block running as root (UID 0)
      if (sc?.runAsUser === 0) {
        const msg = `Pod "${ns}/${podName}" container "${container.name}" runs as root (UID 0)`;
        if (AUDIT_MODE()) {
          Log.warn(`[AUDIT] ${msg}`);
          continue;
        }
        return request.Deny(msg);
      }
    }

    return request.Approve();
  });

// ─── Mutate: Harden pod security context ──────────────────────────
When(a.Pod)
  .IsCreated()
  .Mutate((request) => {
    const podName = request.Raw.metadata?.name || "unknown";
    const containers = request.Raw.spec?.containers || [];

    for (const container of containers) {
      if (!container.securityContext) {
        container.securityContext = {};
      }

      const sc = container.securityContext;

      // Ensure capabilities drop ALL unless explicitly set
      if (!sc.capabilities) {
        sc.capabilities = { drop: ["ALL"], add: [] };
        Log.info(
          `[MUTATE] Pod "${podName}" container "${container.name}": added drop ALL capabilities`
        );
      } else if (!sc.capabilities.drop?.includes("ALL")) {
        sc.capabilities.drop = ["ALL"];
        Log.info(
          `[MUTATE] Pod "${podName}" container "${container.name}": set drop ALL capabilities`
        );
      }

      // Set readOnlyRootFilesystem if not explicitly set
      if (sc.readOnlyRootFilesystem === undefined) {
        sc.readOnlyRootFilesystem = true;
        Log.info(
          `[MUTATE] Pod "${podName}" container "${container.name}": set readOnlyRootFilesystem=true`
        );
      }

      // Ensure allowPrivilegeEscalation is false
      if (sc.allowPrivilegeEscalation === undefined) {
        sc.allowPrivilegeEscalation = false;
        Log.info(
          `[MUTATE] Pod "${podName}" container "${container.name}": set allowPrivilegeEscalation=false`
        );
      }
    }
  });
