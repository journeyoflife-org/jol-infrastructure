package enforce_resource_limits

import rego.v1

# All containers (regular + init) must have CPU and memory limits
deny contains msg if {
	container := pod_containers[_]
	not container.resources.limits.cpu
	msg := sprintf("Container '%s' must specify CPU limits", [container.name])
}

deny contains msg if {
	container := pod_containers[_]
	not container.resources.limits.memory
	msg := sprintf("Container '%s' must specify memory limits", [container.name])
}

# All containers (regular + init) must have CPU and memory requests
deny contains msg if {
	container := pod_containers[_]
	not container.resources.requests.cpu
	msg := sprintf("Container '%s' must specify CPU requests", [container.name])
}

deny contains msg if {
	container := pod_containers[_]
	not container.resources.requests.memory
	msg := sprintf("Container '%s' must specify memory requests", [container.name])
}

# Helper: iterate over both regular containers and init containers
pod_containers contains container if {
	container := input.spec.containers[_]
}

pod_containers contains container if {
	container := input.spec.initContainers[_]
}

test_deny_no_limits if {
	count(deny) > 0 with input as {
		"spec": {"containers": [{"name": "app"}]},
	}
}

test_allow_with_limits if {
	count(deny) == 0 with input as {
		"spec": {"containers": [{"name": "app", "resources": {"limits": {"cpu": "500m", "memory": "512Mi"}, "requests": {"cpu": "100m", "memory": "128Mi"}}}]},
	}
}
