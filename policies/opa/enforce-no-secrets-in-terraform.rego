package enforce_no_secrets_in_terraform

import rego.v1

# Deny hardcoded sensitive values in Terraform variables
deny contains msg if {
	input.resource_type == "aws_secretsmanager_secret_version"
	secret_string := input.config.secret_string
	not startswith(secret_string, "var.")
	not startswith(secret_string, "data.")
	msg := sprintf("Secret '%s' must use a variable or data source, not a hardcoded value", [input.name])
}

# Deny password in RDS instances
deny contains msg if {
	input.resource_type == "aws_db_instance"
	password := input.config.password
	not startswith(password, "var.")
	not startswith(password, "data.")
	msg := sprintf("RDS instance '%s' password must use a variable reference", [input.name])
}

test_deny_hardcoded_secret if {
	count(deny) == 1 with input as {
		"resource_type": "aws_secretsmanager_secret_version",
		"name": "my-secret",
		"config": {"secret_string": "super-secret-value"},
	}
}

test_allow_variable_secret if {
	count(deny) == 0 with input as {
		"resource_type": "aws_secretsmanager_secret_version",
		"name": "my-secret",
		"config": {"secret_string": "var.secret_value"},
	}
}
