# Terraform Remote Backend & State Locking Bootstrap Guide

This document outlines the mandatory process for configuring remote state storage and state locking for all new and existing Terraform root modules in the RemitMortgage repository.

## Overview

To prevent state file corruption caused by concurrent `terraform apply` or `terraform plan` executions across developer machines and CI pipelines, every Terraform root module MUST configure:
1. An **Amazon S3 Bucket** for encrypted remote state storage.
2. An **Amazon DynamoDB Table** for state locking (`dynamodb_table`).

---

## Standard Backend Configuration Template

Add the following block at the top of your module's `main.tf` (inside the `terraform {}` block):

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "remit-mortgage-terraform-state"
    key            = "<MODULE_PATH>/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "remit-mortgage-terraform-locks"
    encrypt        = true
  }
}
```

Replace `<MODULE_PATH>` with the relative module path (e.g., `infrastructure/new-service/terraform.tfstate`).

---

## One-Time Infrastructure Bootstrap Process

If establishing a new environment from scratch, provision the S3 bucket and DynamoDB lock table prior to running `terraform init`:

```bash
# 1. Create S3 Bucket for State Storage
aws s3api create-bucket \
  --bucket remit-mortgage-terraform-state \
  --region us-east-1

# Enable Versioning for State Recovery
aws s3api put-bucket-versioning \
  --bucket remit-mortgage-terraform-state \
  --versioning-configuration Status=Enabled

# Enable Server-Side Encryption
aws s3api put-bucket-encryption \
  --bucket remit-mortgage-terraform-state \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'

# 2. Create DynamoDB Table for State Locking
aws dynamodb create-table \
  --table-name remit-mortgage-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

---

## Automated CI Enforcement

A CI check automatically runs on every pull request targeting `*.tf` files via `.github/workflows/terraform-backend-check.yml`. Any pull request introducing a module without a remote backend or state locking will fail CI review.
