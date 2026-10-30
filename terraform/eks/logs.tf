# S3 로그 저장소: 버킷 하나에 접두사로 구분해서 모은다
#   alb/        ALB 액세스 로그 (ALB 가 받은 요청 기록)
#   vpc-flow/   VPC Flow Logs (VPC 안 네트워크 트래픽의 허용/거부 기록)
#   s3-access/  파일 버킷(<접두사>-files) 서버 액세스 로그 (누가 어떤 객체를 읽고 썼는지)
# EKS 컨트롤 플레인 로그는 CloudWatch 로 가고 있어 여기에 넣지 않음. CloudTrail 은 공용 계정이라
# 다른 학생의 API 호출까지 함께 담겨서 만들지 않음.

variable "log_retention_days" {
  description = "S3 로그를 보관하는 일수. 지나면 자동 삭제 (용량·비용이 계속 쌓이지 않게)"
  type        = number
  default     = 14
}

data "aws_caller_identity" "current" {}

# ALB 액세스 로그를 쓰는 주체는 리전별 ELB 서비스 계정(시드니는 고정값)이라 자동으로 조회
data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket" "logs" {
  bucket = "${local.name_prefix}-logs"

  # destroy 때 쌓인 로그가 남아 있어도 버킷을 지울 수 있게 함
  force_destroy = true

  tags = {
    Name = "${local.name_prefix}-logs"
  }
}

# 외부 공개 전부 차단
resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 서버 액세스 로그는 KMS 암호화 버킷에 쓸 수 없어서 S3 관리형(AES256)으로 암호화
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }
  }
}

# 로그를 쓰는 AWS 서비스 3개만 이 버킷에 쓸 수 있게 허용
data "aws_iam_policy_document" "logs" {
  statement {
    sid       = "AlbAccessLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
  }

  statement {
    sid       = "VpcFlowLogsWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/vpc-flow/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "VpcFlowLogsAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "S3ServerAccessLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/s3-access/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    # 파일 버킷(<접두사>-files)이 보내는 로그만 허용
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.files.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json

  # 공개 차단 설정과 정책을 동시에 바꾸면 S3 가 충돌을 내서 순서를 고정
  depends_on = [aws_s3_bucket_public_access_block.logs]
}

# ---------------------------------------------------------------
# VPC Flow Logs -> S3 (vpc-flow/)
# ---------------------------------------------------------------
resource "aws_flow_log" "vpc" {
  vpc_id                   = module.vpc.vpc_id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = "${aws_s3_bucket.logs.arn}/vpc-flow/"
  max_aggregation_interval = 600

  tags = {
    Name = "${local.name_prefix}-vpc-flow"
  }

  depends_on = [aws_s3_bucket_policy.logs]
}

# ---------------------------------------------------------------
# 파일 버킷(<접두사>-files) 서버 액세스 로그 -> S3 (s3-access/)
# ---------------------------------------------------------------
resource "aws_s3_bucket_logging" "files" {
  bucket = aws_s3_bucket.files.id

  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access/${aws_s3_bucket.files.id}/"

  depends_on = [aws_s3_bucket_policy.logs]
}

output "logs_bucket" {
  description = "S3 로그 버킷 (alb/, vpc-flow/, s3-access/ 접두사로 구분)"
  value       = aws_s3_bucket.logs.bucket
}
