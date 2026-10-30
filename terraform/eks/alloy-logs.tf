# ---------------------------------------------------------------
# Alloy 로그 수집 설정 ConfigMap (강사님의 kubectl create configmap alloy-logs-config 에 해당)
# - 설정 파일은 alloy-logs.alloy. 키 이름은 PDF 와 같은 config.alloy
# - Alloy 로그 수집기(DaemonSet) 설치 단계에서 이 ConfigMap 을 읽도록 연결함
# ---------------------------------------------------------------
resource "kubernetes_config_map_v1" "alloy_logs" {
  metadata {
    name      = "alloy-logs-config"
    namespace = "monitoring"
  }

  data = {
    "config.alloy" = file("${path.module}/alloy-logs.alloy")
  }

  # monitoring 네임스페이스는 prometheus 릴리스가 만듦
  depends_on = [helm_release.prometheus]
}

# ---------------------------------------------------------------
# Alloy 로그 수집기 (강사님의 alloy-logs-values.yaml + helm install 에 해당)
# - 노드마다 1개(DaemonSet)가 그 노드의 파드 로그와 systemd journal 을 읽어 Loki 로 보냄
# - 지표용 alloy-metrics(Deployment 1개)와는 별개의 릴리스
# ---------------------------------------------------------------
resource "helm_release" "alloy_logs" {
  name       = "alloy-logs"
  namespace  = "monitoring"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = "1.14.3"

  values = [yamlencode({
    controller = {
      type        = "daemonset"
      tolerations = [{ operator = "Exists" }] # taint 가 있는 노드에도 배치
    }

    serviceAccount = {
      create = true
      name   = "alloy-logs"
    }

    alloy = {
      configMap = {
        create = false # 위 ConfigMap 을 그대로 사용
        name   = kubernetes_config_map_v1.alloy_logs.metadata[0].name
        key    = "config.alloy"
      }

      # 노드의 /var/log (파드 로그, journal)를 읽기 전용으로 마운트
      mounts = {
        varlog = true
      }

      # alloy-logs.alloy 의 sys.env("NODE_NAME"), sys.env("CLUSTER_NAME")
      extraEnv = [
        {
          name = "NODE_NAME"
          valueFrom = {
            fieldRef = { fieldPath = "spec.nodeName" }
          }
        },
        {
          name  = "CLUSTER_NAME"
          value = module.eks.cluster_name
        },
      ]

      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "512Mi" }
      }
    }

    serviceMonitor = {
      enabled = true # Prometheus 가 이 Alloy 의 지표를 수집
    }
  })]

  # Loki 가 먼저 떠 있어야 전송이 바로 성공함
  depends_on = [helm_release.prometheus, helm_release.loki, kubernetes_config_map_v1.alloy_logs]
}
