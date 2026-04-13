import { PeprValidateRequest, PeprMutateRequest } from "pepr";
import { KubernetesObject } from "kubernetes-fluent-client";
import { V1Pod, V1Namespace, V1Deployment } from "@kubernetes/client-node";

type AdmissionRequest<T = KubernetesObject> = {
  uid: string;
  kind: { group: string; version: string; kind: string };
  resource: { group: string; version: string; resource: string };
  name: string;
  namespace?: string;
  operation: string;
  object: T;
  oldObject?: T;
  userInfo: { username: string; groups: string[] };
  dryRun?: boolean;
};

function makeAdmissionRequest<T extends KubernetesObject>(
  obj: T,
  operation = "CREATE"
): AdmissionRequest<T> {
  return {
    uid: "test-uid-" + Math.random().toString(36).slice(2),
    kind: { group: "", version: "v1", kind: obj.kind || "Unknown" },
    resource: { group: "", version: "v1", resource: "unknown" },
    name: obj.metadata?.name || "",
    namespace: obj.metadata?.namespace,
    operation,
    object: obj,
    userInfo: { username: "test-user", groups: ["system:authenticated"] },
  };
}

export function makeValidateRequest<T extends KubernetesObject>(
  obj: T,
  operation = "CREATE"
): PeprValidateRequest<T> {
  const req = makeAdmissionRequest(obj, operation);
  return new PeprValidateRequest<T>(req as any);
}

export function makeMutateRequest<T extends KubernetesObject>(
  obj: T,
  operation = "CREATE"
): PeprMutateRequest<T> {
  const req = makeAdmissionRequest(obj, operation);
  return new PeprMutateRequest<T>(req as any);
}

export function makePod(overrides: Partial<V1Pod> = {}): V1Pod {
  return {
    apiVersion: "v1",
    kind: "Pod",
    metadata: {
      name: "test-pod",
      namespace: "default",
      labels: {},
      annotations: {},
      ...overrides.metadata,
    },
    spec: {
      containers: [
        {
          name: "app",
          image: "nginx:latest",
          resources: {
            requests: { cpu: "100m", memory: "128Mi" },
            limits: { cpu: "500m", memory: "256Mi" },
          },
        },
      ],
      ...overrides.spec,
    },
  } as V1Pod;
}

export function makeNamespace(
  name: string,
  labels: Record<string, string> = {}
): V1Namespace {
  return {
    apiVersion: "v1",
    kind: "Namespace",
    metadata: { name, labels, annotations: {} },
  } as V1Namespace;
}

export function makeDeployment(
  name: string,
  namespace: string,
  labels: Record<string, string> = {}
): V1Deployment {
  return {
    apiVersion: "apps/v1",
    kind: "Deployment",
    metadata: { name, namespace, labels, annotations: {} },
    spec: {
      replicas: 1,
      selector: { matchLabels: { app: name } },
      template: {
        metadata: { labels: { app: name } },
        spec: {
          containers: [
            {
              name: "app",
              image: "nginx:latest",
            },
          ],
        },
      },
    },
  } as V1Deployment;
}
