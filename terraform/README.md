# EKS Cluster with Karpenter - Multi-Architecture Autoscaling

This Terraform configuration deploys a production-ready Amazon EKS cluster with Karpenter autoscaling, supporting both x86 (AMD64) and ARM64 (Graviton) instances with Spot capability for optimal price/performance.

## Architecture Overview

The infrastructure includes:

- **VPC**: New dedicated VPC with 3 Availability Zones
  - Public subnets for load balancers and NAT gateways
  - Private subnets for EKS nodes
- **EKS Cluster**: Version 1.31 (latest) with managed control plane
  - Managed node group for system workloads (tainted)
  - Cluster addons: vpc-cni, coredns, kube-proxy, pod-identity-agent
- **Karpenter**: Advanced autoscaling with:
  - Support for both x86 (amd64) and arm64 (Graviton) architectures
  - Spot instance prioritization (70-90% cost savings)
  - Automatic node consolidation
  - Spot interruption handling via SQS and EventBridge

### Karpenter NodePools

The configuration includes two NodePools:

1. **Spot NodePool (Weight 80 - Preferred)**
   - Capacity Type: Spot instances only
   - Architectures: Both amd64 and arm64
   - Instance Families: c, m, r, t (generation > 5)
   - Cost Optimization: 70-90% cheaper than on-demand

2. **On-Demand NodePool (Weight 20 - Fallback)**
   - Capacity Type: On-Demand instances
   - Same architecture and instance family support
   - Used when spot capacity is unavailable

## Prerequisites

Before deploying this infrastructure, ensure you have:

1. **AWS Account** with appropriate permissions:
   - VPC, EKS, EC2, IAM, EventBridge, SQS

