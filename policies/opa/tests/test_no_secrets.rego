package enforce_no_secrets_in_terraform

import rego.v1

test_deny_rds_hardcoded_password if {
  count(deny) == 1 with input as {
    "resource_type": "aws_db_instance",
    "name": "my-db",
    "config": {"password": "SuperSecret123!"}
  }
}

test_allow_rds_variable_password if {
  count(deny) == 0 with input as {
    "resource_type": "aws_db_instance",
    "name": "my-db",
    "config": {"password": "var.db_password"}
  }
}

test_allow_ssm_reference if {
  count(deny) == 0 with input as {
    "resource_type": "aws_secretsmanager_secret_version",
    "name": "my-secret",
    "config": {"secret_string": "data.aws_ssm_parameter.secret.value"}
  }
}
