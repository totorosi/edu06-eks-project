import hashlib
import json
import logging
import os
import ssl
import boto3
import pymysql
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, File, HTTPException, Query, UploadFile, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from urllib.parse import quote
from pydantic import BaseModel, EmailStr, Field
from typing import Optional, List, Dict, Any, Literal
from datetime import date

logger = logging.getLogger("member-api")


def hash_password(passwd: str) -> str:
    """scrypt 로 비밀번호를 해시합니다. 저장 형식: scrypt$<salt hex>$<hash hex>"""
    salt = os.urandom(16)
    digest = hashlib.scrypt(passwd.encode("utf-8"), salt=salt, n=2**14, r=8, p=1)
    return f"scrypt${salt.hex()}${digest.hex()}"


# ==========================================
# 1. 데이터베이스 리포지토리 클래스 정의
# ==========================================
class MemberRepository:
    def __init__(self, host: str, user: str, password: str, database: str,
                 use_ssl: bool = False, ssl_ca: Optional[str] = None,
                 ssl_verify: bool = True, secret_arn: Optional[str] = None):
        self.host = host
        self.user = user
        self.password = password
        self.database = database
        self.use_ssl = use_ssl          # RDS Proxy 는 TLS 필수
        self.ssl_ca = ssl_ca            # 비우면 시스템 CA 사용
        self.ssl_verify = ssl_verify
        self.secret_arn = secret_arn    # 있으면 사용자/비밀번호를 Secrets Manager 에서 읽음
        self._secret_loaded = False

    def _load_secret(self):
        """Secrets Manager 에서 DB 사용자/비밀번호를 읽습니다. (비밀번호가 바뀌면 다시 호출)"""
        client = boto3.client("secretsmanager")
        secret = json.loads(client.get_secret_value(SecretId=self.secret_arn)["SecretString"])
        self.user = secret["username"]
        self.password = secret["password"]
        self._secret_loaded = True

    def _ssl_context(self):
        ctx = ssl.create_default_context(cafile=self.ssl_ca)
        if not self.ssl_verify:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        return ctx

    def _connect(self):
        return pymysql.connect(
            host=self.host,
            user=self.user,
            password=self.password,
            database=self.database,
            charset="utf8mb4",
            cursorclass=pymysql.cursors.DictCursor,
            ssl=self._ssl_context() if self.use_ssl else None
        )

    def _get_connection(self):
        """내부용: MySQL 커넥션을 생성하여 반환합니다."""
        if self.secret_arn and not self._secret_loaded:
            self._load_secret()
        try:
            return self._connect()
        except pymysql.err.OperationalError as e:
            # 비밀번호가 바뀐 경우(로테이션): 시크릿을 다시 읽고 한 번만 재시도
            if self.secret_arn and e.args and e.args[0] == 1045:
                self._load_secret()
                return self._connect()
            raise

    def check_connection(self) -> str:
        """데이터베이스 연결 테스트 및 버전 반환"""
        connection = self._get_connection()
        try:
            with connection.cursor() as cursor:
                cursor.execute("SELECT VERSION() as version;")
                result = cursor.fetchone()
                return result.get("version")
        finally:
            connection.close()

    def get_all_members(self, limit: int, offset: int) -> List[Dict[str, Any]]:
        """회원 목록 조회 쿼리 실행"""
        connection = self._get_connection()
        try:
            with connection.cursor() as cursor:
                sql = """
                    SELECT id, name, email, birth_date, gender, phone, address, status, created_at, updated_at
                    FROM members
                    ORDER BY id
                    LIMIT %s OFFSET %s
                """
                cursor.execute(sql, (limit, offset))
                members = cursor.fetchall()
                
                # 날짜 객체 문자열 변환
                for m in members:
                    if m.get('birth_date'):
                        m['birth_date'] = str(m['birth_date'])
                    if m.get('created_at'):
                        m['created_at'] = str(m['created_at'])
                    if m.get('updated_at'):
                        m['updated_at'] = str(m['updated_at'])
                        
                return members
        finally:
            connection.close()

    def email_exists(self, email: str) -> bool:
        """이메일 중복 확인 쿼리 실행"""
        connection = self._get_connection()
        try:
            with connection.cursor() as cursor:
                sql = "SELECT id FROM members WHERE email = %s"
                cursor.execute(sql, (email,))
                return cursor.fetchone() is not None
        finally:
            connection.close()

    def insert_member(self, member) -> int:
        """회원 레코드 삽입 쿼리 실행"""
        connection = self._get_connection()
        try:
            with connection.cursor() as cursor:
                sql = """
                    INSERT INTO members (name, email, passwd, birth_date, gender, phone, address, status)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """
                cursor.execute(sql, (
                    member.name,
                    member.email,
                    hash_password(member.passwd),
                    member.birth_date,
                    member.gender,
                    member.phone,
                    member.address,
                    member.status
                ))
                connection.commit()
                return cursor.lastrowid
        except Exception as e:
            connection.rollback()
            raise e
        finally:
            connection.close()


