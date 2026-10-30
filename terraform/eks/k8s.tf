# EKS 위에 올리는 구성: AWS Load Balancer Controller + FastAPI + nginx + Ingress(ALB)
# 요청 흐름: 인터넷 -> ALB(Ingress) -> nginx(리버스 프록시) -> fastapi -> RDS Proxy -> RDS (database.tf)

variable "fastapi_image" {
  description = "fastapi 이미지 (back-end/member 를 빌드해서 push 한 이미지, 예: <계정>/fastapi:member-api)"
  type        = string
}

variable "cors_origins" {
  description = "API 를 호출할 수 있는 프론트 주소 (쉼표로 구분). 기본값은 내 PC 에서 5500 포트로 연 프론트. * 는 모든 출처 허용"
  type        = string
  default     = "http://localhost:5500,http://127.0.0.1:5500"
}

variable "acm_certificate_arn" {
  description = "ACM 인증서 ARN. 지정하면 ALB 에 HTTPS(443) 리스너를 추가. 비우면 HTTP 80, 8000 만 사용"
  type        = string
  default     = ""
}

variable "fastapi_replicas" {
  type    = number
  default = 2
}

variable "nginx_replicas" {
  type    = number
  default = 2
}

data "aws_region" "current" {}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", data.aws_region.current.name]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", data.aws_region.current.name]
    }
  }
}

# ---------------------------------------------------------------
# IAM 역할 (IRSA): 컨트롤러가 AWS API(ALB)를 호출하기 위한 권한
# ---------------------------------------------------------------
locals {
  irsa_service_accounts = {
    lb-controller = "aws-load-balancer-controller"
    ebs-csi       = "ebs-csi-controller-sa"
  }
}

data "aws_iam_policy_document" "irsa_assume" {
  for_each = local.irsa_service_accounts

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:${each.value}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each = local.irsa_service_accounts

  name               = "${local.name_prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume[each.key].json
}

# LB 컨트롤러 v2.17.1 공식 정책 (lb-controller-iam-policy.json)
resource "aws_iam_policy" "lb_controller" {
  name   = "${local.name_prefix}-lb-controller"
  policy = file("${path.module}/lb-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.irsa["lb-controller"].name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# EBS CSI 드라이버가 EBS 볼륨을 만들고 붙이는 권한 (AWS 관리형 정책, 강사님 eksctl 의 --attach-policy-arn)
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.irsa["ebs-csi"].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# EBS CSI 드라이버 애드온 (강사님 eksctl create addon). 파드가 영구 디스크(PVC)를 쓰게 해 줌
# 서비스 계정 ebs-csi-controller-sa 는 애드온이 만들고, 위 역할(IRSA)을 연결함
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.67.2-eksbuild.1"
  service_account_role_arn = aws_iam_role.irsa["ebs-csi"].arn

  # 강사님 명령의 --force: 이미 있는 설정과 충돌하면 애드온 값으로 덮어씀
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_iam_role_policy_attachment.ebs_csi]
}

# gp3 StorageClass (강사님 gp3-storageclass.yaml). 기본 gp2 대신 gp3 볼륨을 만들게 하는 설정
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }

  # CSI 드라이버가 먼저 있어야 이 StorageClass 로 볼륨을 만들 수 있음
  depends_on = [aws_eks_addon.ebs_csi]
}

# ---------------------------------------------------------------
# AWS Load Balancer Controller(ALB)
# ---------------------------------------------------------------
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.17.1"

  # helm provider 3.x 문법: set 블록이 아니라 리스트 속성
  set = [
    {
      name  = "clusterName"
      value = module.eks.cluster_name
    },
    {
      name  = "region"
      value = data.aws_region.current.name
    },
    {
      name  = "vpcId"
      value = module.vpc.vpc_id
    },
    {
      name  = "serviceAccount.name"
      value = local.irsa_service_accounts["lb-controller"]
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.irsa["lb-controller"].arn
    },
    # 컨트롤러가 만드는 ALB에도 태그 강제
    {
      name  = "defaultTags.Owner"
      value = var.owner_tag
    },
    {
      name  = "defaultTags.Project"
      value = var.project_tag
    },
  ]

  # destroy 때 Ingress(ALB)와 컨트롤러가 먼저 지워져야 하므로 VPC 경로(NAT, 라우트 테이블)보다 나중에 만들어지도록 묶음
  # (경로가 먼저 지워지면 컨트롤러가 STS 에 닿지 못해 ALB 를 못 지우고 VPC 삭제가 막힘)
  depends_on = [module.eks, module.vpc, aws_route.private_nat_instance, aws_iam_role_policy_attachment.lb_controller]
}

