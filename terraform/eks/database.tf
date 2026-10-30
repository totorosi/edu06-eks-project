# RDS(MySQL 단일 DB 인스턴스 + RDS Proxy) 연동
# 흐름: fastapi -> RDS Proxy(TLS) -> RDS 인스턴스. 테이블/앱 전용 사용자 생성은 쿠버네티스 Job 이 한 번 실행.
# 받은 모듈은 terraform/modules/database 에 있음 (이름은 <접두사>-* 로 바꾸고 배스천 SSH 초기화는 Job 으로 대체)
# enable_database = false 이면 이 파일의 리소스는 하나도 만들어지지 않음 (가벼운 모드)

# ---------------------------------------------------------------
# 보안 그룹: 클러스터와 RDS Proxy 가 같이 사용
# ---------------------------------------------------------------
resource "aws_security_group" "mysql" {
  count = var.enable_database ? 1 : 0

  name        = "${local.name_prefix}-mysql-sg"
  description = "RDS MySQL instance and RDS Proxy"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.name_prefix}-mysql-sg"
  }
}

# EKS 노드(= fastapi 파드, 초기화 Job)에서 오는 3306
resource "aws_vpc_security_group_ingress_rule" "mysql_from_nodes" {
  count = var.enable_database ? 1 : 0

  security_group_id            = aws_security_group.mysql[0].id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "EKS nodes to MySQL"
}

# RDS Proxy -> DB 인스턴스 (같은 보안 그룹을 쓰므로 자기 자신에서 오는 3306)
resource "aws_vpc_security_group_ingress_rule" "mysql_from_self" {
  count = var.enable_database ? 1 : 0

  security_group_id            = aws_security_group.mysql[0].id
  referenced_security_group_id = aws_security_group.mysql[0].id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "RDS Proxy to MySQL"
}

# 비밀번호 로테이션 Lambda -> DB (Lambda 보안 그룹은 모듈이 만들기 때문에 모듈 생성 후 규칙을 추가)
resource "aws_vpc_security_group_ingress_rule" "mysql_from_rotation_lambda" {
  count = var.enable_database ? 1 : 0

  security_group_id            = aws_security_group.mysql[0].id
  referenced_security_group_id = module.database[0].lambda_sg_id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "Rotation Lambda to MySQL"
}

resource "aws_vpc_security_group_egress_rule" "mysql_to_self" {
  count = var.enable_database ? 1 : 0

  security_group_id            = aws_security_group.mysql[0].id
  referenced_security_group_id = aws_security_group.mysql[0].id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "RDS Proxy to MySQL"
}

# RDS Proxy 가 Secrets Manager 에서 비밀번호를 읽기 위한 443 (NAT 인스턴스 경유)
resource "aws_vpc_security_group_egress_rule" "mysql_to_https" {
  count = var.enable_database ? 1 : 0

  security_group_id = aws_security_group.mysql[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "RDS Proxy to Secrets Manager"
}

# ---------------------------------------------------------------
# 받은 RDS 모듈 호출
# ---------------------------------------------------------------
module "database" {
  count  = var.enable_database ? 1 : 0
  source = "../modules/database"

  vpc_id        = module.vpc.vpc_id
  region        = data.aws_region.current.name
  mysql_sg_id   = aws_security_group.mysql[0].id
  db_subnet_ids = module.vpc.private_subnets
  tag_header    = "${local.name_prefix}-"
  owner         = local.name_prefix
  database      = "testdb"
  user_name     = "${local.name_prefix}admin" # 마스터 계정 (앱은 사용하지 않음)
  app_user_name = "${local.name_prefix}_app"  # 앱 전용 계정

  # 로테이션 Lambda 와 RDS Proxy 가 Secrets Manager 에 나갈 수 있도록 NAT 경로가 먼저 있어야 함
  depends_on = [aws_route.private_nat_instance]
}

# ---------------------------------------------------------------
# IAM: fastapi 는 앱 전용 비밀만, 초기화 Job 은 마스터/앱 비밀을 읽을 수 있음
# ---------------------------------------------------------------
data "aws_iam_policy_document" "fastapi_db_secret" {
  count = var.enable_database ? 1 : 0

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [module.database[0].app_secret_arn]
  }
}

