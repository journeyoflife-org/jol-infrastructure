package enforce_pod_security

import rego.v1

# Pods must run as non-root
deny contains msg if {
  not input.spec.securityContext.runAsNonRoot
  msg := sprintf("Pod '%s' must set runAsNonRoot: true", [input.metadata.name])
}

# Containers must not allow privilege escalation
deny contains msg if {
  container := input.spec.containers[_]
  not container.securityContext.allowPrivilegeEscalation == false
  msg := sprintf("Container '%s' must set allowPrivilegeEscalation: false", [container.name])
}

# Containers must drop ALL capabilities
deny contains msg if {
  container := input.spec.containers[_]
  caps := container.securityContext.capabilities.drop
  not "ALL" in {caps[_]}
  msg := sprintf("Container '%s' must drop ALL capabilities", [container.name])
}

# Containers must use read-only root filesystem
deny contains msg if {
  container := input.spec.containers[_]
  not container.securityContext.readOnlyRootFilesystem
  msg := sprintf("Container '%s' must set readOnlyRootFilesystem: true", [container.name])
}

test_deny_privileged if {
  count(deny) > 0 with input as {
    "metadata": {"name": "test"},
    "spec": {
      "containers": [{"name": "app", "securityContext": {}}]
    }
  }
}

test_allow_secure_pod if {
  count(deny) == 0 with input as {
    "metadata": {"name": "test"},
    "spec": {
      "securityContext": {"runAsNonRoot": true},
      "containers": [{
        "name": "app",
        "securityContext": {
          "allowPrivilegeEscalation": false,
          "readOnlyRootFilesystem": true,
          "capabilities": {"drop": ["ALL"]}
        }
      }]
    }
  }
}
