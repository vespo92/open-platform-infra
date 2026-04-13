import { Capability, a, Log } from "pepr";

const name = "label-enforcement";
const description = "Enforce required labels on namespaces and workloads";

// Required labels for all Deployments/StatefulSets/DaemonSets
const REQUIRED_WORKLOAD_LABELS = [
  "app.kubernetes.io/name",
  "app.kubernetes.io/part-of",
  "app.kubernetes.io/managed-by",
];

// Required labels for namespaces (excluding system namespaces)
const REQUIRED_NAMESPACE_LABELS = [
  "platform.openplatform.io/owner",
  "platform.openplatform.io/environment",
];

// Namespaces exempt from label enforcement
const EXEMPT_NAMESPACES = [
  "kube-system",
  "kube-public",
  "kube-node-lease",
  "default",
  "pepr-system",
  "flux-system",
];

export const LabelEnforcement = new Capability({
  name,
  description,
  namespaces: [], // all namespaces
});

const { When } = LabelEnforcement;

// ─── Namespace label validation ───────────────────────────────────
When(a.Namespace)
  .IsCreatedOrUpdated()
  .Validate((request) => {
    const ns = request.Raw.metadata?.name || "";
    if (EXEMPT_NAMESPACES.includes(ns)) {
      return request.Approve();
    }

    const labels = request.Raw.metadata?.labels || {};
    const missing = REQUIRED_NAMESPACE_LABELS.filter((l) => !labels[l]);

    if (missing.length > 0) {
      const msg = `Namespace "${ns}" is missing required labels: ${missing.join(", ")}`;

      if (process.env.PEPR_MODE === "audit") {
        Log.warn(`[AUDIT] ${msg}`);
        return request.Approve();
      }

      return request.Deny(msg);
    }

    return request.Approve();
  });

// ─── Deployment label validation ──────────────────────────────────
When(a.Deployment)
  .IsCreatedOrUpdated()
  .Validate((request) => {
    const name = request.Raw.metadata?.name || "";
    const ns = request.Raw.metadata?.namespace || "";
    const labels = request.Raw.metadata?.labels || {};
    const missing = REQUIRED_WORKLOAD_LABELS.filter((l) => !labels[l]);

    if (missing.length > 0) {
      const msg = `Deployment "${ns}/${name}" is missing required labels: ${missing.join(", ")}`;

      if (process.env.PEPR_MODE === "audit") {
        Log.warn(`[AUDIT] ${msg}`);
        return request.Approve();
      }

      return request.Deny(msg);
    }

    return request.Approve();
  });

// ─── StatefulSet label validation ─────────────────────────────────
When(a.StatefulSet)
  .IsCreatedOrUpdated()
  .Validate((request) => {
    const name = request.Raw.metadata?.name || "";
    const ns = request.Raw.metadata?.namespace || "";
    const labels = request.Raw.metadata?.labels || {};
    const missing = REQUIRED_WORKLOAD_LABELS.filter((l) => !labels[l]);

    if (missing.length > 0) {
      const msg = `StatefulSet "${ns}/${name}" is missing required labels: ${missing.join(", ")}`;

      if (process.env.PEPR_MODE === "audit") {
        Log.warn(`[AUDIT] ${msg}`);
        return request.Approve();
      }

      return request.Deny(msg);
    }

    return request.Approve();
  });

// ─── DaemonSet label validation ───────────────────────────────────
When(a.DaemonSet)
  .IsCreatedOrUpdated()
  .Validate((request) => {
    const name = request.Raw.metadata?.name || "";
    const ns = request.Raw.metadata?.namespace || "";
    const labels = request.Raw.metadata?.labels || {};
    const missing = REQUIRED_WORKLOAD_LABELS.filter((l) => !labels[l]);

    if (missing.length > 0) {
      const msg = `DaemonSet "${ns}/${name}" is missing required labels: ${missing.join(", ")}`;

      if (process.env.PEPR_MODE === "audit") {
        Log.warn(`[AUDIT] ${msg}`);
        return request.Approve();
      }

      return request.Deny(msg);
    }

    return request.Approve();
  });
