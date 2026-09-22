# NVIDIA GPU Operator Stack Demo

vCluster Platform hands you a complete NVIDIA GPU cluster, not an empty one. A single Stack delivers cert-manager, the NVIDIA GPU Operator, and NVSentinel with the tenant cluster itself, through Argo CD, in dependency order, onto GPU nodes that are already labeled, tainted, and ready for CUDA workloads.

**Stacks** are a recent addition to vCluster Platform, and they are the point of this demo. One `StackTemplate` declares a dependency-aware task graph, each task becomes an Argo CD Application, and a task starts only once every task in its `dependsOn` list reports healthy. Attach that template to a tenant cluster template under `deploy.stacks` and the cluster arrives with its software already converging. No second pipeline, no post-provisioning runbook, no ticket to go install the GPU Operator after the nodes join.

The `demo-gpu` Stack runs cert-manager and the NVIDIA GPU Operator in parallel, then NVSentinel once both are healthy, with per-task timeouts of 10, 45, and 20 minutes. Five parameters flow from the tenant cluster template through the Stack and into each application's Helm values, so one form in the Platform UI configures GPU driver mode, chart versions, the Argo CD project, and node placement across all three applications.

Two NodeProfiles split the workers: `cpu-services` labels its nodes `workload.example.com/pool=cpu-services` and stays untainted, so it carries cert-manager and the service controllers, while `gpu-compute` labels its nodes `workload.example.com/pool=gpu-compute` and carries a permanent `nvidia.com/gpu=true:NoSchedule` taint that reserves GPU workers for NVIDIA node agents and GPU workloads with a matching toleration. Both pools are provisioned from `privateNodes.autoNodes`, each picked by a `nodeTypeSelector` on `vcluster.com/profile` (`xlarge-gpu` for GPU, `small` for CPU), and every placement decision in the stack keys off the pool label plus that taint.

This repository contains the Platform templates and profiles. It uses existing Platform, Argo CD, and node-provider infrastructure; it does not install those prerequisites.

## Repository contents

| File | Purpose |
| --- | --- |
| [node-profiles.yaml](node-profiles.yaml) | `cpu-services` NodeProfile (pool label only) and `gpu-compute` NodeProfile (pool label plus the `nvidia.com/gpu=true:NoSchedule` taint) |
| [cert-manager-application-template.yaml](cert-manager-application-template.yaml) | `demo-cert-manager`, with CPU placement for all cert-manager components |
| [gpu-operator-application-template.yaml](gpu-operator-application-template.yaml) | `demo-gpu-operator`, with CPU controllers and GPU node agents |
| [nvsentinel-application-template.yaml](nvsentinel-application-template.yaml) | `demo-nvsentinel`, configured for dry-run monitoring |
| [stack-template.yaml](stack-template.yaml) | `demo-gpu`, the Stack: a three-task graph that installs cert-manager and GPU Operator in parallel, then NVSentinel once both are healthy |
| [virtual-cluster-template.yaml](virtual-cluster-template.yaml) | `demo-static-gpu`, which provisions the GPU and CPU worker pools and attaches the Stack through `deploy.stacks` |

All commands below run from the root of your clone of this repository. No parent repository or sibling directory is needed.

## How the Stack works

A Stack deploys several applications as one dependency-aware unit and defines the order in which they become ready. Two resources carry it:

- **`StackTemplate`** is the reusable, parameterized task graph an administrator publishes once. [stack-template.yaml](stack-template.yaml) is this demo's.
- **`StackInstance`** is that graph applied to one tenant cluster. Platform creates it when the tenant cluster is provisioned, drives each task, and aggregates the task phases into one status.

Tasks form a directed acyclic graph. Tasks with no dependencies run concurrently; a task with `dependsOn` waits until every task it names is healthy, not merely created. That is the difference between a Stack and a list of Helm installs:

| Task | `dependsOn` | Timeout | Deploys |
| --- | --- | --- | --- |
| `cert-manager` | none | 10m | `demo-cert-manager` application template |
| `gpu-operator` | none | 45m | `demo-gpu-operator` application template |
| `nvsentinel` | `cert-manager`, `gpu-operator` | 20m | `demo-nvsentinel` application template |

