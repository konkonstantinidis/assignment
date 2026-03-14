# Cloud Architecture Design Document

**Organization:** Innovate Inc.
**Document Version:** 1.0
**Date:** 2026-03-14
**Status:** Approved for Implementation

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Cloud Environment Structure](#cloud-environment-structure)
3. [Network Design](#network-design)
4. [Compute Platform](#compute-platform)
5. [Database Layer](#database-layer)
6. [Security Architecture](#security-architecture)
7. [Observability and Monitoring](#observability-and-monitoring)
8. [High-Level Architecture Diagram](#high-level-architecture-diagram)
9. [Cost Considerations](#cost-considerations)
10. [Scaling Strategy](#scaling-strategy)
11. [Disaster Recovery](#disaster-recovery)
12. [Implementation Roadmap](#implementation-roadmap)

---

## Executive Summary

Innovate Inc. requires a production-grade, cloud-native infrastructure on AWS to support a web application built on Python/Flask, React SPA, and PostgreSQL. The architecture is designed to:

- Support initial traffic in the hundreds of daily active users and scale to millions without re-architecture.
- Protect sensitive user data through defense-in-depth security controls and compliance-oriented account isolation.
- Enable rapid, safe CI/CD deployments multiple times per day with zero downtime.
- Minimize operational burden using managed services (EKS, RDS, ECR, ALB) while retaining flexibility.

The platform is built around AWS Elastic Kubernetes Service (EKS) as the compute foundation, Amazon RDS PostgreSQL Multi-AZ as the data layer, and a three-tier VPC network design with strict segmentation between public, application, and data subnets.

**Key Design Principles:**

- Security by default - least privilege IAM, encrypted data at rest and in transit, no direct internet access to workloads.
- Infrastructure as Code (IaC) - all resources defined in Terraform, version-controlled, and deployed via CI/CD pipelines.
- Operational simplicity - managed services preferred over self-managed to reduce toil.
- Cost efficiency - right-sized resources for current load with defined triggers to scale up.

---

## Cloud Environment Structure

### Multi-Account Strategy

Innovate Inc. will adopt an AWS Organizations multi-account strategy from day one. While the initial workload is small, establishing proper account boundaries early prevents costly reorganization later and provides immediate security, compliance, and billing benefits.

```
AWS Organization (Root)
|
+-- Management Account
|     - AWS Organizations administration
|     - Consolidated billing and cost visibility
|     - No workloads deployed here
|
+-- Security Account
|     - AWS Security Hub (aggregated findings)
|     - AWS GuardDuty (organization-wide threat detection)
|     - AWS CloudTrail (organization-wide audit logs)
|     - AWS Config (organization-wide compliance rules)
|     - Centralized IAM Identity Center (SSO)
|
+-- Shared Services Account
|     - Amazon ECR (shared container registry)
|     - Artifact repositories (S3, CodeArtifact)
|     - Internal tooling and bastion access
|     - Transit Gateway attachments (if needed in future)
|
+-- Production Account
|     - EKS cluster (production workloads)
|     - RDS PostgreSQL (production data)
|     - Production VPC and networking
|
+-- Staging Account
|     - EKS cluster (pre-production validation)
|     - RDS PostgreSQL (staging data, no real user data)
|     - Mirror of production architecture at reduced scale
|
+-- Development Account
      - Developer sandbox environments
      - Ephemeral EKS namespaces per feature branch (optional)
      - Relaxed guardrails to enable experimentation
```

### Justification

**Security Isolation:** AWS accounts are the strongest security boundary available. A compromise or misconfiguration in the development account cannot affect production data or workloads. Sensitive customer data in the production RDS instance is isolated at the account boundary level.

**Billing Clarity:** Per-account cost allocation via AWS Cost Explorer and Cost and Usage Reports provides clean attribution. Each environment's spend is visible independently, enabling accurate chargebacks and budget enforcement using AWS Budgets alerts per account.

**Blast Radius Reduction:** IAM policies, Service Control Policies (SCPs), and resource policies are scoped per account. An overly permissive policy in staging cannot grant access to production resources.

**Compliance Posture:** Regulated workloads (PCI-DSS, SOC 2, HIPAA where applicable) often require production environment isolation. Establishing this boundary early simplifies future audit scopes.

**Service Limits:** AWS service quotas are per account. Isolating production prevents development activity from consuming production quotas (e.g., EC2 instance limits, EIP allocations).

### AWS Organizations Service Control Policies (SCPs)

The following SCPs are applied at the organization level:

| SCP | Scope | Purpose |
|-----|-------|---------|
| DenyRootUserActions | All accounts | Prevent root account usage |
| DenyRegionOutsideApproved | All accounts | Restrict to us-east-1 and us-west-2 only |
| RequireS3Encryption | All accounts | Enforce S3 server-side encryption |
| DenyPublicS3Buckets | Production, Staging | Prevent accidental public S3 exposure |
| DenyDisableCloudTrail | All accounts | Prevent audit log tampering |
| RequireIMDSv2 | All accounts | Enforce instance metadata service v2 |

---

## Network Design

### VPC Architecture

Each workload account (Production, Staging) receives a dedicated VPC. The design uses three subnet tiers across three Availability Zones to achieve high availability and strong network segmentation.

**Production VPC CIDR:** `10.0.0.0/16`
**Staging VPC CIDR:** `10.1.0.0/16`
**Shared Services VPC CIDR:** `10.2.0.0/16`

### Subnet Layout (Production)

The VPC spans three Availability Zones (us-east-1a, us-east-1b, us-east-1c) with the following subnet allocation:

| Tier | AZ | CIDR | Resources |
|------|----|------|-----------|
| Public | us-east-1a | 10.0.0.0/24 | ALB, NAT Gateway |
| Public | us-east-1b | 10.0.1.0/24 | ALB, NAT Gateway |
| Public | us-east-1c | 10.0.2.0/24 | ALB, NAT Gateway |
| Private (App) | us-east-1a | 10.0.10.0/23 | EKS Worker Nodes |
| Private (App) | us-east-1b | 10.0.12.0/23 | EKS Worker Nodes |
| Private (App) | us-east-1c | 10.0.14.0/23 | EKS Worker Nodes |
| Private (Data) | us-east-1a | 10.0.20.0/24 | RDS Primary |
| Private (Data) | us-east-1b | 10.0.21.0/24 | RDS Standby |
| Private (Data) | us-east-1c | 10.0.22.0/24 | RDS Reserved/Replica |

**Rationale for /23 blocks on application subnets:** EKS nodes use AWS VPC CNI, which allocates IP addresses directly from the VPC CIDR for pods. A /23 block (512 addresses) per AZ provides capacity for node IPs plus pod IPs without requiring secondary CIDRs at initial scale. As pod density increases, additional CIDR blocks can be associated with the VPC.

### Routing Architecture

**Public Subnets:**
- Route table entry: `0.0.0.0/0 -> Internet Gateway`
- Used exclusively for load balancers and NAT Gateway egress IPs
- No application workloads run in public subnets

**Private Application Subnets:**
- Route table entry: `0.0.0.0/0 -> NAT Gateway (in same AZ)`
- Each AZ has its own NAT Gateway to avoid cross-AZ data transfer costs and single-AZ NAT Gateway failures
- EKS worker nodes reside here; pods reach the internet (for package downloads, external APIs) through NAT

**Private Data Subnets:**
- No route to `0.0.0.0/0` - fully private, no internet access
- Only accepts connections from the application subnet CIDR ranges
- RDS instances reside exclusively in this tier

### NAT Gateway Configuration

Three NAT Gateways are deployed, one per Availability Zone, each in the corresponding public subnet. This design:
- Eliminates cross-AZ NAT traffic charges (typically $0.01/GB)
- Ensures AZ-local egress continues if one NAT Gateway fails
- Provides clear per-AZ egress IP addresses for IP allowlisting with third-party services

**Elastic IP addresses** are allocated per NAT Gateway and documented. These IPs are provided to any third-party services requiring IP allowlisting (payment processors, external APIs).

### Security Groups

Security groups act as stateful virtual firewalls attached to individual resources. The principle of least privilege is applied: only required ports between specific source/destination security groups are permitted.

**sg-alb (Application Load Balancer):**

| Direction | Protocol | Port | Source/Destination | Purpose |
|-----------|----------|------|-------------------|---------|
| Inbound | TCP | 443 | 0.0.0.0/0 | HTTPS from internet |
| Inbound | TCP | 80 | 0.0.0.0/0 | HTTP redirect to HTTPS |
| Outbound | TCP | 8000 | sg-eks-nodes | Traffic to Flask backend |
| Outbound | TCP | 3000 | sg-eks-nodes | Traffic to React frontend (if SSR) |

**sg-eks-nodes (EKS Worker Nodes):**

| Direction | Protocol | Port | Source/Destination | Purpose |
|-----------|----------|------|-------------------|---------|
| Inbound | TCP | 1025-65535 | sg-alb | ALB target group health checks and traffic |
| Inbound | TCP | 443 | sg-eks-control-plane | EKS control plane communication |
| Inbound | All | All | sg-eks-nodes | Node-to-node communication (pod networking) |
| Outbound | TCP | 5432 | sg-rds | PostgreSQL access |
| Outbound | TCP | 443 | 0.0.0.0/0 | AWS API calls, ECR, external services via NAT |

**sg-rds-proxy (RDS Proxy):**

| Direction | Protocol | Port | Source/Destination | Purpose |
|-----------|----------|------|-------------------|---------|
| Inbound | TCP | 5432 | sg-eks-nodes | Application connections to proxy |
| Outbound | TCP | 5432 | sg-rds | Proxy to RDS backend |

**sg-rds (RDS PostgreSQL):**

| Direction | Protocol | Port | Source/Destination | Purpose |
|-----------|----------|------|-------------------|---------|
| Inbound | TCP | 5432 | sg-rds-proxy | Connections from RDS Proxy only |
| Inbound | TCP | 5432 | sg-bastion | Emergency administrative access |
| Outbound | None | - | - | RDS has no outbound requirements |

**sg-bastion (Bastion / SSM Session Manager):**

No inbound SSH port (22) is opened. Access is exclusively through AWS Systems Manager Session Manager, eliminating the need for open SSH ports or managing SSH keys. The security group has no inbound rules.

### VPC Endpoints

To avoid routing AWS API traffic through NAT Gateways (reducing costs and latency while improving security), the following VPC Endpoints are provisioned:

**Gateway Endpoints (free):**
- `com.amazonaws.us-east-1.s3` - S3 access (ECR image layers, CloudWatch Logs)
- `com.amazonaws.us-east-1.dynamodb` - DynamoDB (if used for session storage)

**Interface Endpoints (charged per hour + per GB):**
- `com.amazonaws.us-east-1.ecr.api` - ECR API for image metadata
- `com.amazonaws.us-east-1.ecr.dkr` - ECR Docker registry for image pulls
- `com.amazonaws.us-east-1.logs` - CloudWatch Logs
- `com.amazonaws.us-east-1.monitoring` - CloudWatch Metrics
- `com.amazonaws.us-east-1.sts` - Security Token Service (IAM role assumption)
- `com.amazonaws.us-east-1.secretsmanager` - Secrets Manager

---

## Compute Platform

### EKS Cluster Configuration

**Cluster Version:** Kubernetes 1.32 (latest stable at document date; upgrade within 60 days of new minor releases)

**Control Plane:** Fully managed by AWS EKS. The control plane runs across multiple AZs with automatic failover. AWS manages etcd, API server, controller manager, and scheduler. SLA: 99.95% uptime.

**Networking:** AWS VPC CNI plugin. Each pod receives a real VPC IP address, enabling direct communication with other AWS services and eliminating the complexity of overlay networks. Pod security groups are enabled for fine-grained network policy at the pod level.

**Authentication:** EKS access configured via IAM Identity Center (SSO) groups mapped to Kubernetes RBAC roles. Direct IAM user-to-cluster mappings are avoided to enable SSO-based access revocation.

### Node Groups

EKS Managed Node Groups are used exclusively (not self-managed nodes or Fargate for the primary workloads). Managed Node Groups provide automated node upgrades, AMI updates, and health monitoring.

**Node Group: system**

| Parameter | Value |
|-----------|-------|
| Purpose | System pods (CoreDNS, aws-node, kube-proxy, cluster-autoscaler, ALB controller) |
| Instance type | t3.medium |
| Min nodes | 3 (one per AZ) |
| Max nodes | 3 |
| Scaling | Fixed - not autoscaled |
| AMI type | AL2_x86_64 (Amazon Linux 2) |
| Disk size | 50 GB gp3 |
| Labels | `role=system` |
| Taints | `role=system:NoSchedule` (application pods cannot schedule here) |

**Node Group: application**

| Parameter | Value |
|-----------|-------|
| Purpose | Flask backend and React frontend pods |
| Instance type | m6i.large (initial), m6i.xlarge (as traffic grows) |
| Min nodes | 2 |
| Max nodes | 20 |
| Scaling | Cluster Autoscaler managed |
| AMI type | AL2_x86_64 |
| Disk size | 50 GB gp3 |
| Labels | `role=application` |
| Taints | None |

**Node Group: application-spot (cost optimization)**

| Parameter | Value |
|-----------|-------|
| Purpose | Overflow capacity for non-critical background workloads |
| Instance types | m6i.large, m5.large, m5a.large (multiple types reduce interruption risk) |
| Min nodes | 0 |
| Max nodes | 10 |
| Scaling | Cluster Autoscaler managed |
| AMI type | AL2_x86_64 |
| Labels | `role=application-spot`, `node-type=spot` |
| Taints | `node-type=spot:NoSchedule` (only tolerant pods schedule here) |

Spot instances are used for workloads tolerant of interruption (batch jobs, background processing). Production-facing Flask and frontend pods have no Spot toleration and run exclusively on on-demand nodes.

### Kubernetes Workload Configuration

**Namespace Structure:**

```
kube-system          - Kubernetes system components
amazon-vpc-cni       - AWS networking
kube-public          - Public cluster info (read-only)
monitoring           - Prometheus, Grafana
ingress-nginx        - Ingress controller (or aws-load-balancer-controller)
cert-manager         - TLS certificate management
production           - Production application workloads
```

**Flask Backend Deployment:**

```yaml
# Illustrative configuration - actual values defined in Helm chart
replicas: 2  # Initial; HPA manages scaling up
strategy: RollingUpdate
  maxUnavailable: 0   # Zero downtime deployments
  maxSurge: 1
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
livenessProbe:
  httpGet: /healthz
  initialDelaySeconds: 10
readinessProbe:
  httpGet: /ready
  initialDelaySeconds: 5
podDisruptionBudget:
  minAvailable: 1     # At least 1 pod available during node drain
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule   # Spread across AZs
```

**React Frontend Deployment:**

The React SPA is a static build served by an Nginx container. This keeps the frontend stateless, enables aggressive CDN caching, and decouples frontend deployments from backend deployments.

```yaml
# Illustrative configuration
replicas: 2
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi
```

**CloudFront Distribution** fronts the ALB for global edge caching of static React assets. Cache-Control headers are set to cache immutable JS/CSS chunks (hashed filenames from Webpack) for one year at the edge, while `index.html` is cached for a short TTL to enable fast deployments.

### Horizontal Pod Autoscaler (HPA)

HPA scales pod replicas based on observed metrics. Custom metrics from the application are preferred over CPU alone, as Flask request handling is I/O-bound and CPU utilization is a poor proxy for load.

**Flask Backend HPA:**

| Metric | Target | Min Replicas | Max Replicas |
|--------|--------|-------------|-------------|
| Requests per second (custom) | 100 RPS per pod | 2 | 50 |
| CPU utilization | 70% | 2 | 50 |
| Memory utilization | 80% | 2 | 50 |

Custom metrics are exported from the Flask application via a `/metrics` Prometheus endpoint and ingested by the Prometheus Adapter to make them available to the HPA controller via the Kubernetes custom metrics API.

**Scaling Behavior:**

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 60    # Avoid thrashing during traffic spikes
    policies:
      - type: Pods
        value: 4                       # Add up to 4 pods per 60 seconds
        periodSeconds: 60
  scaleDown:
    stabilizationWindowSeconds: 300   # Wait 5 minutes before scaling down
    policies:
      - type: Percent
        value: 25                      # Remove at most 25% of pods per 5 minutes
        periodSeconds: 300
```

### Cluster Autoscaler

The Cluster Autoscaler runs as a Deployment in the `kube-system` namespace and automatically provisions or terminates EC2 worker nodes based on pod scheduling pressure.

**Configuration highlights:**
- `--scale-down-delay-after-add=10m` - Wait 10 minutes after a scale-up before considering scale-down
- `--scale-down-unneeded-time=10m` - Node must be unneeded for 10 minutes before termination
- `--skip-nodes-with-system-pods=true` - Never drain system nodes
- `--balance-similar-node-groups=true` - Balance across AZs evenly
- IAM permissions granted via IRSA (IAM Roles for Service Accounts) - no node-level EC2 credentials

**IRSA** (IAM Roles for Service Accounts) is used for all Kubernetes pods that require AWS API access. Pod-level IAM roles eliminate the need for node-level instance profile permissions, enforcing least privilege. Example components using IRSA: Cluster Autoscaler (EC2 AutoScaling API), AWS Load Balancer Controller (ELB API), External Secrets Operator (Secrets Manager API), Fluent Bit (CloudWatch Logs API).

### Container Registry (ECR)

Amazon Elastic Container Registry (ECR) in the Shared Services account serves as the single container registry for all environments.

**Repository structure:**

```
<shared-services-account>.dkr.ecr.us-east-1.amazonaws.com/
  innovate-inc/
    backend/        - Flask application images
    frontend/       - Nginx + React static build images
    migrations/     - Alembic database migration runner images
```

**Image tagging convention:**
- Git commit SHA: `backend:abc1234` - immutable, used in deployments
- Semantic version: `backend:v1.2.3` - for release tracking
- Environment mutable tags (`backend:latest`, `backend:staging`) are not used in automated deployments to ensure reproducibility

**ECR Lifecycle Policies:**
- Keep the last 30 tagged images per repository
- Delete untagged images older than 7 days
- Production environment images are protected from lifecycle deletion if referenced in an active EKS deployment (enforced via custom automation or manual tagging)

**Image Scanning:**
- ECR Enhanced Scanning (powered by Amazon Inspector) is enabled on all repositories
- Scans trigger on push and run continuously for newly discovered CVEs
- CI/CD pipeline gates on Critical and High severity vulnerabilities: images with Critical CVEs are blocked from deployment; High CVEs require manual override with documented justification

### CI/CD Pipeline

The CI/CD pipeline is the critical path for all deployments. It enforces quality gates, security checks, and enables multiple deploys per day with confidence.

**Pipeline Tool:** GitHub Actions (source of truth: application and infrastructure code in GitHub)

**Pipeline Stages:**

```
Developer pushes to feature branch
         |
         v
[1] Continuous Integration
    - Unit tests (pytest for Flask, Jest for React)
    - Integration tests (against ephemeral PostgreSQL via GitHub Actions service container)
    - Static analysis (flake8, mypy for Python; ESLint for TypeScript/React)
    - Security scanning (Bandit for Python SAST, npm audit for frontend dependencies)
    - Code coverage gate (minimum 70% enforced)
         |
         v
[2] Build & Package (on merge to main)
    - Docker build for backend image
    - Docker build for frontend image (multi-stage: Node build + Nginx serve)
    - Tag images with git SHA
    - Push images to ECR (Shared Services account)
    - ECR image vulnerability scan gate (block on Critical CVEs)
         |
         v
[3] Infrastructure Validation
    - terraform fmt check
    - terraform validate
    - tflint (Terraform linting)
    - checkov (Terraform security scanning)
    - terraform plan (output stored as PR comment)
         |
         v
[4] Deploy to Staging
    - Update Helm chart values with new image tag (git SHA)
    - helm upgrade --install to staging EKS cluster
    - Run database migrations (Kubernetes Job using migrations image)
    - Smoke tests (curl endpoints, check HTTP 200)
    - E2E tests (Playwright against staging environment)
         |
         v
[5] Deploy to Production (manual approval gate)
    - Required reviewer approval in GitHub Actions environment protection
    - helm upgrade --install to production EKS cluster
    - Rolling update: zero downtime via maxUnavailable: 0
    - Run database migrations
    - Production smoke tests
    - Automatic rollback if smoke tests fail (helm rollback)
```

**Deployment Frequency Target:** Multiple times per day to staging; 1-3 times per day to production with approval.

**Rollback Strategy:**
- Helm keeps a configurable history of releases (`--history-max 10`)
- Rollback command: `helm rollback <release> <revision>` reverts to a previous known-good image tag
- Database migrations are designed to be forward-compatible (expand-contract pattern) so that a rollback of application code does not require a database schema rollback

---

## Database Layer

### RDS PostgreSQL Configuration

Amazon RDS for PostgreSQL is used for all persistent relational data. The managed service provides automated backups, patching, monitoring, and Multi-AZ failover without operational overhead.

**Engine:** PostgreSQL 16 (latest major version supported by RDS at document date)

**Instance Configuration (Production):**

| Parameter | Initial Value | Scaled Value |
|-----------|--------------|-------------|
| Instance class | db.t3.medium | db.r6g.xlarge |
| Storage type | gp3 | gp3 |
| Allocated storage | 100 GB | 1 TB (auto-scaling enabled) |
| Max storage autoscaling | 500 GB | 5 TB |
| Multi-AZ | Yes | Yes |
| Read replicas | 0 | 1-3 (as read traffic grows) |

**Storage:** gp3 SSD is selected over gp2 for independent IOPS and throughput configuration. Initial IOPS: 3000 (baseline), throughput: 125 MB/s. These can be increased without storage resizing.

**Parameter Group Customizations:**

| Parameter | Value | Reason |
|-----------|-------|--------|
| `shared_buffers` | 25% of RAM | Standard recommendation for dedicated DB server |
| `max_connections` | 100 | RDS Proxy manages the actual connection pool; app connections go through the proxy |
| `log_min_duration_statement` | 1000 | Log queries slower than 1 second for performance analysis |
| `ssl` | on | Enforce SSL for all connections |
| `rds.force_ssl` | 1 | Reject non-SSL connections at the RDS level |
| `log_connections` | on | Audit logging for connection events |

### Multi-AZ High Availability

RDS Multi-AZ provisions a synchronous standby replica in a separate Availability Zone. AWS manages automatic failover:

- **Normal operation:** All reads and writes go to the primary instance. Standby is kept in sync via synchronous replication (no data loss on failover).
- **Failover trigger:** Primary instance failure, AZ outage, or manual failover. The standby is promoted and the RDS DNS endpoint automatically updates (CNAME change). Typical failover time without proxy: 60-120 seconds; **with RDS Proxy: ~5 seconds** (proxy pins to the new primary automatically).
- **Application behavior during failover:** Flask pods connect to the RDS Proxy endpoint, which handles reconnection to the promoted standby transparently. Application code requires no changes.

**RDS Proxy (Managed Connection Pooler):**

Direct connections from potentially hundreds of Flask pod replicas would exhaust PostgreSQL's `max_connections`. Amazon RDS Proxy is a fully managed, highly available connection pooler that sits between EKS pods and the RDS instance:

- **No infrastructure to manage** — no Kubernetes Deployment, no sidecar, no self-managed scaling
- **Native IAM authentication** — pods authenticate to RDS Proxy using an IAM role (IRSA), eliminating database passwords from application code entirely
- **Automatic Secrets Manager integration** — RDS Proxy rotates database credentials transparently; applications are never aware of rotation events
- **Faster failover** — RDS Proxy maintains warm connections to the standby; on failover, it redirects existing application connections to the new primary in ~5 seconds instead of 60-120 seconds
- **Connection pooling mode:** RDS Proxy uses transaction-level multiplexing for PostgreSQL — a backend connection is borrowed for the duration of a transaction, then returned to the pool
- **Deployment:** RDS Proxy is provisioned via Terraform in the same VPC as the EKS cluster; ENIs are created in the private data subnets, secured by `sg-rds-proxy`

### Backup and Recovery

**Automated Backups:**
- RDS automated backups enabled with 35-day retention (maximum)
- Backups stored in the same region; point-in-time recovery (PITR) to any second within the retention window
- Backup window: 03:00-04:00 UTC (low traffic period)

**Cross-Region Backup Replication:**
- Automated backup replication enabled to `us-west-2` (secondary region)
- Provides protection against full `us-east-1` region outage
- Retention in secondary region: 35 days

**Manual Snapshots:**
- Pre-deployment snapshots taken before every production database migration via CI/CD pipeline (AWS CLI `create-db-snapshot` call)
- Snapshots retained for 90 days (manual snapshots are not subject to the automated backup retention window)
- Monthly snapshots archived to S3 via RDS snapshot export for long-term retention and regulatory compliance

**Snapshot Encryption:** All RDS snapshots are encrypted with the same KMS CMK used for the RDS instance. Cross-account snapshot sharing (for disaster recovery testing) uses re-encrypted copies with a different CMK.

### Database Security

- **Encryption at rest:** AWS KMS Customer Managed Key (CMK) with annual automatic rotation enabled
- **Encryption in transit:** SSL/TLS enforced at the parameter group level; certificates signed by AWS RDS CA
- **Network access:** RDS instances reside in private data subnets with no route to the internet; access restricted to `sg-eks-nodes` and `sg-bastion` security groups
- **Credentials:** Master password stored in AWS Secrets Manager with automatic rotation (Lambda function rotates every 30 days); application-level credentials use a separate Secrets Manager secret with dedicated DB user
- **Least privilege DB users:** Application connects as `app_user` with SELECT, INSERT, UPDATE, DELETE on specific schemas only; DDL operations (CREATE TABLE, ALTER TABLE) performed only by the `migrations_user` during migration jobs

---

## Security Architecture

### Defense-in-Depth Layers

**Layer 1 - Account Boundary:** Multi-account structure with SCPs (described above).

**Layer 2 - Network:** VPC with three-tier subnet segmentation, security groups with minimal rules, NACLs as secondary stateless control, no public IP assignments on application or data resources.

**Layer 3 - Identity and Access:** IAM Identity Center (SSO) for human access; IRSA for pod-level AWS API access; no long-lived access keys; MFA required for all human console access.

**Layer 4 - Data:** KMS encryption for RDS, S3, EBS volumes, ECR images, and Secrets Manager values; TLS 1.2+ enforced on all service-to-service communication; secrets never stored in environment variables baked into container images.

**Layer 5 - Application:** OWASP Top 10 mitigations in Flask code; Content Security Policy headers; CORS configuration; rate limiting at the ALB (AWS WAF rules); authentication tokens stored in httpOnly, Secure, SameSite=Strict cookies.

**Layer 6 - Detection:** AWS GuardDuty (threat intelligence-based detection), AWS Security Hub (aggregated findings), VPC Flow Logs (network anomaly detection), CloudTrail (API audit logs), RDS activity streams (database-level audit).

### AWS WAF Configuration

An AWS WAF Web ACL is attached to the Application Load Balancer with the following rule groups:

| Rule Group | Purpose |
|-----------|---------|
| AWSManagedRulesCommonRuleSet | Protection against OWASP Top 10 |
| AWSManagedRulesKnownBadInputsRuleSet | Block known malicious request patterns |
| AWSManagedRulesSQLiRuleSet | SQL injection protection |
| Rate-based rule: 2000 req/5min per IP | DDoS and brute-force mitigation |
| Custom rule: Block non-HTTPS | Enforce HTTPS (belt-and-suspenders with ALB redirect) |

### Secrets Management

All secrets (database credentials, API keys, JWT signing secrets, third-party service credentials) are stored in AWS Secrets Manager:

- Secrets are namespaced by environment: `/innovate-inc/production/database/password`
- Kubernetes pods access secrets via the External Secrets Operator, which syncs Secrets Manager values into Kubernetes Secret objects
- Kubernetes Secrets are encrypted at rest using EKS envelope encryption with a KMS CMK
- Secret values are never logged, included in Helm chart values committed to Git, or passed as environment variables in Dockerfiles

---

## Observability and Monitoring

### Metrics

- **Kubernetes metrics:** kube-state-metrics and metrics-server deployed in cluster
- **Application metrics:** Flask application exposes Prometheus-format `/metrics` endpoint; Prometheus scrapes and stores time-series data
- **Infrastructure metrics:** AWS CloudWatch receives metrics from RDS, ALB, EKS control plane, NAT Gateway, and EC2 nodes via CloudWatch Agent
- **Visualization:** Grafana dashboards for application performance, infrastructure health, and business KPIs; pre-built dashboards for EKS, RDS, and ALB from the Grafana dashboard library

### Logging

- **Application logs:** Flask structured JSON logs (using Python `structlog` library) captured by Fluent Bit as a DaemonSet, forwarded to CloudWatch Logs
- **Kubernetes system logs:** kube-apiserver, kube-controller-manager, kube-scheduler logs captured in EKS control plane logging (enabled for all log types: API, Audit, Authenticator, ControllerManager, Scheduler)
- **VPC Flow Logs:** Enabled at the VPC level, stored in S3 with Athena for query access
- **RDS Logs:** PostgreSQL logs (slow query, connection events, error logs) forwarded to CloudWatch Logs
- **Log Retention:** Application and system logs retained 90 days in CloudWatch; archived to S3 Glacier for 7 years (compliance)

### Alerting

PagerDuty integration with CloudWatch Alarms and Prometheus Alertmanager for on-call notification:

| Alert | Threshold | Severity |
|-------|-----------|---------|
| API error rate > 5% for 5 minutes | 5% 5xx responses | P1 |
| API latency p99 > 2 seconds | p99 > 2000ms | P2 |
| Pod restart loop | CrashLoopBackOff for 15 minutes | P2 |
| RDS CPU > 80% for 10 minutes | 80% sustained | P2 |
| RDS storage > 80% | 80% of allocated | P2 |
| RDS Multi-AZ failover occurred | Failover event | P1 |
| Node count below minimum | < min nodes | P1 |
| HPA at maximum replicas | Max pods reached | P2 |
| GuardDuty High/Critical finding | Any finding | P1 |

---

### Network Flow Description

1. A user's browser requests the React SPA from CloudFront. Static assets (JS, CSS, images) are served from CloudFront's edge cache with long TTLs. `index.html` is served with a short TTL.
2. The React SPA makes API calls to `api.innovate-inc.com`. These requests traverse CloudFront to the AWS WAF Web ACL, which evaluates against managed rule sets and rate limits.
3. WAF forwards clean traffic to the Application Load Balancer over HTTPS. The ALB terminates TLS (ACM-managed certificate) and routes requests to the appropriate Kubernetes target group.
4. The Flask backend pod handles the request, reads secrets via IAM (IRSA) directly from Secrets Manager, and issues SQL queries to the **RDS Proxy** endpoint using IAM authentication — no database password in application config.
5. RDS Proxy multiplexes application connections onto a smaller pool of actual PostgreSQL connections to the RDS primary instance. The proxy authenticates to RDS using the master credential stored in Secrets Manager, rotating it automatically every 30 days.
6. RDS synchronously replicates all writes to the standby instance in a separate AZ before acknowledging the write. On primary failure, RDS promotes the standby within 60-120 seconds.
7. Security events from GuardDuty, CloudTrail, and application logs flow to Security Hub and CloudWatch, with alerts triggering PagerDuty for on-call response.

---

## Cost Considerations

### Initial Cost Estimate (Low Traffic Phase)

The following is an approximate monthly cost estimate for the production account at initial scale (hundreds of daily users):

| Resource | Configuration | Est. Monthly Cost |
|----------|--------------|------------------|
| EKS Cluster | Control plane fee | $73 |
| EC2 - System Nodes | 3x t3.medium (on-demand) | $96 |
| EC2 - App Nodes | 2x m6i.large (on-demand, minimum) | $185 |
| NAT Gateways | 3x NAT GW + ~50 GB/month traffic | $100 |
| RDS PostgreSQL | db.t3.medium Multi-AZ, 100 GB gp3 | $170 |
| RDS Proxy | 2 vCPU equivalent, us-east-1 | $50 |
| ALB | 1 ALB + LCU charges (low traffic) | $25 |
| ECR | Storage + data transfer | $10 |
| CloudFront | Low traffic (~100 GB/month) | $10 |
| CloudWatch | Logs ingestion + storage | $30 |
| Secrets Manager | ~10 secrets + API calls | $5 |
| VPC Endpoints | ~5 interface endpoints | $35 |
| WAF | Web ACL + rule evaluations | $15 |
| **Total Estimate** | | **~$804/month** |

Costs scale primarily with EC2 node count and RDS instance size. At millions of users, dominant costs will be EC2 (application nodes autoscaled) and RDS (larger instance class + read replicas). Reserved Instance or Savings Plan commitments reduce EC2 and RDS costs by 30-60% once usage patterns stabilize (recommended after 3 months of production operation).

---

## Disaster Recovery

### Recovery Objectives

| Scenario | RTO (Recovery Time) | RPO (Data Loss) |
|----------|--------------------|----|
| Single AZ failure | < 5 minutes (automatic) | 0 (synchronous Multi-AZ) |
| RDS primary failure | < 2 minutes (automatic failover) | 0 (synchronous Multi-AZ) |
| EKS node group failure | < 10 minutes (Cluster Autoscaler) | 0 (stateless pods) |
| Full region failure (us-east-1) | < 4 hours | < 5 minutes (cross-region backup) |
| Accidental data deletion | < 1 hour (PITR restore) | Up to 35 days lookback |

### Region Failure Recovery Procedure

In the event of a complete `us-east-1` outage:

1. Restore the latest cross-region RDS snapshot in `us-west-2` to a new RDS instance.
2. Apply Terraform configuration for the `us-west-2` environment (pre-prepared Terraform workspace).
3. Deploy application workloads to the `us-west-2` EKS cluster via Helm.
4. Update Route 53 DNS records to point to the `us-west-2` ALB.
5. Validate application functionality with smoke tests.

The `us-west-2` Terraform configuration is maintained in the same IaC repository as `us-east-1`, updated in parallel during normal operations, and validated in CI/CD. This ensures the secondary region configuration does not drift from primary.

### DR Testing

Quarterly DR exercises are scheduled to validate recovery procedures:
- Test RDS point-in-time restore in an isolated VPC
- Simulate node group failure and validate Cluster Autoscaler recovery
- Tabletop exercise for region-level failure scenario
- Chaos engineering (AWS Fault Injection Simulator) on staging environment to test application resilience

