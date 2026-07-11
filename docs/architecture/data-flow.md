# Data Flow Architecture

## Application Data Flow

```
User Browser
  │
  ▼ HTTPS (TLS 1.3)
ALB (Public Tier)
  │
  ├──▶ jol-frontend (React/Vue)
  │     └──▶ API calls to jol-backend
  │
  ├──▶ jol-backend (Django)
  │     ├──▶ RDS PostgreSQL (DB Tier)
  │     ├──▶ ElastiCache Redis (DB Tier)
  │     ├──▶ S3 (file uploads, media)
  │     └──▶ External APIs (payment, email)
  │
  ├──▶ jol-commerce
  │     ├──▶ RDS PostgreSQL (DB Tier)
  │     └──▶ Payment Gateway (external)
  │
  └──▶ jol-analytics (Airflow)
        ├──▶ RDS PostgreSQL (read replica)
        ├──▶ S3 (data lake)
        └──▶ dbt transformations
```

## Data Classification

| Category | Examples | Encryption | Access Control |
|----------|----------|-----------|----------------|
| Public | Static assets, docs | TLS in transit | ALB |
| Internal | Application configs | TLS + KMS | IRSA |
| Confidential | User data, orders | TLS + KMS + app-level | IRSA + DB auth |
| Restricted | Payment tokens, secrets | TLS + KMS + Vaultwarden | ESO + NetworkPolicy |

## GDPR Data Flows
- Personal data (names, emails) → RDS (encrypted) → backup → S3 (encrypted)
- Payment data → never stored locally → direct to payment processor
- Analytics → anonymized aggregation only → no PII in analytics DB
