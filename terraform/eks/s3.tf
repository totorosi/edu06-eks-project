# 파일 업로드/다운로드용 S3 버킷 + fastapi 파드가 이 버킷만 읽고 쓸 수 있는 권한(IRSA)

resource "aws_s3_bucket" "files" {
  # 이름 규칙: <접두사>-<리소스명> (버킷 이름은 전 세계 공유라서 사용 가능 여부 확인함)
  bucket = "${local.name_prefix}-files"

  tags = {
    Name = "${local.name_prefix}-files"
  }
}

# 외부 공개 전부 차단
resource "aws_s3_bucket_public_access_block" "files" {
  bucket = aws_s3_bucket.files.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# fastapi 서비스 계정(default/app-fastapi)이 맡을 IAM 역할
data "aws_iam_policy_document" "fastapi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:default:app-fastapi"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fastapi" {
  name               = "${local.name_prefix}-fastapi"
  assume_role_policy = data.aws_iam_policy_document.fastapi_assume.json
}

# 이 버킷에 대해서만 목록 조회/업로드/다운로드/삭제 허용
data "aws_iam_policy_document" "fastapi_s3" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.files.arn]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.files.arn}/*"]
  }
}

resource "aws_iam_role_policy" "fastapi_s3" {
  name   = "${local.name_prefix}-fastapi-s3"
  role   = aws_iam_role.fastapi.id
  policy = data.aws_iam_policy_document.fastapi_s3.json
}

resource "kubernetes_service_account_v1" "fastapi" {
  metadata {
    name = "app-fastapi"

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.fastapi.arn
    }
  }

  depends_on = [module.eks]
}

output "s3_bucket" {
  description = "파일 업로드/다운로드용 버킷"
  value       = aws_s3_bucket.files.bucket
}
