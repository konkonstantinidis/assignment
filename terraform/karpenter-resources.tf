# EC2NodeClass - defines the EC2 configuration for Karpenter-provisioned nodes
resource "kubectl_manifest" "karpenter_ec2_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2023
      role: ${module.karpenter.node_iam_role_name}

      # Subnet selection - Karpenter will use subnets tagged with karpenter.sh/discovery
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}

      # Security group selection
      securityGroupSelectorTerms:
        - tags:
            kubernetes.io/cluster/${var.cluster_name}: owned

      # Block device configuration
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 100Gi
            volumeType: gp3
            encrypted: true
            deleteOnTermination: true

      # Metadata options for security
      metadataOptions:
        httpEndpoint: enabled
        httpProtocolIPv6: disabled
        httpPutResponseHopLimit: 1
        httpTokens: required

      # User data for node bootstrap
      userData: |
        #!/bin/bash
        echo "Karpenter node bootstrapped at $(date)"
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

# NodePool for Spot instances (priority 80 - preferred)
resource "kubectl_manifest" "karpenter_node_pool_spot" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: spot
    spec:
      # Template for nodes
      template:
        metadata:
          labels:
            workload-type: spot
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default

          # Requirements for instance selection
          requirements:
            # Support both x86 and arm64 architectures
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64", "arm64"]

            # Spot instances only
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot"]

            # Instance categories - compute, memory, general purpose
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["c", "m", "r", "t"]

            # Use modern instance generations (6th gen and above)
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["5"]

            # Exclude GPU instances to control costs
            - key: karpenter.k8s.aws/instance-gpu-count
              operator: DoesNotExist

          # Taints and tolerations
          taints: []

      # Limits for the NodePool
      limits:
        cpu: "1000"
        memory: 1000Gi

      # Disruption budget for graceful node termination
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 30s
        budgets:
          - nodes: "10%"

      # Weight for this NodePool (higher = more preferred)
      weight: 80
  YAML

  depends_on = [
    kubectl_manifest.karpenter_ec2_node_class
  ]
}

# NodePool for On-Demand instances (priority 20 - fallback)
resource "kubectl_manifest" "karpenter_node_pool_on_demand" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: on-demand
    spec:
      # Template for nodes
      template:
        metadata:
          labels:
            workload-type: on-demand
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default

          # Requirements for instance selection
          requirements:
            # Support both x86 and arm64 architectures
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64", "arm64"]

            # On-Demand instances only
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]

            # Instance categories - compute, memory, general purpose
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["c", "m", "r", "t"]

            # Use modern instance generations (6th gen and above)
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["5"]

            # Exclude GPU instances
            - key: karpenter.k8s.aws/instance-gpu-count
              operator: DoesNotExist

          taints: []

      # Limits for the NodePool
      limits:
        cpu: "1000"
        memory: 1000Gi

      # Disruption budget
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 30s
        budgets:
          - nodes: "10%"

      # Weight for this NodePool (lower = less preferred)
      weight: 20
  YAML

  depends_on = [
    kubectl_manifest.karpenter_ec2_node_class
  ]
}
