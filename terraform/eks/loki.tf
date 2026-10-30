# ---------------------------------------------------------------
# Loki (강사님의 loki-values.yaml + helm install 에 해당)
# - SingleBinary 1개 파드, 로그는 gp3 볼륨(20Gi)에 저장하고 7일(168h) 지나면 삭제
# - gateway 는 VPC 안에서만 접근되는 내부 NLB (소스는 VPC 대역으로 제한)
# - destroy 때 차트의 PVC 자동 삭제 설정(whenDeleted: Delete)으로 EBS 볼륨도 함께 지워짐
# ---------------------------------------------------------------
resource "helm_release" "loki" {
  name       = "loki"
  namespace  = "monitoring"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "7.5.0"
  timeout    = 600 # EBS 볼륨 생성과 NLB 준비를 기다림

  values = [yamlencode({
    deploymentMode = "SingleBinary"

    loki = {
      auth_enabled = false # 멀티테넌시 비활성화 (실습용)
      commonConfig = {
        replication_factor = 1
      }
      storage = {
        type = "filesystem"
      }
      schemaConfig = {
        configs = [{
          from         = "2024-01-01"
          store        = "tsdb"
          object_store = "filesystem"
          schema       = "v13"
          index = {
            prefix = "loki_index_"
            period = "24h"
          }
        }]
      }
      limits_config = {
        retention_period          = "168h" # 7일
        allow_structured_metadata = true
        volume_enabled            = true
        ingestion_rate_mb         = 16
        ingestion_burst_size_mb   = 32
      }
      compactor = {
        retention_enabled    = true # retention_period 적용 (오래된 로그 삭제)
        delete_request_store = "filesystem"
      }
    }

    singleBinary = {
      replicas = 1
      persistence = {
        enabled      = true
        storageClass = kubernetes_storage_class_v1.gp3.metadata[0].name
        size         = "20Gi"
      }
      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { memory = "2Gi" }
      }
    }

    # SingleBinary 모드에서는 분산 컴포넌트를 쓰지 않음
    read         = { replicas = 0 }
    write        = { replicas = 0 }
    backend      = { replicas = 0 }
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    lokiCanary   = { enabled = false }
    test         = { enabled = false }
    minio        = { enabled = false }

    gateway = {
      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
          "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internal"
          "service.beta.kubernetes.io/aws-load-balancer-source-ranges"   = module.vpc.vpc_cidr_block

          # 우리가 만든 보안 그룹(loki-lambda-sg.tf)을 이 NLB 에 붙임. 지정하지 않으면 컨트롤러가 k8s-monitori-lokigate-* 를 자동으로 만듦
          "service.beta.kubernetes.io/aws-load-balancer-security-groups" = aws_security_group.loki_nlb.id
          # NLB 보안 그룹에서 파드로 가는 트래픽을 컨트롤러가 백엔드 쪽 보안 그룹에 자동으로 허용해 줌
          "service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules" = "true"
        }
      }
    }
  })]

  # monitoring 네임스페이스는 prometheus 릴리스가 만듦.
  # LB 컨트롤러가 먼저 있어야 NLB 가 만들어지고, destroy 때도 Service 가 먼저 지워져 NLB 가 정리됨.
  # gp3 StorageClass 와 EBS CSI 애드온이 먼저 있어야 PVC 가 바인딩됨.
  depends_on = [
    helm_release.prometheus,
    helm_release.aws_lb_controller,
    kubernetes_storage_class_v1.gp3,
    aws_eks_addon.ebs_csi,
  ]
}
