# ALB 로그를 S3 에서 읽어 Loki 로 보내는 Lambda(lambda-promtail)의 실행 역할
# - PDF 의 trust.json(Lambda 가 이 역할을 맡을 수 있음)과 권한 정책을 코드로 만든 것
# - Lambda 함수 본체, S3 호출 허가, S3 알림은 같은 파일 아래에 있음

# 신뢰 정책: Lambda 서비스가 이 역할을 맡을 수 있다 (PDF 의 trust.json)
data "aws_iam_policy_document" "alb_log_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_log_lambda" {
  name               = "${local.name_prefix}-alb-log-lambda"
  assume_role_policy = data.aws_iam_policy_document.alb_log_lambda_assume.json
}

# VPC 안에서 실행(네트워크 인터페이스 생성)과 CloudWatch Logs 기록에 필요한 AWS 관리형 정책
resource "aws_iam_role_policy_attachment" "alb_log_lambda_vpc" {
  role       = aws_iam_role.alb_log_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# 권한 정책 (PDF 의 s3-read.json): 로그 버킷의 alb/AWSLogs/ 아래 파일 읽기 + 버킷 목록 조회
data "aws_iam_policy_document" "alb_log_lambda_s3" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.logs.arn}/alb/AWSLogs/*"]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.logs.arn]
  }
}

resource "aws_iam_role_policy" "alb_log_lambda_s3" {
  name   = "read-alb-logs"
  role   = aws_iam_role.alb_log_lambda.id
  policy = data.aws_iam_policy_document.alb_log_lambda_s3.json
}

# ---------------------------------------------------------------
# Lambda 함수 (Grafana lambda-promtail): S3 의 ALB 로그를 읽어 Loki 로 보냄
# - zip 은 lambda/ 폴더에 직접 내려받아 둠 (안에는 Go 실행 파일 bootstrap 1개)
# - bootstrap 은 사용자 지정 런타임 방식이라 runtime=provided.al2023, handler=bootstrap, CPU=x86_64
# - 클러스터 밖에서 실행되므로 클러스터 안 주소(svc.cluster.local)는 못 쓰고 Loki 앞의 내부 NLB 주소로 보냄
# - S3 알림(새 로그 파일이 생기면 호출)과 호출 허가는 아래 함수 뒤에 있음
# ---------------------------------------------------------------

# Loki NLB 주소: LB 컨트롤러가 만든 것이라 Terraform 상태에 없어서 Service 에서 읽어 옴
# (loki 릴리스가 먼저 만들어져야 읽을 수 있으므로 depends_on 으로 apply 때까지 미룸)
data "kubernetes_service_v1" "loki_gateway" {
  metadata {
    name      = "loki-gateway"
    namespace = "monitoring"
  }

  depends_on = [helm_release.loki]
}

resource "aws_lambda_function" "alb_log_shipper" {
  function_name = "${local.name_prefix}-alb-log-shipper"
  role          = aws_iam_role.alb_log_lambda.arn

  runtime       = "provided.al2023"
  handler       = "bootstrap"
  architectures = ["x86_64"]

  filename         = "${path.module}/lambda/lambda-promtail-v1.0.2.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/lambda-promtail-v1.0.2.zip")

  # PDF 의 create-function 과 같은 값
  timeout     = 60
  memory_size = 256

  # 내부 NLB 에 닿으려면 같은 VPC 안에서 실행해야 함
  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.alb_log_lambda.id]
  }

  environment {
    variables = {
      # Loki 에 로그를 보낼 주소
      WRITE_ADDRESS = "http://${data.kubernetes_service_v1.loki_gateway.status[0].load_balancer[0].ingress[0].hostname}/loki/api/v1/push"
      # 모든 로그에 붙일 라벨: job=alb-logs, cluster=<클러스터 이름> (이름,값,이름,값 순서)
      EXTRA_LABELS = "job,alb-logs,cluster,${module.eks.cluster_name}"
      # 라벨 이름 앞에 __extra_ 접두사를 붙이지 않음
      OMIT_EXTRA_LABELS_PREFIX = "true"
      # 로그 한 줄 한 줄을 CloudWatch 에 출력하지 않음 (비용·소음 감소)
      PRINT_LOG_LINE = "false"
      # 라벨 정리: __aws_s3_lb 라벨을 loadbalancer 로 바꾸고, 나머지 __aws_* 라벨은 버림
      RELABEL_CONFIGS = jsonencode([
        { source_labels = ["__aws_s3_lb"], target_label = "loadbalancer", action = "replace" },
        { regex = "__aws_.*", action = "labeldrop" },
      ])
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.alb_log_lambda_vpc,
    aws_iam_role_policy.alb_log_lambda_s3,
  ]
}

# S3 가 이 Lambda 를 호출할 수 있도록 허가 (PDF 의 add-permission)
resource "aws_lambda_permission" "alb_log_s3" {
  statement_id   = "s3-invoke-alb-logs"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.alb_log_shipper.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.logs.arn
  source_account = data.aws_caller_identity.current.account_id
}

# 새 ALB 로그 파일이 생기면 Lambda 호출
# - prefix 는 PDF 표의 'PRE alb/' 경우: alb/AWSLogs/<계정>/elasticloadbalancing/
#   (vpc-flow/, s3-access/ 는 제외, ELBAccessLogTestFile 은 이 경로 밖이라 제외)
# - suffix 는 PDF 의 notify.json 과 같이 .log.gz (압축된 ALB 로그 파일만)
# - 이 리소스는 버킷의 알림 설정 전체를 관리하므로 CLI 로 따로 건드리지 않는다
resource "aws_s3_bucket_notification" "alb_logs" {
  bucket = aws_s3_bucket.logs.id

  lambda_function {
    id                  = "alb-logs-to-loki"
    lambda_function_arn = aws_lambda_function.alb_log_shipper.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "alb/AWSLogs/${data.aws_caller_identity.current.account_id}/elasticloadbalancing/"
    filter_suffix       = ".log.gz"
  }

  depends_on = [aws_lambda_permission.alb_log_s3]
}
