# RDS 인스턴스 타입 조회 예시:
# aws rds describe-orderable-db-instance-options \
#     --engine mysql \
#     --region ap-south-1 \
#     --query "OrderableDBInstanceOptions[].DBInstanceClass" \
#     --output text | tr '\t' '\n' | sort -u

# EC2 인스턴스 타입 조회 예시
# aws ec2 describe-instance-type-offerings \
#     --location-type region \
#     --region ap-south-1 \
#     --query "InstanceTypeOfferings[].InstanceType" \
#     --output text | tr '\t' '\n' | sort -u

locals {
  region            = var.region
  vpc_id            = var.vpc_id
  tag_header        = var.tag_header
  db_subnets_ids    = join(",", var.db_subnet_ids)
  mysql_sg_id       = var.mysql_sg_id
  owner             = var.owner
  database          = var.database
  user_name         = var.user_name
  app_user_name     = var.app_user_name
  engine_version    = "8.4.11" # 시드니에서 db.t4g.micro 단일 인스턴스 지원 확인됨
  db_instance_class = "db.t4g.micro"
  multi_az          = false # true 로 바꾸면 대기(standby) 인스턴스가 하나 더 생겨 비용이 약 2배
}