2. **Tools Installed**:
   - [Terraform](https://www.terraform.io/downloads) >= 1.9
   - [AWS CLI](https://aws.amazon.com/cli/) >= 2.0
   - [kubectl](https://kubernetes.io/docs/tasks/tools/) >= 1.31
   - [Helm](https://helm.sh/docs/intro/install/) >= 3.14 (optional)

3. **AWS Credentials Configured**:
   ```bash
   aws configure
   # Or set environment variables:
   # export AWS_ACCESS_KEY_ID="your-access-key"
   # export AWS_SECRET_ACCESS_KEY="your-secret-key"
   # export AWS_DEFAULT_REGION="eu-west-1"
   ```

4. **Verify AWS Access**:
   ```bash
   aws sts get-caller-identity
   ```

## Quick Start

### 1. Clone and Configure

```bash
# Navigate to the terraform directory
cd terraform/

# Create your variables file from the example
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars to customize (optional - defaults work fine)
vi terraform.tfvars
```

### 2. Initialize Terraform

```bash
# Initialize Terraform and download providers
terraform init
```

### 3. Review the Plan

```bash
# See what will be created
terraform plan
```

Expected resources: ~70 resources including VPC, subnets, NAT gateway, EKS cluster, node groups, IAM roles, SQS queue, EventBridge rules, and Karpenter installation.

### 4. Deploy the Infrastructure

```bash
# Apply the configuration
terraform apply

# Type 'yes' when prompted
```

**Note**: Deployment takes approximately 15-20 minutes. The EKS cluster creation is the slowest step (~10-12 minutes).

### 5. Configure kubectl

```bash
# Configure kubectl to access your cluster
aws eks update-kubeconfig --region eu-west-1 --name opsfleet-eks-cluster

# Verify cluster access
kubectl get nodes
```

You should see 2 system nodes (t3.medium) with taint `CriticalAddonsOnly=true:NoSchedule`.

### 6. Verify Karpenter Installation

```bash
# Check Karpenter pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# View Karpenter logs
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f

# Check NodePools
kubectl get nodepools

# Expected output:
# NAME        AGE
# on-demand   5m
# spot        5m

# Check EC2NodeClass
kubectl get ec2nodeclasses
```

## Running Workloads on Specific Architectures

Karpenter automatically provisions nodes based on pod requirements. You control the architecture using `nodeSelector` or node affinity.

### Example 1: Deploy on x86/AMD64 Instances

```bash
# Deploy nginx on x86 nodes
kubectl apply -f k8s-manifests/deployment-x86.yaml

# Watch Karpenter provision an x86 node
kubectl get nodes --watch

# Check node architecture
kubectl get nodes -L kubernetes.io/arch

# Verify pods are running on amd64 nodes
kubectl get pods -l app=nginx-x86 -o wide
```

The `deployment-x86.yaml` uses:
```yaml
nodeSelector:
  kubernetes.io/arch: amd64
```

This tells Karpenter to provision an x86 instance (e.g., t3a.medium, c6i.large, etc.).

### Example 2: Deploy on ARM64/Graviton Instances

```bash
# Deploy nginx on ARM64/Graviton nodes
kubectl apply -f k8s-manifests/deployment-arm64.yaml

# Watch Karpenter provision a Graviton node
kubectl get nodes --watch

# Verify pods are running on arm64 nodes
kubectl get pods -l app=nginx-arm64 -o wide

# Check the instance type (should be Graviton like t4g, c7g, etc.)
kubectl get nodes -L node.kubernetes.io/instance-type -L kubernetes.io/arch
```

The `deployment-arm64.yaml` uses:
```yaml
nodeSelector:
  kubernetes.io/arch: arm64
```

This tells Karpenter to provision a Graviton instance (e.g., t4g.medium, c7g.large, etc.).

### Example 3: Deploy on Spot Instances

```bash
# Deploy application preferring spot instances
kubectl apply -f k8s-manifests/deployment-spot.yaml

# Karpenter will prefer the spot NodePool (weight 80)
kubectl get pods -l app=app-spot -o wide
```

### Example 4: Mixed Architecture (Let Karpenter Decide)

```bash
# Deploy without architecture preference
kubectl apply -f k8s-manifests/deployment-mixed.yaml

# Karpenter chooses the best option based on:
# - Available spot capacity
# - Cost optimization
# - Existing node utilization
kubectl get pods -l app=app-mixed -o wide
```

## Understanding Karpenter Node Provisioning

### How Karpenter Selects Instances

1. **Pod Requirements**: Karpenter analyzes pending pods' resource requests, node selectors, and affinities
2. **NodePool Matching**: Finds NodePools that satisfy the requirements
3. **Weight-Based Selection**: Prefers higher-weight NodePools (spot: 80 > on-demand: 20)
4. **Cost Optimization**: Within a NodePool, selects the cheapest instance type that fits
5. **Provisioning**: Launches the instance and joins it to the cluster

### Viewing Karpenter Decisions

```bash
# Watch Karpenter controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50 -f

# Check node labels
kubectl get nodes --show-labels

# View instance types in use
kubectl get nodes -L node.kubernetes.io/instance-type -L karpenter.sh/capacity-type
```

### Key Node Labels

- `kubernetes.io/arch`: Architecture (amd64 or arm64)
- `karpenter.sh/capacity-type`: Capacity type (spot or on-demand)
- `node.kubernetes.io/instance-type`: EC2 instance type
- `topology.kubernetes.io/zone`: Availability zone
- `workload-type`: Custom label (spot or on-demand)

## Monitoring and Observability

### Check Cluster Status

```bash
# View all nodes
kubectl get nodes -o wide

# Check node capacity and allocatable resources
kubectl describe nodes

# View pods across all namespaces
kubectl get pods -A -o wide

# Check resource usage
kubectl top nodes
kubectl top pods -A
```

### Karpenter Metrics

```bash
# View Karpenter events
kubectl get events -n kube-system --sort-by='.lastTimestamp' | grep karpenter

# Check disruption events (consolidation)
kubectl get events -A --field-selector reason=Disruption
```

### AWS Console

- **EKS Console**: View cluster status, add-ons, and node groups
- **EC2 Console**: See provisioned instances (filter by tag `karpenter.sh/nodeclaim`)
- **CloudWatch**: View cluster logs (if enabled)
- **Cost Explorer**: Monitor spending by tag

## Cost Optimization Tips

1. **Spot Instances**: The spot NodePool (weight 80) provides 70-90% savings
2. **Graviton Instances**: ARM64 instances are ~20% cheaper than equivalent x86
3. **Consolidation**: Karpenter automatically removes underutilized nodes after 30 seconds
4. **Right-Sizing**: Set appropriate resource requests/limits on pods
5. **NAT Gateway**: Using single NAT gateway saves $64/month (can upgrade to HA if needed)

### Expected Monthly Costs (eu-west-1)

- EKS Control Plane: $72
- Managed Node Group (2x t3.medium on-demand): ~$60
- NAT Gateway (single): $32
- Karpenter Nodes (varies with workload):
  - Spot: $0.02-0.15/hour per instance
  - On-Demand: $0.05-0.50/hour per instance

**Estimated Total**: $200-400/month for base infrastructure + workloads

## Scaling Examples

### Horizontal Scaling

```bash
# Scale the x86 deployment
kubectl scale deployment nginx-x86 --replicas=10

# Watch Karpenter provision additional nodes
kubectl get nodes --watch

# Scale down
kubectl scale deployment nginx-x86 --replicas=1

# Watch Karpenter consolidate (remove underutilized nodes)
```

### Testing Node Consolidation

```bash
# Deploy a workload
kubectl apply -f k8s-manifests/deployment-mixed.yaml
kubectl scale deployment app-mixed --replicas=20

# Wait for nodes to be provisioned
kubectl get nodes

# Scale down
kubectl scale deployment app-mixed --replicas=2

# Watch Karpenter consolidate nodes (usually within 30-60 seconds)
kubectl get nodes --watch
```

## Troubleshooting

### Pods Stuck in Pending

```bash
# Check why pods are pending
kubectl describe pod <pod-name>

# Common issues:
# - Insufficient capacity: Karpenter is provisioning (wait 1-2 minutes)
# - Unsatisfiable requirements: Check nodeSelector/affinity
# - Image pull issues: Verify image exists for architecture

# Check Karpenter logs
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100
```

### Nodes Not Provisioning

```bash
# Verify Karpenter is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# Check NodePools
kubectl get nodepools
kubectl describe nodepool spot

# Check EC2NodeClass
kubectl get ec2nodeclasses
kubectl describe ec2nodeclass default

# View Karpenter events
kubectl get events -n kube-system --sort-by='.lastTimestamp'

# Check IAM permissions
aws iam get-role --role-name opsfleet-eks-cluster-karpenter-node
```

### Architecture Mismatch

```bash
# If pod fails with "exec format error"
# The image doesn't support the target architecture

# Solution: Use multi-arch images or specify correct nodeSelector

# Check image architectures
docker manifest inspect nginx:latest | grep architecture
```

### Spot Interruptions

Karpenter handles spot interruptions automatically via SQS queue:

```bash
# Check SQS queue for interruption notices
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw karpenter_queue_name) \
  --attribute-names ApproximateNumberOfMessages

# View EventBridge rules
aws events list-rules --name-prefix opsfleet-eks-cluster
```

## Cleanup

To destroy all resources and avoid ongoing costs:

```bash
# Delete all Kubernetes resources first
kubectl delete -f k8s-manifests/

# Wait for Karpenter to deprovision nodes
kubectl get nodes --watch

# Destroy Terraform infrastructure
terraform destroy

# Type 'yes' when prompted
```

**Important**: Always delete Kubernetes resources before running `terraform destroy` to avoid orphaned EC2 instances.

## Architecture Reference

### Node Selector Examples

| Requirement | nodeSelector | Result |
|------------|--------------|--------|
| x86 instances | `kubernetes.io/arch: amd64` | Provisions x86 instance (t3, c6i, etc.) |
| Graviton instances | `kubernetes.io/arch: arm64` | Provisions ARM instance (t4g, c7g, etc.) |
| Spot instances | `workload-type: spot` | Uses spot NodePool |
| On-Demand instances | `workload-type: on-demand` | Uses on-demand NodePool |

### Available Instance Types

Karpenter can provision from these families (generation > 5):

**x86/AMD64**:
- General: t3, t3a, m5, m6i, m7i
- Compute: c5, c6i, c7i
- Memory: r5, r6i, r7i

**ARM64/Graviton**:
- General: t4g, m6g, m7g
- Compute: c6g, c7g
- Memory: r6g, r7g

All with `spot` or `on-demand` capacity types.

## Additional Resources

- [EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [Karpenter Documentation](https://karpenter.sh/)
- [Graviton Performance](https://aws.amazon.com/ec2/graviton/)
- [Terraform AWS EKS Module](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest)

## Support

For issues or questions:
1. Check Karpenter logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter`
2. Review [Karpenter Troubleshooting Guide](https://karpenter.sh/docs/troubleshooting/)
3. Check AWS Service Health Dashboard
4. Review Terraform state: `terraform show`

## License

This configuration is provided as-is for demonstration purposes.
