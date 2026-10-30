// 이 페이지는 내 PC에서 http://localhost:5500 으로 열어서 사용 (예: python -m http.server 5500)
// 로컬 docker compose 로 테스트할 때는 아래 값 그대로,
// AWS(EKS)에 배포했다면 terraform 출력 alb_hostname 으로 변경: "http://<alb_hostname>"
// 모든 화면이 이 파일의 주소를 같이 쓰므로 여기 한 곳만 바꾸면 됩니다.
const API_BASE_URL = "http://localhost:8000";

// 서버 오류 응답(detail)을 읽을 수 있는 문자열로 변환 (입력값 오류 422 는 detail 이 배열로 옴)
function errorDetail(result) {
  if (!result || !result.detail) return "알 수 없는 오류";
  if (Array.isArray(result.detail)) {
    return result.detail.map(function (d) { return d.msg; }).join(", ");
  }
  return result.detail;
}