# ==========================================
# 2. FastAPI 앱 및 인스턴스 초기화
# ==========================================
app = FastAPI(title="Member API", version="1.0")

# CORS_ORIGINS: 허용할 프론트 주소를 쉼표로 구분 (예: http://example.com,http://localhost:8080)
# 쿠키/인증 정보를 쓰지 않으므로 allow_credentials 는 켜지 않습니다.
cors_origins = [o.strip() for o in os.getenv("CORS_ORIGINS", "*").split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type"],
)

# 데이터베이스 레포지토리 객체 생성 (설정은 환경변수로 주입)
# - DB_SECRET_ARN 이 있으면 사용자/비밀번호를 Secrets Manager 에서 읽음 (EKS + RDS Proxy)
# - 없으면 DB_PASSWORD 가 필수 (로컬 docker compose)
# - DB_SSL=true 면 TLS 로 접속 (RDS Proxy)
secret_arn = os.getenv("DB_SECRET_ARN")
db_repo = MemberRepository(
    host=os.getenv("DB_HOST", "app-mysql"),
    user=os.getenv("DB_USER", "appuser"),
    password="" if secret_arn else os.environ["DB_PASSWORD"],
    database=os.getenv("DB_NAME", "testdb"),
    use_ssl=os.getenv("DB_SSL", "false").lower() == "true",
    ssl_ca=os.getenv("DB_SSL_CA") or None,
    ssl_verify=os.getenv("DB_SSL_VERIFY", "true").lower() == "true",
    secret_arn=secret_arn
)

# S3 (파일 업로드/다운로드). S3_BUCKET 이 없으면 파일 API 는 503 을 반환합니다.
# EKS 에서는 서비스 계정(IRSA)으로 자격 증명이 자동 주입되므로 키를 코드/환경변수에 넣지 않습니다.
S3_BUCKET = os.getenv("S3_BUCKET")
MAX_UPLOAD_BYTES = int(os.getenv("MAX_UPLOAD_MB", "10")) * 1024 * 1024
s3_client = boto3.client("s3")


# ==========================================
# 3. Pydantic 모델 (Request Validation)
# ==========================================
class MemberCreate(BaseModel):
    name: str = Field(..., max_length=50)
    email: EmailStr = Field(..., max_length=100)
    passwd: str = Field(..., max_length=255)
    birth_date: Optional[date] = None
    gender: Optional[str] = Field(None, pattern="^(M|F|OTHER)$")
    phone: Optional[str] = Field(None, max_length=20)
    address: Optional[str] = Field(None, max_length=255)
    status: Literal["ACTIVE", "INACTIVE", "WITHDRAWN"] = "ACTIVE"


# ==========================================
# 4. 엔드포인트 정의
# ==========================================

@app.get("/health")
def health():
    """프로세스 상태 확인 (DB 미접속, 로드밸런서 헬스체크용)"""
    return {"status": "ok"}

@app.get("/")
def check_db_connection():
    """데이터베이스 연결 확인 엔드포인트"""
    try:
        db_version = db_repo.check_connection()
        return {
            "status": "success",
            "message": "Database connection successful!",
            "db_version": db_version
        }
    except Exception:
        logger.exception("database connection failed")
        raise HTTPException(status_code=500, detail="Database connection failed")

@app.get("/member/list")
def get_member_list(
    limit: int = Query(100, ge=1, le=1000),
    offset: int = Query(0, ge=0),
):
    """회원 목록 조회 엔드포인트"""
    try:
        members = db_repo.get_all_members(limit, offset)
        return {
            "status": "success",
            "data": members
        }
    except Exception:
        logger.exception("failed to list members")
        raise HTTPException(status_code=500, detail="Internal server error")

