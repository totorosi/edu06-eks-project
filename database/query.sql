USE testdb;

CREATE TABLE IF NOT EXISTS members (
    id INT AUTO_INCREMENT COMMENT '회원 고유 식별자 (PK)',
    name VARCHAR(50) NOT NULL COMMENT '이름',
    email VARCHAR(100) NOT NULL UNIQUE COMMENT '이메일 주소 (로그인 ID 겸용)',
    passwd VARCHAR(255) NOT NULL COMMENT '비밀번호 (해시 저장 권장)',
    birth_date DATE NULL COMMENT '출생일 (YYYY-MM-DD)',
    gender ENUM('M', 'F', 'OTHER') NULL COMMENT '성별 (남성: M, 여성: F, 기타: OTHER)',
    phone VARCHAR(20) NULL COMMENT '연락처 ("-" 포함 또는 숫자만)',
    address VARCHAR(255) NULL COMMENT '주소',
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' COMMENT '회원 상태 (ACTIVE: 활동, INACTIVE: 휴면, WITHDRAWN: 탈퇴)',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT '가입일시',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '정보 수정일시',
    PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci COMMENT = '회원 정보 테이블';