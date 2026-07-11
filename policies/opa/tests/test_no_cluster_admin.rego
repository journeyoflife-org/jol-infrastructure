package enforce_no_cluster_admin

import rego.v1

# Additional edge-case tests

test_deny_wildcard_admin if {
  count(deny) == 1 with input as {
    "kind": "ClusterRoleBinding",
    "metadata": {"name": "wildcard-admin"},
    "roleRef": {"name": "cluster-admin", "kind": "ClusterRole"}
  }
}

test_allow_viewer_role if {
  count(deny) == 0 with input as {
    "kind": "ClusterRoleBinding",
    "metadata": {"name": "viewer-binding"},
    "roleRef": {"name": "view", "kind": "ClusterRole"}
  }
}

test_deny_namespaced_admin_binding if {
  count(deny) == 1 with input as {
    "kind": "RoleBinding",
    "metadata": {"name": "ns-admin", "namespace": "kube-system"},
    "roleRef": {"name": "cluster-admin", "kind": "ClusterRole"}
  }
}
