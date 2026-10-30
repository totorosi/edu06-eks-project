# EKS 모니터링·로깅 실습 프로젝트

회원 관리 API(FastAPI)와 정적 프런트를 **AWS EKS**에 올리고, 그 위에 **지표(Prometheus + Grafana)와 로그(Loki)** 를 한 화면에서 보는 구성을 **Terraform 한 번으로** 만듭니다.
강의 자료 두 가지(「1단계 Prometheus & Grafana 스택 설치」, 「EKS 통합 메트릭 대시보드 구축 실습」)의 `helm install`, `aws iam …` 같은 손작업을 이 저장소의 Terraform 코드로 옮긴 것이고, 로그 수집 부분은 직접 덧붙였습니다.

> 이 저장소에는 계정번호, 비밀번호, 내 IP, 이름·태그 값이 **들어 있지 않습니다.** 그런 값은 아래 [값 넣기](#값-넣기-git-에-올라가지-않는-것)처럼 `terraform.tfvars`, `backend.hcl`, `.env` 에서 받습니다.

## 구성

```
인터넷 ─▶ ALB(Ingress) ─▶ nginx ─▶ FastAPI ─▶ RDS Proxy ─▶ RDS MySQL      (프라이빗 서브넷의 EKS 노드)
                │                     └────▶ S3 (파일 업로드, IRSA 권한)
                └─ 액세스 로그 ─▶ S3 logs 버킷 ─▶ Lambda(lambda-promtail) ─▶ 내부 NLB ─▶ Loki

[지표]  CloudWatch(ALB·EC2·RDS) ─▶ Alloy(alloy-metrics) ─▶ Prometheus ─┐
        kubelet · node-exporter · kube-state-metrics ─────────────────┤──▶ Grafana
[로그]  Pod/노드 로그 ─▶ Alloy(alloy-logs, DaemonSet) ─▶ Loki ─────────┤
        K8s 이벤트 ─▶ Alloy ─▶ Loki                                    │
        EKS 컨트롤 플레인 · RDS 슬로우쿼리/에러 ─▶ CloudWatch Logs ────┘
```

## 폴더

```
.
├── back-end/member        FastAPI 회원 API (Dockerfile 포함)
├── front-end/member       정적 화면 (common.js 한 곳에서 API 주소 지정)
├── database               query.sql(로컬 초기화), init_rds.py(RDS 초기화 Job 이 사용)
├── docker-compose.yaml    로컬 실행용 (MySQL + FastAPI)
└── terraform
    ├── main.tf            EC2 1대 + 보안 그룹 (기본 VPC, 가벼운 별도 스택)
    ├── modules/database   RDS MySQL, RDS Proxy, 비밀번호 로테이션
    └── eks                ★ 본 구성: VPC, EKS, 앱, 모니터링, 로깅
        ├── main.tf        EKS 클러스터·노드 그룹, 변수, 상태 백엔드
        ├── network.tf     VPC, 서브넷, NAT 인스턴스
        ├── k8s.tf         AWS LB Controller, nginx, FastAPI, Ingress(ALB)
        ├── database.tf    RDS 모듈 호출, DB 초기화 Job, RDS 용 IAM
        ├── s3.tf          파일 버킷 + FastAPI 의 S3 권한(IRSA)
        ├── monitoring.tf  kube-prometheus-stack, Grafana/Alloy IAM, alloy-metrics
        ├── alloy-config.alloy.tftpl   CloudWatch 지표 수집 + K8s 이벤트 설정
        ├── loki.tf        Loki (단일 바이너리, gp3 디스크, 내부 NLB 게이트웨이)
        ├── alloy-logs.tf / alloy-logs.alloy   Pod·노드 로그 수집(DaemonSet)
        ├── logs.tf        로그 S3 버킷(alb/, vpc-flow/, s3-access/), 수명 주기
        ├── alb-log-lambda.tf   ALB 로그 → Loki 로 보내는 Lambda 와 S3 알림
        ├── loki-lambda-sg.tf   위 Lambda 와 Loki NLB 용 보안 그룹
        ├── grafana-dashboard.tf + dashboards/   로그 대시보드(ConfigMap 으로 등록)
        └── *.example      값 넣기용 예시 파일
```

## 준비물

| 도구 | 용도 |
|---|---|
| Terraform 1.10 이상 | `terraform/eks` (S3 자체 잠금 때문) |
| AWS CLI v2 + 자격 증명 | 배포, `kubeconfig` 만들기 |
| kubectl | 클러스터 확인, Grafana 접속(port-forward) |
| Docker | 로컬 실행, 이미지 빌드·push |
| jq (선택) | Grafana API 응답 정리 |

미리 만들어 둘 것: **상태 저장용 S3 버킷**(버전 관리 켜기 권장), 이미지를 올릴 **Docker Hub 저장소**(공개), `terraform/` 스택을 쓴다면 **EC2 키 페어**.

## 값 넣기 (git 에 올라가지 않는 것)

개인·계정에 묶인 값은 모두 **환경 설정으로 분리**했습니다. 예시 파일을 복사해서 채우세요.

| 파일 | 담는 값 | 예시 파일 |
|---|---|---|
| `terraform/eks/terraform.tfvars` | 이름 접두사, Owner·Project 태그, EKS API 허용 IP, 이미지 이름 | `terraform.tfvars.example` |
| `terraform/eks/backend.hcl` | 상태 저장 S3 버킷 이름 | `backend.hcl.example` |
| `terraform/terraform.tfvars` | 위와 같은 이름·태그, 키 페어 이름, SSH 허용 IP | `terraform.tfvars.example` |
| `.env` | 로컬 DB 비밀번호·계정, 이미지 이름 | `.env.example` |

```bash
cp terraform/eks/terraform.tfvars.example terraform/eks/terraform.tfvars
cp terraform/eks/backend.hcl.example      terraform/eks/backend.hcl
cp .env.example .env
# 각 파일을 열어 가짜 값을 내 값으로 바꾸기
```

- 같은 값을 `TF_VAR_name_prefix` 처럼 **`TF_VAR_<변수 이름>` 환경변수**로 넘겨도 됩니다.
- `name_prefix`가 모든 리소스 이름의 앞부분(`<접두사>-eks`, `<접두사>-logs` …)이 됩니다. **배포한 뒤에 바꾸면 리소스가 모두 새로 만들어지니** 처음에 정하고 그대로 두세요.

## 배포

```bash
cd terraform/eks

# 1) 상태 백엔드 초기화 (버킷 이름은 backend.hcl 에서 읽음)
terraform init -backend-config=backend.hcl

# 2) ALB 로그를 Loki 로 보내는 Lambda 의 실행 파일을 직접 받아 둠 (git 에는 없음)
#    Grafana lambda-promtail v1.0.2 (x86_64, 안에 bootstrap 한 개) 를 아래 이름으로 저장
mkdir -p lambda      # → lambda/lambda-promtail-v1.0.2.zip

# 3) 만들 것 확인 후 적용 (노드·RDS 때문에 보통 20~30분)
terraform plan
terraform apply

# 4) kubectl 연결
$(terraform output -raw kubeconfig_command)
kubectl get nodes
```

`apply` 끝에 `alb_hostname`, `cluster_name`, `grafana_port_forward` 같은 출력이 나옵니다. 비밀번호는 `<sensitive>`로 가려져 있습니다.

- `enable_database = false` 로 두면 RDS 를 만들지 않는 **가벼운 모드**입니다(회원 API 는 500, 파일 API 는 동작). 그 경우 Grafana 의 RDS 로그 패널은 비어 있습니다.
- 노드는 기본 `t3.large` 3대(`node_instance_types`, `node_desired_size` 로 바꿈)입니다.

### 로컬에서만 돌려 보기

```bash
cp .env.example .env     # DB_PASSWORD 를 정함
docker compose up -d --build
python -m http.server 5500 --directory front-end/member   # http://localhost:5500
```

## 1단계 자료 → 우리 구성 (kube-prometheus-stack)

| 강의 자료 | 이 저장소 |
|---|---|
| `helm repo add` + `helm install prometheus … -f values.yaml` | `monitoring.tf` 의 `helm_release.prometheus` (차트 버전 고정) |
| Grafana `adminPassword: "admin"` | **20자 무작위 비밀번호** (`random_password`). `terraform output -raw grafana_admin_password` 로 확인 |
| Grafana Service `NodePort 30000` | **ClusterIP** (노드가 프라이빗 서브넷이라 `port-forward` 로 접속) |
| `serviceMonitorSelectorNilUsesHelmValues: false`, `podMonitorSelector…: false` | 같음. 라벨 오타로 ServiceMonitor 연동이 실패하는 것을 막음 |
| `retention: 7d` | 같음 |
| `storageSpec`(영구 볼륨, 기본 주석) | **켜지 않음.** Prometheus 는 파드가 다시 뜨면 지표가 비워짐 |
| 컨트롤 플레인 수집 | `kubeEtcd`, `kubeScheduler`, `kubeControllerManager` 는 EKS 가 관리해서 끔 |

설치 확인은 자료와 같습니다.

```bash
kubectl get pods -n monitoring                     # 모두 Running, READY 가 모두 찬 상태
kubectl get crd | grep monitoring.coreos.com       # alertmanagers, prometheuses, servicemonitors …
```

## 통합 메트릭 자료 → 우리 구성

| 강의 자료 (단계) | 이 저장소 |
|---|---|
| 3. IAM 정책·역할 (IRSA) | `monitoring.tf` 에서 Grafana 용(CloudWatch 지표·로그 조회), Alloy 용(CloudWatch 지표 읽기·태그 검색) 역할을 서비스 계정에 연결 |
| 4. Alloy 설치 | `helm_release.alloy_metrics`: **Deployment 1개**(CloudWatch 수집이 노드마다 중복되지 않게). 설정은 `alloy-config.alloy.tftpl` |
| 수집 대상 | `AWS/ApplicationELB`, `AWS/EC2`, `AWS/RDS` 지표를 읽어 Prometheus 로 remote write (Prometheus 의 `enableRemoteWriteReceiver` 켬) |
| RDS 찾는 법 | Owner 태그로 걸러 같은 계정의 다른 DB 가 섞이지 않게 함 (`owner_tag` 변수) |
| 6. 데이터 소스 | Prometheus(기본), Alertmanager, **CloudWatch**, **Loki** 가 **코드로 미리 등록**됨 |
| 7. 대시보드 `EKS Integrated Metrics` | **이 저장소에는 없음.** 자료의 7장대로 화면에서 만들고, 만든 뒤 JSON 으로 내보내 둘 것 (아래 주의 참고) |

## 로그 (직접 추가한 부분)

| 로그 | 경로 | Loki 에서 찾는 법 |
|---|---|---|
| Pod 로그(nginx 포함) | `alloy-logs` DaemonSet → Loki | `{namespace="…", pod="…"}`, `{app="nginx", stream="stdout"}` |
| 노드 로그(systemd) | 같은 DaemonSet | `{job="node/journal", unit="kubelet.service"}` |
| K8s 이벤트 | `alloy-metrics` → Loki | `{job="kubernetes-events"} \| logfmt \| type="Warning"` |
| ALB 액세스 로그 | ALB → S3 `alb/` → S3 알림 → Lambda(VPC 안) → 내부 NLB → Loki | `{job="alb-logs"}` |
| EKS 컨트롤 플레인 | CloudWatch Logs (7일 보관) | Grafana 의 CloudWatch 데이터 소스 |
| RDS 슬로우쿼리·에러 | CloudWatch Logs | 같음 |
| VPC Flow, S3 접근 로그 | S3 logs 버킷 (`vpc-flow/`, `s3-access/`) | Loki 로는 보내지 않음 |

ALB 로그 한 줄은 공백으로 구분된 고정 형식이라 `pattern` 파서로 칸을 나눕니다.

```
{job="alb-logs"} | pattern `<type> <ts> <elb> <client>:<cport> <target> <req_t> <target_t> <resp_t> <elb_status> <target_status> <rx> <tx> "<method> <url> <proto>" "<ua>" <_>`
```

### Grafana 로그 대시보드

`grafana-dashboard.tf` 가 `monitoring` 네임스페이스에 **ConfigMap**(`grafana_dashboard: "1"` 라벨)을 만들면, Grafana 파드의 대시보드 사이드카(모든 네임스페이스 감시)가 읽어서 **재시작 없이** 등록합니다. 제목은 `EKS Integrated Logs` 이고 행 5개, 패널 34개입니다.

| 행 | 데이터 | 내용 |
|---|---|---|
| 1. Ingress ALB | Loki | 상태 코드별 추이, 5xx, 느린 URL, 요청 많은 클라이언트 |
| 2. RDS | CloudWatch Logs | 슬로우쿼리 추이·Top 20, 에러, 접속 거부 |
| 3. EKS 컨트롤 플레인·이벤트 | CloudWatch Logs + Loki | 변경 이력, 403, 인증 실패, Warning 이벤트 |
| 4. 노드 | Loki | 에러 추이, kubelet/containerd 에러, 커널 OOM |
| 5. Pod / Nginx | Loki | 로그량, 에러 많은 Pod, 상태 코드 분포, 4xx/5xx 비율 |

변수는 `namespace`, `pod`, `node`, `search`(검색어)입니다. CloudWatch 패널은 조회할 때마다 비용이 조금 들어서 자동 새로고침을 꺼 두었습니다.

## Grafana 접속

```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80     # 켜 둔 채로 두기
terraform output -raw grafana_admin_password; echo                    # terraform/eks 에서
```

브라우저에서 `http://localhost:3000`, 아이디 `admin`. 포트가 이미 쓰이면 `30000:80` 처럼 다른 번호를 씁니다.
읽기만 하는 확인 하나: 등록된 데이터 소스 목록.

```bash
curl -s -u admin:"$GRAFANA_PW" http://localhost:3000/api/datasources | jq -r '.[] | [.name,.type,.uid] | @tsv'
```

## 알아 둘 점

- **Grafana 와 Prometheus 는 영구 저장소가 없습니다.** 파드가 다시 뜨면(재시작, 노드 교체) Grafana 는 화면에서 바꾼 비밀번호와 직접 만든 대시보드가 사라지고 처음 비밀번호로 돌아오며, Prometheus 의 지표도 지워집니다. 코드로 등록한 데이터 소스와 로그 대시보드(ConfigMap)는 다시 생깁니다. 직접 만든 대시보드는 **Export → JSON** 으로 내보내 두거나, 같은 방식의 ConfigMap 으로 코드에 넣으세요.
- Loki 로그는 gp3 디스크(PVC)에 있어서 Grafana 가 재시작해도 남습니다.
- 노드 그룹은 인스턴스 타입이 바뀌면 **새로 만들어지고 옛 것이 지워집니다.** 파드가 옮겨 가는 동안 앱이 잠깐 끊깁니다. 사용한 EKS 모듈은 노드 그룹 생성 후 `desired_size` 변경을 무시하므로, 대수만 바꿀 때는 `aws eks update-nodegroup-config` 로 직접 바꿉니다.
- 상태 파일은 S3 에 있고(`terraform/eks`), `terraform/` 의 EC2 스택은 로컬 `terraform.tfstate` 를 씁니다. 로컬 상태 파일은 git 에 없으니 따로 보관하세요.
- Lambda 가 VPC 안에서 만든 네트워크 인터페이스는 함수를 지운 뒤에도 한참 남아서, `destroy` 때 그 보안 그룹이 바로 안 지워질 수 있습니다. 시간이 지나면 풀립니다.
- ALB 로그는 S3 알림을 건 **뒤에 생긴 파일**만 Loki 로 갑니다. 이전 파일을 한꺼번에 넣지는 않습니다. 시험으로 파일을 자기 자신에게 복사해 알림을 일으킬 수는 있지만, 같은 로그가 중복으로 들어갑니다.
- 노드 3대(t3.large)와 NAT 인스턴스, RDS 가 계속 요금을 냅니다. 쓰지 않을 때는 정리하세요.

## 정리

```bash
cd terraform/eks
terraform destroy
```

Ingress(ALB)와 LB Controller 가 먼저 지워져야 VPC 가 지워집니다. 코드에 순서가 걸려 있으니 중간에 끊지 마세요. 상태 저장 S3 버킷은 Terraform 밖에서 만든 것이라 지워지지 않습니다.

## git 에 올리지 않는 것

`*.tfstate*`, `tfplan*`, `.terraform/`, `*.tfvars`, `backend.hcl`, `.env`, `terraform/eks/lambda/*.zip`. 저장소를 공개로 바꾸기 전에는 `git log -p` 로 과거 커밋에도 개인 값이 없는지 한 번 더 확인하세요.