The ordering is load-bearing here. NVSentinel scrapes DCGM at `nvidia-dcgm.gpu-operator.svc:5555`, an endpoint that does not exist until GPU Operator is healthy, and on a fresh node image GPU Operator has a driver to build and validate first. `dependsOn` and the generous 45-minute timeout encode that wait once, in the template, instead of in a runbook or a retry loop.

Parameters flow down the same path. `cpuNodePool`, `argoProject`, `driverPreinstalled`, `gpuOperatorVersion`, and `nvsentinelVersion` are declared on the tenant cluster template, passed to the Stack under `deploy.stacks[].parameters`, and forwarded by each task into its application template. Change `driverPreinstalled` at cluster creation and both GPU Operator and NVSentinel switch driver modes together.

Each task here is an `argoCDApplication`, so Argo CD owns reconciliation and drift correction once the Stack has ordered the rollout. Tasks can also be `app`, creating an `AppInstance`, and a single Stack may mix both.

## Prerequisites

- vCluster Platform 4.13 with the features and permissions needed for Private Nodes, NodeProfiles, Stacks, and Argo CD integration. Stacks need no separate license feature; the Argo CD task type uses the Argo CD integration you already have.
- vCluster 0.37 or later for the `deploy.stacks` install path. The template pins `0.37.1`. Older versions hide the Stacks section during tenant cluster creation.
- An existing Argo CD connector and an Argo CD project that permits the chart sources and destination namespaces.
- An existing node provider with an available NVIDIA GPU machine, plus at least one CPU worker for the tenant cluster.
- Platform Private Nodes VPN configured and reachable by workers. The control plane cluster also needs storage for the tenant control-plane PVC. The template enables Flannel for the tenant CNI.
- Compatible GPU hardware, node OS/kernel, and NVIDIA drivers, plus access to the chart repositories and container registries referenced in the manifests.
- `kubectl`, a Platform management kubeconfig, and a tenant cluster kubeconfig once the tenant cluster is created. `jq` is used in the demo checks.

Default versions are vCluster `0.37.1`, cert-manager `v1.20.3`, GPU Operator `v26.3.3`, and NVSentinel `v1.13.0`. Platform and vCluster chart versions are separate. These application templates carry their own Helm values and do not inherit future changes to Platform's built-in templates.

## Configure your environment

Before applying the manifests, edit [virtual-cluster-template.yaml](virtual-cluster-template.yaml). The checked-in template provisions **both** pools from `privateNodes.autoNodes`: one GPU worker from a Metal3 provider and one CPU worker from a KubeVirt provider. Each pool pairs a `nodeTypeSelector`, which chooses the machine the provider hands out, with a `profile`, which applies that NodeProfile's labels and taints as the node joins:

| Pool | Provider | `nodeTypeSelector` | `profile` | Node label | Taint |
| --- | --- | --- | --- | --- | --- |
| GPU | `metal3-us-va-blacksburg-dc1` | `vcluster.com/profile In [xlarge-gpu]` | `gpu-compute` | `workload.example.com/pool=gpu-compute` | `nvidia.com/gpu=true:NoSchedule` |
| CPU | `kubevirt-us-va-blacksburg-dc1` | `vcluster.com/profile In [small]` | `cpu-services` | `workload.example.com/pool=cpu-services` | none |

The `vcluster.com/profile` property inside `nodeTypeSelector` names a node type published by the node provider. Despite the name, it is unrelated to the NodeProfile named in `profile`.

Provider names and node type values are lab-specific, so substitute your own:

- Replace the GPU provider `metal3-us-va-blacksburg-dc1` and change its `nodeTypeSelector` to match your GPU node type.
- Replace the CPU provider `kubevirt-us-va-blacksburg-dc1` and change its `nodeTypeSelector` to match a CPU node type that provider offers. Drop the selector entirely if the provider serves only one type.
- Keep `profile: gpu-compute` on the GPU pool and `profile: cpu-services` on the CPU pool. These match the NodeProfiles in [node-profiles.yaml](node-profiles.yaml) and drive every placement decision in the stack.
- Adjust `quantity` on either pool if needed. Both default to one worker and inherit the provider's OS image, SSH keys, and networking.

**Both pools are required.** Without a CPU worker labeled `workload.example.com/pool=cpu-services`, cert-manager and the GPU Operator controller stay Pending. A pool entry has this shape:

