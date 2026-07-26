package enforce_pod_security

import rego.v1

test_deny_privileged_container if {
	count(deny) > 0 with input as {
		"metadata": {"name": "priv-pod"},
		"spec": {
			"securityContext": {"runAsNonRoot": true},
			"containers": [{
				"name": "evil",
				"securityContext": {
					"privileged": true,
					"allowPrivilegeEscalation": true,
					"readOnlyRootFilesystem": false,
					"capabilities": {"drop": ["ALL"], "add": ["NET_ADMIN"]},
				},
			}],
		},
	}
}

test_deny_root_user if {
	count(deny) > 0 with input as {
		"metadata": {"name": "root-pod"},
		"spec": {
			"containers": [{
				"name": "app",
				"securityContext": {
					"runAsUser": 0,
					"allowPrivilegeEscalation": false,
					"readOnlyRootFilesystem": true,
					"capabilities": {"drop": ["ALL"]},
				},
			}],
		},
	}
}
