# ---------------------------------------------------------------
# Grafana 대시보드 "EKS Integrated Logs" (PDF 9장)
# - 화면에서 만들면 Grafana 파드가 다시 뜰 때 사라지므로(영구 저장소 없음) ConfigMap 으로 등록
# - grafana_dashboard 라벨이 붙은 ConfigMap 은 대시보드 사이드카(모든 네임스페이스 감시)가 읽어서
#   Grafana 에 자동 등록함 (Grafana 재시작 불필요)
# - 패널 34개 / 변수 4개(namespace, pod, node, search) 는 dashboards/ 의 JSON 안에 있음
# - Row 2(RDS)는 enable_database = true 일 때만 로그 그룹이 있음
# ---------------------------------------------------------------
resource "kubernetes_config_map_v1" "grafana_dashboard_logs" {
  metadata {
    name      = "grafana-dashboard-eks-logs"
    namespace = "monitoring"

    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "eks-integrated-logs.json" = templatefile("${path.module}/dashboards/eks-integrated-logs.json.tftpl", {
      region      = data.aws_region.current.name
      account_id  = data.aws_caller_identity.current.account_id
      cluster     = module.eks.cluster_name
      name_prefix = local.name_prefix
    })
  }

  # monitoring 네임스페이스는 prometheus 릴리스가 만듦
  depends_on = [helm_release.prometheus]
}