```yaml
- provider: <cpu-vm-node-provider>
  static:
    - name: cpu-services
      quantity: 1
      profile: cpu-services
      nodeTypeSelector:
        - property: vcluster.com/profile
          operator: In
          values:
            - <cpu-node-type-value>
```

The templates are owned by the `loft-admins` team. Update `spec.owner` if your installation uses another team. Ensure the Platform project allows the tenant cluster template, node providers, and both NodeProfiles, and that your identity can use the stack and application templates.

## Node placement

Two NodeProfiles in [node-profiles.yaml](node-profiles.yaml) define everything the tenant cluster scheduler sees:

| NodeProfile | Display name | Node label | Taints |
| --- | --- | --- | --- |
| `cpu-services` | Demo - CPU Services | `workload.example.com/pool=cpu-services` | none, so any pod may land here |
| `gpu-compute` | Demo - GPU Compute | `workload.example.com/pool=gpu-compute` | `nvidia.com/gpu=true:NoSchedule`, permanent |

Pods reach a pool through a `nodeSelector` on `workload.example.com/pool`. Anything selecting `gpu-compute` also needs a toleration for the GPU taint. The stack templates use the `key: nvidia.com/gpu, operator: Exists, effect: NoSchedule` form; the demo Job in step 5 spells out the equivalent `operator: Equal, value: "true"` form. The CPU selector below is the `cpuNodePool` parameter value, `cpu-services` by default; the GPU selector is hard-coded to `gpu-compute`.

| Components | Placement |
| --- | --- |
| cert-manager controller, webhook, cainjector, startup API check | CPU selector via `global.nodeSelector` |
| GPU Operator controller, NFD master and garbage collector | CPU selector |
| NFD workers | GPU selector and GPU taint toleration |
| NVIDIA driver, toolkit, device plugin, validators and monitoring agents | Operator-managed GPU discovery selectors; GPU taint toleration |
| NVSentinel labeler | CPU selector |
| NVSentinel health monitors and metadata collector | GPU selector plus NVIDIA capability labels; GPU taint toleration |
| NVSentinel `platformConnector` | Required GPU node affinity and GPU taint toleration; shares a node-local socket with health monitors |

The GPU Operator CRD upgrade hook has no node-selector setting in the pinned chart. It has no GPU toleration, so the GPU taint keeps it off GPU workers. NVSentinel's optional `nodeConditionCleanup` Job is disabled by default; its CPU selector applies only if the Job is enabled.

These profiles omit `startupTaints`: those disappear at Kubernetes Node Ready, which does not prove that NVIDIA initialization has completed. This repository does not include a custom GPU-readiness controller or a `gpu-ready` label gate. GPU resource requests provide normal scheduler gating until GPUs are advertised; they do not guarantee that every optional NVIDIA component is ready.

## Install

Use a Platform management context with access to `management.loft.sh` resources. Replace the example context name:

```sh
export PLATFORM_CONTEXT=your-platform-admin-context
kubectl --context "$PLATFORM_CONTEXT" apply -f node-profiles.yaml
kubectl --context "$PLATFORM_CONTEXT" apply -f cert-manager-application-template.yaml
kubectl --context "$PLATFORM_CONTEXT" apply -f gpu-operator-application-template.yaml
kubectl --context "$PLATFORM_CONTEXT" apply -f nvsentinel-application-template.yaml
kubectl --context "$PLATFORM_CONTEXT" apply -f stack-template.yaml
kubectl --context "$PLATFORM_CONTEXT" apply -f virtual-cluster-template.yaml
```

Create a tenant cluster from **Demo - Static GPU Nodes** in the Platform UI. Set these parameters:

| Parameter | Value |
| --- | --- |
| `argoConnector` | Required: your existing Argo CD connector name |
| `argoProject` | Your Argo CD project; defaults to `default` |
| `cpuNodePool` | CPU pool label value passed through the stack to all three application templates; defaults to `cpu-services` |
| `driverPreinstalled` | `false` to let GPU Operator install the driver; `true` if the node image already has it |
| `gpuOperatorVersion` | Defaults to `v26.3.3` |
| `nvsentinelVersion` | Defaults to `v1.13.0` for both chart and images |

`cpuNodePool` selects the value of `workload.example.com/pool`; it does not create or rename a NodeProfile. If you change it, update your CPU NodeProfile's label value to match. GPU pool placement remains `gpu-compute`.

