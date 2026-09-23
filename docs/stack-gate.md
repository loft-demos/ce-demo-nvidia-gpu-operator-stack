# The reusable Stack gate

`demo-stack-gate` is a Stack task that waits for something to become true, optionally verifies scheduler capacity, and optionally publishes a contract other tasks can read. It is one ArgoCDApplicationTemplate and one Helm chart, parameterized, and this repository instantiates it three times for three different jobs.

## Why it exists

A Stack task is ready when its Argo CD Application reports both `Synced` and `Healthy`. For a Helm chart that installs an operator, `Healthy` means "Argo CD created the resources," which can be minutes to an hour before the thing the operator manages is actually usable. Anything that depends on an operator being *useful* rather than merely installed needs a stronger signal.

The obvious fix is a custom Argo CD health check, and it does not fit inside a Stack. Argo CD reads custom health checks from exactly two places:

- **`argocd-cm`.** The `resource.customizations.health.<group>_<kind>` key is instance-wide configuration in the Argo CD namespace, not per-Application. Argo CD also typically runs outside the tenant cluster while the Stack's destination is the tenant cluster. A StackInstance has a single destination, so the patch cannot be part of the same Stack. It would also fight whatever release owns `argocd-cm` and change health for every Application on that instance.
- **Built into Argo CD.** Health checks contributed upstream under `resource_customizations/<group>/<kind>/health.lua` ship with Argo CD itself.

So derive the health from a kind Argo CD already understands. **Argo CD's built-in Job health reports `Progressing` while a Job runs and `Healthy` only when it completes.** A task that deploys an Application containing exactly one Job is therefore a real readiness gate, with no Argo CD configuration and no cluster-wide side effects.

Three things fall out of that:

- The wait becomes its own node in the task graph, visible in the UI with its own timeout, rather than a health status buried inside another Application.
- The Job can verify anything `kubectl` can express, not just what a health check author anticipated.
- The Job can publish what it learned, so the wait and the handoff are one task instead of two.

## What the gate does

[`gate/stack-gate.sh`](../gate/stack-gate.sh) runs four steps, each of which can be switched off:

1. **Wait for the resource to exist.** Polls `kubectl get <waitResource>`, bounded by `existsTimeoutSeconds`. Polling rather than `kubectl wait --for=create` because this also covers the window where a CRD is not served yet.
2. **Wait for it to report ready.** `kubectl wait <waitResource> --for=<waitCondition> --timeout=<waitTimeout>`.
3. **Count scheduler capacity.** Sums allocatable `<capacityResource>` across nodes matching `<capacityNodeSelector>`. Blocks until it reaches `capacityMin`, or counts once without blocking when `capacityMin` is `0`.
4. **Publish the contract.** Writes `<contractName>` as a ConfigMap in the destination namespace, last, so its existence is the signal that every check passed.

Setting `waitEnabled: 'false'` skips 1 and 2. Setting `capacityMin: '0'` makes 3 observational. Setting `contractName: ''` skips 4. The script refuses to run if all three are off, because that gate would do nothing.

## How to reuse it

Add a task pointing at `demo-stack-gate` and set the parameters for what you need. Everything has a default, so most gates set three or four.

```yaml
- name: somethingready
  dependsOn:
    - the-task-that-creates-it
  timeout: 15m0s
  argoCDApplication:
    templateRef:
      name: demo-stack-gate
    parameters:
      project: '{{ .Values.argoProject }}'
      cpuNodePool: '{{ .Values.cpuNodePool }}'
      releaseName: something-ready
      waitResource: deployment/my-thing
      waitNamespace: my-namespace
      waitCondition: condition=Available
      watchAPIGroup: apps
      watchResources: deployments
      capacityMin: '0'
      contractName: ''
```

Give each instance a distinct `releaseName`. It is what separates the Jobs, ServiceAccounts and ClusterRoles of two gates running in the same namespace.

**Grant it what it watches.** `watchAPIGroup` and `watchResources` build the ClusterRole the gate runs with. Point the gate at a new kind without updating them and it will poll forever against a resource it cannot read. Use `watchAPIGroup: ''` for core resources.

**Name it without a hyphen if it declares outputs.** Outputs are referenced as `{{ .Outputs.task.name }}`, and the template syntax cannot address a name containing a hyphen. Platform rejects a hyphenated task name that declares outputs. `gpuready`, not `gpu-ready`. A gate that publishes nothing can be named normally.

## Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `project` | `default` | Argo CD project |
| `destinationNamespace` | `gpu-stack` | Where the Job and contract live. Stack outputs can only be read from a namespace the Stack deploys into |
| `releaseName` | `gpu-ready` | Helm release name. Must be unique per gate instance |
| `cpuNodePool` | `cpu-services` | Pool the Job runs on. The gate only talks to the API server |
| `waitEnabled` | `true` | `false` skips steps 1 and 2 |
| `waitResource` | `clusterpolicy/cluster-policy` | `TYPE/NAME` passed to kubectl |
| `waitNamespace` | empty | Empty for a cluster-scoped resource |
| `waitCondition` | `jsonpath={.status.state}=ready` | Passed to `kubectl wait --for` |
| `waitTimeout` | `30m` | Bound on step 2 |
| `existsTimeoutSeconds` | `900` | Bound on step 1, which also covers an unserved CRD |
| `watchAPIGroup` | `nvidia.com` | API group granted read-only to the gate |
| `watchResources` | `clusterpolicies` | Plural resource name granted read-only |
| `capacityResource` | `nvidia.com/gpu` | Scheduler resource to count |
| `capacityMin` | `1` | Minimum to wait for. `0` counts without blocking |
| `capacityNodeSelector` | `workload.example.com/pool=gpu-compute` | Which nodes count |
| `contractName` | `gpu-stack-contract` | ConfigMap to publish. Empty publishes nothing |
| `contractData` | empty | YAML key/value pairs added to the contract. The caller supplies whatever its consumers need |
| `repoURL` / `targetRevision` / `chartPath` | this repo, `main`, `charts/stack-gate` | Chart source |
| `imageRepository` / `imageTag` | `ghcr.io/loft-demos/stack-gate`, `edge` | Gate image |

The contract always carries `ready`, `observedCount`, `verifiedAt` and `resourceName`, plus whatever the contract parameters add.

## The three instances in this repository

### `gpuready`: capacity, then publish

Proves the scheduler will admit a GPU pod, then publishes the contract the other tasks read.

```yaml
parameters:
  capacityMin: '{{ .Values.minGPUs }}'
  waitEnabled: '{{ .Values.waitForClusterPolicy | toString }}'
  contractData: |
    gpuPool: gpu-compute
    dcgmHost: nvidia-dcgm.gpu-operator.svc
    dcgmPort: "5555"
```

Note where the GPU specifics sit. The gate template knows nothing about NVIDIA: the caller passes the keys its consumers need, and the gate adds `ready`, `observedCount`, `resourceName` and `verifiedAt` to them.

`waitForClusterPolicy` is `false` by default, so steps 1 and 2 are skipped and the gate is capacity plus publish. `ClusterPolicy` is a weaker signal than it looks: it aggregates every GPU Operator operand, so it stays `notReady` while `dcgm-exporter` loses its startup race against the DCGM host engine, even though the GPU is already schedulable. In a measured run the node advertised `nvidia.com/gpu: 1` at 18:01:55 and `nvidia-cuda-validator` had already succeeded at 18:00:22, but the gate sat until 18:03:21 waiting on `ClusterPolicy`. About 90 seconds spent on a metrics exporter nothing downstream reads.

Turn it on when you want the Stack to hold until the whole operand set is healthy, or when your Argo CD has a Lua health check for `ClusterPolicy` and you want the Stack to respect it.

### `dcgmready`: wait only

Holds NVSentinel until the DCGM host engine is serving. Publishes nothing, counts nothing.

```yaml
parameters:
  releaseName: dcgm-ready
  waitResource: daemonset/nvidia-dcgm
  waitNamespace: gpu-operator
  waitCondition: 'jsonpath={.status.numberReady}=1'
  watchAPIGroup: apps
  watchResources: daemonsets
  capacityMin: '0'
  contractName: ''
```

The GPU Operator creates `dcgm-exporter` and `nvidia-dcgm` at the same instant with nothing ordering them, and on a cold start the exporter dials the host engine before it is listening. Without this gate NVSentinel starts against a DCGM that is not serving and its first act is to report `GpuDcgmConnectivityFailure` in the Fleet Health dashboard.

### `demo-cert-manager-check`: verify instead of install

