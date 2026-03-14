# Karpenter module - creates IAM roles, SQS queue, and EventBridge rules
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # Enable spot interruption handling and Pod Identity
  create_pod_identity_association = true

  # Create IAM role for Karpenter nodes
  create_node_iam_role          = true
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"

  # Attach additional policies to node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}

# Install Karpenter using Helm
resource "helm_release" "karpenter" {
  namespace        = var.karpenter_namespace
  create_namespace = false
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_chart_version
  wait             = true

  values = [
    <<-EOT
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}

    serviceAccount:
      name: karpenter
      annotations:
        eks.amazonaws.com/role-arn: ${module.karpenter.iam_role_arn}

    controller:
      resources:
        requests:
          cpu: 1
          memory: 1Gi
        limits:
          cpu: 1
          memory: 1Gi

    # Tolerations to run on system nodes
    tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
        effect: NoSchedule

    # Replicas for high availability (optional for POC)
    replicas: 2

    podDisruptionBudget:
      maxUnavailable: 1
    EOT
  ]

  depends_on = [
    module.eks,
    module.karpenter
  ]
}
