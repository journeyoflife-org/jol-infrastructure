package enforce_resource_limits

import rego.v1

# All containers must have CPU and memory limits
deny contains msg if {
  container := input.spec.containers[_]
  not container.resources.limits.cpu
  msg := sprintf("Container '%s' must specify CPU limits", [container.name])
}

deny contains msg if {
  container := input.spec.containers[_]
  not container.resources.limits.memory
  msg := sprintf("Container '%s' must specify memory limits", [container.name])
}

# All containers must have CPU and memory requests
deny contains msg if {
  container := input.spec.containers[_]
  not container.resources.requests.cpu
  msg := sprintf("Container '%s' must specify CPU requests", [container.name])
}

deny contains msg if {
  container := input.spec.containers[_]
  not container.resources.requests.memory
  msg := sprintf("Container '%s' must specify memory requests", [container.name])
}

test_deny_no_limits if {
  count(deny) > 0 with input as {
    "spec": {"containers": [{"name": "app"}]}
  }
}

test_allow_with_limits if {
  count(deny) == 0 with input as {
    "spec": {"containers": [{"name": "app", "resources": {"limits": {"cpu": "500m", "memory": "512Mi"}, "requests": {"cpu": "100m", "memory": "128Mi"}}}]}
  }
}
