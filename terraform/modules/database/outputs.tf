output "db_endpoint" {
  description = "RDS DB 인스턴스 주소 (초기화 Job 이 직접 접속)"
  value       = aws_db_instance.mysql.address
}

output "proxy_endpoint" {
  description = "RDS Proxy 쓰기 엔드포인트 (앱이 접속)"
  value       = aws_db_proxy.proxy.endpoint
}

output "master_secret_arn" {
  description = "마스터 계정 비밀 (30일마다 자동 변경)"
  value       = aws_secretsmanager_secret.mysql_secrets_manager.arn
}

output "app_secret_arn" {
  description = "앱 전용 사용자 비밀"
  value       = aws_secretsmanager_secret.mysql_app_secrets_manager.arn
}

output "lambda_sg_id" {
  description = "로테이션 Lambda 보안 그룹 (DB 보안 그룹에서 3306 허용 필요)"
  value       = aws_security_group.lambda_sg.id
}

output "app_user_name" {
  value = local.app_user_name
}

output "database" {
  value = local.database
}