`driverPreinstalled=true` disables operator driver installation and enables NVSentinel's preinstalled-driver labeling mode. GPU Operator still installs the container toolkit.

Download or connect to the tenant cluster kubeconfig, then select its context for the following demo commands:

```sh
export TENANT_CONTEXT=your-tenant-context
kubectl --context "$TENANT_CONTEXT" get nodes
```

## Demo flow

### 1. Show the Stack, then the node profiles

Open the `demo-gpu` StackTemplate in Platform and walk the three tasks. cert-manager and GPU Operator have no dependencies and start together; NVSentinel lists both in `dependsOn` and does not start until both report healthy. Each task references an application template instead of carrying its own copy of the Helm values, and the five Stack parameters are the only knobs anyone turns. This is the whole point: the cluster and its GPU software stack are one declarative unit with one lifecycle.

Then open `cpu-services` and `gpu-compute`. Show that both set `workload.example.com/pool` to identify the pool, that `cpu-services` adds no taints, and that the `nvidia.com/gpu=true:NoSchedule` taint on `gpu-compute` reserves GPU nodes for pods with a matching toleration.

### 2. Create the tenant cluster and watch the workers join

Create the tenant cluster using the installation steps above. In the tenant cluster context, watch both workers register their pool labels:

```sh
kubectl --context "$TENANT_CONTEXT" get nodes \
  -L workload.example.com/pool --watch
```

Stop the watch with Ctrl+C when ready to continue. Inspect the GPU taint:

```sh
kubectl --context "$TENANT_CONTEXT" get nodes \
  -l workload.example.com/pool=gpu-compute \
  -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'
```

Explain that Node Ready and GPU readiness are separate milestones. The CPU worker can run service controllers while NVIDIA initializes the GPU worker.

### 3. Watch the Stack converge

The Stack runs on its own as soon as the tenant cluster is reachable. Find its `StackInstance` in the project namespace, on the Platform management context:

```sh
kubectl --context "$PLATFORM_CONTEXT" get stackinstances -A
```

Then follow the aggregate phase and the individual tasks:

```sh
export STACK_NS=your-project-namespace
export STACK_NAME=your-stackinstance-name
kubectl --context "$PLATFORM_CONTEXT" get stackinstance "$STACK_NAME" -n "$STACK_NS" \
  -o jsonpath='{.status.phase}{"\n"}{range .status.tasks[*]}{.name}{"\t"}{.phase}{"\t"}{.message}{"\n"}{end}'
```

The aggregate phase moves through `Pending`, `Progressing`, and `Healthy`, and reports `Degraded` when a task fails or exceeds its timeout. Point out the shape of the run: `cert-manager` and `gpu-operator` progress at the same time, `nvsentinel` sits idle until both are healthy, and no one has touched the cluster since creating it. The Platform UI shows the same graph and the same phases.

### 4. Show service placement and NVIDIA initialization

```sh
kubectl --context "$TENANT_CONTEXT" get pods -n cert-manager -o wide
kubectl --context "$TENANT_CONTEXT" get pods -n gpu-operator -o wide
kubectl --context "$TENANT_CONTEXT" get pods -n gpu-operator \
  -l app=nvidia-operator-validator -o wide
```

Point out the CPU placement of cert-manager and the GPU Operator controller, then the GPU placement of NVIDIA's node agents. On a fresh image, driver installation and validation may take several minutes. With a preinstalled driver, the driver DaemonSet is intentionally absent.

Check the operator and the GPUs advertised to the scheduler:

```sh
kubectl --context "$TENANT_CONTEXT" get clusterpolicy
kubectl --context "$TENANT_CONTEXT" get nodes -o json \
  | jq '.items[] | {name: .metadata.name, pool: .metadata.labels["workload.example.com/pool"], gpus: (.status.allocatable["nvidia.com/gpu"] // "0")}'
```

### 5. Run a CUDA workload on the GPU pool

This uses NVIDIA's [CUDA VectorAdd sample](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/26.3/getting-started.html#cuda-vectoradd), with the pool selector and taint toleration added. The sample expects a full GPU exposed as `nvidia.com/gpu`.

