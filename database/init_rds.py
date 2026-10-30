"""RDS 초기화 (쿠버네티스 Job 에서 실행, 여러 번 실행해도 안전)

1. Secrets Manager 에서 마스터 계정과 앱 전용 사용자 정보를 읽는다. (키/비밀번호를 환경변수로 넘기지 않음)
2. 마스터 계정으로 DB 에 접속해서 query.sql(테이블 생성)을 실행한다.
3. 앱 전용 사용자를 만들고(이미 있으면 비밀번호만 시크릿 값으로 맞춤), 이 DB 의 데이터 읽기/쓰기 권한만 준다.
"""
import json
import os
import re
import ssl
import sys
import time

import boto3
import pymysql
from pymysql.constants import CLIENT


def read_secret(arn):
    client = boto3.client("secretsmanager")
    return json.loads(client.get_secret_value(SecretId=arn)["SecretString"])


master = read_secret(os.environ["MASTER_SECRET_ARN"])
app = read_secret(os.environ["APP_SECRET_ARN"])
sql = open(os.environ.get("SQL_FILE", "/init/query.sql"), encoding="utf-8").read()

db_name = app["dbname"]
app_user = app["username"]
if not re.fullmatch(r"\w+", db_name):
    sys.exit("DB 이름이 올바르지 않습니다.")

# VPC 안에서의 접속이므로 암호화(TLS)는 켜되, RDS 인증서(자체 CA)는 검증하지 않는다.
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def connect():
    return pymysql.connect(
        host=master["host"],
        port=int(master.get("port", 3306)),
        user=master["username"],
        password=master["password"],
        ssl=ctx,
        connect_timeout=10,
        charset="utf8mb4",
        client_flag=CLIENT.MULTI_STATEMENTS,
    )


conn = None
for attempt in range(1, 61):
    try:
        conn = connect()
        break
    except Exception as e:  # DB 가 준비될 때까지 최대 10분 대기
        print(f"DB 연결 대기 ({attempt}/60): {type(e).__name__}", flush=True)
        time.sleep(10)
if conn is None:
    sys.exit("DB 에 연결하지 못했습니다.")

with conn.cursor() as cur:
    cur.execute(sql)
    while cur.nextset():  # 여러 문장을 한 번에 실행했으므로 결과를 모두 소비
        pass
    cur.execute("CREATE USER IF NOT EXISTS %s@'%%' IDENTIFIED BY %s", (app_user, app["password"]))
    cur.execute("ALTER USER %s@'%%' IDENTIFIED BY %s", (app_user, app["password"]))
    cur.execute(f"GRANT SELECT, INSERT, UPDATE, DELETE ON `{db_name}`.* TO %s@'%%'", (app_user,))
conn.commit()
conn.close()
print(f"초기화 완료: 테이블 생성, 앱 전용 사용자 '{app_user}' 준비", flush=True)
