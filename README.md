# NVIDIA GPU Operator Stack Demo

Deploy a GPU-enabled tenant cluster with vCluster Platform, Argo CD, NVIDIA GPU Operator, cert-manager, and NVSentinel. CPU workers run service controllers; GPU workers run NVIDIA node agents and GPU workloads. NodeProfiles provide consistent labels and GPU scheduling taints.

This repository contains the Platform templates and profiles. It uses existing Platform, Argo CD, and node-provider infrastructure; it does not install those prerequisites.

## Repository contents

| File | Purpose |
| --- | --- |
| [node-profiles.yaml](node-profiles.yaml) | `cpu-services` and `gpu-compute` NodeProfiles |
| [cert-manager-application-template.yaml](cert-manager-application-template.yaml) | `demo-cert-manager`, with CPU placement for all cert-manager components |
| [gpu-operator-application-template.yaml](gpu-operator-application-template.yaml) | `demo-gpu-operator`, with CPU controllers and GPU node agents |
| [nvsentinel-application-template.yaml](nvsentinel-application-template.yaml) | `demo-nvsentinel`, configured for dry-run monitoring |
| [stack-template.yaml](stack-template.yaml) | `demo-gpu`, which installs cert-manager and GPU Operator in parallel, then NVSentinel |
| [virtual-cluster-template.yaml](virtual-cluster-template.yaml) | `demo-static-gpu`, which provisions the GPU and CPU worker pools and attaches the stack |

All commands below run from the root of your clone of this repository. No parent repository or sibling directory is needed.

## Prerequisites

- vCluster Platform 4.13 with the features and permissions needed for Private Nodes, NodeProfiles, Stacks, and Argo CD integration.
- An existing Argo CD connector and an Argo CD project that permits the chart sources and destination namespaces.
- An existing node provider with an available NVIDIA GPU machine, plus at least one CPU worker for the tenant cluster.
- Platform Private Nodes VPN configured and reachable by workers. The control plane cluster also needs storage for the tenant control-plane PVC. The template enables Flannel for the tenant CNI.
- Compatible GPU hardware, node OS/kernel, and NVIDIA drivers, plus access to the chart repositories and container registries referenced in the manifests.
- `kubectl`, a Platform management kubeconfig, and a tenant cluster kubeconfig once the tenant cluster is created. `jq` is used in the demo checks.

Default versions are vCluster `0.37.1`, cert-manager `v1.20.3`, GPU Operator `v26.3.3`, and NVSentinel `v1.13.0`. Platform and vCluster chart versions are separate. These application templates carry their own Helm values and do not inherit future changes to Platform's built-in templates.

## Configure your environment

Before applying the manifests, edit [virtual-cluster-template.yaml](virtual-cluster-template.yaml). The checked-in template provisions **both** pools from `privateNodes.autoNodes`: one GPU worker from a Metal3 provider and one CPU worker from a KubeVirt provider. Both provider names are lab-specific, so substitute your own:

- Replace the GPU provider `metal3-us-va-blacksburg-dc1` with your provider name.
- Update the GPU `nodeTypeSelector` to match your GPU node type. The checked-in selector is `vcluster.com/profile In [xlarge-gpu]`.
- Replace the CPU provider `kubevirt-us-va-blacksburg-dc1` with your provider name. The CPU pool carries no `nodeTypeSelector`, so it accepts whatever node type that provider offers. Add one if your provider serves more than one type.
- Keep `profile: gpu-compute` on the GPU pool and `profile: cpu-services` on the CPU pool. These match the NodeProfiles in [node-profiles.yaml](node-profiles.yaml) and drive every placement decision in the stack.
- Adjust `quantity` on either pool if needed. Both default to one worker and inherit the provider's OS image, SSH keys, and networking.

**Both pools are required.** Without a CPU worker labeled `workload.example.com/pool=cpu-services`, cert-manager and the GPU Operator controller stay Pending. If your CPU capacity comes from a provider that needs an explicit node type, the pool entry looks like this:

```yaml
- provider: <cpu-vm-node-provider>
  static:
    - name: cpu-services
      quantity: 1
      profile: cpu-services
      nodeTypeSelector:
        - property: <cpu-node-type-property>
          operator: In
          values:
            - <cpu-node-type-value>
```

