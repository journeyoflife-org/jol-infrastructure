package enforce_resource_limits

import rego.v1

test_deny_init_container_without_limits if {
  count(deny) > 0 with input as {
    "spec": {
      "containers": [{"name": "app", "resources": {"limits": {"cpu": "1", "memory": "1Gi"}, "requests": {"cpu": "100m", "memory": "128Mi"}}}],
      "initContainers": [{"name": "init"}]
    }
  }
}

test_allow_multi_container_with_limits if {
  count(deny) == 0 with input as {
    "spec": {
      "containers": [
        {"name": "app", "resources": {"limits": {"cpu": "1", "memory": "1Gi"}, "requests": {"cpu": "100m", "memory": "128Mi"}}},
        {"name": "sidecar", "resources": {"limits": {"cpu": "500m", "memory": "512Mi"}, "requests": {"cpu": "50m", "memory": "64Mi"}}}
      ]
    }
  }
}