```sh
kubectl --context "$TENANT_CONTEXT" apply -f - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: cuda-vectoradd
  namespace: default
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        workload.example.com/pool: gpu-compute
      tolerations:
        - key: nvidia.com/gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: cuda-vectoradd
          image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubuntu22.04
          resources:
            limits:
              nvidia.com/gpu: 1
YAML

kubectl --context "$TENANT_CONTEXT" -n default wait \
  --for=condition=complete job/cuda-vectoradd --timeout=10m
kubectl --context "$TENANT_CONTEXT" -n default logs job/cuda-vectoradd
kubectl --context "$TENANT_CONTEXT" -n default get pods \
  -l job-name=cuda-vectoradd -o wide
```

Expected result: the Job completes on the GPU worker and its logs include `Test PASSED`. The selector chooses the pool, the toleration permits placement on the tainted node, and the resource limit requests one GPU.

For an initialization demo, submit this Job during step 4, before the device plugin advertises GPUs. It can remain Pending with an `Insufficient nvidia.com/gpu` event until capacity appears. Use `kubectl --context "$TENANT_CONTEXT" -n default describe pods -l job-name=cuda-vectoradd` to show the actual scheduling reason. This waiting phase may be brief and is not a gate on completion of every NVIDIA component.

### 6. Show NVSentinel monitoring

Once the preceding stack tasks are ready:

```sh
kubectl --context "$TENANT_CONTEXT" get pods -n nvsentinel -o wide
kubectl --context "$TENANT_CONTEXT" get daemonsets -n nvsentinel
kubectl --context "$TENANT_CONTEXT" get nodes -o json \
  | jq '.items[] | {name: .metadata.name, conditions: .status.conditions}'
```

Show the labeler on the CPU pool and the node-local monitors on GPU workers. Some capability-specific DaemonSets can have zero desired pods when no nodes match their NVIDIA labels.

NVSentinel is configured for dry-run monitoring. Quarantine, draining, remediation, Janitor, and MongoDB are disabled, so this demo does not demonstrate automatic fault recovery. GPU Operator provides DCGM at `nvidia-dcgm.gpu-operator.svc:5555`; Prometheus PodMonitor/ServiceMonitor creation is disabled.

### 7. Clean up the sample

```sh
kubectl --context "$TENANT_CONTEXT" -n default delete job cuda-vectoradd
```

Delete the sample Job before repeating step 5. Keep the tenant cluster for further demonstrations, or delete it through Platform when finished; node deprovisioning follows your provider's configuration.

## Troubleshooting

- **cert-manager or operator controller Pending:** confirm a CPU worker has the `cpu-services` pool label. These pods intentionally cannot use the GPU pool.
- **GPU agents missing:** confirm NVIDIA hardware discovery labels and matching tolerations. Inspect the GPU Operator pod events and logs.
- **CUDA Job Pending:** inspect its pod events. Check GPU capacity, the pool label, and whether another workload already occupies the GPU.
- **Stack waiting or failing:** read the `StackInstance` task phases with the jsonpath command in step 3. A task stuck in `Pending` is waiting on its `dependsOn` list; a `Degraded` task names its reason in `message`. Then check the tenant cluster's `StacksSynced` condition and the corresponding Argo CD applications. Task timeouts are 10 minutes for cert-manager, 45 minutes for GPU Operator, and 20 minutes for NVSentinel.
- **Chart or image download failures:** check registry access and credentials from Argo CD and the worker nodes. Local rendering does not prove that the deployed cluster can pull artifacts.
- **A template parameter change did not reach an existing tenant cluster:** a `VirtualClusterInstance` keeps the parameter values rendered at creation time. Editing a template's parameters reaches new tenant clusters only; existing ones render the new reference as an empty string with no error anywhere. Use **Sync Template** on the instance in the Platform UI, or set `spec.templateRef.syncOnce: true`.

## Validation scope

The templates have been locally rendered for both driver modes, including checks of CPU/GPU placement and template references. NVSentinel validation used the `v1.13.0` GitHub source chart because the OCI download returned HTTP 403. GPU Operator creates its operand DaemonSets at runtime, so Helm rendering alone does not validate their live behavior. The manifests and demo workload still need an end-to-end run in your environment.

Additional reference: [vCluster Private Nodes configuration](https://www.vcluster.com/docs/vcluster/configure/vcluster-yaml/private-nodes/).