resource "aws_iam_role_policy" "fastapi_db_secret" {
  count = var.enable_database ? 1 : 0

  name   = "${local.name_prefix}-fastapi-db-secret"
  role   = aws_iam_role.fastapi.id
  policy = data.aws_iam_policy_document.fastapi_db_secret[0].json
}

data "aws_iam_policy_document" "db_init_assume" {
  count = var.enable_database ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:default:${local.name_prefix}-db-init"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "db_init" {
  count = var.enable_database ? 1 : 0

  name               = "${local.name_prefix}-db-init"
  assume_role_policy = data.aws_iam_policy_document.db_init_assume[0].json
}

data "aws_iam_policy_document" "db_init_secrets" {
  count = var.enable_database ? 1 : 0

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [module.database[0].master_secret_arn, module.database[0].app_secret_arn]
  }
}

resource "aws_iam_role_policy" "db_init_secrets" {
  count = var.enable_database ? 1 : 0

  name   = "${local.name_prefix}-db-init-secrets"
  role   = aws_iam_role.db_init[0].id
  policy = data.aws_iam_policy_document.db_init_secrets[0].json
}

resource "kubernetes_service_account_v1" "db_init" {
  count = var.enable_database ? 1 : 0

  metadata {
    name = "${local.name_prefix}-db-init"

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.db_init[0].arn
    }
  }

  depends_on = [module.eks]
}

# ---------------------------------------------------------------
# 초기화 Job: 테이블 생성 + 앱 전용 사용자 생성 (database/init_rds.py, database/query.sql)
# fastapi 이미지(boto3, pymysql 포함)를 그대로 사용. 한 번 성공하면 끝이고 여러 번 실행해도 안전함.
# 다시 실행하려면: terraform apply -replace='kubernetes_job_v1.db_init[0]'
# ---------------------------------------------------------------
resource "kubernetes_config_map_v1" "db_init" {
  count = var.enable_database ? 1 : 0

  metadata {
    name = "db-init"
  }

  data = {
    "init_rds.py" = file("${path.module}/../../database/init_rds.py")
    "query.sql"   = file("${path.module}/../../database/query.sql")
  }
}

resource "kubernetes_job_v1" "db_init" {
  count = var.enable_database ? 1 : 0

  metadata {
    name = "${local.name_prefix}-db-init"
  }

  spec {
    backoff_limit = 4

    template {
      metadata {
        labels = { app = "db-init" }
      }

      spec {
        restart_policy       = "Never"
        service_account_name = kubernetes_service_account_v1.db_init[0].metadata[0].name

        container {
          name    = "init"
          image   = var.fastapi_image
          command = ["python", "/init/init_rds.py"]

          env {
            name  = "MASTER_SECRET_ARN"
            value = module.database[0].master_secret_arn
          }

          env {
            name  = "APP_SECRET_ARN"
            value = module.database[0].app_secret_arn
          }

          env {
            name  = "AWS_DEFAULT_REGION"
            value = data.aws_region.current.name
          }

          volume_mount {
            name       = "init"
            mount_path = "/init"
            read_only  = true
          }
        }

        volume {
          name = "init"
          config_map {
            name = kubernetes_config_map_v1.db_init[0].metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "25m"
  }

  depends_on = [
    module.database,
    aws_vpc_security_group_ingress_rule.mysql_from_nodes,
    aws_iam_role_policy.db_init_secrets,
    helm_release.aws_lb_controller,
  ]
}

output "db_proxy_endpoint" {
  description = "RDS Proxy 쓰기 엔드포인트 (fastapi 가 접속). enable_database = false 이면 null"
  value       = var.enable_database ? module.database[0].proxy_endpoint : null
}