The templates are owned by the `loft-admins` team. Update `spec.owner` if your installation uses another team. Ensure the Platform project allows the tenant cluster template, node providers, and both NodeProfiles, and that your identity can use the stack and application templates.

## Node placement

The `cpu-services` profile sets `workload.example.com/pool=cpu-services` and has no taints. The `gpu-compute` profile sets `workload.example.com/pool=gpu-compute` and the permanent `nvidia.com/gpu=true:NoSchedule` taint.

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

### 1. Show the profiles and stack dependencies

In Platform, open `cpu-services` and `gpu-compute`. Explain how the label identifies each pool and how the GPU taint reserves GPU nodes for pods with matching tolerations.

Open the `demo-gpu` stack: cert-manager and GPU Operator start independently; NVSentinel waits for both tasks to become ready. Show the separate application templates and their scheduling values.

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

### 3. Show service placement and NVIDIA initialization

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

### 4. Run a CUDA workload on the GPU pool

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

For an initialization demo, submit this Job during step 3, before the device plugin advertises GPUs. It can remain Pending with an `Insufficient nvidia.com/gpu` event until capacity appears. Use `kubectl --context "$TENANT_CONTEXT" -n default describe pods -l job-name=cuda-vectoradd` to show the actual scheduling reason. This waiting phase may be brief and is not a gate on completion of every NVIDIA component.

### 5. Show NVSentinel monitoring

Once the preceding stack tasks are ready:

```sh
kubectl --context "$TENANT_CONTEXT" get pods -n nvsentinel -o wide
kubectl --context "$TENANT_CONTEXT" get daemonsets -n nvsentinel
kubectl --context "$TENANT_CONTEXT" get nodes -o json \
  | jq '.items[] | {name: .metadata.name, conditions: .status.conditions}'
```

Show the labeler on the CPU pool and the node-local monitors on GPU workers. Some capability-specific DaemonSets can have zero desired pods when no nodes match their NVIDIA labels.

NVSentinel is configured for dry-run monitoring. Quarantine, draining, remediation, Janitor, and MongoDB are disabled, so this demo does not demonstrate automatic fault recovery. GPU Operator provides DCGM at `nvidia-dcgm.gpu-operator.svc:5555`; Prometheus PodMonitor/ServiceMonitor creation is disabled.

### 6. Clean up the sample

```sh
kubectl --context "$TENANT_CONTEXT" -n default delete job cuda-vectoradd
```

Delete the sample Job before repeating step 4. Keep the tenant cluster for further demonstrations, or delete it through Platform when finished; node deprovisioning follows your provider's configuration.

## Troubleshooting

- **cert-manager or operator controller Pending:** confirm a CPU worker has the `cpu-services` pool label. These pods intentionally cannot use the GPU pool.
- **GPU agents missing:** confirm NVIDIA hardware discovery labels and matching tolerations. Inspect the GPU Operator pod events and logs.
- **CUDA Job Pending:** inspect its pod events. Check GPU capacity, the pool label, and whether another workload already occupies the GPU.
- **Stack waiting or failing:** inspect StackInstance task status, the tenant cluster's `StacksSynced` condition, and the corresponding Argo CD applications. Task timeouts are 10 minutes for cert-manager, 45 minutes for GPU Operator, and 20 minutes for NVSentinel.
- **Chart or image download failures:** check registry access and credentials from Argo CD and the worker nodes. Local rendering does not prove that the deployed cluster can pull artifacts.
- **A template parameter change did not reach an existing tenant cluster:** a `VirtualClusterInstance` keeps the parameter values rendered at creation time. Editing a template's parameters reaches new tenant clusters only; existing ones render the new reference as an empty string with no error anywhere. Use **Sync Template** on the instance in the Platform UI, or set `spec.templateRef.syncOnce: true`.

## Validation scope

The templates have been locally rendered for both driver modes, including checks of CPU/GPU placement and template references. NVSentinel validation used the `v1.13.0` GitHub source chart because the OCI download returned HTTP 403. GPU Operator creates its operand DaemonSets at runtime, so Helm rendering alone does not validate their live behavior. The manifests and demo workload still need an end-to-end run in your environment.

Additional reference: [vCluster Private Nodes configuration](https://www.vcluster.com/docs/vcluster/configure/vcluster-yaml/private-nodes/).
