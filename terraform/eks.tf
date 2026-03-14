module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # Cluster endpoint access
  cluster_endpoint_public_access = true

  # Enable IRSA (IAM Roles for Service Accounts)
  enable_irsa = true

  # Cluster addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  # VPC and networking configuration
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Enable cluster logging
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # EKS managed node group for system workloads
  # These nodes are tainted to prevent application workloads and reserved for:
  # - Karpenter controller
  # - CoreDNS
  # - kube-proxy
  # - Other system components
  eks_managed_node_groups = {
    system = {
      name = "${var.cluster_name}-system"

      instance_types = var.managed_node_group_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.managed_node_group_min_size
      max_size     = var.managed_node_group_max_size
      desired_size = var.managed_node_group_desired_size

      # Taint to prevent application workloads from scheduling on these nodes
      taints = [{
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]

      labels = {
        role = "system"
      }

      # Allow tolerations for system workloads
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      tags = merge(
        var.tags,
        {
          Name = "${var.cluster_name}-system-node"
        }
      )
    }
  }

  # Node security group configuration
  node_security_group_additional_rules = {
    # Allow nodes to communicate with each other
    ingress_self_all = {
      description = "Node to node all traffic"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Allow pods to communicate with the cluster API
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  tags = var.tags
}