@app.post("/member/append", status_code=status.HTTP_201_CREATED)
def append_member(member: MemberCreate):
    """회원 등록 엔드포인트"""
    try:
        # 이메일 중복 검사
        if db_repo.email_exists(member.email):
            raise HTTPException(status_code=400, detail="이미 등록된 이메일입니다.")

        # 회원 정보 삽입
        insert_id = db_repo.insert_member(member)
        
        return {
            "status": "success", 
            "data": "append ok",
            "insert_id": insert_id
        }
    except HTTPException as he:
        raise he
    except pymysql.err.IntegrityError as e:
        # 중복 검사 이후 동시에 같은 이메일이 들어온 경우 (UNIQUE 위반)
        if e.args and e.args[0] == 1062:
            raise HTTPException(status_code=400, detail="이미 등록된 이메일입니다.")
        logger.exception("failed to insert member")
        raise HTTPException(status_code=500, detail="Internal server error")
    except Exception:
        logger.exception("failed to insert member")
        raise HTTPException(status_code=500, detail="Internal server error")


# ==========================================
# 5. 파일 업로드/다운로드 (S3)
# ==========================================

def require_s3() -> str:
    """S3 버킷이 설정되어 있는지 확인하고 버킷 이름을 반환합니다."""
    if not S3_BUCKET:
        raise HTTPException(status_code=503, detail="S3 is not configured")
    return S3_BUCKET


def validate_file_key(name: str) -> str:
    """파일 이름 검증: 경로 문자(/, \\), 제어 문자, 빈 이름, '.', '..' 은 허용하지 않습니다."""
    if (not name or len(name) > 200 or name in (".", "..")
            or "/" in name or "\\" in name or any(ord(c) < 32 for c in name)):
        raise HTTPException(status_code=400, detail="올바르지 않은 파일 이름입니다.")
    return name


@app.post("/files", status_code=status.HTTP_201_CREATED)
def upload_file(file: UploadFile = File(...)):
    """파일 업로드 (같은 이름이 이미 있으면 409, 크기 제한은 MAX_UPLOAD_MB)"""
    bucket = require_s3()
    key = validate_file_key(file.filename or "")

    file.file.seek(0, os.SEEK_END)
    size = file.file.tell()
    file.file.seek(0)
    if size > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="파일이 너무 큽니다.")

    try:
        try:
            s3_client.head_object(Bucket=bucket, Key=key)
            raise HTTPException(status_code=409, detail="같은 이름의 파일이 이미 있습니다.")
        except ClientError as e:
            if e.response["Error"]["Code"] not in ("404", "NoSuchKey", "NotFound"):
                raise
        s3_client.upload_fileobj(file.file, bucket, key)
        return {"status": "success", "key": key, "size": size}
    except HTTPException:
        raise
    except (ClientError, BotoCoreError):
        logger.exception("failed to upload file")
        raise HTTPException(status_code=500, detail="Internal server error")


@app.get("/files")
def list_files(limit: int = Query(100, ge=1, le=1000)):
    """업로드된 파일 목록"""
    bucket = require_s3()
    try:
        result = s3_client.list_objects_v2(Bucket=bucket, MaxKeys=limit)
        return {
            "status": "success",
            "data": [
                {"key": o["Key"], "size": o["Size"], "last_modified": o["LastModified"].isoformat()}
                for o in result.get("Contents", [])
            ],
            "is_truncated": result.get("IsTruncated", False),
        }
    except (ClientError, BotoCoreError):
        logger.exception("failed to list files")
        raise HTTPException(status_code=500, detail="Internal server error")


@app.get("/files/{name}")
def download_file(name: str):
    """파일 다운로드 (브라우저가 내용을 실행/렌더링하지 않도록 항상 첨부 파일로 응답)"""
    bucket = require_s3()
    key = validate_file_key(name)
    try:
        obj = s3_client.get_object(Bucket=bucket, Key=key)
    except ClientError as e:
        if e.response["Error"]["Code"] in ("NoSuchKey", "404"):
            raise HTTPException(status_code=404, detail="파일을 찾을 수 없습니다.")
        logger.exception("failed to download file")
        raise HTTPException(status_code=500, detail="Internal server error")
    except BotoCoreError:
        logger.exception("failed to download file")
        raise HTTPException(status_code=500, detail="Internal server error")

    return StreamingResponse(
        obj["Body"].iter_chunks(),
        media_type="application/octet-stream",
        headers={
            "Content-Disposition": f"attachment; filename*=UTF-8''{quote(key)}",
            "Content-Length": str(obj["ContentLength"]),
            "X-Content-Type-Options": "nosniff",
        },
    )