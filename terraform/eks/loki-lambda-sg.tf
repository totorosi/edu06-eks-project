# S3 에 쌓인 ALB 로그를 Lambda 가 읽어 Loki 로 보내는 구성에 쓰는 보안 그룹 두 개
# 흐름: S3(alb/) -> S3 알림 -> Lambda -> Loki 앞의 내부 NLB(TCP 80) -> Loki gateway 파드
# 보안 그룹 설명(description)은 영어/ASCII 만 허용되므로 영어로 씀

# ---------------------------------------------------------------
# Loki NLB 용 보안 그룹
# - 인바운드: VPC 안(Lambda 등)에서 오는 TCP 80 (Loki push)
# - 아웃바운드: 전체 (NLB -> Loki gateway 파드)
# ---------------------------------------------------------------
resource "aws_security_group" "loki_nlb" {
  name        = "${local.name_prefix}-loki-nlb-sg"
  description = "Loki NLB: allow Loki push from inside the VPC"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.name_prefix}-loki-nlb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "loki_nlb_http" {
  security_group_id = aws_security_group.loki_nlb.id
  cidr_ipv4         = module.vpc.vpc_cidr_block
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "Loki push from VPC (Lambda)"
}

resource "aws_vpc_security_group_egress_rule" "loki_nlb_all" {
  security_group_id = aws_security_group.loki_nlb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "NLB to Loki gateway pods"
}

# ---------------------------------------------------------------
# ALB 로그 -> Loki 전송 Lambda 용 보안 그룹
# - 인바운드: 없음 (S3 알림은 AWS 가 Lambda 를 직접 호출하므로 네트워크 문이 필요 없음)
# - 아웃바운드: 전체 (Loki NLB TCP 80, S3 게이트웨이 엔드포인트 TCP 443)
# ---------------------------------------------------------------
resource "aws_security_group" "alb_log_lambda" {
  name        = "${local.name_prefix}-alb-log-lambda-sg"
  description = "Lambda that ships ALB logs from S3 to Loki"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.name_prefix}-alb-log-lambda-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "alb_log_lambda_all" {
  security_group_id = aws_security_group.alb_log_lambda.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "To Loki NLB (TCP 80) and S3 gateway endpoint (TCP 443)"
}
