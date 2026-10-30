# 모니터링: kube-prometheus-stack(Prometheus + Grafana) + Grafana 가 CloudWatch 를 읽는 IAM 역할(IRSA)
# Grafana 는 외부에 열지 않음. 접속은 kubectl port-forward 로만 (outputs 의 grafana_port_forward 참고)

# ---------------------------------------------------------------
# Grafana 가 CloudWatch 지표를 조회하는 읽기 전용 권한
# (강사님 안내의 정책과 같은 내용을 <접두사> 이름으로 따로 만듦: 공용 계정이라 이름이 겹치지 않게)
# 강사님 최신 정책: 지표 조회 + 로그 조회(CloudWatch Logs) + EC2 태그 조회, 전부 읽기 전용
# ---------------------------------------------------------------
data "aws_iam_policy_document" "grafana_cloudwatch" {
  statement {
    sid = "AllowCloudWatchGetMetrics"
    actions = [
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:GetInsightRuleReport",
    ]
    resources = ["*"]
  }

  statement {
    sid = "AllowCloudWatchLogs"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:GetLogGroupFields",
      "logs:GetQueryResults",
      "logs:StartQuery",
      "logs:StopQuery",
    ]
    resources = ["*"]
  }

  statement {
    sid = "AllowEC2AndTagging"
    actions = [
      "ec2:DescribeTags",
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "grafana_cloudwatch" {
  name   = "${local.name_prefix}-grafana-cloudwatch"
  policy = data.aws_iam_policy_document.grafana_cloudwatch.json
}

# 서비스 계정 monitoring/prometheus-grafana 만 이 역할을 맡을 수 있음 (강사님 eksctl 명령이 하던 일)
data "aws_iam_policy_document" "grafana_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:monitoring:prometheus-grafana"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "grafana" {
  name               = "${local.name_prefix}-grafana-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.grafana_assume.json
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch" {
  role       = aws_iam_role.grafana.name
  policy_arn = aws_iam_policy.grafana_cloudwatch.arn
}

# ---------------------------------------------------------------
# Alloy 가 CloudWatch 지표를 읽는 읽기 전용 권한 (강사님 alloy-cw-policy.json 과 같은 내용)
# Grafana 역할은 서비스 계정이 달라 재사용할 수 없어서 따로 만듦
# ---------------------------------------------------------------
data "aws_iam_policy_document" "alloy_cloudwatch" {
  statement {
    sid = "CloudWatchRead"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ResourceDiscovery"
    actions   = ["tag:GetResources"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "alloy_cloudwatch" {
  name   = "${local.name_prefix}-alloy-cloudwatch"
  policy = data.aws_iam_policy_document.alloy_cloudwatch.json
}

# 서비스 계정 monitoring/alloy-metrics 만 이 역할을 맡을 수 있음 (강사님 alloy-trust.json 과 같은 이름)
data "aws_iam_policy_document" "alloy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:monitoring:alloy-metrics"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alloy" {
  name               = "${local.name_prefix}-alloy-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.alloy_assume.json
}

resource "aws_iam_role_policy_attachment" "alloy_cloudwatch" {
  role       = aws_iam_role.alloy.name
  policy_arn = aws_iam_policy.alloy_cloudwatch.arn
}

# ---------------------------------------------------------------
# Grafana 관리자 비밀번호: 기본값(prom-operator)을 쓰지 않고 임의로 만든다
# 확인: terraform output -raw grafana_admin_password
# ---------------------------------------------------------------
resource "random_password" "grafana_admin" {
  length  = 20
  special = false
}

# ---------------------------------------------------------------
# kube-prometheus-stack (강사님의 helm install 에 해당)
# - 서비스 계정을 만들면서 역할 ARN 을 붙임 (강사님 values.yaml 의 serviceAccount 부분)
# - Grafana 에 CloudWatch 데이터 소스를 미리 등록 (인증은 서비스 계정의 역할을 자동 사용)
# ---------------------------------------------------------------
resource "helm_release" "prometheus" {
  name             = "prometheus"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "92.11.0"
  timeout          = 900

  values = [yamlencode({
    grafana = {
      serviceAccount = {
        create = true
        name   = "prometheus-grafana"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.grafana.arn
        }
      }

      additionalDataSources = [{
        name   = "CloudWatch"
        uid    = "cloudwatch"
        type   = "cloudwatch"
        access = "proxy"
        jsonData = {
          authType      = "default"
          defaultRegion = data.aws_region.current.name
        }
        }, {
        # 강사님 values.yaml 의 Loki 데이터 소스 (loki.tf 의 gateway 서비스 주소)
        name   = "Loki"
        uid    = "loki"
        type   = "loki"
        access = "proxy"
        url    = "http://loki-gateway.monitoring.svc.cluster.local"
        jsonData = {
          maxLines = 1000
        }
      }]
    }

    # 강사님 PDF(1단계 Step 2)의 Prometheus 설정
    prometheus = {
      prometheusSpec = {
        # false: ServiceMonitor/PodMonitor 에 release=prometheus 라벨이 없어도 모든 네임스페이스에서 수집
        # (뒤 실습에서 fastapi/nginx 용 ServiceMonitor 라벨 오타로 연동이 실패하는 것을 막음)
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false

        # 지표 보존 기간 (기본 10일). 영구 볼륨을 쓰지 않아 파드가 재시작되면 지표는 사라짐
        retention = "7d"

        # Alloy 가 remote write 로 지표를 밀어 넣을 수 있게 수신 허용
        enableRemoteWriteReceiver = true
      }
    }

    # EKS 가 관리하는 컨트롤 플레인 구성요소는 수집할 수 없으므로 끔
    # (kubeProxy 는 지금 수집이 되고 있어서 그대로 둠)
    kubeEtcd              = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeControllerManager = { enabled = false }
  })]

  # 비밀번호는 계획 출력에 보이지 않도록 따로 전달
  set_sensitive = [
    {
      name  = "grafana.adminPassword"
      value = random_password.grafana_admin.result
    },
  ]

  # LB 컨트롤러 웹훅이 준비되기 전에 Service 가 만들어져 거부되는 것을 막음
  depends_on = [module.eks, helm_release.aws_lb_controller, aws_iam_role_policy_attachment.grafana_cloudwatch]
}

# ---------------------------------------------------------------
# Alloy (강사님의 helm install alloy-metrics 에 해당)
# - CloudWatch 지표를 읽어 위 Prometheus 로 remote write (설정: alloy-config.alloy.tftpl)
# - CloudWatch 수집은 한 번만 돌아야 하므로 Deployment 1개 (기본값 DaemonSet 은 노드마다 중복 수집)
# - 서비스 계정 alloy-metrics 에 IAM 역할을 붙임 (위 alloy 역할의 신뢰 대상과 같은 이름)
# ---------------------------------------------------------------
resource "helm_release" "alloy_metrics" {
  name       = "alloy-metrics"
  namespace  = "monitoring"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = "1.14.3"

  values = [yamlencode({
    controller = {
      type     = "deployment"
      replicas = 1
    }

    serviceAccount = {
      create = true
      name   = "alloy-metrics"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.alloy.arn
      }
    }

    alloy = {
      configMap = {
        create = true
        content = templatefile("${path.module}/alloy-config.alloy.tftpl", {
          region       = data.aws_region.current.name
          cluster_name = module.eks.cluster_name
          owner_tag    = var.owner_tag
        })
      }
    }
  })]

  # monitoring 네임스페이스는 prometheus 릴리스가 만듦
  depends_on = [helm_release.prometheus, helm_release.aws_lb_controller, aws_iam_role_policy_attachment.alloy_cloudwatch]
}

output "grafana_admin_password" {
  description = "Grafana 관리자(admin) 비밀번호. terraform output -raw grafana_admin_password"
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "grafana_port_forward" {
  description = "Grafana 접속: 이 명령을 실행해 두고 브라우저에서 http://localhost:3000 (아이디 admin)"
  value       = "kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
}
