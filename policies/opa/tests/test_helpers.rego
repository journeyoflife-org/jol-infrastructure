package test_helpers

import rego.v1

# Shared test fixtures for OPA policy tests

mock_pod(name) := {
  "metadata": {"name": name, "namespace": "default"},
  "spec": {
    "securityContext": {"runAsNonRoot": true},
    "containers": [{
      "name": "app",
      "securityContext": {
        "allowPrivilegeEscalation": false,
        "readOnlyRootFilesystem": true,
        "capabilities": {"drop": ["ALL"]}
      },
      "resources": {
        "limits": {"cpu": "500m", "memory": "512Mi"},
        "requests": {"cpu": "100m", "memory": "128Mi"}
      }
    }]
  }
}

mock_cluster_role_binding(name, role) := {
  "kind": "ClusterRoleBinding",
  "metadata": {"name": name},
  "roleRef": {"name": role, "kind": "ClusterRole", "apiGroup": "rbac.authorization.k8s.io"}
}
