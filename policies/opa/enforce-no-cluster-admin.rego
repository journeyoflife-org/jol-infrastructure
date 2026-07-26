package enforce_no_cluster_admin

import rego.v1

# Deny ClusterRoleBinding that grants cluster-admin
deny contains msg if {
	input.kind == "ClusterRoleBinding"
	input.roleRef.name == "cluster-admin"
	msg := sprintf("ClusterRoleBinding '%s' must not bind cluster-admin role", [input.metadata.name])
}

# Deny RoleBinding that references cluster-admin in any namespace
deny contains msg if {
	input.kind == "RoleBinding"
	input.roleRef.name == "cluster-admin"
	msg := sprintf("RoleBinding '%s' must not bind cluster-admin role", [input.metadata.name])
}

# Tests
test_deny_cluster_admin_crb if {
	count(deny) == 1 with input as {
		"kind": "ClusterRoleBinding",
		"metadata": {"name": "admin-binding"},
		"roleRef": {"name": "cluster-admin"},
	}
}

test_allow_non_admin_crb if {
	count(deny) == 0 with input as {
		"kind": "ClusterRoleBinding",
		"metadata": {"name": "reader-binding"},
		"roleRef": {"name": "monitoring-reader"},
	}
}