# ---------------------------------------------------------------
# FastAPI
# ---------------------------------------------------------------
resource "kubernetes_deployment_v1" "fastapi" {
  metadata {
    name = "app-fastapi"
  }

  spec {
    replicas = var.fastapi_replicas

    selector {
      match_labels = { app = "app-fastapi" }
    }

    template {
      metadata {
        labels = { app = "app-fastapi" }
      }

      spec {
        # S3 접근 권한(IRSA)이 연결된 서비스 계정
        service_account_name = kubernetes_service_account_v1.fastapi.metadata[0].name

        container {
          name  = "fastapi"
          image = var.fastapi_image

          port {
            container_port = 8000
          }

          # DB: RDS Proxy 로 TLS 접속, 사용자/비밀번호는 Secrets Manager(앱 전용 사용자)에서 읽음
          # enable_database = false 이면 접속 정보가 없으므로 자리표시 값만 넣어 앱이 뜨게 함 (회원 API 는 500)
          dynamic "env" {
            for_each = var.enable_database ? tomap({
              DB_HOST       = module.database[0].proxy_endpoint
              DB_USER       = module.database[0].app_user_name
              DB_NAME       = module.database[0].database
              DB_SECRET_ARN = module.database[0].app_secret_arn
              DB_SSL        = "true"
            }) : tomap({ DB_PASSWORD = "database-disabled" })

            content {
              name  = env.key
              value = env.value
            }
          }

          env {
            name  = "CORS_ORIGINS"
            value = var.cors_origins
          }

          env {
            name  = "S3_BUCKET"
            value = aws_s3_bucket.files.bucket
          }

          env {
            name  = "AWS_DEFAULT_REGION"
            value = data.aws_region.current.name
          }

          readiness_probe {
            http_get {
              # DB 를 쓰는 모드는 DB 연결까지 확인(/), DB 를 끈 모드는 프로세스만 확인(/health)
              path = var.enable_database ? "/" : "/health"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
      }
    }
  }

  # 롤아웃 완료를 기다리지 않음: 준비 상태는 DB 초기화 Job 이 끝나야 되는데,
  # 기다리다 시간 초과로 실패하면 배포가 실패 상태로 남고 apply 가 중단된다
  wait_for_rollout = false

  # DB 초기화(테이블, 앱 전용 사용자)가 끝난 뒤에 파드를 띄움
  depends_on = [helm_release.aws_lb_controller, kubernetes_job_v1.db_init]
}

resource "kubernetes_service_v1" "fastapi" {
  metadata {
    name = "app-fastapi"
  }

  spec {
    selector = { app = "app-fastapi" }

    port {
      port        = 8000
      target_port = 8000
    }
  }

  depends_on = [helm_release.aws_lb_controller]
}

# ---------------------------------------------------------------
# nginx: fastapi 리버스 프록시
# ---------------------------------------------------------------
resource "kubernetes_config_map_v1" "nginx" {
  metadata {
    name = "nginx-conf"
  }

  data = {
    "default.conf" = <<-EOT
      # ALB 가 붙여 준 원래 프로토콜(http/https)을 fastapi 에 그대로 전달 (없으면 nginx 가 받은 값)
      map $http_x_forwarded_proto $forwarded_proto {
        default $http_x_forwarded_proto;
        ""      $scheme;
      }

      server {
        listen 80;

        # ALB 헬스체크용: fastapi 프로세스가 살아 있어야 200 (DB 상태와는 무관)
        location = /healthz {
          access_log off;
          proxy_pass http://app-fastapi:8000/health;
        }

        location / {
          proxy_pass http://app-fastapi:8000;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $forwarded_proto;
        }
      }
    EOT
  }
}

resource "kubernetes_deployment_v1" "nginx" {
  metadata {
    name = "nginx"
  }

  spec {
    replicas = var.nginx_replicas

    selector {
      match_labels = { app = "nginx" }
    }

    template {
      metadata {
        labels = { app = "nginx" }
      }

      spec {
        container {
          name  = "nginx"
          image = "nginx:1.27-alpine"

          port {
            container_port = 80
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 80
            }
            period_seconds = 5
          }

          volume_mount {
            name       = "conf"
            mount_path = "/etc/nginx/conf.d/default.conf"
            sub_path   = "default.conf"
            read_only  = true
          }
        }

        volume {
          name = "conf"
          config_map {
            name = kubernetes_config_map_v1.nginx.metadata[0].name
          }
        }
      }
    }
  }

  # nginx 준비 상태는 fastapi 가 준비되어야 하므로 롤아웃 완료를 기다리지 않음
  wait_for_rollout = false

  depends_on = [helm_release.aws_lb_controller]
}

resource "kubernetes_service_v1" "nginx" {
  metadata {
    name = "nginx"
  }

  spec {
    selector = { app = "nginx" }

    port {
      port        = 80
      target_port = 80
    }
  }

  depends_on = [helm_release.aws_lb_controller]
}

# ---------------------------------------------------------------
# Ingress -> ALB (internet-facing). 모든 경로를 nginx 로 전달
# ---------------------------------------------------------------
resource "kubernetes_ingress_v1" "app" {
  metadata {
    name = "${local.name_prefix}-ingress"

    annotations = merge(
      {
        "alb.ingress.kubernetes.io/load-balancer-name" = "${local.name_prefix}-alb"
        "alb.ingress.kubernetes.io/scheme"             = "internet-facing"
        "alb.ingress.kubernetes.io/target-type"        = "ip"
        "alb.ingress.kubernetes.io/subnets"            = join(",", module.vpc.public_subnets)
        "alb.ingress.kubernetes.io/healthcheck-path"   = "/healthz"
        "alb.ingress.kubernetes.io/tags"               = "Name=${local.name_prefix}-alb"
        # 리스너: HTTP 80, HTTP 8000, (인증서가 있으면) HTTPS 443. 모두 같은 nginx 로 전달
        "alb.ingress.kubernetes.io/listen-ports" = (
          var.acm_certificate_arn == ""
          ? jsonencode([{ HTTP = 80 }, { HTTP = 8000 }])
          : jsonencode([{ HTTP = 80 }, { HTTP = 8000 }, { HTTPS = 443 }])
        )
      },
      # ALB 액세스 로그를 S3 로그 버킷(logs.tf)의 alb/ 아래에 저장
      {
        "alb.ingress.kubernetes.io/load-balancer-attributes" = "access_logs.s3.enabled=true,access_logs.s3.bucket=${aws_s3_bucket.logs.id},access_logs.s3.prefix=alb"
      },
      # HTTPS(443)는 인증서가 있어야 만들 수 있음.
      # 8000 을 HTTP 로 계속 쓸 수 있도록 HTTP -> HTTPS 리다이렉트는 쓰지 않음
      var.acm_certificate_arn == "" ? {} : {
        "alb.ingress.kubernetes.io/certificate-arn" = var.acm_certificate_arn
      }
    )
  }

  spec {
    ingress_class_name = "alb"

    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.nginx.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  # ALB 주소가 할당될 때까지 대기
  wait_for_load_balancer = true

  # 버킷 정책이 먼저 있어야 ALB 가 로그 저장을 켤 수 있음
  depends_on = [helm_release.aws_lb_controller, aws_s3_bucket_policy.logs]
}

output "alb_hostname" {
  description = "접속 주소: http://<이 값>/  (FastAPI 문서: /docs)"
  value       = kubernetes_ingress_v1.app.status[0].load_balancer[0].ingress[0].hostname
}