The "already installed" variant of the cert-manager task, selected when `certManagerPreinstalled` is true. It runs the same chart against the cert-manager already in the cluster.

```yaml
waitResource: deployment/cert-manager-webhook
waitNamespace: cert-manager
waitCondition: condition=Available
watchAPIGroup: apps
watchResources: deployments
capacityMin: 0
contractName: ''
```

This is the shape to reach for whenever a condition means "something else already handles this." A no-op variant would satisfy the dependency edge without proving anything; this one fails loudly if the claim was false.

## Other things it can gate on

**A cross-Stack contract.** A second Stack can wait on the ConfigMap this one published, which makes the handoff explicit instead of a race:

```yaml
waitResource: configmap/gpu-stack-contract
waitNamespace: gpu-stack
waitCondition: 'jsonpath={.data.ready}=true'
watchAPIGroup: ''
watchResources: configmaps
```

**A CRD that is not served yet.** Step 1 polls rather than failing, so a gate can be scheduled before the operator that defines the kind has finished installing. Give it a generous `existsTimeoutSeconds`.

**A different accelerator or extended resource.** Nothing about step 3 is NVIDIA-specific:

```yaml
capacityResource: amd.com/gpu
capacityNodeSelector: workload.example.com/pool=amd-compute
capacityMin: '2'
```

**Storage or networking readiness**, for example a StorageClass-backed test claim or an operator's status field:

```yaml
waitResource: 'ipaddresspool/default'
waitNamespace: metallb-system
waitCondition: 'jsonpath={.status.conditions[?(@.type=="Ready")].status}=True'
```

**A pure publish step.** `waitEnabled: 'false'` with `capacityMin: '0'` and a `contractName` set records the observed capacity and publishes a contract without blocking on anything. Useful when another task already guarantees readiness and you only want the handoff.

## Outputs and the contract

The contract is written last, so its existence means every check passed. A task can then declare Stack outputs from it, and later tasks consume them:

```yaml
outputs:
  - name: dcgmhost
    fromResource:
      apiVersion: v1
      kind: ConfigMap
      namespace: gpu-stack
      name: gpu-stack-contract
      jsonPath: '{.data.dcgmHost}'
```

```yaml
parameters:
  dcgmHost: '{{ .Outputs.gpuready.dcgmhost }}'
```

Two rules worth knowing: a task declaring outputs is not ready until every output is captured, reported as `CapturingOutputs`, so a missing key holds the task rather than failing it; and `fromResource` cannot read cluster-scoped resources or core Secrets, which is why the contract is a namespaced ConfigMap.

## Operational notes

**The image.** Upstream `kubectl` copied onto Alpine, running as UID 65532, published to `ghcr.io/loft-demos/stack-gate` by [`.github/workflows/publish-image.yaml`](../.github/workflows/publish-image.yaml). The upstream `kubectl` image is distroless with no shell, which is the only reason this image exists.

**Pin the source once there is a release.** `targetRevision` defaults to `main` and `imageTag` to `edge`, which means every consumer floats on a demo repository's default branch. That is fine while this is the only consumer. As soon as a second Stack depends on the gate, cut a release and set `targetRevision` to the tag and `imageTag` to the version, so a change here cannot break someone else's Stack.

**Job immutability.** The Job name carries a hash of the gate's configuration. A Job spec is immutable, so without it a changed parameter would make Argo CD try to patch an existing Job and fail the sync. With it, a changed parameter produces a new Job and prune removes the old one, which also re-runs the gate.

**No `ttlSecondsAfterFinished`.** A TTL-deleted Job would be recreated by Argo CD self-heal, re-running the gate and flipping the Application back to `Progressing`.

**Layered timeouts.** The Stack task timeout should exceed the Job's `activeDeadlineSeconds`, which should exceed `existsTimeoutSeconds` plus `waitTimeout` plus the capacity timeout. The task timeout firing first is the intended reporting path, since it surfaces in the Stack rather than only in the Job.

**It is one-shot.** A Lua health check would flip the Application to `Degraded` if the watched resource later went unready; the Job never re-evaluates. For install ordering that does not matter, and ongoing health is a monitoring concern. The long-term fix for the GPU case is to upstream a `resource_customizations/nvidia.com/ClusterPolicy/health.lua` to Argo CD, which would make it built in everywhere with no configuration and turn this Job into an option rather than a requirement.
