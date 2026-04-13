import { PeprModule } from "pepr";
import cfg from "./package.json";

// Phase 1: Label governance (audit-only)
import { LabelEnforcement } from "./capabilities/phase1-labels/label-enforcement";

// Phase 2: Pod security baseline (audit → enforce)
import { PodSecurityBaseline } from "./capabilities/phase2-security/pod-security";

// Phase 3: Resource governance (audit → enforce)
import { ResourceGovernance } from "./capabilities/phase3-resources/resource-governance";

// Phase 4: Namespace automation (watch + mutate)
import { NamespaceAutomation } from "./capabilities/phase4-network/namespace-automation";

new PeprModule(cfg, [
  // ──────────────────────────────────────────────
  // Rollout order — enable one phase at a time.
  // Set PEPR_MODE=audit in package.json to log-only.
  // Set PEPR_MODE=enforce when ready to block.
  // ──────────────────────────────────────────────

  // Phase 1 — start here
  LabelEnforcement,

  // Phase 2 — enable after Phase 1 is stable (~2 weeks)
  PodSecurityBaseline,

  // Phase 3 — enable after Phase 2 is stable (~2 weeks)
  ResourceGovernance,

  // Phase 4 — enable after Phase 3 is stable (~2 weeks)
  NamespaceAutomation,
]);
